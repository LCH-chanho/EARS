// lib/address_input_screen.dart

// 1. 주소 자동완성 - 카카오 우선 -> 실패 시 구글 places 폴백
// 2. 지오코딩 - 카카오 우선 -> 실패 시 구글 지오코딩 폴백
// 3. 출발지 입력이 비어 있으면 GPS기반 현재 위치를 출발지로 사용
// 4. '저장 후 진행' 시 경로 확인 -> HUDSplitNavigationScreen 으로 이동
// 5. 세로 고정(입력) -> 가로 고정(메인 화면)

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:location/location.dart' as loc;
import 'dart:typed_data';

import 'hud_navigation_screen.dart';

//API 키 값들
const String KAKAO_LOCAL_KEY = '키 값 입력 필요';
const String GOOGLE_PLACES_GEOCODE_KEY = '키 값 입력 필요';

class AddressInputScreen extends StatefulWidget {
  final BluetoothConnection connection;
  final Stream<Uint8List> stream;

  const AddressInputScreen({
    super.key,
    required this.connection,
    required this.stream,
  });

  @override
  State<AddressInputScreen> createState() => _AddressInputScreenState();
}

class _AddressInputScreenState extends State<AddressInputScreen> {
  final TextEditingController startController = TextEditingController();
  final TextEditingController endController = TextEditingController();

  LatLng? _currentLocation;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _fetchCurrentLocation();
  }

  //현재 GPS 위치 가져오기
  Future<void> _fetchCurrentLocation() async {
    try {
      final location = loc.Location();
      final locData = await location.getLocation();
      setState(() {
        _currentLocation = LatLng(locData.latitude!, locData.longitude!);
      });
    } catch (e) {
      print('[GPS] 현재 위치 가져오기 실패: $e');
    }
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  // =======================================================
  // 주소 자동완성: 카카오 우선 -> 안될 경우 구글 폴백구조
  // =======================================================
  Future<List<String>> _getSuggestions(String input) async {
    final query = input.trim();
    if (query.isEmpty) return [];

    // 1) Kakao API 주소검색
    if (KAKAO_LOCAL_KEY.isNotEmpty) {
      try {
        final uri = Uri.parse(
          'https://dapi.kakao.com/v2/local/search/address.json?query=${Uri.encodeComponent(query)}&size=10',
        );
        final res = await http
            .get(uri, headers: {'Authorization': 'KakaoAK $KAKAO_LOCAL_KEY'})
            .timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          final docs = (data['documents'] as List?) ?? const [];
          final list = docs
              .map((e) => (e['address_name'] as String?) ?? '')
              .where((s) => s.isNotEmpty)
              .cast<String>()
              .toList();
          if (list.isNotEmpty) return list;
        }
      } catch (e) {
        print('[주소검색-카카오] 실패: $e');
      }
    }

    // 2) Google API 주소검색 (폴백)
    if (GOOGLE_PLACES_GEOCODE_KEY.isNotEmpty) {
      try {
        final url = Uri.parse(
          'https://maps.googleapis.com/maps/api/place/autocomplete/json'
          '?input=${Uri.encodeComponent(query)}&language=ko&key=$GOOGLE_PLACES_GEOCODE_KEY',
        );
        final response = await http
            .get(url)
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data['status'] == 'OK') {
            return List<String>.from(
              data['predictions'].map((p) => p['description']),
            );
          }
        }
      } catch (e) {
        print('[주소검색-구글] 실패: $e');
      }
    }

    return [];
  }

  // =======================================================
  // 지오코딩: 카카오 우선 → 구글 폴백
  // =======================================================
  Future<LatLng?> _getLatLngFromAddress(String address) async {
    final q = address.trim();
    if (q.isEmpty) return null;

    // 1) 카카오 → 첫 결과 사용
    if (KAKAO_LOCAL_KEY.isNotEmpty) {
      try {
        final uri = Uri.parse(
          'https://dapi.kakao.com/v2/local/search/address.json?query=${Uri.encodeComponent(q)}&size=1',
        );
        final res = await http
            .get(uri, headers: {'Authorization': 'KakaoAK $KAKAO_LOCAL_KEY'})
            .timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          final docs = (data['documents'] as List?) ?? const [];
          if (docs.isNotEmpty) {
            final x = double.tryParse(docs[0]['x'] ?? '');
            final y = double.tryParse(docs[0]['y'] ?? '');
            if (x != null && y != null) return LatLng(y, x);
          }
        }
      } catch (e) {
        print('[지오코딩-카카오] 실패: $e');
      }
    }

    // 2) Google Geocoding (폴백)
    if (GOOGLE_PLACES_GEOCODE_KEY.isNotEmpty) {
      try {
        final url = Uri.parse(
          'https://maps.googleapis.com/maps/api/geocode/json'
          '?address=${Uri.encodeComponent(q)}&key=$GOOGLE_PLACES_GEOCODE_KEY',
        );
        final response = await http
            .get(url)
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data['status'] == 'OK' && (data['results'] as List).isNotEmpty) {
            final loc = data['results'][0]['geometry']['location'];
            return LatLng(
              (loc['lat'] as num).toDouble(),
              (loc['lng'] as num).toDouble(),
            );
          }
        }
      } catch (e) {
        print('[지오코딩-구글] 실패: $e');
      }
    }

    return null;
  }

  // 저장 버튼 클릭 시 처리
  Future<void> _handleSubmit() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("경로를 지정하시겠습니까?"),
        content: const Text("출발지는 현재 위치로 자동 설정됩니다."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("아니오"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("예"),
          ),
        ],
      ),
    );

    if (!context.mounted || confirm != true) return;

    final end = await _getLatLngFromAddress(endController.text);
    final start = startController.text.isNotEmpty
        ? await _getLatLngFromAddress(startController.text)
        : _currentLocation;

    if (start != null && end != null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => HUDSplitNavigationScreen(
            connection: widget.connection,
            stream: widget.stream,
            start: start,
            end: end,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('❌ 주소 좌표 변환 실패')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("경로 입력")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TypeAheadField<String>(
              textFieldConfiguration: TextFieldConfiguration(
                controller: startController,
                decoration: const InputDecoration(
                  labelText: "출발지 주소 (비워두면 현재 위치 사용)",
                ),
              ),
              suggestionsCallback: _getSuggestions,
              itemBuilder: (context, suggestion) =>
                  ListTile(title: Text(suggestion)),
              onSuggestionSelected: (suggestion) {
                startController.text = suggestion;
              },
            ),
            const SizedBox(height: 10),
            TypeAheadField<String>(
              textFieldConfiguration: TextFieldConfiguration(
                controller: endController,
                decoration: const InputDecoration(labelText: "도착지 주소"),
              ),
              suggestionsCallback: _getSuggestions,
              itemBuilder: (context, suggestion) =>
                  ListTile(title: Text(suggestion)),
              onSuggestionSelected: (suggestion) {
                endController.text = suggestion;
              },
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _handleSubmit,
              child: const Text("저장 후 진행"),
            ),
          ],
        ),
      ),
    );
  }
}
