import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/consent_screen.dart';
import 'screens/home_screen.dart';
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
      setState(() => _consented = true);
    } else {
      setState(() => _consented = false);
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
