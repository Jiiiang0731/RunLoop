import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/location_result.dart';
import '../services/location/location_service.dart';

/// 定位诊断页：不依赖 ADB，直接在手机内查看定位状态、错误码、权限并复制诊断信息。
class LocationDiagnosticsScreen extends StatefulWidget {
  const LocationDiagnosticsScreen({super.key});

  @override
  State<LocationDiagnosticsScreen> createState() =>
      _LocationDiagnosticsScreenState();
}

class _LocationDiagnosticsScreenState extends State<LocationDiagnosticsScreen> {
  final LocationService _loc = LocationService.instance;
  Timer? _ticker;
  String _systemLocation = '读取中…';
  String _appPermission = '读取中…';
  String? _copyTip;

  @override
  void initState() {
    super.initState();
    _refreshPermission();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _refreshPermission() async {
    try {
      final ServiceStatus serviceStatus = await Permission.location.serviceStatus;
      final PermissionStatus permStatus = await Permission.location.status;
      if (!mounted) return;
      setState(() {
        _systemLocation = serviceStatus.isEnabled ? '已开启' : '未开启（系统定位服务关闭）';
        _appPermission = _permLabel(permStatus);
      });
    } catch (e) {
      if (mounted) setState(() => _appPermission = '读取失败：$e');
    }
  }

  static String _permLabel(PermissionStatus s) {
    if (s.isGranted) return '已授权（精确定位）';
    if (s.isLimited) return '已授权（大致位置）';
    if (s.isDenied) return '已拒绝';
    if (s.isPermanentlyDenied) return '永久拒绝（需去系统设置开启）';
    if (s.isRestricted) return '受限';
    return s.name;
  }

  String _statusLabel() {
    switch (_loc.status) {
      case LocationStatus.idle:
        return '未开始';
      case LocationStatus.waiting:
        return '等待定位结果…';
      case LocationStatus.success:
        return '定位成功';
      case LocationStatus.failed:
        return '定位失败';
      case LocationStatus.timeout:
        return '定位超时';
    }
  }

  String _fmt(DateTime? t) {
    if (t == null) return '—';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  }

  void _retry() {
    _loc.start();
    setState(() {});
  }

  void _copy() {
    final LocationResult? lr = _loc.lastResult;
    final StringBuffer buf = StringBuffer()
      ..writeln('=== RunLoop 定位诊断 ===')
      ..writeln('时间：${DateTime.now()}')
      ..writeln('定位状态：${_statusLabel()}')
      ..writeln('请求开始：${_fmt(_loc.requestStartTime)}')
      ..writeln('最近回调：${_fmt(_loc.lastCallbackAt)}')
      ..writeln('系统定位开关：$_systemLocation')
      ..writeln('应用定位权限：$_appPermission')
      ..writeln('错误详情：${_loc.errorDetail ?? '无'}');
    if (lr != null) {
      buf
        ..writeln('经度：${lr.longitude}')
        ..writeln('纬度：${lr.latitude}')
        ..writeln('精度：${lr.accuracy} m')
        ..writeln('定位类型：${lr.locationType}（1=GPS）')
        ..writeln('速度：${lr.speed}')
        ..writeln('定位时间：${lr.timestamp}');
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    setState(() => _copyTip = '已复制到剪贴板（不含任何 API Key / 密码）');
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LocationResult? lr = _loc.lastResult;
    return Scaffold(
      appBar: AppBar(title: const Text('定位诊断')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _row('定位状态', _statusLabel()),
          _row('请求开始', _fmt(_loc.requestStartTime)),
          _row('最近回调', _fmt(_loc.lastCallbackAt)),
          _row('系统定位开关', _systemLocation),
          _row('应用定位权限', _appPermission),
          _row('错误详情', _loc.errorDetail ?? '无'),
          if (lr != null) ...<Widget>[
            _row('经度', '${lr.longitude}'),
            _row('纬度', '${lr.latitude}'),
            _row('精度', '${lr.accuracy} m'),
            _row('定位类型', '${lr.locationType}'),
            _row('定位时间', '${lr.timestamp}'),
          ],
          const SizedBox(height: 16),
          if (_copyTip != null)
            Text(_copyTip!, style: const TextStyle(color: Colors.green)),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新定位'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy),
                  label: const Text('复制诊断信息'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(color: Colors.grey[700])),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}
