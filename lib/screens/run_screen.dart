import 'dart:async';

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/config.dart';
import '../models/km_split.dart';
import '../models/planned_route.dart';
import '../models/run_record.dart';
import '../models/track_point.dart';
import '../services/nav/foreground_run_service.dart';
import '../services/nav/heading_controller.dart';
import '../services/nav/nav_announcer.dart';
import '../services/nav/nav_settings.dart';
import '../services/nav/tts_service.dart';
import '../services/run_recorder/run_recorder.dart';
import '../utils/geo.dart' hide haversineMeters;
import '../utils/map_icons.dart';
import '../utils/route_path.dart';
import '../utils/route_style.dart';
import '../widgets/countdown_overlay.dart';
import 'run_summary_screen.dart';

/// 地图朝向模式（阶段 L 模块 D）：预览固定北朝上；跑步开始后默认 Heading-Up。
enum MapOrientation { headingUp, northUp }

/// 跑步中页面（阶段 L 全面升级）：
/// - 开始前三秒环形倒计时，GO 时刻才启动计时（模块 C）；
/// - Heading-Up 相机：跑者居中、前进方向朝上、旋转地图而非图标，
///   GPS course 优先 + 平滑 + 静止冻结 + 手动平移后一键回中（模块 D）；
/// - 语音导航：真实 steps + 窗口化匹配里程驱动播报（模块 A）；
/// - 每公里分段：完成时轻提示 + 播报（模块 B）；
/// - 视觉融合：已跑段低权重蓝灰、剩余段渐变主线、GPS 橙轨在上（模块 E）；
/// - 布局：顶部转弯信息 + 距离，中部地图，底部数据面板与按钮（模块 F）；
/// - 前台服务：GO 时启动 location 型 FGS，锁屏/后台持续（模块 8）。
class RunScreen extends StatefulWidget {
  const RunScreen({super.key, this.plannedRoute, this.targetM});

  final PlannedRoute? plannedRoute;
  final double? targetM;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  /// 偏航判定阈值（米）：集中配置于 AppConfig（决策#6）。
  static const double _offRouteMeters = AppConfig.offRouteMeters;

  /// 投影搜索窗口（米）：只在上次里程 ±250m 内找最近点，避免吸附到重叠的另一条腿。
  static const double _matchWindowM = AppConfig.matchWindowM;

  /// 跑步跟随缩放（比预览更近，看清脚下路线）。
  static const double _runZoom = 17.0;

  final RunRecorder _recorder = RunRecorder();
  final FlutterTtsEngine _tts = FlutterTtsEngine();
  final HeadingController _heading = HeadingController();
  late final NavAnnouncer _announcer = NavAnnouncer(
    engine: _tts,
    config: _SettingsVoiceConfig(),
  );

  bool _ending = false;

  // ---- 倒计时（模块 C）----
  bool _showCountdown = true;
  bool _started = false; // GO 已触发（计时已开始）

  // ---- 相机（模块 D）----
  AMapController? _controller;
  bool _followCamera = true;
  MapOrientation _orientation = MapOrientation.headingUp;
  LatLng? _lastCameraTarget;
  double? _lastCameraBearing;
  double? _lastHeadingAtMs; // 方向平滑的 dt 计算（毫秒时间戳）

  // ---- 路线与匹配 ----
  RoutePath? _plannedPath;
  List<LatLng> _plannedPts = const <LatLng>[];
  double? _lastAlong; // 上次投影里程（map-matching 提示）
  bool _hasFix = false; // 已成功匹配过一次
  double _alongForDraw = 0; // 驱动完成/剩余折线拆分

  // ---- 公里提示（模块 B）----
  int _lastCompletedKm = 0;
  KmSplit? _toastSplit;
  Timer? _toastTimer;

  // ---- TTS 诊断（模块 A，绝不静默失败）----
  String? _ttsProblem;

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
    // 注意：不在这里 start()——倒计时 GO 时刻才开始计时（规范 4.2）。
    _recorder.addListener(_onRecorderTick);
    _loadIcons();
    _initVoice();
  }

  Future<void> _initVoice() async {
    await NavSettings.instance.load();
    if (!mounted) return;
    await _tts.configure(
      rate: NavSettings.instance.speechRate,
      volume: NavSettings.instance.volume,
    );
    if (!mounted) return;
    if (NavSettings.instance.voiceNavEnabled) {
      final TtsDiagnostic d = await _tts.diagnose();
      if (mounted && !d.ok) {
        setState(() => _ttsProblem = d.guidance); // 明确指引，不静默
      }
    }
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _recorder.removeListener(_onRecorderTick);
    if (_started) {
      _announcer.onEnd(); // 结束语音立即停止并清空队列
      if (!_ending) _recorder.end();
      unawaited(ForegroundRunService.stop()); // 释放前台服务/通知
    }
    _recorder.dispose();
    unawaited(_tts.dispose());
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

  // ---------- 倒计时（模块 C） ----------

  /// GO 时刻：跑步计时从这里开始（规范 4.2#2），倒计时不计入成绩。
  void _onCountdownGo() {
    if (_started) return;
    _started = true;
    _recorder.start();
    _announcer.attach(widget.plannedRoute?.steps ?? const <RouteStep>[]);
    unawaited(_startForeground());
  }

  Future<void> _startForeground() async {
    try {
      // Android 13+：通知权限（无权限时 FGS 仍运行，只是通知不可见）。
      await Permission.notification.request();
    } catch (_) {
      // 权限失败不阻断跑步。
    }
    await ForegroundRunService.start();
  }

  void _onCountdownCancel() {
    // 未开始 → 无任何记录产生，直接退出（规范 4.2#4/5）。
    Navigator.pop(context);
  }

  // ---------- 相机与方向（模块 D） ----------

  /// 记录器通知（约 1Hz）：仅在跟随时更新相机；带位置/角度死区防抖，
  /// 不满足阈值就不调用 moveCamera（规范 5.2#4）。
  void _onRecorderTick() {
    if (!mounted || _controller == null || !_followCamera || !_started) return;
    final List<TrackPoint> pts = _recorder.points;
    if (pts.isEmpty) return;
    final TrackPoint last = pts.last;
    final LatLng target = LatLng(last.latitude, last.longitude);
    final double camBearing = _orientation == MapOrientation.headingUp
        ? (_heading.heading ?? _lastCameraBearing ?? 0)
        : 0;
    if (_lastCameraTarget != null) {
      final double moved = haversineMeters(_lastCameraTarget!, target);
      final double rot = HeadingController.shortestDelta(_lastCameraBearing ?? camBearing, camBearing).abs();
      if (moved < 1.5 && rot < 2) return; // 死区：忽略 GPS 抖动
    }
    _controller!.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: target,
          zoom: _runZoom,
          bearing: camBearing, // 旋转地图（2D 顶视，tilt=0，不强制 3D）
          tilt: 0,
        ),
      ),
      animated: true,
    );
    _lastCameraTarget = target;
    _lastCameraBearing = camBearing;
  }

  /// 相机移动结束：与跑者距离过远 ⇒ 判定为用户手动平移 → 暂停跟随，
  /// 显示「回到跑者」按钮（规范 5.2#6）。
  void _onCameraMoveEnd(CameraPosition pos) {
    final List<TrackPoint> pts = _recorder.points;
    if (pts.isEmpty) return;
    final LatLng runner = LatLng(pts.last.latitude, pts.last.longitude);
    if (haversineMeters(pos.target, runner) > 40 && _followCamera) {
      if (mounted) setState(() => _followCamera = false);
    }
  }

  void _recenter() {
    setState(() {
      _followCamera = true;
      _lastCameraTarget = null;
      _lastCameraBearing = null;
    });
    _onRecorderTick();
  }

  void _toggleOrientation() {
    setState(() {
      _orientation = _orientation == MapOrientation.headingUp
          ? MapOrientation.northUp
          : MapOrientation.headingUp;
      _lastCameraTarget = null;
      _lastCameraBearing = null;
    });
    _onRecorderTick();
  }

  // ---------- 暂停 / 继续 / 结束 ----------

  void _pause() {
    _announcer.onPause(); // 先停语音（规范 2.4#5）
    _recorder.pause();
  }

  void _resume() {
    _recorder.resume();
    _announcer.onResume(alongM: _lastAlong ?? _alongForDraw);
  }

  Future<void> _end() async {
    _announcer.onEnd(); // 立即停止并清空语音（规范 2.4#7）
    await ForegroundRunService.stop(); // 释放前台服务、通知、WakeLock
    final RunRecord? record = _recorder.end();
    if (!mounted) return;
    if (record == null) {
      Navigator.pop(context);
      return;
    }
    setState(() => _ending = true);
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

  /// 每帧匹配驱动：方向平滑（模块 D）+ 语音播报（模块 A）+ 公里提示（模块 B）。
  /// 全部幂等：build 多次执行不会重复播报/抖动。
  void _onMatched(RouteProjection? proj, List<TrackPoint> pts, bool offRoute) {
    if (proj != null && !offRoute) {
      _hasFix = true;
      _alongForDraw = proj.alongM;
    }
    if (!_started || pts.isEmpty) return;

    // ---- 方向：GPS course 优先，路线切线兜底，静止冻结 ----
    final TrackPoint last = pts.last;
    final double nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();
    final double dt = _lastHeadingAtMs == null
        ? 1.0
        : ((nowMs - _lastHeadingAtMs!) / 1000.0).clamp(0.05, 5.0);
    _lastHeadingAtMs = nowMs;
    final RoutePath? path = _plannedPath;
    _heading.update(
      speed: last.speed,
      accuracy: last.accuracy,
      gpsBearing: last.bearing,
      routeBearing: (path != null && proj != null && !offRoute)
          ? path.at(proj.alongM).bearing
          : null,
      dtSeconds: dt,
    );

    // ---- 语音导航 ----
    _announcer.onPosition(
      alongM: proj?.alongM ?? _alongForDraw,
      offRoute: offRoute,
    );

    // ---- 公里完成检测（completedKm 变大 = 刚跨过 1000m 边界） ----
    if (_recorder.completedKm > _lastCompletedKm) {
      _lastCompletedKm = _recorder.completedKm;
      final Iterable<KmSplit> full =
          _recorder.kmSplits.where((KmSplit s) => !s.isPartial);
      if (full.isNotEmpty) {
        final KmSplit split = full.last;
        _announcer.onKmSplit(split);
        _toastSplit = split;
        _toastTimer?.cancel();
        _toastTimer = Timer(const Duration(seconds: 4), () {
          if (mounted) setState(() => _toastSplit = null);
        });
      }
    }
  }

  // ---------- 覆盖物（稳定 id，插件按 id 原地增量更新） ----------

  /// 视觉融合（模块 E）：规划线拆成「已跑（低权重蓝灰）」+「剩余（渐变主线）」，
  /// GPS 实际轨迹（橙 + 白描边）压在最上——三者数据各自独立，展示层合成。
  /// 偏航时橙色轨迹离开蓝色剩余线，真实偏离清晰可见，绝不被遮盖。
  Set<Polyline> _buildPolylines(List<LatLng> trackPts) {
    final Set<Polyline> lines = <Polyline>{};
    final RoutePath? path = _plannedPath;
    if (path != null && _plannedPts.length >= 2) {
      List<LatLng> remaining = _plannedPts;
      List<LatLng>? completed;
      if (_hasFix && _started) {
        final double along = _alongForDraw.clamp(0.0, path.total);
        completed = path.upTo(along);
        remaining = path.fromDistance(along);
      }
      if (completed != null && completed.length >= 2) {
        lines.add(Polyline(
          points: completed,
          color: RouteStyle.completedColor,
          width: RouteStyle.completedWidth,
          capType: CapType.round,
          joinType: JoinType.round,
          zIndex: RouteStyle.zCompleted,
        )..setIdForCopy('planned-done'));
      }
      if (remaining.length >= 2) {
        lines.add(Polyline(
          points: remaining,
          color: RouteStyle.casingColor,
          width: RouteStyle.casingWidth,
          capType: CapType.round,
          joinType: JoinType.round,
          zIndex: RouteStyle.zCasing,
        )..setIdForCopy('planned-casing'));
        lines.add(Polyline(
          points: remaining,
          gradient: true,
          colorList: RouteStyle.plannedGradient,
          color: RouteStyle.plannedGradient.first,
          width: RouteStyle.coreWidth,
          capType: CapType.round,
          joinType: JoinType.round,
          zIndex: RouteStyle.zCore,
        )..setIdForCopy('planned-core'));
      }
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
      // Heading-Up：地图已旋转到前进方向朝上 → 图标不转（始终指屏幕上方）；
      // 北朝上：图标按平滑后的方向旋转（无方向时退回轨迹切线）。
      double rotation = 0;
      if (_orientation == MapOrientation.northUp) {
        if (_heading.heading != null) {
          rotation = _heading.heading!;
        } else if (trackPts.length >= 2) {
          final LatLng a = trackPts[trackPts.length - 2];
          final LatLng b = trackPts.last;
          if (haversineMeters(a, b) > 3) rotation = bearingDeg(a, b);
        }
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
      // 预览构图：整条路线 + 北朝上（倒计时覆盖层就在其上方）。
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
              zoom: _runZoom,
            ),
          ),
          animated: false,
        );
      }
    }
  }

  // ---------- 导航提示（顶部面板数据） ----------

  /// 下一转弯：规划 steps 中首个在当前位置前方的转向动作（真实高德步骤）。
  _TurnHint? _nextTurnHint(double alongM) {
    final List<RouteStep> steps = widget.plannedRoute?.steps ?? const <RouteStep>[];
    for (final RouteStep s in steps) {
      if (s.cumulativeM <= alongM + 20) continue;
      final IconData? icon = _turnIcons[s.action];
      if (icon == null) continue;
      return _TurnHint(
        icon: icon,
        distM: s.cumulativeM - alongM,
        name: _turnNames[s.action]!,
        road: s.road,
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

  // ---------- UI（模块 F 布局） ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('跑步中'),
        automaticallyImplyLeading: false,
        actions: <Widget>[
          IconButton(
            tooltip: _orientation == MapOrientation.headingUp
                ? '切换为正北朝上'
                : '切换为前进方向朝上',
            icon: Icon(_orientation == MapOrientation.headingUp
                ? Icons.navigation
                : Icons.explore),
            onPressed: _toggleOrientation,
          ),
          IconButton(
            tooltip: _followCamera ? '关闭相机跟随' : '回到跑者位置',
            icon: Icon(_followCamera ? Icons.my_location : Icons.location_searching),
            onPressed: _followCamera
                ? () => setState(() => _followCamera = false)
                : _recenter,
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
          if (trackPts.isNotEmpty && _plannedPath != null) {
            proj = _mapMatch(trackPts.last);
          }
          final bool offRoute =
              proj != null && proj.offsetM > _offRouteMeters && pts.length > 3;
          _onMatched(proj, pts, offRoute);

          final _TurnHint? hint =
              (proj != null && !offRoute) ? _nextTurnHint(proj.alongM) : null;

          final double? targetM = widget.targetM;
          final double progress = (targetM != null && targetM > 0)
              ? (_recorder.distanceMeters / targetM).clamp(0.0, 1.0)
              : 0.0;
          final double? remainPlannedM =
              (proj != null && _plannedPath != null && !offRoute)
                  ? (_plannedPath!.total - proj.alongM)
                  : null;

          return Stack(
            children: <Widget>[
              Column(
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
                          rotateGesturesEnabled: true,
                          polylines: _buildPolylines(trackPts),
                          markers: _buildMarkers(trackPts),
                          onMapCreated: _onMapCreated,
                          onCameraMoveEnd: _onCameraMoveEnd,
                        ),
                        // ---- 顶部：偏航告警 / 下一转弯大卡片 / 语音故障提示 ----
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
                            child: _TurnCard(hint: hint),
                          ),
                        if (_ttsProblem != null && NavSettings.instance.voiceNavEnabled)
                          Positioned(
                            top: hint != null && !offRoute ? 96 : 10,
                            left: 12,
                            right: 12,
                            child: _Banner(
                              icon: Icons.volume_off,
                              color: Colors.blueGrey,
                              text: _ttsProblem!,
                            ),
                          ),
                        // ---- 公里完成轻提示（不遮挡地图中部） ----
                        if (_toastSplit != null)
                          Positioned(
                            bottom: 16,
                            left: 0,
                            right: 0,
                            child: Center(child: _KmToast(split: _toastSplit!)),
                          ),
                        // ---- 手动平移后的回中按钮 ----
                        if (!_followCamera)
                          Positioned(
                            right: 12,
                            bottom: 16,
                            child: FloatingActionButton.small(
                              heroTag: 'run-recenter',
                              onPressed: _recenter,
                              child: const Icon(Icons.my_location),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // ---- 底部数据面板（模块 F：距离/配速/时长/剩余 + 按钮） ----
                  Expanded(
                    flex: 2,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: <Widget>[
                            Text(formatKm(_recorder.distanceMeters),
                                style: const TextStyle(
                                    fontSize: 56, fontWeight: FontWeight.bold, height: 1.1)),
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Text('公里', style: TextStyle(fontSize: 16)),
                            ),
                          ],
                        ),
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
                        ],
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: <Widget>[
                            _Metric(label: '当前配速', value: formatPace(_recorder.currentPaceSecondsPerKm), big: true),
                            _Metric(label: '平均配速', value: formatPace(_recorder.avgPaceSecondsPerKm)),
                            _Metric(label: '时长', value: formatDuration(_recorder.durationSeconds), big: true),
                            _Metric(
                              label: '剩余(规划)',
                              value: remainPlannedM != null
                                  ? _fmtDist(remainPlannedM)
                                  : (targetM != null && targetM > 0
                                      ? _fmtDist((targetM - _recorder.distanceMeters).clamp(0, double.infinity))
                                      : '--'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: <Widget>[
                            if (state == RunState.running)
                              FilledButton.tonalIcon(
                                onPressed: _pause,
                                icon: const Icon(Icons.pause),
                                label: const Text('暂停'),
                              )
                            else if (state == RunState.paused)
                              FilledButton.tonalIcon(
                                onPressed: _resume,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('继续'),
                              ),
                            if (_started)
                              FilledButton.icon(
                                onPressed: _end,
                                icon: const Icon(Icons.stop),
                                label: const Text('结束'),
                              ),
                          ],
                        ),
                        if (state == RunState.paused)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('已暂停：计时冻结，语音播报停止',
                                style: TextStyle(fontSize: 12, color: Colors.grey)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              // ---- 三秒环形倒计时（模块 C）：覆盖全屏，地图已预加载 ----
              if (_showCountdown)
                CountdownOverlay(
                  onGo: _onCountdownGo,
                  onCancelled: _onCountdownCancel,
                  onComplete: () {
                    if (mounted) setState(() => _showCountdown = false);
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

/// NavSettings → NavAnnouncer 的适配（保持播报引擎可单测）。
class _SettingsVoiceConfig implements NavVoiceConfig {
  @override
  bool get voiceNav => NavSettings.instance.voiceNavEnabled;

  @override
  bool get kmPace => NavSettings.instance.kmPaceEnabled;

  @override
  double get announceM => NavSettings.instance.announceDistanceM;
}

class _TurnHint {
  const _TurnHint({
    required this.icon,
    required this.distM,
    required this.name,
    required this.road,
  });
  final IconData icon;
  final double distM;
  final String name;
  final String road;
}

/// 顶部转弯大卡片（模块 F：户外可读，转弯图标 + 距离大字 + 动作/道路）。
class _TurnCard extends StatelessWidget {
  const _TurnCard({required this.hint});

  final _TurnHint hint;

  @override
  Widget build(BuildContext context) {
    final bool km = hint.distM >= 1000;
    final String distText =
        km ? (hint.distM / 1000).toStringAsFixed(1) : '${(hint.distM / 10).round() * 10}';
    return Material(
      color: const Color(0xF01565C0),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(hint.icon, color: Colors.white, size: 40),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  distText,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, height: 1),
                ),
                Text(km ? '公里后' : '米后',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    hint.name,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hint.road.isNotEmpty)
                    Text(
                      '进入 ${hint.road}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 公里完成轻提示（模块 B/F：小卡片，不遮挡地图，4 秒自动消失）。
class _KmToast extends StatelessWidget {
  const _KmToast({required this.split});

  final KmSplit split;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE637474F),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.flag, color: Color(0xFF69F0AE), size: 18),
            const SizedBox(width: 8),
            Text(
              '第 ${split.index} 公里 · 配速 ${formatPace(split.paceSecondsPerKm)}',
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// 地图顶部提示横幅（偏航告警 / 语音故障）。
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
  const _Metric({required this.label, required this.value, this.big = false});

  final String label;
  final String value;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(value,
            style: TextStyle(
                fontSize: big ? 24 : 20,
                fontWeight: big ? FontWeight.w700 : FontWeight.w600)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      ],
    );
  }
}
