import 'dart:async';

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/config.dart';
import '../models/location_result.dart';
import '../services/location/location_service.dart';
import 'history_screen.dart';
import 'run_screen.dart';

/// 首页：高德地图 + 实时定位点 + 开始跑步入口。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AMapController? _controller;
  StreamSubscription<LocationResult>? _sub;
  LocationResult? _location;
  bool _locating = false;
  String? _error;
  Set<Marker> _markers = <Marker>{};
  bool _hasMovedCamera = false;

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  Future<void> _initLocation() async {
    final bool granted = await _requestPermission();
    if (!granted) {
      setState(() => _error = '定位权限被拒绝，无法显示当前位置');
      return;
    }
    if (!mounted) return;
    setState(() => _locating = true);
    _sub = LocationService.instance.stream.listen(_onLocation, onError: (Object e) {
      if (mounted) setState(() => _error = '定位失败：$e');
    });
    LocationService.instance.start();
  }

  Future<bool> _requestPermission() async {
    PermissionStatus status = await Permission.location.request();
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied || status.isDenied) {
      // 再次尝试（部分机型首次拒绝后会给出“永久拒绝”）
      status = await Permission.location.request();
    }
    return status.isGranted;
  }

  void _onLocation(LocationResult r) {
    if (!mounted) return;
    if (r.hasError) {
      setState(() => _error = '定位错误：${r.errorInfo ?? r.errorCode}');
      return;
    }
    setState(() {
      _location = r;
      _locating = true;
      _error = null;
      _markers = <Marker>{
        Marker(position: LatLng(r.latitude, r.longitude)),
      };
    });
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
    // 地图创建后再把当前位置作为中心（若有定位）。
    final LocationResult? loc = _location;
    if (loc != null && !_hasMovedCamera) {
      _hasMovedCamera = true;
      controller.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: LatLng(loc.latitude, loc.longitude), zoom: 16),
        ),
        animated: false,
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    LocationService.instance.stop();
    super.dispose();
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
              target: LatLng(31.2304, 121.4737),
              zoom: 13,
            ),
            markers: _markers,
            onMapCreated: _onMapCreated,
          ),
          // 顶部信息栏
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopBar(),
          ),
          // 底部操作区
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: _buildBottomBar(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _error ?? '环跑 · 当前位置定位中…',
                        style: TextStyle(
                          color: _error != null ? Colors.red : Colors.black87,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.history),
                      tooltip: '历史记录',
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const HistoryScreen(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            if (_location != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(
                    '坐标 ${_location!.latitude.toStringAsFixed(6)}, '
                    '${_location!.longitude.toStringAsFixed(6)} · '
                    '精度 ${_location!.accuracy.toStringAsFixed(0)}m',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return FilledButton.icon(
      onPressed: _locating
          ? () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const RunScreen()),
              );
            }
          : null,
      icon: const Icon(Icons.directions_run),
      label: const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Text('开始跑步', style: TextStyle(fontSize: 18)),
      ),
    );
  }
}
