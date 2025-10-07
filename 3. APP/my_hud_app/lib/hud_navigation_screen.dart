// lib/hud_navigation_screen.dart

// 1. 카카오 경로 탐색 + 턴 안내(guide) 파싱/표시
// 2. Course-Up(진행방향 기준 회전) + 방위각 스무딩/히스테리시스 + 최소 업데이트 주기
// 3. cameras.json 로딩 후 캐시(Map)로 제한속도 관리(snippet 의존 X)
// 4. 반경 200M 카메라 감지 -> 제한속도 UI 표기 + 라즈베리 speed_limit=숫지/none 전송(중복 방지)
// 5. 반경 500M 카메라 오버레이(미니 아이콘) 표시
// 6. 지도 드래그 시 5초 뒤 자동 추적 복귀
// 7. 경로 이탈/초기 진입 시 자동 재탐색(쿨다운 20초, 이탈 임계 값: 60m)
// 8. STT/사이렌/경적(BT 이벤트) 7초 표시 + 경고 테두리색(siren = red, horn = green)
// 9. HUD 반사용 전체 좌우 반전

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show setEquals, debugPrint;
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:location/location.dart';

// API 키 값들
const String KAKAO_MOBILITY_KEY = '9623a32ea8eab0b9dd6e1273e2b8787f';
const String GOOGLE_MAPS_KEY = 'AIzaSyD2SjuehFRtjXEBsK1-ugBvgMU4wrtn7Os';

class HUDSplitNavigationScreen extends StatefulWidget {
  final BluetoothConnection connection;
  final Stream<Uint8List> stream;
  final LatLng start;
  final LatLng end;

  const HUDSplitNavigationScreen({
    super.key,
    required this.connection,
    required this.stream,
    required this.start,
    required this.end,
  });

  @override
  State<HUDSplitNavigationScreen> createState() =>
      _HUDSplitNavigationScreenState();
}

class _HUDSplitNavigationScreenState extends State<HUDSplitNavigationScreen> {
  GoogleMapController? mapController;

  // 지도 요소
  Set<Polyline> _polylines = {};
  Set<Marker> _markers = {};
  Set<Marker> _cameraMarkers = {};
  Set<Marker> _nearbyCameraOverlays = {};

  // 블루투스 수신(STT/사이렌) 관련
  String? _receivedText;
  DateTime? _lastTextTime;
  bool showAlert = false;
  String alertType = "siren"; // siren 또는 horn
  double signalDegree = 0;
  DateTime? lastAlertTime;

  // 위치 추적
  final location = Location();
  StreamSubscription<LocationData>? _locationSubscription;
  LatLng? currentLocation;
  bool _isTracking = true;

  bool _ignoreNextCameraMoveStarted = false;

  // 제한속도 표시/전송 상태
  String? _currentSpeedLimit; // UI에 띄울 숫자 문자열(예: "60")
  String _lastSentSpeedLimit = 'none'; // 마지막 전송 값(중복 방지)
  final Set<String> _shownCameraIds = {};
  final double cameraAlertRadius = 200.0;
  final double overlayRadius = 500.0;
  BitmapDescriptor? _speedIcon;

  // cameras.json 파싱 캐시 (markerId -> "60")
  final Map<String, String> _cameraLimitById = {};

  // 지도 드래그 복귀
  Timer? _retrackTimer;
  DateTime? _lastUserCameraMove;
  static const Duration kRetrackDelay = Duration(seconds: 5);

  // 턴 안내
  List<Map<String, dynamic>> _kakaoGuides = [];
  int _currentGuideIndex = 0;
  double? _distanceToNextGuide;

  // Course-Up 회전 최적화
  double _currentBearing = 0.0;
  double _lastAppliedBearing = 0.0;
  static const int _minUpdateGapMs = 120;
  DateTime _lastCameraUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  static const double _bearingHysteresis = 3;
  static const double _bearingSmoothing = 0.40;

  // 자동 재탐색 제어
  DateTime _lastRerouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration kRerouteCooldown = Duration(seconds: 20);
  static const double kRerouteDeviationThreshold = 60.0; // m

  @override
  void initState() {
    super.initState();

    // 위치 이벤트 설정(실시간 내비게이션에 적합한 주기/정확도로 조정)
    location.changeSettings(
      interval: 250,
      distanceFilter: 0,
      accuracy: LocationAccuracy.navigation,
    );

    _loadSpeedIcon();
    _fetchAndDrawRoute(); // 폴백 호출
    _loadCameraMarkers();

    // Bluetooth 수신 처리 (프레임 빌드 직후 안전하게 UI 반영)
    widget.stream.listen((data) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleBluetoothData(data);
      });
    });

    // 위치 스트림
    _locationSubscription = location.onLocationChanged.listen((locData) {
      currentLocation = LatLng(locData.latitude!, locData.longitude!);

      // 카메라/제한속도
      _checkNearbyCameras();
      _updateNearbyCameraOverlays();

      // 턴까지 거리
      _updateNextGuideDistance();

      // 카메라 추적/회전
      if (_isTracking) {
        _updateCameraCourseUp();
      }

      // 자동 재탐색 트리거
      _maybeReroute();
    });
  }

  @override
  void dispose() {
    // 정리 - 지도 드래그 복귀 타이머/위치/BT 해제
    _cancelRetrackTimer();
    _locationSubscription?.cancel();

    // 종료/이탈 시 none 한 번 보내 정리
    _broadcastSpeedLimit(null);

    super.dispose();
  }

  // =========================
  // Course-Up 유틸/핵심 로직
  // =========================

  // 방위각 계산 - 현재위치→목표지점의 방위각(0~360) + 보정 포함.
  double _computeBearing(double lat1, double lon1, double lat2, double lon2) {
    final dLon = (lon2 - lon1) * pi / 180.0;
    final y = sin(dLon) * cos(lat2 * pi / 180.0);
    final x =
        cos(lat1 * pi / 180.0) * sin(lat2 * pi / 180.0) -
        sin(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * cos(dLon);
    double brng = atan2(y, x) * 180.0 / pi;
    brng = (brng + 360.0) % 360.0;
    return brng;
  }

  // 스무딩 - 회전 튀는 걸 방지. 최근 방위각과 새 방위각 사이를 alpha로 보간.
  double _smoothBearing(double prev, double next, double alpha) {
    double diff = ((next - prev + 540) % 360) - 180;
    return (prev + alpha * diff + 360) % 360;
  }

  // 타겟점 - 가이드에 따라 다음 회전 지점을 알려줌.
  LatLng _nextTargetForBearing() {
    if (_kakaoGuides.isNotEmpty && _currentGuideIndex < _kakaoGuides.length) {
      final g = _kakaoGuides[_currentGuideIndex];
      final lat = (g['y'] as double);
      final lng = (g['x'] as double);
      return LatLng(lat, lng);
    }
    return widget.end;
  }

  // Course-Up - 일정 각도/주기 이상 변할 때만 지도 회전(애니메이션/즉시) 적용
  void _updateCameraCourseUp() {
    if (currentLocation == null || mapController == null) return;

    final now = DateTime.now();
    if (now.difference(_lastCameraUpdate).inMilliseconds < _minUpdateGapMs) {
      return;
    }

    final target = _nextTargetForBearing();
    final newBearing = _computeBearing(
      currentLocation!.latitude,
      currentLocation!.longitude,
      target.latitude,
      target.longitude,
    );

    final delta = ((newBearing - _lastAppliedBearing + 540) % 360) - 180;
    if (delta.abs() < _bearingHysteresis) return;

    _currentBearing = _smoothBearing(
      _lastAppliedBearing,
      newBearing,
      _bearingSmoothing,
    );
    _lastAppliedBearing = _currentBearing;

    final useAnimate = delta.abs() >= 15;

    _ignoreNextCameraMoveStarted = true;
    final camPos = CameraPosition(
      target: currentLocation!,
      zoom: 17,
      bearing: _currentBearing,
      tilt: 0,
    );

    if (useAnimate) {
      mapController!.animateCamera(CameraUpdate.newCameraPosition(camPos));
    } else {
      mapController!.moveCamera(CameraUpdate.newCameraPosition(camPos));
    }

    _lastCameraUpdate = now;
  }

  // 외부에서 현재 위치로 즉시 복귀할 때 사용
  void _centerToCurrent() {
    if (currentLocation != null && mapController != null) {
      _updateCameraCourseUp();
    }
  }

  // 사용자가 지도 조작을 멈추면 kRetrackDelay 후 자동으로 센터로 이동
  void _scheduleRetrack() {
    _retrackTimer?.cancel();
    final scheduledAt = _lastUserCameraMove;
    _retrackTimer = Timer(kRetrackDelay, () {
      if (!mounted) return; // 위젯 파괴 시 setState 방지

      if (!_isTracking &&
          scheduledAt != null &&
          _lastUserCameraMove == scheduledAt &&
          DateTime.now().difference(scheduledAt) >= kRetrackDelay) {
        setState(() => _isTracking = true);
        _centerToCurrent();
      }
    });
  }

  void _cancelRetrackTimer() {
    _retrackTimer?.cancel();
    _retrackTimer = null;
  }

  // 제한속도 아이콘 로드
  Future<void> _loadSpeedIcon() async {
    final cfg = const ImageConfiguration(size: Size(24, 24));
    final icon = await BitmapDescriptor.fromAssetImage(cfg, 'assets/speed.png');
    setState(() => _speedIcon = icon);
  }

  // =========================
  // 단속 카메라 감지 — 캐시(Map) 기반으로 제한속도 결정 + BT 전송
  // =========================
  //가장 가까운 카메라의 제한속도를 UI/BT에 반영(중복 전송 방지)
  void _checkNearbyCameras() {
    //
    if (currentLocation == null) return;

    String? nearestLimit; // "60" 같은 문자열
    double nearestDist = double.infinity;

    for (final marker in _cameraMarkers) {
      final d = _calculateDistance(
        currentLocation!.latitude,
        currentLocation!.longitude,
        marker.position.latitude,
        marker.position.longitude,
      );

      if (d <= cameraAlertRadius) {
        final id = marker.markerId.value;
        final limit = _cameraLimitById[id]; // snippet 대신 캐시 조회
        if (limit != null && d < nearestDist) {
          nearestDist = d;
          nearestLimit = limit;
        }
      }
    }

    // UI + BT 업데이트 (가장 가까운 제한속도 적용)
    if (nearestLimit != null) {
      if (_currentSpeedLimit != nearestLimit) {
        setState(() => _currentSpeedLimit = nearestLimit);
        debugPrint(
          '[CAM] hit: $nearestLimit km/h (dist=${nearestDist.toStringAsFixed(1)}m)',
        );
        _broadcastSpeedLimit(nearestLimit); // 라즈베리파이로 전송
      }
    } else {
      if (_currentSpeedLimit != null) {
        setState(() => _currentSpeedLimit = null);
        debugPrint('[CAM] leave radius → hide sign');
        _broadcastSpeedLimit(null); // 반경 이탈시 none을 전송
      }
    }
  }

  // 라즈베리파이에 문자열 전송(중복 전송 방지, 반드시 개행 포함)
  Future<void> _broadcastSpeedLimit(String? limit) async {
    final value = limit ?? 'none';
    if (_lastSentSpeedLimit == value) return; // 동일 값이면 무시

    final line = 'speed_limit=$value\n'; // ← Pi는 readline() 사용하므로 \n 필수
    try {
      widget.connection.output.add(Uint8List.fromList(utf8.encode(line)));
      await widget.connection.output.allSent;
      _lastSentSpeedLimit = value;
      debugPrint('[BT] sent: $line');
    } catch (e) {
      debugPrint('[BT] send error: $e');
    }
  }

  // 오버레이 - 반경 500M 내 카메라에 미니 아이콘(속도 표지)을 표시
  void _updateNearbyCameraOverlays() {
    if (currentLocation == null || _speedIcon == null) return;
    final newOverlays = <Marker>{};
    for (final cam in _cameraMarkers) {
      final d = _calculateDistance(
        currentLocation!.latitude,
        currentLocation!.longitude,
        cam.position.latitude,
        cam.position.longitude,
      );
      if (d <= overlayRadius) {
        newOverlays.add(
          Marker(
            markerId: MarkerId('camera_overlay_${cam.markerId.value}'),
            position: cam.position,
            icon: _speedIcon!,
            zIndex: 5,
            anchor: const Offset(0.5, 0.5),
          ),
        );
      }
    }
    if (setEquals(newOverlays, _nearbyCameraOverlays)) return;
    setState(() {
      _nearbyCameraOverlays = newOverlays;
    });
  }

  //거리함수 - 두 위도/경도 간의 거리(m)를 구함 (Haversine 공식)
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
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

  // =========================
  // 카메라 마커 로딩 + 제한속도 숫자 캐시
  // =========================
  Future<void> _loadCameraMarkers() async {
    // JSON에서 카메라 좌표/제한속도 파싱
    final jsonStr = await rootBundle.loadString('assets/cameras.json');
    final data = json.decode(jsonStr);
    final List records = data['records'];

    final markers = records
        .map<Marker?>((record) {
          final latStr = record['위도'];
          final lngStr = record['경도'];
          if (latStr == null || lngStr == null) return null;
          final lat = double.tryParse(latStr);
          final lng = double.tryParse(lngStr);
          if (lat == null || lng == null) return null;

          final idRaw = record['무인교통단속카메라관리번호'] ?? 'unknown';
          final id = 'camera_$idRaw';
          final loc = record['설치장소'] ?? '단속카메라';
          final rawLimit = record['제한속도'];

          // 제한속도 숫자만 추출해 캐시(Map)에 저장
          final parsedLimit = _parseSpeedLimit(rawLimit); // "60" / null
          if (parsedLimit != null) {
            _cameraLimitById[id] = parsedLimit;
          }

          return Marker(
            markerId: MarkerId(id),
            position: LatLng(lat, lng),
            // 안내 텍스트는 그대로 두되, 로직은 캐시(Map)를 사용
            infoWindow: InfoWindow(
              title: loc,
              snippet: parsedLimit != null
                  ? '제한속도 $parsedLimit km/h'
                  : '제한속도 정보 없음',
            ),
            visible: false,
          );
        })
        .whereType<Marker>()
        .toSet();

    setState(() {
      _cameraMarkers = markers;
    });

    _updateNearbyCameraOverlays();
    debugPrint(
      '[CAM] loaded ${_cameraMarkers.length} cameras, '
      '${_cameraLimitById.length} with speed limits',
    );
  }

  // 제한속도 파싱 - "60km/h", "속도 80", "80" 등에서 숫자만 안전 추출(10~140)
  String? _parseSpeedLimit(dynamic raw) {
    if (raw == null) return null;
    final s = raw.toString();
    final m = RegExp(r'(\d{2,3})').firstMatch(s);
    if (m == null) return null;
    final n = int.tryParse(m.group(1)!);
    if (n == null) return null;
    if (n < 10 || n > 140) return null;
    return '$n';
  }

  // ==============================
  // 블루투스 수신 처리 (none 제거)
  // ==============================
  //  - STT 텍스트:  "text=..." (7초 표시)
  //  - 경고 신호:   "siren,90" / "horn,270" (7초 표시)

  void _handleBluetoothData(Uint8List data) {
    final str = utf8.decode(data).trim();
    if (str.startsWith("text=")) {
      final now = DateTime.now();
      setState(() {
        _receivedText = str.substring(5);
        _lastTextTime = now;
      });
      Timer(const Duration(seconds: 7), () {
        if (mounted &&
            DateTime.now().difference(_lastTextTime!) >=
                const Duration(seconds: 7)) {
          setState(() {
            _receivedText = null;
          });
        }
      });
      return;
    }

    if (str.contains(",")) {
      final parts = str.split(",");
      if (parts.length == 2) {
        final type = parts[0].trim().toLowerCase();
        if (type != 'siren' && type != 'horn') return; // none/기타 무시

        final deg = double.tryParse(parts[1]);
        final now = DateTime.now();
        if (deg != null) {
          if (lastAlertTime == null ||
              now.difference(lastAlertTime!) > const Duration(seconds: 7)) {
            setState(() {
              showAlert = true;
              alertType = type;
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
  // 경로 탐색 - 실패 시 빈 리스트 반환, 호출부 폴백)
  // ==============================
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
      final List<Map<String, dynamic>> guides = [];

      for (final sec in sections) {
        final roads = (sec['roads'] as List?) ?? const [];
        for (final road in roads) {
          final verts = (road['vertexes'] as List?)?.cast<num>();
          if (verts == null) continue;
          for (int i = 0; i + 1 < verts.length; i += 2) {
            pts.add(LatLng(verts[i + 1].toDouble(), verts[i].toDouble()));
          }
        }
        final gList = (sec['guides'] as List?) ?? const [];
        for (final g in gList) {
          guides.add({
            'name': g['name'] ?? '',
            'x': g['x']?.toDouble(),
            'y': g['y']?.toDouble(),
            'turnType': g['turnType'],
            'distance': g['distance'],
          });
        }
      }

      if (guides.isNotEmpty) {
        setState(() {
          _kakaoGuides = guides;
          _currentGuideIndex = 0;
        });
      }

      return pts;
    } catch (_) {
      return [];
    }
  }

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
      // 폴백 - 구글 경로. 제한된 환경에서는 실패할 수 있으므로 조용히 빈 리스트 반환.
      if (res.statusCode != 200) return [];

      final data = json.decode(res.body);
      if (data['status'] != 'OK') return [];

      final points = data['routes'][0]['overview_polyline']['points'];
      return _decodePolyline(points);
    } catch (_) {
      return [];
    }
  }

  Future<void> _fetchAndDrawRoute() async {
    List<LatLng> decoded = await _fetchKakaoRoute(widget.start, widget.end);
    if (decoded.isEmpty) {
      decoded = await _fetchGoogleRoute(widget.start, widget.end);
    }

    if (decoded.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('경로 탐색 실패 (Kakao/Google)')));
      return;
    }

    _applyPolylineAndMarkers(decoded);
  }

  // 렌더링 적용 - 라인/마커UI 갱신 및 근접 오버레이 업데이트
  void _applyPolylineAndMarkers(List<LatLng> points) {
    setState(() {
      _polylines = {
        Polyline(
          polylineId: const PolylineId("route"),
          color: Colors.green,
          width: 6,
          points: points,
        ),
      };

      _markers = {
        Marker(
          markerId: const MarkerId("end"),
          position: widget.end,
          infoWindow: const InfoWindow(title: "도착"),
          zIndex: 10,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      };
    });

    if (mapController != null && points.isNotEmpty) {
      mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(points.first, 15),
      );
    }
    _updateNearbyCameraOverlays();
  }

  //디코딩 - 구글 polyline 인코딩을 경로 지점으로 복원
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

  // 턴 안내 거리 - 다음 가이트까지 직선거리(m). 20m 이내면 다음 가이드로 이동
  void _updateNextGuideDistance() {
    if (currentLocation == null || _kakaoGuides.isEmpty) return;
    if (_currentGuideIndex >= _kakaoGuides.length) return;

    final guide = _kakaoGuides[_currentGuideIndex];

    final double? gLat = (guide['y'] as num?)?.toDouble();
    final double? gLng = (guide['x'] as num?)?.toDouble();
    if (gLat == null || gLng == null) return;

    final dist = _calculateDistance(
      currentLocation!.latitude,
      currentLocation!.longitude,
      gLat,
      gLng,
    );

    setState(() {
      _distanceToNextGuide = dist;
    });

    if (dist <= 20 && _currentGuideIndex < _kakaoGuides.length - 1) {
      _currentGuideIndex++;
    }
  }

  // ==============================
  // 자동 재탐색 로직
  // ==============================

  void _maybeReroute() {
    if (currentLocation == null) return;

    // 경로가 없으면 최초 1회 재탐색
    if (_polylines.isEmpty) {
      _rerouteFromCurrentPosition();
      return;
    }

    final dev = _minDistanceToRoute(currentLocation!);
    if (dev > kRerouteDeviationThreshold) {
      debugPrint('[REROUTE] deviation=${dev.toStringAsFixed(1)}m > threshold');
      _rerouteFromCurrentPosition();
    }
  }

  // 현재 위치에서 목적지로 다시 재계산(쿨다운 포함)
  Future<void> _rerouteFromCurrentPosition() async {
    if (currentLocation == null) return;

    // 쿨다운
    final now = DateTime.now();
    if (now.difference(_lastRerouteAt) < kRerouteCooldown) return;
    _lastRerouteAt = now;

    final start = currentLocation!;
    final end = widget.end;

    List<LatLng> decoded = await _fetchKakaoRoute(start, end);
    if (decoded.isEmpty) {
      decoded = await _fetchGoogleRoute(start, end);
    }
    if (decoded.isEmpty) {
      debugPrint('[REROUTE] 실패 (Kakao/Google)');
      return;
    }
    _applyPolylineAndMarkers(decoded);
    debugPrint('[REROUTE] 완료: start=${start.latitude},${start.longitude}');
  }

  // 현재 위치가 기존 경로(Polyline)에서 얼마나 벗어났는지(m) 계산
  double _minDistanceToRoute(LatLng p) {
    if (_polylines.isEmpty) return double.infinity;
    final route = _polylines.first.points;
    if (route.length < 2) return double.infinity;

    double minDist = double.infinity;
    for (int i = 0; i < route.length - 1; i++) {
      final a = route[i];
      final b = route[i + 1];
      final d = _pointToSegmentDistanceMeters(p, a, b);
      if (d < minDist) minDist = d;
      if (minDist < 5.0) break; // 충분히 가깝다면 빠른 탈출
    }
    return minDist;
  }

  // 점-선분 최단거리(m) — 소구간 평면 근사
  double _pointToSegmentDistanceMeters(LatLng p, LatLng a, LatLng b) {
    const mPerDegLat = 111320.0;
    final mPerDegLngAtLat = 111320.0 * cos(p.latitude * pi / 180.0);

    final ax = 0.0;
    final ay = 0.0;
    final px = (p.longitude - a.longitude) * mPerDegLngAtLat;
    final py = (p.latitude - a.latitude) * mPerDegLat;
    final sx = (b.longitude - a.longitude) * mPerDegLngAtLat;
    final sy = (b.latitude - a.latitude) * mPerDegLat;

    final segLen2 = sx * sx + sy * sy;
    if (segLen2 == 0) {
      // a==b
      return sqrt(px * px + py * py);
    }
    double t = (px * sx + py * sy) / segLen2;
    t = t.clamp(0.0, 1.0);

    final projx = t * sx + ax;
    final projy = t * sy + ay;
    final dx = px - projx;
    final dy = py - projy;
    return sqrt(dx * dx + dy * dy);
  }

  // ==============================
  // UI - siren=red, horn=green (없으면 투명)
  // ==============================
  Color _alertBorderColor() {
    switch (alertType) {
      case 'siren':
        return Colors.redAccent;
      case 'horn':
        return Colors.greenAccent;
      default:
        return Colors.transparent;
    }
  }

  double _alertBorderWidth() => showAlert ? 6.0 : 0.0;

  @override
  Widget build(BuildContext context) {
    final fullWidth = MediaQuery.of(context).size.width;
    final fullHeight = MediaQuery.of(context).size.height;
    final cx = fullWidth * 0.25;
    final cy = fullHeight / 2;

    // HUD 반사용 전체 좌우반전 (입력 화면 제외)
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..scale(-1.0, 1.0, 1.0),
      child: Scaffold(
        body: Row(
          children: [
            // ================= 좌측: HUD 알림 영역 + 7초 표시
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
                    Positioned(
                      left: cx - 30,
                      top: cy - 30,
                      child: Image.asset('assets/car.png', width: 60),
                    ),
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

            // ================= 우측: 지도/경로 안내
            Expanded(
              child: Stack(
                children: [
                  GoogleMap(
                    onMapCreated: (controller) => mapController = controller,
                    initialCameraPosition: CameraPosition(
                      target: widget.start,
                      zoom: 15,
                    ),
                    polylines: _polylines,
                    markers: {..._markers, ..._nearbyCameraOverlays},
                    myLocationEnabled: true,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    compassEnabled: false,

                    // Course-Up 유지: 회전/기울기 제스처 비활성화
                    rotateGesturesEnabled: false,
                    tiltGesturesEnabled: false,
                    mapToolbarEnabled: false,

                    // 수동 조작 시 자동 추적을 잠시 중단하고 kRetrackDelay 후 복귀
                    onCameraMove: (pos) {
                      if (!_isTracking) {
                        _lastUserCameraMove = DateTime.now();
                        _scheduleRetrack();
                      }
                    },
                    onCameraMoveStarted: () {
                      if (_ignoreNextCameraMoveStarted) return;
                      if (_isTracking) {
                        setState(() => _isTracking = false);
                      }
                      _lastUserCameraMove = DateTime.now();
                      _scheduleRetrack();
                    },
                    onCameraIdle: () {
                      if (_ignoreNextCameraMoveStarted) {
                        _ignoreNextCameraMoveStarted = false;
                      }
                      if (!_isTracking) {
                        _lastUserCameraMove = DateTime.now();
                        _scheduleRetrack();
                      }
                    },
                  ),

                  // 턴 안내
                  if (_kakaoGuides.isNotEmpty && _distanceToNextGuide != null)
                    Positioned(
                      bottom: 10,
                      left: 10,
                      right: 45,
                      child: Card(
                        color: Colors.black87,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Icon(
                                _turnIcon(
                                  _kakaoGuides[_currentGuideIndex]['turnType'],
                                ),
                                color: Colors.white,
                                size: 32,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  "${_distanceToNextGuide!.toStringAsFixed(0)}m 후 "
                                  "${_kakaoGuides[_currentGuideIndex]['name']}에서 이동",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // STT 팝업 - 7초간 하단 표시
                  if (_receivedText != null)
                    Positioned(
                      left: 10,
                      right: 45,
                      bottom: 100,
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

                  // 나가기 버튼 - 경고 + 네비게이션 화면에서 메인 화면으로 복귀
                  Positioned(
                    top: 16,
                    right: 50,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.9),
                        foregroundColor: Colors.black,
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text("나가기"),
                    ),
                  ),

                  // 제한속도 UI - Stack 최상단, SafeArea, 터치 무시
                  if (_currentSpeedLimit != null)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: SafeArea(
                        child: IgnorePointer(
                          ignoring: true, // 지도 터치 방해 X
                          child: Image.asset(
                            'assets/speed_limit_${_currentSpeedLimit!}.png',
                            width: 90,
                            errorBuilder: (context, error, stackTrace) =>
                                const SizedBox.shrink(),
                          ),
                        ),
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

  IconData _turnIcon(int? turnType) {
    switch (turnType) {
      case 12:
        return Icons.turn_left;
      case 13:
        return Icons.turn_right;
      case 11:
        return Icons.straight;
      default:
        return Icons.navigation;
    }
  }
}
