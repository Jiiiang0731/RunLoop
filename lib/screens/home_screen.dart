import 'dart:async';
import 'dart:convert';

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/config.dart';
import '../models/location_result.dart';
import '../models/planned_route.dart';
import '../services/location/location_service.dart';
import '../services/route_api/route_api_service.dart';
import '../services/storage/database.dart';
import 'history_screen.dart';
import 'location_diagnostics_screen.dart';
import 'route_candidates_screen.dart';

/// 首页：高德地图 + 实时定位 + 目标距离输入 + 生成闭环路线。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final LocationService _loc = LocationService.instance;
  AMapController? _controller;
  StreamSubscription<LocationResult>? _sub;
  Timer? _timeoutTimer;
  bool _timedOut = false;
  bool _hasMovedCamera = false;
  String? _permError;

  // 目标距离（公里）
  final TextEditingController _targetController =
      TextEditingController(text: '15');
  bool _generating = false;

  /// 生成进行中：实时计时，给用户进度反馈（阶段 J）。
  Timer? _genTimer;
  int _genElapsed = 0;

  static const List<int> _quickKm = <int>[5, 10, 15, 20];

  bool _hasSavedRoute = false;

  @override
  void initState() {
    super.initState();
    _sub = _loc.stream.listen(_onLocation);
    _initLocation();
    _checkSavedRoute();
  }

  Future<void> _checkSavedRoute() async {
    try {
      final Map<String, dynamic>? row =
          await AppDatabase.instance.getLatestPlannedRoute();
      if (mounted && row != null) setState(() => _hasSavedRoute = true);
    } catch (_) {
      // 读取失败静默忽略（不影响主流程）。
    }
  }

  Future<void> _restoreLastRoute() async {
    try {
      final Map<String, dynamic>? row =
          await AppDatabase.instance.getLatestPlannedRoute();
      if (row == null) {
        setState(() => _hasSavedRoute = false);
        return;
      }
      final PlannedRoute route = PlannedRoute.fromJson(
        jsonDecode(row['payload'] as String) as Map<String, dynamic>,
      );
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => RouteCandidatesScreen(
            originLng: route.polyline.isNotEmpty ? route.polyline.first[0] : 0,
            originLat: route.polyline.isNotEmpty ? route.polyline.first[1] : 0,
            targetM: (row['target_m'] as num?)?.toDouble() ?? route.distanceM,
            routes: <PlannedRoute>[route],
            tolM: 500,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('恢复路线失败：$e')));
      }
    }
  }

  Future<void> _initLocation() async {
    final bool granted = await _requestPermission();
    if (!granted) {
      setState(() => _permError = '定位权限被拒绝，无法获取当前位置');
      return;
    }
    if (!mounted) return;
    _startLocation();
  }

  Future<bool> _requestPermission() async {
    PermissionStatus status = await Permission.location.request();
    if (status.isGranted || status.isLimited) return true;
    status = await Permission.location.request();
    return status.isGranted || status.isLimited;
  }

  void _startLocation() {
    _loc.start();
    _startTimeoutTimer();
    if (mounted) setState(() {});
  }

  void _startTimeoutTimer() {
    _timeoutTimer?.cancel();
    _timedOut = false;
    _timeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted) return;
      if (_loc.status == LocationStatus.waiting) {
        setState(() => _timedOut = true);
      }
    });
  }

  void _retry() {
    setState(() => _timedOut = false);
    _loc.start();
    _startTimeoutTimer();
    setState(() {});
  }

  void _onLocation(LocationResult r) {
    if (!mounted) return;
    setState(() {});
    if (r.hasError) return;
    if (_controller != null && !_hasMovedCamera) {
      _hasMovedCamera = true;
      _controller!.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: LatLng(r.latitude, r.longitude), zoom: 16),
        ),
        animated: true,
      );
    }
  }

  void _onMapCreated(AMapController controller) {
    _controller = controller;
    final LocationResult? r = _loc.lastResult;
    if (r != null && !_hasMovedCamera) {
      _hasMovedCamera = true;
      controller.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: LatLng(r.latitude, r.longitude), zoom: 16),
        ),
        animated: false,
      );
    }
  }

  double? _parseTargetKm() {
    final double? v = double.tryParse(_targetController.text.trim());
    if (v == null || v.isNaN) return null;
    if (v < 1 || v > 50) return null;
    return v;
  }

  Future<void> _generateRoute() async {
    final LocationResult? r = _loc.lastResult;
    if (r == null || r.hasError) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先成功定位后再生成路线')),
      );
      return;
    }
    final double? targetKm = _parseTargetKm();
    if (targetKm == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入 1~50 之间的有效距离（公里）')),
      );
      return;
    }
    setState(() => _generating = true);
    _startGenTimer();
    try {
      final RouteApiService api = RouteApiService();
      // 优先只生成 1 条候选，成功即展示，避免等待全部候选。
      final RouteGenResult res = await api.generate(
        lng: r.longitude,
        lat: r.latitude,
        targetM: targetKm * 1000,
        tolM: 500,
        seeds: <int>[1, 2, 3],
        points: 0, // 0 = 后端按目标距离自适应控制点数（阶段 I/J 调优）
        maxCandidates: 1,
      );
      if (!mounted) return;
      _stopGenTimer();
      setState(() => _generating = false);
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => RouteCandidatesScreen(
            originLng: r.longitude,
            originLat: r.latitude,
            targetM: targetKm * 1000,
            routes: res.routes,
            tolM: 500,
            elapsedS: res.elapsedS,
            apiCalls: res.apiCalls,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _stopGenTimer();
      setState(() => _generating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('生成失败：$e')));
    }
  }

  void _startGenTimer() {
    _genTimer?.cancel();
    _genElapsed = 0;
    _genTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _genElapsed++);
    });
  }

  void _stopGenTimer() {
    _genTimer?.cancel();
    _genTimer = null;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timeoutTimer?.cancel();
    _genTimer?.cancel();
    _loc.stop();
    _targetController.dispose();
    super.dispose();
  }

  Set<Marker> _markers() {
    final LocationResult? r = _loc.lastResult;
    if (r == null || r.hasError) return <Marker>{};
    return <Marker>{
      Marker(position: LatLng(r.latitude, r.longitude)),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
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
              zoom: 13,
            ),
            markers: _markers(),
            onMapCreated: _onMapCreated,
          ),
          Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
          Positioned(left: 12, right: 12, bottom: 16, child: _buildRoutePanel()),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('环跑',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green[800])),
                    ),
                    IconButton(
                      icon: const Icon(Icons.tune),
                      tooltip: '定位诊断',
                      onPressed: () {
                        Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LocationDiagnosticsScreen()));
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.history),
                      tooltip: '历史记录',
                      onPressed: () {
                        Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const HistoryScreen()));
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_statusText(), style: TextStyle(color: _statusColor())),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _statusText() {
    if (_permError != null) return _permError!;
    final LocationResult? r = _loc.lastResult;
    switch (_loc.status) {
      case LocationStatus.idle:
        return '尚未开始定位';
      case LocationStatus.waiting:
        return _timedOut ? '定位超时（已等待 15 秒）。请检查手机定位开关、权限和网络，点击「重新定位」。' : '正在定位…（请稍候）';
      case LocationStatus.success:
        final String acc = r != null ? '精度 ${r.accuracy.toStringAsFixed(0)}m' : '';
        return '定位成功：${r?.latitude.toStringAsFixed(6)}, ${r?.longitude.toStringAsFixed(6)} $acc';
      case LocationStatus.failed:
        return '定位失败：${_loc.errorDetail ?? '未知错误'}';
      case LocationStatus.timeout:
        return '定位超时：请检查定位开关/权限/网络后点「重新定位」';
    }
  }

  Color _statusColor() {
    if (_permError != null) return Colors.red;
    switch (_loc.status) {
      case LocationStatus.success:
        return Colors.green[800]!;
      case LocationStatus.failed:
      case LocationStatus.timeout:
        return Colors.red;
      case LocationStatus.waiting:
        return _timedOut ? Colors.red : Colors.orange[800]!;
      case LocationStatus.idle:
        return Colors.grey;
    }
  }

  Widget _buildRoutePanel() {
    final bool located = _loc.status == LocationStatus.success;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Text('目标距离', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _targetController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      isDense: true,
                      suffixText: '公里',
                      hintText: '例如 15',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                for (final int km in _quickKm)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('$km'),
                      selected: _targetController.text.trim() == '$km',
                      onSelected: (_) => setState(() => _targetController.text = '$km'),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_hasSavedRoute)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton.icon(
                  onPressed: _restoreLastRoute,
                  icon: const Icon(Icons.restore),
                  label: const Text('恢复上次路线（离线可用）'),
                ),
              ),
            if (!located)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.tonalIcon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新定位'),
                ),
              ),
            FilledButton.icon(
              onPressed: (!located || _generating) ? null : _generateRoute,
              icon: _generating
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.route),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_generating
                    ? '正在生成路线… $_genElapsed 秒（通常 10-20 秒）'
                    : (located ? '生成闭环路线' : '定位成功后可生成路线')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
