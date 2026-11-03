import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/consent_screen.dart';
import 'screens/home_screen.dart';
import 'services/client_config_service.dart';
import 'services/device_id.dart';
import 'services/location/location_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RunLoopApp());
}

const String _kPrivacyAgreedKey = 'privacy_agreed';

class RunLoopApp extends StatefulWidget {
  const RunLoopApp({super.key});

  @override
  State<RunLoopApp> createState() => _RunLoopAppState();
}

class _RunLoopAppState extends State<RunLoopApp> {
  bool? _consented; // null = 加载中

  @override
  void initState() {
    super.initState();
    _loadConsent();
  }

  Future<void> _loadConsent() async {
    bool agreed = false;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      agreed = prefs.getBool(_kPrivacyAgreedKey) ?? false;
    } catch (_) {
      agreed = false;
    }
    if (!mounted) return;
    if (agreed) {
      // 仅用户已同意时才初始化高德隐私合规。
      LocationService.init();
      _warmUpServices(); // 不 await：尽力而为，不阻塞首帧
      setState(() => _consented = true);
    } else {
      setState(() => _consented = false);
    }
  }

  /// 启动预热（阶段 K 规范⑦⑨）：设备 ID 预生成 + 远程配置拉取/沿用缓存。
  /// 仅在用户同意隐私政策后调用；设备 ID 为本地随机串（不含硬件标识符），
  /// 服务端只存其哈希。任何失败都静默——离线时 App 功能不受影响。
  Future<void> _warmUpServices() async {
    try {
      await DeviceId.get();
    } catch (_) {
      // 忽略：首次网络调用时会再试。
    }
    try {
      await appClientConfig.init();
      if (mounted) setState(() {}); // 公告等配置就绪后刷新一次
    } catch (_) {
      // 忽略：远程配置是增强而非依赖。
    }
  }

  Future<void> _onAgree() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPrivacyAgreedKey, true);
    } catch (_) {
      // 忽略存储失败，下一次启动会再次询问。
    }
    // 用户同意后才初始化高德 SDK 隐私合规。
    LocationService.init();
    _warmUpServices(); // 不 await：尽力而为，不阻塞首帧
    if (mounted) setState(() => _consented = true);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '环跑',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
      ),
      home: _consented == null
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _consented == true
              ? const HomeScreen()
              : ConsentScreen(onAgree: _onAgree),
    );
  }
}
