// lib/main.dart

// 1. 앱 시작 전에 화면 방향을 가로고정
// 2. HUD 반사용 전체 좌우 반전
// 3. 최초 진입 화면: BluetoothConnectScreen
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bluetooth_connect_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const HUDApp());
}

class HUDApp extends StatelessWidget {
  const HUDApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scale(-1.0, 1.0, 1.0), // 좌우 반전
        child: const BluetoothConnectScreen(),
      ),
    );
  }
}
