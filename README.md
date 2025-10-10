# EARS
청각 기능이 약화된 운전자를 위한  실시간 소리 감지 및 방향 시각화 알림 시스템 (Echo-based Alert &amp; Response System)


**1. HUD App**
├─ main.dart
│   ├─ main()                                    # 가로 모드 고정 후 앱 실행
│   └─ HUDApp.build()                            # 화면 좌우 반전 적용 + 초기화면(BluetoothConnectScreen) 진입
│   # 앱 실행 및 전체 HUD 초기화
│   # 실행 직후 블루투스 연결 화면으로 이동

├─ bluetooth_connect_screen.dart
│   ├─ connectToHC06()                           # 권한 요청, HC-06 검색 및 연결 시도 -> 성공 시 화면(HUDScreen)전환, 실패 시 5초 후 재시도
│   └─ bluetoothStream                           # 라즈베리파이 데이터 스트림(STT, 소리 분류 및 방향 값)을 HUD 화면에 전달
│   # HC-06 블루투스 탐색 및 연결 관리
│   # 연결 성공 시 HUD 화면으로 전환

├─ address_input_screen.dart
│   ├─ _fetchCurrentLocation()                   # GPS 현재 위치 추정
│   ├─ _getSuggestions()                         # 카카오/구글 주소 자동완성
│   ├─ _getLatLngFromAddress()                   # 주소 → 위도·경도 좌표 변환
│   └─ _handleSubmit()                           # 출발/도착 좌표 전달 후 화면(HUDSplitNavigationScreen) 전환
│   # 경로 탐색을 위한 주소 입력·좌표 변환 화면

├─ hud_screen.dart
│   ├─ _handleBluetoothData()                    # STT 텍스트 / 사이렌·경적 신호 수신 및 화면에 해당 아이콘 출력, 7초 후 자동 해제
│   ├─ _updateCameraToCurrent()                  # 현재 위치 기반 지도 이동 (레이트 리미터 적용)
│   ├─ _labeledFab()                             # 지도 기능 버튼(경로 지정 / 내 위치 / 추적 토글)
│   └─ _alertBorderColor()                       # HUD 테두리 색상 매핑 (사이렌=빨강, 경적=초록)
│   # HUD 경고 알림 + 지도 표시 화면
│   # STT 팝업과 HUD 경고 UI 제공

└─ hud_navigation_screen.dart
    ├─ _handleBluetoothData()                    # STT 텍스트 / 사이렌·경적 신호 수신 및 화면에 아이콘 출력, 7초 후 자동 해제
    ├─ _fetchKakaoRoute() / _fetchGoogleRoute()  # 카카오/구글 기반 경로 탐색
    ├─ _maybeReroute()                           # 경로 이탈 시 자동 재탐색 (쿨다운 적용)
    ├─ _checkNearbyCameras()                     # 단속 카메라 감지 + 제한속도 이미지 표시
    ├─ _updateCameraCourseUp()                   # 도착지까지 차량 진행 경로 안내 
    └─ _updateNextGuideDistance()                # 다음 좌회전/우회전까지 거리 계산 및 HUD 안내
    # HUD 알림 + 지도/경로 안내 결합 화면
    # 단속 카메라, 제한속도, 경로 안내까지 통합 지원



**2. Raspberry Pi**
├─ bridge_workers.py
│ ├─ DetectionWorker(QThread)      # 오디오 감지/추론 워커 (CNN + DOA)
│ │ ├─ _cb()                       # 실시간 마이크 입력을 버퍼에 누적
│ │ ├─ _preprocess()               # 누적된 오디오 → 감마톤 변환 및 CNN 입력 준비
│ │ ├─ start()                     # 모델 로드 → 실시간 추론 반복
│ │ └─ _predict_and_emit()         # 소리 분류 + DOA 각도 계산 후 결과 전송
│ │
│ ├─ CameraWorker(QThread)         # 카메라 프레임 캡처 워커
│ │ └─ start_capture()             # 카메라 장치 실행 후 프레임 캡처 및 전송(15fps 제한)
│ │  # 감지된 이벤트 발생 시 7초 동안 특정 카메라 화면을 표시
│ │
│ ├─ SingleShotSTTWorker(QThread)  # 단발성 음성 인식 워커
│ └─ start_once()                  # 오디오 녹음 → wav 변환 → Google STT 호출 후 텍스트로 변환
│    # 마이크 버튼 클릭 시 1회만 실행



├─ EARS_UI_Controller.py
│ ├─ TxWorker(QThread)          # Bluetooth/Arduino 전송 전담 워커
│ │  └─run()                    # 큐에서 메시지를 꺼내 전송
│ │  # Arduino: 시리얼(/dev/ttyACM0)로 LED/진동 제어 명령 전송
│ │  # Bluetooth(HC-06): "siren,90\n" 등 HUD 앱으로 송신

│ ├─ STT 함수                    # STT 실제 처리 모듈
│ │ ├─ record_audio()           # 오디오 녹음
│ │ ├─ convert_to_wav_bytes()   # numpy 오디오 → wav 바이트 변환
│ │ └─ recognize_audio()        # Google Cloud STT API 호출 → 텍스트 반환
│ │
│ ├─ GUI 위젯 클래스              # GUI 전용 커스텀 위젯
│ │ ├─ ClickableLabel            # 클릭 가능한 아이콘 라벨(STT 버튼 등)
│ │ ├─ MovieLabel                # GIF 애니메이션 라벨
│ │ ├─ HRule / VRule             # GUI 구분선 표시 위젯
│ │ └─ InvisibleButton           # 숨김 종료 버튼(5클릭 → 앱 종료)
│ │
│ ├─ App(QMainWindow)           # 메인 GUI 컨트롤러
│ │ ├─ _build_splash()          # 시작 화면 표시
│ │ ├─ _build_main_ui()         # GUI 메인 UI 구성 (STT 버튼, 소리종류, 방향, 구분선)
│ │ ├─ _on_mic_clicked_for_stt()# 마이크 클릭 시 STT 수행
│ │ ├─ _on_stt_finished()       # STT 결과 표시 + 7초 뒤 자동 숨김
│ │ ├─ on_detection()           # 전달 받은 소리 감지 결과 값→ Arduino/Bluetooth 전송 + 카메라 출력 + HUD 갱신
│ │ ├─ _send_arduino_now() / _send_bt_now() # 즉시 값을 아두이노로 전송
│ │ ├─ _select_camera_safe()    # DOA 각도 기반 카메라 선택 (전방/좌/우/후방)
│ │ └─ _handshake_and_init()    # 아두이노와 핸드셰이크 -> 초기 LED 패턴 점등
│ # UI 제어, 감지 결과 연동, 전송, 카메라 동작까지 총괄 관리
│ └─ ensure_autostart() # 부팅 시 자동 실행 설정 (autostart .desktop 파일 생성)



**3. Arduino**
├─ [I/O Protocol]
│  └ checkSerialInput()             # "CLASS,ANGLE" 파싱 → 상태 세팅
│
├─ [Init]
│  └ handleInitPattern(now)         # 통신 확인 시 RGB LED 제어 후 종료
│
├─ [Visual (Ambient/Array)]
│  ├ handleLEDPattern(type, now)    # SIREN/HORN 채널 패턴 로직
│  ├ handleArrayLEDPattern(now)     # 각도 기반 4방향 점멸 토글
│  ├ burst(ch,r,g,b,repeat,speed)   # 깜빡임 유닛(버스트 제어)
│  ├ setAllArrayLEDsColor(r,g,b)    # Array 1~4 일괄 색상
│  ├ setArrayLEDColor(led,r,g,b)    # 특정 Array LED 색상
│  └ setArrayLED(led,state,isSiren) # 적/녹 선택 ON/OFF
│
├─ [Haptic (Motor)]
│  ├ handleSirenVibration(now)      # 500ms 롱+단 펄스 반복
│  ├ handleHornVibration(now)       # 150/100ms 더블 펄스 반복
│  ├ setMotors(state)               # 모터 동시 ON/OFF
│  └ stopVibration()                # 모터 정지
│
└─ [Util]
   └ getActiveLEDs(angle, leds[4])  # 각도→활성 LED 맵핑


