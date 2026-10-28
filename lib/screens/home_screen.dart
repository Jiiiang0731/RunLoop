import 'dart:async';

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/config.dart';
import '../models/location_result.dart';
import '../services/location/location_service.dart';
import 'history_screen.dart';
import 'location_diagnostics_screen.dart';
import 'run_screen.dart';

/// 首页：高德地图 + 实时定位点 + 定位状态/诊断入口 + 开始跑步。
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

  @override
  void initState() {
    super.initState();
    _sub = _loc.stream.listen(_onLocation);
    _initLocation();
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

  @override
  void dispose() {
    _sub?.cancel();
    _timeoutTimer?.cancel();
    _loc.stop();
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
          Positioned(left: 16, right: 16, bottom: 24, child: _buildBottomBar()),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(child: Text('环跑', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green[800]))),
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
          ],
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
        final String upd = _loc.lastCallbackAt != null ? '更新 ${_fmt(_loc.lastCallbackAt!)}' : '';
        return '定位成功：${r?.latitude.toStringAsFixed(6)}, ${r?.longitude.toStringAsFixed(6)} $acc $upd';
      case LocationStatus.failed:
        return '定位失败：${_loc.errorDetail ?? '未知错误'}（点击「重新定位」或查看诊断）';
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

  static String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  Widget _buildBottomBar() {
    final bool canStart = _loc.status == LocationStatus.success;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!canStart)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FilledButton.tonalIcon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('重新定位'),
            ),
          ),
        FilledButton.icon(
          onPressed: canStart
              ? () {
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const RunScreen()));
                }
              : null,
          icon: const Icon(Icons.directions_run),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(canStart ? '开始跑步' : '定位成功后可开始跑步', style: const TextStyle(fontSize: 18)),
          ),
        ),
      ],
    );
  }
}
