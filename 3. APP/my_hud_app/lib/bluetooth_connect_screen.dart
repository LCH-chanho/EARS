//lib/bluetooth_connect_screen.dart

// 1. HC-06 페어링된 기기 검색 -> 주소로 소켓 연결 시도
// 2. 권한 요청(ANDROID 12+)
// 3. 연결 성공 시 HUDScreen 으로 이동
// 4. 실패 시 5초 후 자동 재시도

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'hud_screen.dart';
import 'package:permission_handler/permission_handler.dart' as perm;

class BluetoothConnectScreen extends StatefulWidget {
  const BluetoothConnectScreen({super.key});

  @override
  State<BluetoothConnectScreen> createState() => _BluetoothConnectScreenState();
}

class _BluetoothConnectScreenState extends State<BluetoothConnectScreen> {
  BluetoothConnection? connection;
  Stream<Uint8List>? bluetoothStream;
  String status = "🔍 HC-06 블루투스 검색 중...";
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    connectToHC06();
  }

  Future<void> connectToHC06() async {
    final granted = await [
      perm.Permission.bluetooth,
      perm.Permission.bluetoothScan,
      perm.Permission.bluetoothConnect,
      perm.Permission.location,
    ].request();

    if (!(granted[perm.Permission.bluetoothConnect]?.isGranted ?? false)) {
      setState(() => status = "❌ 블루투스 권한 필요");
      return;
    }

    try {
      setState(() => status = "🔄 HC-06 연결 시도 중...");
      final devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      final target = devices.firstWhere(
        (d) => d.name == "HC-06",
        orElse: () => throw Exception("HC-06 not found"),
      );
      final newConn = await BluetoothConnection.toAddress(target.address);
      connection = newConn;
      bluetoothStream = newConn.input!.asBroadcastStream();

      setState(() => status = "✅ HC-06 연결 성공!");
      await Future.delayed(const Duration(seconds: 1));

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) =>
              HUDScreen(connection: newConn, stream: bluetoothStream!),
        ),
      );
    } catch (e) {
      setState(() => status = "❌ 연결 실패. 5초 후 재시도");
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 5), connectToHC06);
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..scale(-1.0, 1.0, 1.0), // 좌우 반전
      child: Scaffold(body: Center(child: Text(status))),
    );
  }
}
