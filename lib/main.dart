import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/location/location_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 高德定位隐私合规 + 设置 Key（必须在任何定位调用前执行）。
  LocationService.init();
  runApp(const RunLoopApp());
}

class RunLoopApp extends StatelessWidget {
  const RunLoopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '环跑',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
