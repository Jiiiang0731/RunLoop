import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';

import '../app/config.dart';
import '../models/planned_route.dart';
import '../models/run_record.dart';
import '../models/track_point.dart';
import '../services/run_recorder/run_recorder.dart';
import '../utils/geo.dart' hide haversineMeters;
import '../utils/map_icons.dart';
import '../utils/route_path.dart';
import '../utils/route_style.dart';
import 'run_summary_screen.dart';

/// 跑步中页面（阶段 J 升级）：
/// - 规划路线：白描边 + 渐变主线（与候选页同款视觉）；
/// - GPS 实际轨迹：橙色主线 + 白描边，实时增长（稳定 id 原地更新，不重建）；
/// - 沿线进度：窗口化投影（去/返程重叠腿不串线）→ 进度条 + 剩余里程；
/// - 偏航提示：垂距 > 120m 顶部横幅告警；
/// - 下一转弯：按规划 steps 的累计里程给出「X m 后左转进入 XX 路」；
/// - 相机跟随可开关；跑者标记随 GPS 原地移动。
class RunScreen extends StatefulWidget {
  const RunScreen({super.key, this.plannedRoute, this.targetM});

  final PlannedRoute? plannedRoute;
  final double? targetM;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  /// 偏航判定阈值（米）：集中配置于 AppConfig（决策#6）。
  /// 城市 GPS 误差 ±20~50m，120m 兼顾灵敏与误报；未做长距离实跑标定。
  static const double _offRouteMeters = AppConfig.offRouteMeters;

  /// 投影搜索窗口（米）：只在上次里程 ±250m 内找最近点，避免吸附到重叠的另一条腿。
  static const double _matchWindowM = AppConfig.matchWindowM;

  final RunRecorder _recorder = RunRecorder();
  bool _ending = false;
  AMapController? _controller;
  bool _followCamera = true;

  RoutePath? _plannedPath;
  List<LatLng> _plannedPts = const <LatLng>[];
  double? _lastAlong; // 上次投影里程（map-matching 提示）
  bool _offRoute = false;

  BitmapDescriptor? _runnerIcon;
  BitmapDescriptor? _startIcon;

  @override
  void initState() {
    super.initState();
    final PlannedRoute? route = widget.plannedRoute;
    if (route != null && route.polyline.length >= 2) {
      _plannedPts =
          route.polyline.map((List<double> p) => LatLng(p[1], p[0])).toList();
      _plannedPath = RoutePath.fromPoints(_plannedPts);
    }
    _recorder.start();
    _recorder.addListener(_onRecorderTick);
    _loadIcons();
  }

  @override
  void dispose() {
    _recorder.removeListener(_onRecorderTick);
    if (!_ending) {
      _recorder.end();
    }
    _recorder.dispose();
    _controller = null;
    super.dispose();
  }

  Future<void> _loadIcons() async {
    try {
      final BitmapDescriptor runner =
          await createRunnerIcon(const Color(0xFF1565C0));
      final BitmapDescriptor start = await createStartIcon();
      if (mounted) {
        setState(() {
          _runnerIcon = runner;
          _startIcon = start;
        });
      }
    } catch (_) {
      // 图标失败时退化为系统默认标记。
    }
  }

  /// GPS 更新（约 1Hz）：相机跟随时平移到当前位置。
  void _onRecorderTick() {
    if (!mounted || !_followCamera || _controller == null) return;
    final List<TrackPoint> pts = _recorder.points;
    if (pts.isEmpty) return;
    final TrackPoint last = pts.last;
    _controller!.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(last.latitude, last.longitude),
          zoom: 16.5,
        ),
      ),
      animated: true,
    );
  }

  Future<void> _end() async {
    final RunRecord? record = _recorder.end();
    if (record == null) {
      Navigator.pop(context);
      return;
    }
    setState(() => _ending = true);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RunSummaryScreen(
          record: record,
          plannedRoute: widget.plannedRoute,
        ),
      ),
    );
  }

  // ---------- 地图匹配（沿线进度 / 偏航） ----------

  RouteProjection? _mapMatch(LatLng p) {
    final RoutePath? path = _plannedPath;
    if (path == null) return null;
    RouteProjection proj = path.projectNear(p, _lastAlong, _matchWindowM);
    if (proj.offsetM > _offRouteMeters) {
      // 窗口内找不到（可能抄近路跳到前方）：退回全局投影重新锚定
      final RouteProjection global = path.project(p);
      if (global.offsetM < proj.offsetM) proj = global;
    }
    if (proj.offsetM <= _offRouteMeters) {
      _lastAlong = proj.alongM; // 仅在路线上时更新提示，偏航期间保持锚点
    }
    return proj;
  }

  // ---------- 覆盖物（全部使用稳定 id，插件按 id 原地更新） ----------

  Set<Polyline> _buildPolylines(List<LatLng> trackPts) {
    final Set<Polyline> lines = <Polyline>{};
    if (_plannedPts.length >= 2) {
      lines.add(Polyline(
        points: _plannedPts,
        color: RouteStyle.casingColor,
        width: RouteStyle.casingWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCasing,
      )..setIdForCopy('planned-casing'));
      lines.add(Polyline(
        points: _plannedPts,
        gradient: true,
        colorList: RouteStyle.plannedGradient,
        color: RouteStyle.plannedGradient.first,
        width: RouteStyle.coreWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCore,
      )..setIdForCopy('planned-core'));
    }
    if (trackPts.length >= 2) {
      lines.add(Polyline(
        points: trackPts,
        color: RouteStyle.trackCasingColor,
        width: RouteStyle.trackCasingWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zTrackCasing,
      )..setIdForCopy('track-casing'));
      lines.add(Polyline(
        points: trackPts,
        color: RouteStyle.trackColor,
        width: RouteStyle.trackCoreWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zTrack,
      )..setIdForCopy('track-core'));
    }
    return lines;
  }

  Set<Marker> _buildMarkers(List<LatLng> trackPts) {
    final Set<Marker> markers = <Marker>{};
    if (_plannedPts.isNotEmpty) {
      markers.add(Marker(
        position: _plannedPts.first,
        icon: _startIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        infoWindow: const InfoWindow(title: '起点 / 终点'),
        zIndex: 200,
      )..setIdForCopy('run-start'));
    }
    if (trackPts.isNotEmpty) {
      double rotation = 0;
      if (trackPts.length >= 2) {
        final LatLng a = trackPts[trackPts.length - 2];
        final LatLng b = trackPts.last;
        if (haversineMeters(a, b) > 3) rotation = bearingDeg(a, b);
      }
      markers.add(Marker(
        position: trackPts.last,
        icon: _runnerIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        rotation: rotation,
        zIndex: 300,
      )..setIdForCopy('run-pos'));
    }
    return markers;
  }

  void _onMapCreated(AMapController controller) {
    _controller = controller;
    if (_plannedPts.length >= 2) {
      final List<double> lngs = _plannedPts.map((p) => p.longitude).toList()..sort();
      final List<double> lats = _plannedPts.map((p) => p.latitude).toList()..sort();
      controller.moveCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(lats.first, lngs.first),
            northeast: LatLng(lats.last, lngs.last),
          ),
          40,
        ),
        animated: false,
      );
    } else {
      final List<TrackPoint> pts = _recorder.points;
      if (pts.isNotEmpty) {
        controller.moveCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: LatLng(pts.last.latitude, pts.last.longitude),
              zoom: 16.5,
            ),
          ),
          animated: false,
        );
      }
    }
  }

  // ---------- 导航提示 ----------

  /// 下一转弯提示：规划 steps 中首个在当前位置前方的转向动作。
  _TurnHint? _nextTurnHint(double alongM) {
    final List<RouteStep> steps = widget.plannedRoute?.steps ?? const <RouteStep>[];
    for (final RouteStep s in steps) {
      if (s.cumulativeM <= alongM + 20) continue;
      final IconData? icon = _turnIcons[s.action];
      if (icon == null) continue;
      return _TurnHint(
        icon: icon,
        text: '${_fmtDist(s.cumulativeM - alongM)}后 ${_turnNames[s.action]}'
            '${s.road.isNotEmpty ? ' 进入 ${s.road}' : ''}',
      );
    }
    return null;
  }

  static const Map<String, IconData> _turnIcons = <String, IconData>{
    'left': Icons.turn_left,
    'right': Icons.turn_right,
    'uturn': Icons.u_turn_left,
  };
  static const Map<String, String> _turnNames = <String, String>{
    'left': '左转',
    'right': '右转',
    'uturn': '掉头',
  };

  static String _fmtDist(double m) =>
      m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('跑步中'),
        automaticallyImplyLeading: false,
        actions: <Widget>[
          IconButton(
            tooltip: _followCamera ? '关闭相机跟随' : '开启相机跟随',
            icon: Icon(_followCamera ? Icons.my_location : Icons.location_searching),
            onPressed: () {
              setState(() => _followCamera = !_followCamera);
              if (_followCamera) _onRecorderTick();
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _recorder,
        builder: (BuildContext context, _) {
          final RunState state = _recorder.state;
          final List<TrackPoint> pts = _recorder.points;
          final List<LatLng> trackPts = pts
              .map((TrackPoint p) => LatLng(p.latitude, p.longitude))
              .toList();

          // 地图匹配：进度 / 偏航 / 下一转弯
          RouteProjection? proj;
          if (trackPts.isNotEmpty) {
            proj = _mapMatch(trackPts.last);
          }
          final bool offRoute =
              proj != null && proj.offsetM > _offRouteMeters && pts.length > 3;
          if (offRoute != _offRoute) {
            _offRoute = offRoute;
          }
          final _TurnHint? hint =
              (proj != null && !offRoute) ? _nextTurnHint(proj.alongM) : null;

          final double? targetM = widget.targetM;
          final double progress = (targetM != null && targetM > 0)
              ? (_recorder.distanceMeters / targetM).clamp(0.0, 1.0)
              : 0.0;
          final double? remainPlannedM = (proj != null && _plannedPath != null && !offRoute)
              ? (_plannedPath!.total - proj.alongM)
              : null;

          return Column(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: Stack(
                  children: <Widget>[
                    AMapWidget(
                      apiKey: const AMapApiKey(
                        androidKey: AppConfig.amapAndroidKey,
                        iosKey: AppConfig.amapIosKey,
                      ),
                      privacyStatement: const AMapPrivacyStatement(
                        hasContains: true,
                        hasShow: true,
                        hasAgree: true,
                      ),
                      initialCameraPosition: const CameraPosition(
                        target: LatLng(30.536395, 114.087279),
                        zoom: 15,
                      ),
                      polylines: _buildPolylines(trackPts),
                      markers: _buildMarkers(trackPts),
                      onMapCreated: _onMapCreated,
                    ),
                    if (offRoute)
                      Positioned(
                        top: 10,
                        left: 12,
                        right: 12,
                        child: _Banner(
                          icon: Icons.warning_amber_rounded,
                          color: Colors.deepOrange,
                          text: '已偏离规划路线约 ${proj.offsetM.round()} m，请返回蓝色路线',
                        ),
                      )
                    else if (hint != null)
                      Positioned(
                        top: 10,
                        left: 12,
                        right: 12,
                        child: _Banner(
                          icon: hint.icon,
                          color: const Color(0xFF1565C0),
                          text: hint.text,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(formatKm(_recorder.distanceMeters),
                        style: const TextStyle(fontSize: 56, fontWeight: FontWeight.bold, height: 1.1)),
                    const Text('公里', style: TextStyle(fontSize: 16)),
                    if (targetM != null && targetM > 0) ...<Widget>[
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 36),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 8,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2979FF)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        remainPlannedM != null
                            ? '目标 ${(targetM / 1000).toStringAsFixed(1)} 公里 · 沿规划线还剩约 ${_fmtDist(remainPlannedM)}'
                            : '目标 ${(targetM / 1000).toStringAsFixed(1)} 公里 · 已完成 ${(progress * 100).toStringAsFixed(0)}%',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        _Metric(label: '实时配速', value: formatPace(_recorder.currentPaceSecondsPerKm)),
                        _Metric(label: '平均配速', value: formatPace(_recorder.avgPaceSecondsPerKm)),
                        _Metric(label: '总时长', value: formatDuration(_recorder.durationSeconds)),
                        _Metric(label: '移动时长', value: formatDuration(_recorder.movingSeconds)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        if (state == RunState.running)
                          FilledButton.tonalIcon(
                            onPressed: _recorder.pause,
                            icon: const Icon(Icons.pause),
                            label: const Text('暂停'),
                          )
                        else if (state == RunState.paused)
                          FilledButton.tonalIcon(
                            onPressed: _recorder.resume,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('继续'),
                          ),
                        FilledButton.icon(
                          onPressed: _end,
                          icon: const Icon(Icons.stop),
                          label: const Text('结束'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TurnHint {
  const _TurnHint({required this.icon, required this.text});
  final IconData icon;
  final String text;
}

/// 地图顶部提示横幅（偏航告警 / 下一转弯）。
class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withAlpha(235),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: <Widget>[
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      ],
    );
  }
}
