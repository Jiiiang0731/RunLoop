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
import '../utils/route_style.dart';
import 'run_screen.dart';

/// 候选路线页：路线生长动画 + 移动标记 + 相机跟随 + 完整静态预览 + 自然导航 + 按里程地标。
///
/// 阶段 J 视觉升级：选中路线 = 白描边 + 渐变主线 + 圆角端点（专业地图式包边），
/// 未选中路线半透明细线；静态覆盖物缓存 + 生长线/跑者固定 id 逐帧原地更新，
/// 避免每帧「删旧+加新」造成卡顿（阶段 H 教训）。
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
  static const double _offsetMeters = 10.0;

  late List<PlannedRoute> _routes;
  int _selected = 0;
  AMapController? _controller;
  bool _mapReady = false;
  bool _regenerating = false;
  BitmapDescriptor? _arrowIcon;
  BitmapDescriptor? _runnerIcon;
  BitmapDescriptor? _startIcon;

  late AnimationController _anim;
  RoutePath? _path;
  bool _animDone = false;
  int _followTick = 0;
  /// 把重建节流到 ~30fps，避免每帧全量刷新平台通道导致卡顿。
  final ValueNotifier<double> _animProgress = ValueNotifier<double>(0);
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  /// 动画专用 Polyline（渐变主线 + 白描边）：固定 id，逐帧只改 points。
  ///
  /// 关键：插件按 id 做差异。若每帧新建 Polyline，id（hashCode）会变，
  /// 插件会每帧「删旧+加新」，真机上极易卡顿/看起来没有动画。
  /// 复用同一实例的 id（copyWith 会保留 id），插件才会走「修改 → 原地 setPoints」。
  Polyline? _growthCore;
  Polyline? _growthCasing;

  /// 跑者标记：固定 id，逐帧只改 position/rotation（原地移动不重建）。
  Marker? _runnerMarker;

  /// 「换一批」轮次：每轮使用一组新种子，避免重复路线。
  int _regenRound = 0;

  /// 静态覆盖物缓存（未选中路线 / 完成后的选中路线 / 起点标记 / 方向箭头）。
  /// 仅在路线、选中项、动画状态、图标变化时重建；动画期间逐帧复用（id 稳定）。
  Set<Polyline>? _staticPolylinesCache;
  Set<Marker>? _staticMarkersCache;

  void _invalidateOverlayCache() {
    _staticPolylinesCache = null;
    _staticMarkersCache = null;
  }

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
    _loadIcons();
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
      setState(() {
        _animDone = true;
        _invalidateOverlayCache(); // 完成后改画静态渐变线 + 箭头
      });
      _fitSelectedRoute();
    }
  }

  Future<void> _loadIcons() async {
    try {
      final BitmapDescriptor arrow =
          await createArrowIcon(RouteStyle.primary(_selected));
      final BitmapDescriptor start = await createStartIcon();
      if (mounted) {
        setState(() {
          _arrowIcon = arrow;
          _startIcon = start;
          _invalidateOverlayCache();
        });
      }
    } catch (_) {
      // 图标生成失败时跳过装饰。
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
    final List<Color> grad = RouteStyle.gradient(index);
    if (pts.isEmpty) {
      _growthCore = null;
      _growthCasing = null;
      _runnerMarker = null;
    } else {
      // 白描边（底层）+ 渐变主线（上层），都用固定 id 逐帧原地更新 points。
      _growthCasing = Polyline(
        points: <LatLng>[pts.first],
        color: RouteStyle.casingColor,
        width: RouteStyle.growthCasingWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCasing,
      );
      _growthCore = Polyline(
        points: <LatLng>[pts.first],
        gradient: true,
        colorList: grad,
        color: grad.first,
        width: RouteStyle.growthCoreWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCore,
      );
      _runnerMarker = Marker(
        position: pts.first,
        icon: _runnerIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        zIndex: 300,
      );
    }
    _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    _animProgress.value = 0;
    setState(() {
      _selected = index;
      _path = path;
      _animDone = false;
      _followTick = 0;
      _invalidateOverlayCache();
    });
    _loadRouteIcons(index);
    _anim.duration = _durationFor(path.total);
    if (_mapReady && _controller != null) {
      _moveToStart(path);
      _anim.forward();
    }
    // 地图未就绪时，等待 onMapCreated 再启动，避免动画丢失。
  }

  /// 按当前选中路线主色刷新跑者/箭头图标。
  Future<void> _loadRouteIcons(int index) async {
    final Color c = RouteStyle.primary(index);
    try {
      final BitmapDescriptor runner = await createRunnerIcon(c);
      final BitmapDescriptor arrow = await createArrowIcon(c);
      if (!mounted) return;
      setState(() {
        _runnerIcon = runner;
        _arrowIcon = arrow;
        if (_runnerMarker != null) {
          _runnerMarker = _runnerMarker!.copyWith(iconParam: runner);
        }
        _invalidateOverlayCache();
      });
    } catch (_) {
      // 忽略图标刷新失败。
    }
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
    setState(() {
      _animDone = true;
      _invalidateOverlayCache();
    });
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

  /// 选中路线的静态绘制：每段 = 白描边（下）+ 渐变主线（上），圆角端点。
  /// 去/返程重叠段保留 ±10m 视觉偏移（阶段 G 逻辑不变）。
  List<Polyline> _selectedSpans(List<LatLng> pts, PlannedRoute r, int colorIndex) {
    final Map<int, MapEntry<double, double>> offsetAt =
        <int, MapEntry<double, double>>{};
    for (final OverlapGroup g in r.overlaps) {
      for (final OverlapRange rng in g.ranges) {
        for (int i = rng.start; i < rng.end && i < pts.length; i++) {
          offsetAt[i] = MapEntry<double, double>(rng.offset, g.refBearing);
        }
      }
    }
    final List<Polyline> out = <Polyline>[];
    int spanNo = 0;
    void emitSpan(List<LatLng> span) {
      if (span.length < 2) return;
      // 描边与主线各自连续成一条 Polyline（相邻 span 首尾点重叠 1 个，接缝圆润）
      out.add(Polyline(
        points: span,
        color: RouteStyle.casingColor,
        width: RouteStyle.casingWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCasing,
      )..setIdForCopy('sel-casing-$colorIndex-$spanNo'));
      out.add(Polyline(
        points: span,
        gradient: true,
        colorList: RouteStyle.gradient(colorIndex),
        color: RouteStyle.primary(colorIndex),
        width: RouteStyle.coreWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCore,
      )..setIdForCopy('sel-core-$colorIndex-$spanNo'));
      spanNo++;
    }

    if (offsetAt.isEmpty) {
      emitSpan(pts);
      return out;
    }
    int i = 0;
    while (i < pts.length) {
      final MapEntry<double, double>? cur = offsetAt[i];
      int j = i + 1;
      while (j < pts.length && _sameOffset(offsetAt[j], cur)) {
        j++;
      }
      final List<LatLng> span = pts.sublist(i, j);
      if (cur == null || cur.key == 0) {
        emitSpan(span);
      } else {
        emitSpan(_offsetSpan(span, cur.key, cur.value));
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
    // 静态部分带缓存：动画期间逐帧复用（id 稳定 → 插件不做删旧加新）
    if (_staticPolylinesCache == null) {
      final Set<Polyline> statics = <Polyline>{};
      for (int i = 0; i < _routes.length; i++) {
        final PlannedRoute r = _routes[i];
        final List<LatLng> pts = _latLngs(r);
        if (pts.isEmpty) continue;
        if (i == _selected) {
          // 动画中由生长线负责；完成后画完整静态（含去返程视觉偏移）
          if (_animDone) statics.addAll(_selectedSpans(pts, r, i));
          continue;
        }
        statics.add(Polyline(
          points: pts,
          color: RouteStyle.unselectedColor(i),
          width: RouteStyle.unselectedWidth,
          capType: CapType.round,
          joinType: JoinType.round,
          zIndex: RouteStyle.zUnselected,
        )..setIdForCopy('unsel-$i'));
      }
      _staticPolylinesCache = statics;
    }
    final Set<Polyline> result = Set<Polyline>.of(_staticPolylinesCache!);
    final RoutePath? path = _path;
    if (!_animDone && path != null && _growthCore != null && _growthCasing != null) {
      // 生长中：复用同一 id，只改 points（插件原地 setPoints，不重建）
      final List<LatLng> drawn = path.upTo(_anim.value * path.total);
      if (drawn.length >= 2) {
        result.add(_growthCasing!.copyWith(pointsParam: drawn));
        result.add(_growthCore!.copyWith(pointsParam: drawn));
      } else {
        result.add(_growthCasing!);
        result.add(_growthCore!);
      }
    }
    return result;
  }

  Set<Marker> _buildMarkers() {
    if (_staticMarkersCache == null) {
      final Set<Marker> statics = <Marker>{
        Marker(
          position: LatLng(widget.originLat, widget.originLng),
          icon: _startIcon ?? BitmapDescriptor.defaultMarker,
          anchor: const Offset(0.5, 0.5),
          infoWindow: const InfoWindow(
            title: '起点 / 终点',
            snippet: '闭合路线，最终回到此处',
          ),
          zIndex: 200,
        )..setIdForCopy('start-marker'),
      };
      // 静态完成后的方向箭头（主色 + 白描边）
      if (_animDone && _arrowIcon != null && _routes.isNotEmpty) {
        final List<LatLng> pts = _latLngs(_routes[_selected]);
        final double lengthM = _routeLengthMeters(pts);
        final int count = arrowCountForLengthMeters(lengthM);
        final double spacing = count > 0 ? lengthM / (count + 1) : 2500;
        int ai = 0;
        for (final MapEntry<LatLng, double> e in arrowPointsByDistance(
            pts, spacingMeters: spacing, maxCount: count)) {
          statics.add(Marker(
            position: e.key,
            rotation: e.value,
            icon: _arrowIcon!,
            anchor: const Offset(0.5, 0.5),
            zIndex: 150,
          )..setIdForCopy('arrow-$ai'));
          ai++;
        }
      }
      _staticMarkersCache = statics;
    }
    final Set<Marker> result = Set<Marker>.of(_staticMarkersCache!);
    // 动画中的跑者标记：固定 id，逐帧只改 position/rotation
    final RoutePath? path = _path;
    if (!_animDone && path != null && _runnerMarker != null) {
      final RoutePosition pos = path.at(_anim.value * path.total);
      result.add(_runnerMarker!.copyWith(
        positionParam: pos.point,
        rotationParam: pos.bearing,
        iconParam: _runnerIcon,
      ));
    }
    return result;
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
      // 每轮换新种子，保证「换一批」真的给出不同路线
      final int base = 7 + _regenRound * 3;
      _regenRound++;
      final RouteGenResult res = await api.generate(
        lng: widget.originLng,
        lat: widget.originLat,
        targetM: widget.targetM,
        tolM: widget.tolM,
        seeds: <int>[base, base + 1, base + 2],
        points: 0, // 0 = 后端按目标距离自适应控制点数（阶段 I/J 调优成果）
        maxCandidates: 2,
      );
      if (!mounted) return;
      setState(() {
        // 与现有路线合并后按「达标优先 + 评分降序」重排，保留最多 3 条
        final Map<int, PlannedRoute> bySeed = <int, PlannedRoute>{
          for (final PlannedRoute r in _routes) r.seed: r,
        };
        for (final PlannedRoute r in res.routes) {
          bySeed[r.seed] = r;
        }
        final List<PlannedRoute> merged = bySeed.values.toList()
          ..sort((PlannedRoute a, PlannedRoute b) {
            final int aw = a.withinTolerance ? 0 : 1;
            final int bw = b.withinTolerance ? 0 : 1;
            if (aw != bw) return aw - bw;
            return (b.score ?? -1).compareTo(a.score ?? -1);
          });
        _routes = merged.take(3).toList();
        _selected = 0;
        _animDone = false;
        _regenerating = false;
        _invalidateOverlayCache();
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
        _buildMetricsBar(current),
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

  Widget _buildMetricsBar(PlannedRoute r) {
    final Map<String, dynamic> m = r.metrics;
    final int turns = (m['turns'] as num?)?.toInt() ?? 0;
    final double density = (m['turn_density'] as num?)?.toDouble() ?? 0;
    final double maxStraight = (m['straight_max_m'] as num?)?.toDouble() ?? 0;
    final double ratio300 = (m['straight_ratio_300'] as num?)?.toDouble() ?? 0;
    final double rep = (m['repetition_ratio'] as num?)?.toDouble() ?? 0;
    final int shortTurns = (m['short_consecutive'] as num?)?.toInt() ?? 0;
    final int sharp = (m['sharp_turns'] as num?)?.toInt() ?? 0;
    final Color color = RouteStyle.primary(_selected);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('$turns 次转弯 · ${density.toStringAsFixed(1)} 次/km',
                  style: const TextStyle(fontSize: 12)),
              const Spacer(),
              Text('最长直行 ${(maxStraight / 1000).toStringAsFixed(1)} km',
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
          Row(
            children: <Widget>[
              Text(
                '>300m 直行占比 ${(ratio300 * 100).toStringAsFixed(0)}% · 重复 ${(rep * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 12),
              ),
              const Spacer(),
              Text(_qualityLabel(density, ratio300, shortTurns, sharp),
                  style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  /// 定性标签：必须来自真实指标，不能只按总分推测。
  static String _qualityLabel(double density, double ratio300, int shortTurns, int sharp) {
    if (density <= 0.6 && ratio300 >= 0.4) return '少转弯 · 长直路段较多';
    if (shortTurns >= 2 || sharp >= 3) return '转弯较多 · 有连续短转弯';
    if (density <= 1.0) return '转弯适中';
    return '转弯较多';
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
    final Color color = RouteStyle.primary(index);
    final Map<String, dynamic> m = r.metrics;
    final int? turns = (m['turns'] as num?)?.toInt();
    final double? density = (m['turn_density'] as num?)?.toDouble();
    return GestureDetector(
      onTap: () => _select(index),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: sel ? color : Colors.grey.shade300, width: sel ? 2 : 1),
          borderRadius: BorderRadius.circular(10),
          color: sel ? color.withAlpha(18) : Colors.white,
          boxShadow: sel
              ? <BoxShadow>[BoxShadow(color: color.withAlpha(40), blurRadius: 6)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                Text('路线 ${index + 1}',
                    style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                if (r.recommended) ...<Widget>[
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('推荐',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 3),
            Text('${(r.distanceM / 1000).toStringAsFixed(2)} km',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(
              '误差 ${r.errorM.toStringAsFixed(0)}m',
              style: TextStyle(fontSize: 12, color: r.withinTolerance ? Colors.green[800] : Colors.red),
            ),
            if (turns != null && density != null)
              Text('$turns 次转弯 · ${density.toStringAsFixed(1)} 次/km',
                  style: const TextStyle(fontSize: 12)),
            if (r.score != null)
              Text('评分 ${r.score!.toStringAsFixed(1)}', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
