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
import 'run_screen.dart';

/// 候选路线页：细线 + 方向箭头 + 去返程视觉分离 + 自然导航面板 + 按里程地标。
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

class _RouteCandidatesScreenState extends State<RouteCandidatesScreen> {
  static const List<Color> _colors = <Color>[
    Color(0xFF1565C0),
    Color(0xFFEF6C00),
    Color(0xFF6A1B9A),
  ];
  static const double _selectedWidth = 4.0;
  static const double _unselectedWidth = 2.0;
  static const double _offsetMeters = 10.0;

  late List<PlannedRoute> _routes;
  int _selected = 0;
  AMapController? _controller;
  bool _regenerating = false;
  BitmapDescriptor? _arrowIcon;

  @override
  void initState() {
    super.initState();
    _routes = widget.routes;
    _loadArrowIcon();
  }

  Future<void> _loadArrowIcon() async {
    try {
      final BitmapDescriptor icon = await createArrowIcon(Colors.white);
      if (mounted) setState(() => _arrowIcon = icon);
    } catch (_) {
      // 图标生成失败时跳过箭头。
    }
  }

  List<LatLng> _latLngs(PlannedRoute r) =>
      r.polyline.map((List<double> p) => LatLng(p[1], p[0])).toList();

  // ---------- 路线绘制（含去返程视觉偏移，仅显示层） ----------

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
    for (int i = 0; i < _routes.length; i++) {
      final PlannedRoute r = _routes[i];
      final Color color = _colors[i % _colors.length];
      final List<LatLng> pts = _latLngs(r);
      if (pts.isEmpty) continue;
      if (i == _selected) {
        result.addAll(_selectedSpans(pts, r, color));
      } else {
        result.add(Polyline(
          points: pts,
          color: color.withAlpha(55),
          width: _unselectedWidth,
        ));
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
    final BitmapDescriptor? icon = _arrowIcon;
    if (icon != null && _routes.isNotEmpty) {
      final List<LatLng> pts = _latLngs(_routes[_selected]);
      final double lengthM = _routeLengthMeters(pts);
      final int count = arrowCountForLengthMeters(lengthM);
      final double spacing = count > 0 ? lengthM / (count + 1) : 2500;
      for (final MapEntry<LatLng, double> e
          in arrowPointsByDistance(pts, spacingMeters: spacing, maxCount: count)) {
        markers.add(Marker(
          position: e.key,
          rotation: e.value,
          icon: icon,
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

  void _fitSelectedRoute({bool animated = true}) {
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
      animated: animated,
    );
  }

  void _onMapCreated(AMapController controller) {
    _controller = controller;
    _fitSelectedRoute(animated: false);
  }

  void _select(int index) {
    setState(() => _selected = index);
    _fitSelectedRoute();
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
        _regenerating = false;
      });
      _fitSelectedRoute();
    } catch (e) {
      if (!mounted) return;
      setState(() => _regenerating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重新生成失败：$e')));
    }
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

  Future<List<Map<String, dynamic>>> _loadPoiRows(PlannedRoute r) async {
    final RouteApiService api = RouteApiService();
    // 传完整折线，由后端按累计里程采样（覆盖前/中/后段）。
    return api.queryPois(polyline: r.polyline, intervalM: 1000, radius: 500);
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
          Text('累计 ${(cum / 1000).toStringAsFixed(1)} km', style: const TextStyle(fontWeight: FontWeight.bold)),
          if (pois.isEmpty)
            const Text('附近无可靠地标，参考道路名称', style: TextStyle(fontSize: 12, color: Colors.grey))
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

  @override
  Widget build(BuildContext context) {
    final PlannedRoute current = _routes[_selected];
    return Scaffold(
      appBar: AppBar(title: const Text('候选路线')),
      body: Column(
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
                  initialCameraPosition: CameraPosition(
                    target: LatLng(widget.originLat, widget.originLng),
                    zoom: 14,
                  ),
                  polylines: _buildPolylines(),
                  markers: _buildMarkers(),
                  onMapCreated: _onMapCreated,
                ),
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
            ),
          ),
          Expanded(
            flex: 3,
            child: _buildPanel(current),
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
