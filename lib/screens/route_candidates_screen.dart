import 'dart:convert';
import 'dart:math' as math;

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';

import '../app/config.dart';
import '../models/planned_route.dart';
import '../services/route_api/route_api_service.dart';
import '../services/storage/database.dart';
import '../utils/map_icons.dart';
import '../utils/route_path.dart';
import 'run_screen.dart';

/// 候选路线页：路线生长动画 + 移动标记 + 相机跟随 + 完整静态预览 + 自然导航 + 按里程地标。
class RouteCandidatesScreen extends StatefulWidget {
  const RouteCandidatesScreen({
    super.key,
    required this.originLng,
    required this.originLat,
    required this.targetM,
    required this.routes,
    required this.tolM,
    this.elapsedS = 0,
    this.apiCalls = 0,
  });

  final double originLng;
  final double originLat;
  final double targetM;
  final List<PlannedRoute> routes;
  final double tolM;
  final double elapsedS;
  final int apiCalls;

  @override
  State<RouteCandidatesScreen> createState() => _RouteCandidatesScreenState();
}

class _RouteCandidatesScreenState extends State<RouteCandidatesScreen>
    with SingleTickerProviderStateMixin {
  static const List<Color> _colors = <Color>[
    Color(0xFF1565C0),
    Color(0xFFEF6C00),
    Color(0xFF6A1B9A),
  ];
  // 线宽单位是 dp；原生 ConvertUtil.toFloatPixels = width × density。
  // 1.2dp ≈ 3.6px（3x 屏），符合「2~3 屏幕像素」的细线要求。
  static const double _selectedWidth = 1.2;
  static const double _unselectedWidth = 0.8;
  static const double _growthWidth = 1.8;
  static const double _offsetMeters = 10.0;

  late List<PlannedRoute> _routes;
  int _selected = 0;
  AMapController? _controller;
  bool _mapReady = false;
  bool _regenerating = false;
  BitmapDescriptor? _arrowIcon;
  BitmapDescriptor? _runnerIcon;

  late AnimationController _anim;
  RoutePath? _path;
  bool _animDone = false;
  int _followTick = 0;
  /// 把重建节流到 ~30fps，避免每帧全量刷新平台通道导致卡顿。
  final ValueNotifier<double> _animProgress = ValueNotifier<double>(0);
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  /// 动画专用 Polyline：固定 id，逐帧只改 points。
  ///
  /// 关键：插件按 id 做差异。若每帧新建 Polyline，id（hashCode）会变，
  /// 插件会每帧「删旧+加新」，真机上极易卡顿/看起来没有动画。
  /// 复用同一实例的 id（copyWith 会保留 id），插件才会走「修改 → 原地 setPoints」。
  Polyline? _growthPolyline;

  @override
  void initState() {
    super.initState();
    _routes = widget.routes;
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )
      ..addStatusListener(_onAnimStatus)
      ..addListener(_onAnimTick);
    _loadArrowIcon();
  }

  /// 动画每帧回调：把重建节流到 ~30fps 再通知地图。
  void _onAnimTick() {
    final DateTime now = DateTime.now();
    if (now.difference(_lastUiUpdate).inMilliseconds < 33) return;
    _lastUiUpdate = now;
    _animProgress.value = _anim.value;
  }

  @override
  void dispose() {
    _animProgress.dispose();
    _anim.dispose();
    _controller = null;
    super.dispose();
  }

  void _onAnimStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      setState(() => _animDone = true);
      _fitSelectedRoute();
    }
  }

  Future<void> _loadArrowIcon() async {
    try {
      final BitmapDescriptor icon = await createArrowIcon(Colors.white);
      if (mounted) setState(() => _arrowIcon = icon);
    } catch (_) {
      // 图标生成失败时跳过箭头。
    }
  }

  Future<void> _loadRunnerIcon(Color color) async {
    try {
      final BitmapDescriptor icon = await createRunnerIcon(color);
      if (mounted) setState(() => _runnerIcon = icon);
    } catch (_) {
      // 忽略。
    }
  }

  // ---------- 动画控制 ----------

  Duration _durationFor(double meters) {
    final double seconds = (8 + meters / 1500.0).clamp(8.0, 15.0);
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// 开始/重播某条路线的生长动画（会取消上一条未完成的动画）。
  void _startAnimation(int index) {
    _anim.stop();
    _anim.reset();
    final List<LatLng> pts = _latLngs(_routes[index]);
    final RoutePath path = RoutePath.fromPoints(pts);
    _growthPolyline = pts.isEmpty
        ? null
        : Polyline(
            points: <LatLng>[pts.first],
            color: _colors[index % _colors.length],
            width: _growthWidth,
          );
    _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    _animProgress.value = 0;
    setState(() {
      _selected = index;
      _path = path;
      _animDone = false;
      _followTick = 0;
    });
    _loadRunnerIcon(_colors[index % _colors.length]);
    _anim.duration = _durationFor(path.total);
    if (_mapReady && _controller != null) {
      _moveToStart(path);
      _anim.forward();
    }
    // 地图未就绪时，等待 onMapCreated 再启动，避免动画丢失。
  }

  void _moveToStart(RoutePath path) {
    if (path.points.isEmpty) return;
    _controller?.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: path.points.first, zoom: 16),
      ),
      animated: false,
    );
  }

  void _pause() {
    if (_anim.isAnimating) {
      _anim.stop();
      setState(() {});
    }
  }

  void _resume() {
    if (!_animDone && !_anim.isAnimating) {
      if (_anim.value >= 1.0) {
        _startAnimation(_selected);
      } else {
        _anim.forward();
        setState(() {});
      }
    }
  }

  void _replay() => _startAnimation(_selected);

  void _skip() {
    _anim.stop();
    _anim.value = 1.0;
    _animProgress.value = 1.0;
    setState(() => _animDone = true);
    _fitSelectedRoute();
  }

  /// 相机跟随（节流，避免每帧移动导致抖动）。
  void _followCamera() {
    final RoutePath? path = _path;
    if (path == null || _controller == null || _animDone) return;
    _followTick++;
    if (_followTick % 30 != 0) return;
    final RoutePosition pos = path.at(_anim.value * path.total);
    _controller!.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: pos.point, zoom: 16),
      ),
      animated: true,
    );
  }

  // ---------- 绘制 ----------

  List<LatLng> _latLngs(PlannedRoute r) =>
      r.polyline.map((List<double> p) => LatLng(p[1], p[0])).toList();

  List<Polyline> _selectedSpans(List<LatLng> pts, PlannedRoute r, Color color) {
    final Map<int, MapEntry<double, double>> offsetAt =
        <int, MapEntry<double, double>>{};
    for (final OverlapGroup g in r.overlaps) {
      for (final OverlapRange rng in g.ranges) {
        for (int i = rng.start; i < rng.end && i < pts.length; i++) {
          offsetAt[i] = MapEntry<double, double>(rng.offset, g.refBearing);
        }
      }
    }
    if (offsetAt.isEmpty) {
      return <Polyline>[Polyline(points: pts, color: color, width: _selectedWidth)];
    }
    final List<Polyline> out = <Polyline>[];
    int i = 0;
    while (i < pts.length) {
      final MapEntry<double, double>? cur = offsetAt[i];
      int j = i + 1;
      while (j < pts.length && _sameOffset(offsetAt[j], cur)) {
        j++;
      }
      final List<LatLng> span = pts.sublist(i, j);
      if (cur == null || cur.key == 0) {
        out.add(Polyline(points: span, color: color, width: _selectedWidth));
      } else {
        out.add(Polyline(
          points: _offsetSpan(span, cur.key, cur.value),
          color: color,
          width: _selectedWidth,
        ));
      }
      i = j;
    }
    return out;
  }

  static bool _sameOffset(MapEntry<double, double>? a, MapEntry<double, double>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.key == b.key && a.value == b.value;
  }

  List<LatLng> _offsetSpan(List<LatLng> span, double offset, double refBearing) {
    final double perp = (refBearing + 90) * math.pi / 180;
    final double lat0 = span[span.length ~/ 2].latitude;
    final double dx = math.cos(perp);
    final double dy = math.sin(perp);
    final double dLat = dy * _offsetMeters * offset / 111320.0;
    final double dLng =
        dx * _offsetMeters * offset / (111320.0 * math.cos(lat0 * math.pi / 180));
    return <LatLng>[
      for (final LatLng p in span) LatLng(p.latitude + dLat, p.longitude + dLng),
    ];
  }

  Set<Polyline> _buildPolylines() {
    final Set<Polyline> result = <Polyline>{};
    final RoutePath? path = _path;
    for (int i = 0; i < _routes.length; i++) {
      final PlannedRoute r = _routes[i];
      final Color color = _colors[i % _colors.length];
      final List<LatLng> pts = _latLngs(r);
      if (pts.isEmpty) continue;
      if (i != _selected) {
        result.add(Polyline(
          points: pts,
          color: color.withAlpha(45),
          width: _unselectedWidth,
        ));
        continue;
      }
      // 选中路线
      if (!_animDone && path != null && _growthPolyline != null) {
        // 生长中：复用同一 id，只改 points（插件原地 setPoints，不重建）
        final List<LatLng> drawn = path.upTo(_anim.value * path.total);
        if (drawn.length >= 2) {
          result.add(_growthPolyline!.copyWith(pointsParam: drawn));
        } else {
          result.add(_growthPolyline!);
        }
      } else {
        // 完成/跳过：完整静态（含去返程视觉偏移）
        result.addAll(_selectedSpans(pts, r, color));
      }
    }
    return result;
  }

  Set<Marker> _buildMarkers() {
    final Set<Marker> markers = <Marker>{
      Marker(
        position: LatLng(widget.originLat, widget.originLng),
        icon: BitmapDescriptor.defaultMarker,
        infoWindow: const InfoWindow(
          title: '起点 / 终点',
          snippet: '闭合路线，最终回到此处',
        ),
        zIndex: 200,
      ),
    };
    final RoutePath? path = _path;
    // 动画中的移动标记
    if (!_animDone && path != null && _runnerIcon != null) {
      final RoutePosition pos = path.at(_anim.value * path.total);
      markers.add(Marker(
        position: pos.point,
        rotation: pos.bearing,
        icon: _runnerIcon!,
        anchor: const Offset(0.5, 0.5),
        zIndex: 300,
      ));
    }
    // 静态完成后的方向箭头
    if (_animDone && _arrowIcon != null && _routes.isNotEmpty) {
      final List<LatLng> pts = _latLngs(_routes[_selected]);
      final double lengthM = _routeLengthMeters(pts);
      final int count = arrowCountForLengthMeters(lengthM);
      final double spacing = count > 0 ? lengthM / (count + 1) : 2500;
      for (final MapEntry<LatLng, double> e
          in arrowPointsByDistance(pts, spacingMeters: spacing, maxCount: count)) {
        markers.add(Marker(
          position: e.key,
          rotation: e.value,
          icon: _arrowIcon!,
          anchor: const Offset(0.5, 0.5),
          zIndex: 150,
        ));
      }
    }
    return markers;
  }

  double _routeLengthMeters(List<LatLng> pts) {
    double sum = 0;
    for (int i = 1; i < pts.length; i++) {
      sum += haversineMeters(pts[i - 1], pts[i]);
    }
    return sum;
  }

  void _fitSelectedRoute() {
    if (_controller == null || _routes.isEmpty) return;
    final List<double> lngs =
        _routes[_selected].polyline.map((p) => p[0]).toList()..sort();
    final List<double> lats =
        _routes[_selected].polyline.map((p) => p[1]).toList()..sort();
    if (lngs.isEmpty) return;
    _controller!.moveCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(lats.first, lngs.first),
          northeast: LatLng(lats.last, lngs.last),
        ),
        60,
      ),
      animated: true,
    );
  }

  void _onMapCreated(AMapController controller) {
    _controller = controller;
    _mapReady = true;
    // 地图就绪后播放当前选中的路线（初始进入即演示路线 1）。
    _startAnimation(_selected);
  }

  void _select(int index) {
    // 切换 / 再次点击当前路线：均从头播放。
    _startAnimation(index);
  }

  // ---------- 交互 ----------

  Future<void> _regenerate() async {
    setState(() => _regenerating = true);
    try {
      final RouteApiService api = RouteApiService();
      final RouteGenResult res = await api.generate(
        lng: widget.originLng,
        lat: widget.originLat,
        targetM: widget.targetM,
        tolM: widget.tolM,
        seeds: <int>[7, 8, 9],
        points: 10,
        maxCandidates: 2,
      );
      if (!mounted) return;
      setState(() {
        _routes = res.routes;
        _selected = 0;
        _animDone = false;
        _regenerating = false;
      });
      _startAnimation(0);
    } catch (e) {
      if (!mounted) return;
      setState(() => _regenerating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重新生成失败：$e')));
    }
  }

  Future<List<Map<String, dynamic>>> _loadPoiRows(PlannedRoute r) async {
    final RouteApiService api = RouteApiService();
    return api.queryPois(polyline: r.polyline, intervalM: 1000, radius: 500);
  }

  Future<void> _showLandmarks() async {
    final PlannedRoute r = _routes[_selected];
    if (r.polyline.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该路线折线不足，无法查询地标')),
      );
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('沿途地标（按里程）'),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _loadPoiRows(r),
              builder: (BuildContext c, AsyncSnapshot<List<Map<String, dynamic>>> snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Text('查询失败：${snap.error}');
                }
                final List<Map<String, dynamic>> rows = snap.data ?? <Map<String, dynamic>>[];
                if (rows.isEmpty) {
                  return const Text('路线太短，暂无沿途地标。');
                }
                return ListView(
                  children: <Widget>[
                    for (final Map<String, dynamic> row in rows) _poiRow(row),
                  ],
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        );
      },
    );
  }

  Widget _poiRow(Map<String, dynamic> row) {
    final double cum = (row['cumulative_m'] as num?)?.toDouble() ?? 0;
    final List<Map<String, dynamic>> pois =
        (row['pois'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? <Map<String, dynamic>>[];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('累计 ${(cum / 1000).toStringAsFixed(1)} km',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          if (pois.isEmpty)
            const Text('附近无可靠地标，参考道路名称',
                style: TextStyle(fontSize: 12, color: Colors.grey))
          else
            for (final Map<String, dynamic> p in pois)
              Text(
                '• ${p['name']}  ${(p['distance_m'] as num?)?.toStringAsFixed(0) ?? ''}m',
                style: const TextStyle(fontSize: 13),
              ),
        ],
      ),
    );
  }

  Future<void> _startRun() async {
    final PlannedRoute r = _routes[_selected];
    if (!r.canStartRun) {
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('路线不符合验收要求'),
          content: Text(
            '距离误差 ${r.errorM.toStringAsFixed(0)}m（容差 ±${widget.tolM.round()}m）'
            '，闭合误差 ${r.closureM.toStringAsFixed(1)}m。\n\n'
            '该路线未通过距离/闭合校验，建议重新生成。是否仍要开始？',
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仍要开始')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await AppDatabase.instance.savePlannedRoute(
        targetM: widget.targetM,
        seed: r.seed,
        distanceM: r.distanceM,
        payload: jsonEncode(r.toJson()),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('路线本地保存失败（不影响本次跑步）')),
        );
      }
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RunScreen(plannedRoute: r, targetM: widget.targetM),
      ),
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final PlannedRoute current = _routes[_selected];
    return Scaffold(
      appBar: AppBar(title: const Text('候选路线')),
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: ValueListenableBuilder<double>(
              valueListenable: _animProgress,
              builder: (BuildContext context, double progress, _) {
                _followCamera();
                return Stack(
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
                      initialCameraPosition: CameraPosition(
                        target: LatLng(widget.originLat, widget.originLng),
                        zoom: 14,
                      ),
                      polylines: _buildPolylines(),
                      markers: _buildMarkers(),
                      onMapCreated: _onMapCreated,
                    ),
                    _buildAnimControls(),
                    if (_regenerating)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black26,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                CircularProgressIndicator(),
                                SizedBox(height: 12),
                                Text('正在重新生成…', style: TextStyle(color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          Expanded(flex: 3, child: _buildPanel(current)),
        ],
      ),
    );
  }

  Widget _buildAnimControls() {
    final double total = _path?.total ?? 0;
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (!_animDone)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(230),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: <Widget>[
                  LinearProgressIndicator(value: _anim.value, minHeight: 3),
                  const SizedBox(height: 3),
                  Text(
                    '演示 ${(_anim.value * 100).toStringAsFixed(0)}% · 已走 ${((_anim.value * total) / 1000).toStringAsFixed(2)} km',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          Center(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(235),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const <BoxShadow>[
                  BoxShadow(color: Colors.black12, blurRadius: 6),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (!_animDone) ...<Widget>[
                    IconButton(
                      tooltip: _anim.isAnimating ? '暂停' : '继续',
                      onPressed: _anim.isAnimating ? _pause : _resume,
                      icon: Icon(_anim.isAnimating ? Icons.pause : Icons.play_arrow),
                    ),
                    IconButton(
                      tooltip: '重新播放',
                      onPressed: _replay,
                      icon: const Icon(Icons.replay),
                    ),
                    TextButton(
                      onPressed: _skip,
                      child: const Text('跳过动画'),
                    ),
                  ] else
                    TextButton.icon(
                      onPressed: _replay,
                      icon: const Icon(Icons.replay, size: 18),
                      label: const Text('重新播放'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(PlannedRoute current) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < _routes.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _candidateCard(i, _routes[i]),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(
            children: <Widget>[
              Text(
                '本次生成：${widget.elapsedS.toStringAsFixed(1)}s · ${widget.apiCalls} 次调用',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _showLandmarks,
                icon: const Icon(Icons.place, size: 18),
                label: const Text('沿途地标'),
              ),
            ],
          ),
        ),
        if (!current.canStartRun)
          Container(
            width: double.infinity,
            color: Colors.red.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              '⚠ 该路线不满足距离容差/闭合要求，开始跑步前会二次确认。',
              style: TextStyle(color: Colors.red.shade800, fontSize: 13),
            ),
          ),
        Expanded(child: _stepsList(current)),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _regenerating ? null : _regenerate,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新生成'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _regenerating ? null : _startRun,
                  icon: const Icon(Icons.directions_run),
                  label: const Text('开始跑步'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stepsList(PlannedRoute r) {
    if (r.steps.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('该路线未返回分段说明，可参考地图折线与道路名称。'),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: r.steps.length,
      itemBuilder: (BuildContext context, int i) {
        final RouteStep s = r.steps[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 62,
                child: Text(
                  '${(s.cumulativeM / 1000).toStringAsFixed(2)}km',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ),
              Icon(_turnIcon(s.action), size: 18, color: Colors.blueGrey),
              const SizedBox(width: 6),
              Expanded(
                child: Text(s.instruction, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
        );
      },
    );
  }

  static IconData _turnIcon(String action) {
    switch (action) {
      case 'left':
        return Icons.turn_left;
      case 'right':
        return Icons.turn_right;
      case 'uturn':
        return Icons.u_turn_left;
      case 'end':
        return Icons.flag;
      default:
        return Icons.straight;
    }
  }

  Widget _candidateCard(int index, PlannedRoute r) {
    final bool sel = index == _selected;
    final Color color = _colors[index % _colors.length];
    return GestureDetector(
      onTap: () => _select(index),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: sel ? color : Colors.grey.shade300, width: sel ? 2 : 1),
          borderRadius: BorderRadius.circular(8),
          color: sel ? color.withAlpha(20) : Colors.white,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('路线 ${index + 1}', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 2),
            Text('${(r.distanceM / 1000).toStringAsFixed(2)} km',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(
              '误差 ${r.errorM.toStringAsFixed(0)}m',
              style: TextStyle(fontSize: 12, color: r.withinTolerance ? Colors.green[800] : Colors.red),
            ),
            Text('闭合 ${r.closureM.toStringAsFixed(1)}m', style: const TextStyle(fontSize: 12)),
            if (r.score != null)
              Text('评分 ${r.score!.toStringAsFixed(1)}', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
