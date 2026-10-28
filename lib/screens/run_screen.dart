import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';

import '../app/config.dart';
import '../models/planned_route.dart';
import '../models/run_record.dart';
import '../models/track_point.dart';
import '../services/run_recorder/run_recorder.dart';
import '../utils/geo.dart';
import 'run_summary_screen.dart';

/// 跑步中页面：地图显示所选路线与当前位置 + 实时距离/配速/时长 + 暂停/继续/结束。
class RunScreen extends StatefulWidget {
  const RunScreen({super.key, this.plannedRoute, this.targetM});

  final PlannedRoute? plannedRoute;
  final double? targetM;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  final RunRecorder _recorder = RunRecorder();
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    _recorder.start();
  }

  @override
  void dispose() {
    if (!_ending) {
      _recorder.end();
    }
    _recorder.dispose();
    super.dispose();
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

  Set<Polyline> _buildPolylines() {
    final PlannedRoute? route = widget.plannedRoute;
    if (route == null || route.polyline.isEmpty) return <Polyline>{};
    return <Polyline>{
      Polyline(
        points: route.polyline.map((List<double> p) => LatLng(p[1], p[0])).toList(),
        color: Colors.blue,
        width: 8,
      ),
    };
  }

  Set<Marker> _buildMarkers() {
    final List<TrackPoint> pts = _recorder.points;
    if (pts.isEmpty) return <Marker>{};
    final TrackPoint last = pts.last;
    return <Marker>{Marker(position: LatLng(last.latitude, last.longitude))};
  }

  void _onMapCreated(AMapController controller) {
    final PlannedRoute? route = widget.plannedRoute;
    if (route != null && route.polyline.isNotEmpty) {
      final List<double> lngs = route.polyline.map((p) => p[0]).toList()..sort();
      final List<double> lats = route.polyline.map((p) => p[1]).toList()..sort();
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('跑步中'),
        automaticallyImplyLeading: false,
      ),
      body: ListenableBuilder(
        listenable: _recorder,
        builder: (BuildContext context, _) {
          final RunState state = _recorder.state;
          return Column(
            children: <Widget>[
              Expanded(
                flex: 2,
                child: AMapWidget(
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
                  polylines: _buildPolylines(),
                  markers: _buildMarkers(),
                  onMapCreated: _onMapCreated,
                ),
              ),
              Expanded(
                flex: 3,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(formatKm(_recorder.distanceMeters),
                        style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold)),
                    const Text('公里', style: TextStyle(fontSize: 18)),
                    if (widget.targetM != null && widget.targetM! > 0)
                      Text('目标 ${(widget.targetM! / 1000).toStringAsFixed(1)} 公里',
                          style: TextStyle(color: Colors.grey[600])),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        _Metric(label: '实时配速', value: formatPace(_recorder.currentPaceSecondsPerKm)),
                        _Metric(label: '平均配速', value: formatPace(_recorder.avgPaceSecondsPerKm)),
                        _Metric(label: '总时长', value: formatDuration(_recorder.durationSeconds)),
                        _Metric(label: '移动时长', value: formatDuration(_recorder.movingSeconds)),
                      ],
                    ),
                    const SizedBox(height: 16),
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
