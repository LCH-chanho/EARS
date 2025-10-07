// lib/hud_screen.dart

// 1. STT/사이렌/경적(BT 이벤트) 7초 표시 + 경고 테두리색(siren = red, horn = green)
// 2. 위치 추적 250ms 주기 간격, 지도 자동 추적 토글(OFF/ON)
// 3. 카메라 이동 버퍼링 - 최소 간격(150ms) + 스냅/애니메이션 혼합(거리 기반)
// 4. HUD 반사용 전체 좌우 반전
// 5. 주소 입력 화면으로 전환(세로 고정), 복귀 시 HUD 유지

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:location/location.dart' as loc;
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'address_input_screen.dart';
import 'package:http/http.dart' as http;

// API 키값들
const String KAKAO_MOBILITY_KEY = '9623a32ea8eab0b9dd6e1273e2b8787f';
const String GOOGLE_MAPS_KEY = 'AIzaSyD2SjuehFRtjXEBsK1-ugBvgMU4wrtn7Os';

class HUDScreen extends StatefulWidget {
  final BluetoothConnection connection; // 블루투스 연결 객체
  final Stream<Uint8List> stream; // 블루투스 데이터 스트림
  final LatLng? start; // 경로 시작 좌표
  final LatLng? end; // 경로 끝 좌표

  const HUDScreen({
    super.key,
    required this.connection,
    required this.stream,
    this.start,
    this.end,
  });

  @override
  State<HUDScreen> createState() => _HUDScreenState();
}

class _HUDScreenState extends State<HUDScreen> {
  // HUD 경고 관련
  bool showAlert = false; // 경고 아이콘 표시 여부
  String alertType = "siren"; // 경고 타입 (siren/horn)
  double signalDegree = 0; // 경고 방향 각도
  DateTime? lastAlertTime; // 마지막 경고 표시 시간

  // 지도 관련
  Set<Polyline> _polylines = {}; // 경로 선
  Set<Marker> _markers = {}; // 마커(출발, 도착)
  GoogleMapController? mapController;

  // 위치 추적
  final location = loc.Location();
  LatLng? currentLocation;
  bool _isTracking = false; // 지도 자동 추적 여부
  StreamSubscription<loc.LocationData>? _locationSubscription;

  // STT 텍스트 관련
  String? _receivedText; // 수신된 STT 텍스트
  DateTime? _lastTextTime; // STT 표시 시작 시간

  // ===== 버퍼 개선: 카메라 업데이트 레이트 리미터 / 스냅-애니메이션 혼합 =====
  static const int _minUpdateGapMs = 150; // 카메라 업데이트 최소 간격(너무 잦은 호출 방지)
  DateTime _lastCameraUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastCameraTarget;

  @override
  void initState() {
    super.initState();
    _initLocation(); // 현재 위치 초기화

    // 블루투스 데이터 수신 처리
    widget.stream.listen((data) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleBluetoothData(data);
      });
    });

    // start/end 좌표가 있으면 경로 탐색
    if (widget.start != null && widget.end != null) {
      _drawRoute(widget.start!, widget.end!);
    }
  }

  /// 현재 위치 초기화 + 위치 추적 리스너 등록
  void _initLocation() async {
    // 위치 콜백 빈도/정확도 튜닝 (버퍼/렌더링 안정화)
    await location.changeSettings(
      interval: 250, // 약 4Hz
      distanceFilter: 0,
      accuracy: loc.LocationAccuracy.navigation,
    );

    final locData = await location.getLocation();
    setState(() {
      currentLocation = LatLng(locData.latitude!, locData.longitude!);
    });

    _locationSubscription = location.onLocationChanged.listen((locData) {
      currentLocation = LatLng(locData.latitude!, locData.longitude!);
      // 자동 추적 상태면 카메라 이동(레이트 리미터 + 스냅/애니 적용)
      if (_isTracking) {
        _updateCameraToCurrent(animatePreferred: true);
      }
    });
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    super.dispose();
  }

  // ==============================
  // 블루투스 데이터 처리
  // ==============================

  /// 블루투스 데이터 처리 (STT 텍스트 또는 경고 신호)
  void _handleBluetoothData(Uint8List data) {
    final str = utf8.decode(data).trim();

    // STT 텍스트 수신 (형식: text=인식된문장)
    if (str.startsWith("text=")) {
      final now = DateTime.now();
      final received = str.substring(5);
      setState(() {
        _receivedText = received;
        _lastTextTime = now;
      });
      // 7초 뒤 자동 삭제
      Timer(const Duration(seconds: 7), () {
        if (!mounted) return;
        if (_lastTextTime != null &&
            DateTime.now().difference(_lastTextTime!) >=
                const Duration(seconds: 7)) {
          setState(() {
            _receivedText = null;
          });
        }
      });
      return;
    }

    // 경고 신호 수신 (형식: type,degree) — 이제 type은 siren/horn만 유효
    if (str.contains(",")) {
      final parts = str.split(",");
      if (parts.length == 2) {
        final type = parts[0].trim().toLowerCase();
        // none 제거: siren/horn 외 문자열은 무시
        if (type != 'siren' && type != 'horn') return;

        final deg = double.tryParse(parts[1]);
        final now = DateTime.now();
        if (deg != null) {
          // 7초 이상 지난 경우에만 새 경고 표시
          if (lastAlertTime == null ||
              now.difference(lastAlertTime!) > const Duration(seconds: 7)) {
            setState(() {
              showAlert = true;
              alertType = type; // siren 또는 horn
              signalDegree = deg;
              lastAlertTime = now;
            });
            Timer(const Duration(seconds: 7), () {
              if (mounted) {
                setState(() {
                  showAlert = false;
                });
              }
            });
          }
        }
      }
    }
  }

  // ==============================
  // 경로 탐색 (카카오 → 구글 폴백)
  // ==============================

  // 카카오 API 호출 (실패/예외 시 빈 리스트 반환)
  Future<List<LatLng>> _fetchKakaoRoute(LatLng start, LatLng end) async {
    if (KAKAO_MOBILITY_KEY.isEmpty) return [];
    try {
      final uri = Uri.parse(
        'https://apis-navi.kakaomobility.com/v1/directions'
        '?origin=${start.longitude},${start.latitude}'
        '&destination=${end.longitude},${end.latitude}'
        '&summary=false&alternatives=false&priority=RECOMMEND&road_details=true',
      );
      final res = await http.get(
        uri,
        headers: {
          'Authorization': 'KakaoAK $KAKAO_MOBILITY_KEY',
          'Content-Type': 'application/json',
        },
      );
      if (res.statusCode != 200) return [];

      final map = json.decode(res.body);
      if (map['routes'] == null || (map['routes'] as List).isEmpty) return [];

      final sections = (map['routes'][0]['sections'] as List?) ?? const [];
      final List<LatLng> pts = [];
      for (final sec in sections) {
        final roads = (sec['roads'] as List?) ?? const [];
        for (final road in roads) {
          final verts = (road['vertexes'] as List?)?.cast<num>();
          if (verts == null) continue;
          for (int i = 0; i + 1 < verts.length; i += 2) {
            final x = verts[i].toDouble();
            final y = verts[i + 1].toDouble();
            pts.add(LatLng(y, x));
          }
        }
      }
      return pts;
    } catch (_) {
      return [];
    }
  }

  // 구글 Directions API 호출 (실패/예외 시 빈 리스트 반환)
  Future<List<LatLng>> _fetchGoogleRoute(LatLng start, LatLng end) async {
    if (GOOGLE_MAPS_KEY.isEmpty) return [];
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${start.latitude},${start.longitude}'
        '&destination=${end.latitude},${end.longitude}'
        '&mode=transit'
        '&key=$GOOGLE_MAPS_KEY',
      );
      final res = await http.get(url);
      if (res.statusCode != 200) return [];

      final data = json.decode(res.body);
      if (data['status'] != 'OK') return [];

      final points = data['routes'][0]['overview_polyline']['points'];
      return _decodePolyline(points);
    } catch (_) {
      return [];
    }
  }

  // 경로 탐색 실행 (카카오 → 구글 순, 빈 리스트 기반 폴백)
  Future<void> _drawRoute(LatLng start, LatLng end) async {
    List<LatLng> decoded = await _fetchKakaoRoute(start, end);

    // 카카오 실패 시 Google API 시도
    if (decoded.isEmpty) {
      decoded = await _fetchGoogleRoute(start, end);
    }

    if (decoded.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('경로를 찾지 못했습니다 (Kakao/Google 실패)')),
      );
      return;
    }

    setState(() {
      _polylines = {
        Polyline(
          polylineId: const PolylineId("route"),
          color: Colors.blue,
          width: 5,
          points: decoded, // ✅ non-null, 빈 리스트일 수만 있음
        ),
      };
      _markers = {
        Marker(markerId: const MarkerId("start"), position: start),
        Marker(markerId: const MarkerId("end"), position: end),
      };
    });

    if (mapController != null) {
      mapController!.animateCamera(CameraUpdate.newLatLng(decoded.first));
    }
  }

  /// 구글 Polyline 문자열을 LatLng 리스트로 디코딩
  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  // ==============================
  // 카메라 업데이트(버퍼 최적화)
  // ==============================

  // 현재 위치로 카메라 이동 (레이트 리미터 + 스냅/애니메이션 혼합)
  void _updateCameraToCurrent({bool animatePreferred = true}) {
    if (mapController == null || currentLocation == null) return;

    final now = DateTime.now();
    if (now.difference(_lastCameraUpdate).inMilliseconds < _minUpdateGapMs) {
      return; // 호출 빈도 제한
    }

    // 이동 거리(대략 m). 가까우면 스냅, 멀면 애니메이션
    double meters = 0;
    if (_lastCameraTarget != null) {
      meters = _haversine(
        _lastCameraTarget!.latitude,
        _lastCameraTarget!.longitude,
        currentLocation!.latitude,
        currentLocation!.longitude,
      );
    }
    _lastCameraTarget = currentLocation;

    final bool bigMove = meters > 30; // 큰 이동 기준(필요시 조정)
    final useAnimate = animatePreferred && bigMove;

    final update = CameraUpdate.newLatLng(currentLocation!);
    if (useAnimate) {
      mapController!.animateCamera(update);
    } else {
      mapController!.moveCamera(update);
    }

    _lastCameraUpdate = now;
  }

  // 단순 거리 계산(m) – 폴리라인 거리용 하버사인
  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) *
            cos(_deg2rad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  double _deg2rad(double deg) => deg * pi / 180.0;

  // ==============================
  // UI 유틸
  // ==============================

  /// 지도 버튼 + 라벨 생성
  Widget _labeledFab({
    required String heroTag,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? backgroundColor,
    String? tooltip,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Tooltip(
          message: tooltip ?? label,
          child: FloatingActionButton.small(
            heroTag: heroTag,
            onPressed: onPressed,
            backgroundColor: backgroundColor,
            child: Icon(icon),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  // ====== 알림 테두리 색상 매핑 (siren=빨강, horn=초록)
  Color _alertBorderColor() {
    switch (alertType) {
      case 'siren':
        return Colors.redAccent;
      case 'horn':
        return Colors.greenAccent;
      default:
        return Colors.transparent; // 미지정 타입은 강조 없음
    }
  }

  double _alertBorderWidth() => showAlert ? 6.0 : 0.0;

  // ==============================
  // UI 빌드
  // ==============================

  @override
  Widget build(BuildContext context) {
    final fullWidth = MediaQuery.of(context).size.width;
    final fullHeight = MediaQuery.of(context).size.height;
    final cx = fullWidth * 0.25;
    final cy = fullHeight / 2;

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..scale(-1.0, 1.0, 1.0), // 좌우 반전 (화면 전체)
      child: Scaffold(
        body: Row(
          children: [
            // ===== 좌측 HUD 영역 (경고 테두리)
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _alertBorderColor().withOpacity(
                      showAlert ? 1.0 : 0.0,
                    ),
                    width: _alertBorderWidth(),
                  ),
                  boxShadow: showAlert
                      ? [
                          BoxShadow(
                            color: _alertBorderColor().withOpacity(0.25),
                            blurRadius: 16,
                            spreadRadius: 1.5,
                          ),
                        ]
                      : [],
                ),
                child: Stack(
                  children: [
                    // 차량 아이콘
                    Positioned(
                      left: cx - 30,
                      top: cy - 30,
                      child: Image.asset('assets/car.png', width: 60),
                    ),
                    // 경고 방향 신호
                    if (showAlert)
                      Positioned(
                        top:
                            cy + 100 * sin((signalDegree - 90) * pi / 180) - 20,
                        left:
                            cx - 100 * cos((signalDegree - 90) * pi / 180) - 20,
                        child: Transform.rotate(
                          angle: (135 - signalDegree) * pi / 180,
                          child: Image.asset('assets/signal.png', width: 40),
                        ),
                      ),
                    // 경고 타입 아이콘 (siren/horn만)
                    if (showAlert)
                      Positioned(
                        top:
                            cy + 160 * sin((signalDegree - 90) * pi / 180) - 20,
                        left:
                            cx - 160 * cos((signalDegree - 90) * pi / 180) - 20,
                        child: Image.asset(
                          alertType == "horn"
                              ? 'assets/horn.png'
                              : 'assets/siren.png',
                          width: 40,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // ===== 우측 지도 영역 =====
            Expanded(
              child: Stack(
                children: [
                  GoogleMap(
                    onMapCreated: (controller) => mapController = controller,
                    initialCameraPosition: const CameraPosition(
                      target: LatLng(37.5665, 126.9780),
                      zoom: 14,
                    ),
                    polylines: _polylines,
                    markers: _markers,
                    myLocationEnabled: true,
                    myLocationButtonEnabled: false,
                    compassEnabled: false,
                    zoomControlsEnabled: false,
                  ),
                  // STT 텍스트 팝업
                  if (_receivedText != null)
                    Positioned(
                      bottom: 10,
                      left: 10,
                      right: 45,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _receivedText!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  // 지도 버튼 영역
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _labeledFab(
                          heroTag: "routeBtn",
                          icon: Icons.route,
                          label: "경로 지정",
                          tooltip: "출발지/도착지 입력",
                          onPressed: () async {
                            await SystemChrome.setPreferredOrientations([
                              DeviceOrientation.portraitUp,
                            ]);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AddressInputScreen(
                                  connection: widget.connection,
                                  stream: widget.stream,
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        _labeledFab(
                          heroTag: "locBtn",
                          icon: Icons.my_location,
                          label: "내 위치",
                          tooltip: "내 위치로 이동",
                          onPressed: () {
                            if (currentLocation != null) {
                              // 버튼으로 이동할 때도 레이트 리미터/스냅 적용
                              _updateCameraToCurrent(animatePreferred: true);
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        _labeledFab(
                          heroTag: "trackBtn",
                          icon: Icons.gps_fixed,
                          label: _isTracking ? "추적 ON" : "추적 OFF",
                          tooltip: _isTracking ? "실시간 추적 해제" : "실시간 추적 활성화",
                          backgroundColor: _isTracking
                              ? Colors.green
                              : Colors.grey,
                          onPressed: () {
                            setState(() {
                              _isTracking = !_isTracking;
                            });
                            if (_isTracking) {
                              // 즉시 현재 위치로 스냅
                              _updateCameraToCurrent(animatePreferred: false);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
