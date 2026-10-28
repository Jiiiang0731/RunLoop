import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';

import '../app/config.dart';
import '../models/planned_route.dart';
import '../services/route_api/route_api_service.dart';
import 'run_screen.dart';

/// 候选路线页：地图上绘制后端返回的真实折线，支持切换、选择、重新生成。
class RouteCandidatesScreen extends StatefulWidget {
  const RouteCandidatesScreen({
    super.key,
    required this.originLng,
    required this.originLat,
    required this.targetM,
    required this.routes,
    required this.tolM,
  });

  final double originLng;
  final double originLat;
  final double targetM;
  final List<PlannedRoute> routes;
  final double tolM;

  @override
  State<RouteCandidatesScreen> createState() => _RouteCandidatesScreenState();
}

class _RouteCandidatesScreenState extends State<RouteCandidatesScreen> {
  static const List<Color> _colors = <Color>[
    Color(0xFF1565C0),
    Color(0xFFEF6C00),
    Color(0xFF6A1B9A),
  ];

  late List<PlannedRoute> _routes;
  int _selected = 0;
  AMapController? _controller;
  bool _regenerating = false;

  @override
  void initState() {
    super.initState();
    _routes = widget.routes;
  }

  Set<Polyline> _buildPolylines() {
    final Set<Polyline> result = <Polyline>{};
    for (int i = 0; i < _routes.length; i++) {
      final PlannedRoute r = _routes[i];
      final Color color = _colors[i % _colors.length];
      result.add(Polyline(
        points: r.polyline.map((List<double> p) => LatLng(p[1], p[0])).toList(),
        color: i == _selected ? color : color.withAlpha(90),
        width: i == _selected ? 10 : 5,
      ));
    }
    return result;
  }

  void _fitRoute() {
    final PlannedRoute r = _routes[_selected];
    if (r.polyline.isEmpty || _controller == null) return;
    List<double> lngs = r.polyline.map((p) => p[0]).toList();
    List<double> lats = r.polyline.map((p) => p[1]).toList();
    lngs.sort();
    lats.sort();
    final LatLngBounds bounds = LatLngBounds(
      southwest: LatLng(lats.first, lngs.first),
      northeast: LatLng(lats.last, lngs.last),
    );
    _controller!.moveCamera(
      CameraUpdate.newLatLngBounds(bounds, 60),
      animated: true,
    );
  }

  void _onMapCreated(AMapController controller) {
    _controller = controller;
    _fitRoute();
  }

  void _select(int index) {
    setState(() => _selected = index);
    _fitRoute();
  }

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
      );
      if (!mounted) return;
      setState(() {
        _routes = res.routes;
        _selected = 0;
        _regenerating = false;
      });
      _fitRoute();
    } catch (e) {
      if (!mounted) return;
      setState(() => _regenerating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重新生成失败：$e')));
    }
  }

  void _startRun() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RunScreen(
          plannedRoute: _routes[_selected],
          targetM: widget.targetM,
        ),
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
                    zoom: 13,
                  ),
                  polylines: _buildPolylines(),
                  markers: <Marker>{
                    Marker(position: LatLng(widget.originLat, widget.originLng)),
                  },
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
                            Text('正在重新生成…（约 30-90 秒）', style: TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: _buildPanel(current),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(PlannedRoute current) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        Row(
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
        const SizedBox(height: 8),
        if (!current.withinTolerance)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '⚠ 该路线误差 ${current.errorM.toStringAsFixed(0)}m，超出 ±${widget.tolM.round()}m 容差，是否接受请自行判断。',
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        Row(
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
      ],
    );
  }

  Widget _candidateCard(int index, PlannedRoute r) {
    final bool sel = index == _selected;
    final Color color = _colors[index % _colors.length];
    final bool ok = r.withinTolerance && r.closureOk;
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
            const SizedBox(height: 4),
            Text('${(r.distanceM / 1000).toStringAsFixed(2)} km', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text('误差 ${r.errorM.toStringAsFixed(0)}m',
                style: TextStyle(fontSize: 12, color: ok ? Colors.green[800] : Colors.red)),
            Text('闭合 ${r.closureM.toStringAsFixed(1)}m', style: const TextStyle(fontSize: 12)),
            if (r.score != null) Text('评分 ${r.score!.toStringAsFixed(1)}', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
