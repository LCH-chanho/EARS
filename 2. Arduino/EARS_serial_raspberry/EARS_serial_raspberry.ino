// === 아두이노:  RGB는 Soft PWM ===


// === RGB LED 핀 설정 (소프트 PWM) Mega의 Embient Light 담당 2채널 ===
#define LED1_R 34
#define LED1_G 36
#define LED1_B 38
#define LED2_R 35
#define LED2_G 37
#define LED2_B 39

// === 진동 모터 핀 ===
#define MOTOR1 40
#define MOTOR2 42

// === ArrayLED 핀 설정 (LED1~LED4: Anode 타입) ===
#define LED1_PIN_R 22
#define LED1_PIN_G 24
#define LED1_PIN_B 26
#define LED2_PIN_R 23
#define LED2_PIN_G 25
#define LED2_PIN_B 27
#define LED3_PIN_R 28
#define LED3_PIN_G 30
#define LED3_PIN_B 32
#define LED4_PIN_R 29
#define LED4_PIN_G 31
#define LED4_PIN_B 33

// === 사운드 타입 정의 (라즈베리 CLASS_ID_MAP과 일치) ===
#define SOUND_INIT   "INIT"
#define SOUND_NONE   "NONE"
#define SOUND_SIREN  "SIREN"
#define SOUND_HORN   "HORN"

// === 상태 변수 ===
int detectedSound = SOUND_NONE;
unsigned long lastChangeTime = 0;
int patternPhase = 0;
unsigned long lastUpdate = 0;
bool soundActive = false;
unsigned long detectedStartTime = 0;

// === 감지 후 7초 동작 보증 변수 ===
bool eventLock = false; //True면 다른이벤트 무시
unsigned long eventStartTime = 0; //동작시간 체크
const unsigned long EVENT_DURATION = 7000;  // 7초

// ArrayLED 관련 변수
unsigned long arrayLEDToggleTimer = 0;
bool arrayLEDState = false;
String currentClass = "NONE";
int currentAngle = -1;

// 혼 패턴용 변수
bool hornBurst = true;
unsigned long hornStart = 0;
unsigned long hornTimer = 0;
bool hornToggle = false;

// 사이렌 순환 패턴
static bool directionRightFirst = true;
static int sirenPatternStep = 0; // 소방→경찰→응급 순서 전환
static int sirenRepeatCounter = 0; // 각 패턴 반복 횟수 누적

// INIT 패턴용 변수
bool initMode = false;
unsigned long initStartTime = 0;
int initPhase = 0;
unsigned long initPhaseTime = 0;

// 진동 제어 변수
unsigned long vibStartTime = 0;

// === LED 버스트 상태 구조체 ===
struct BurstState {
  unsigned long timer = 0;
  int count = 0;
};
BurstState burstCH1, burstCH2;



// === 핀 초기화 ===
void initLEDPin(int r, int g, int b) {
  pinMode(r, OUTPUT);
  pinMode(g, OUTPUT);
  pinMode(b, OUTPUT);
  digitalWrite(r, HIGH);
  digitalWrite(g, HIGH);
  digitalWrite(b, HIGH);
}

void setAllArrayLEDsColor(bool red, bool green, bool blue) {
  for (int i = 1; i <= 4; i++) {
    setArrayLEDColor(i, red, green, blue);
  }
}

// INIT Array LED 제어
void setArrayLEDColor(int led, bool red, bool green, bool blue) {
  int r, g, b;
  if (led == 1) { r = LED1_PIN_R; g = LED1_PIN_G; b = LED1_PIN_B; }
  else if (led == 2) { r = LED2_PIN_R; g = LED2_PIN_G; b = LED2_PIN_B; }
  else if (led == 3) { r = LED3_PIN_R; g = LED3_PIN_G; b = LED3_PIN_B; }
  else { r = LED4_PIN_R; g = LED4_PIN_G; b = LED4_PIN_B; }

  digitalWrite(r, red ? LOW : HIGH);
  digitalWrite(g, green ? LOW : HIGH);
  digitalWrite(b, blue ? LOW : HIGH);
}

void setArrayLED(int led, bool state, bool isSiren) {
  int r, g, b;
  if (led == 1) { r = LED1_PIN_R; g = LED1_PIN_G; b = LED1_PIN_B; }
  else if (led == 2) { r = LED2_PIN_R; g = LED2_PIN_G; b = LED2_PIN_B; }
  else if (led == 3) { r = LED3_PIN_R; g = LED3_PIN_G; b = LED3_PIN_B; }
  else { r = LED4_PIN_R; g = LED4_PIN_G; b = LED4_PIN_B; }

  digitalWrite(r, isSiren && state ? LOW : HIGH);
  digitalWrite(g, !isSiren && state ? LOW : HIGH);
  digitalWrite(b, HIGH);
}

void resetArrayLEDs() {
  for (int i = 1; i <= 4; i++) setArrayLED(i, false, true);
}

void getActiveLEDs(int angle, bool* leds) {
  for (int i = 0; i < 4; i++) leds[i] = false;
  if (angle >= 10 && angle <= 80) leds[0] = true;
  else if (angle >= 81 && angle <= 109) { leds[0] = true; leds[1] = true; }
  else if (angle >= 110 && angle <= 170) leds[1] = true;
  else if (angle >= 171 && angle <= 189) { leds[1] = true; leds[2] = true; }
  else if (angle >= 190 && angle <= 260) leds[2] = true;
  else if (angle >= 261 && angle <= 279) { leds[2] = true; leds[3] = true; }
  else if (angle >= 280 && angle <= 350) leds[3] = true;
  else if ((angle >= 351 && angle <= 359) || (angle >= 0 && angle <= 9)) { leds[0] = true; leds[3] = true; }
}

void handleArrayLEDPattern(unsigned long now) {
  if (!soundActive || currentClass == SOUND_NONE) {
    resetArrayLEDs();
    return;
  }
  if (now - arrayLEDToggleTimer >= 650) {
    arrayLEDToggleTimer = now;
    arrayLEDState = !arrayLEDState;
    bool leds[4];
    getActiveLEDs(currentAngle, leds);
    for (int i = 0; i < 4; i++) {
      setArrayLED(i + 1, leds[i] && arrayLEDState, currentClass == SOUND_SIREN);
    }
  }
}




// === LED 채널 제어 함수 (Anode 타입 반전) ===
void setLED_CH1(int r, int g, int b) {
  analogWrite(LED1_R, 255 - r);
  analogWrite(LED1_G, 255 - g);
  analogWrite(LED1_B, 255 - b);
}
void setLED_CH2(int r, int g, int b) {
  analogWrite(LED2_R, 255 - r);
  analogWrite(LED2_G, 255 - g);
  analogWrite(LED2_B, 255 - b);
}

// === 버스트 초기화 ===
void resetBursts() {
  burstCH1.count = 0;
  burstCH2.count = 0;
  setLED_CH1(0, 0, 0);
  setLED_CH2(0, 0, 0);
}

// === LED 버스트 함수 ===
void burst(int ch, int r, int g, int b, int repeat = 6, int speed = 30) {
  BurstState* bs = (ch == 1) ? &burstCH1 : &burstCH2;
  if (millis() - bs->timer >= speed) {
    bs->timer = millis();
    bool on = (bs->count % 2 == 0);
    if (ch == 1) setLED_CH1(on ? r : 0, on ? g : 0, on ? b : 0);
    else         setLED_CH2(on ? r : 0, on ? g : 0, on ? b : 0);
    bs->count++;
    if (bs->count >= repeat * 2) {
      bs->count = 0;
      if (ch == 1) setLED_CH1(0, 0, 0);
      else         setLED_CH2(0, 0, 0);
    }
  }
}


// === 진동 모터 함수 ===
void setMotors(bool state) {
  digitalWrite(MOTOR1, state ? HIGH : LOW);
  digitalWrite(MOTOR2, state ? HIGH : LOW);
}

void stopVibration() {
  setMotors(false);
}

void handleHornVibration(unsigned long now) {
  static int step = 0;
  static unsigned long stepStart = 0;
  if (now - vibStartTime >= EVENT_DURATION) return;

  switch (step) {
    case 0:  // 진동 ON 150ms
      setMotors(true);
      if (now - stepStart >= 150) {
        step = 1;
        stepStart = now;
      }
      break;
    case 1:  // OFF 100ms
      setMotors(false);
      if (now - stepStart >= 100) {
        step = 2;
        stepStart = now;
      }
      break;
    case 2:  // 두 번째 진동 ON 150ms
      setMotors(true);
      if (now - stepStart >= 150) {
        step = 3;
        stepStart = now;
      }
      break;
    case 3:  // OFF 100ms
      setMotors(false);
      if (now - stepStart >= 100) {
        step = 4;
        stepStart = now;
      }
      break;
    case 4:  // 대기 600ms
      setMotors(false);
      if (now - stepStart >= 600) {
        step = 0;
        stepStart = now;
      }
      break;
  }
}

void handleSirenVibration(unsigned long now) {
  static int step = 0;
  static unsigned long stepStart = 0;
  if (now - vibStartTime >= EVENT_DURATION) return;

  switch (step) {
    case 0:  // 긴 진동 500ms
      setMotors(true);
      if (now - stepStart >= 500) {
        step = 1;
        stepStart = now;
      }
      break;
    case 1:  // OFF 100ms
      setMotors(false);
      if (now - stepStart >= 100) {
        step = 2;
        stepStart = now;
      }
      break;
    case 2:  // 짧은 진동 150ms
      setMotors(true);
      if (now - stepStart >= 150) {
        step = 3;
        stepStart = now;
      }
      break;
    case 3:  // OFF 200ms
      setMotors(false);
      if (now - stepStart >= 200) {
        step = 0;
        stepStart = now;
      }
      break;
  }
}




// === LED 패턴 처리 함수 ===
void handleLEDPattern(int type, unsigned long now);



// === 시리얼 입력 처리 ===
void checkSerialInput() {
  // 시리얼 버퍼에 데이터가 있으면 처리 시작
  if (Serial.available() > 0) {
    String inputStr = Serial.readStringUntil('\n');  // 줄바꿈 기준으로 전체 문자열 수신
    inputStr.trim();  // 앞뒤 공백 제거

    Serial.println("[RECEIVED] 시리얼 입력: " + inputStr);  // 디버깅용 출력

    // ',' 구분자를 기준으로 사운드 클래스와 각도를 분리할 준비
    int commaIndex = inputStr.indexOf(',');
    String classStr = inputStr;   // 전체를 기본으로 지정
    String angleStr = "-1";       // 기본 각도는 -1로 초기화

    // ','가 존재할 경우만 분리하여 클래스와 각도 문자열 추출
    if (commaIndex != -1) {
      classStr = inputStr.substring(0, commaIndex);           // 앞쪽 문자열 = 클래스 이름
      angleStr = inputStr.substring(commaIndex + 1);          // 뒤쪽 문자열 = 각도 정보
    }

    classStr.trim(); angleStr.trim();                         // 불필요한 공백 제거
    int angleValue = angleStr.toInt();                        // 문자열 각도를 정수형으로 변환

    // INIT 명령은 언제든 수신 가능 (eventLock 무시)
    if (classStr == SOUND_INIT) {
      if (!initMode) {
        initMode = true;
        initStartTime = millis();
        initPhase = 0;
        initPhaseTime = millis();
        Serial.println("[STATE] INIT → 초기 패턴 시작");
      }
      return;
    }

    // 이벤트 잠금 중에는 다른 입력 무시 (7초간 보호 로직)
    if (eventLock && classStr != SOUND_INIT) {
      Serial.println("[BLOCKED] 7초 내 입력 무시됨");
      return;
    }

    // NONE 명령: 모든 동작 중단, LED/진동 OFF
    if (classStr == SOUND_NONE) {
      soundActive = false;
      detectedSound = SOUND_NONE;
      currentClass = SOUND_NONE;
      currentAngle = -1;
      resetBursts();
      stopVibration();
      resetArrayLEDs();
      Serial.println("[STATE] NONE → 모든 동작 정지");
    }
    // SIREN 또는 HORN 명령: 진동/LED/ArrayLED 동작 시작
    else if (classStr == SOUND_SIREN || classStr == SOUND_HORN) {
      eventLock = true;                  // 이벤트 잠금 시작
      eventStartTime = millis();        // 타이머 시작
      vibStartTime = millis();          // 진동용 타이머도 시작

      soundActive = true;               // 활성 상태 설정
      detectedSound = (classStr == SOUND_SIREN) ? SOUND_SIREN : SOUND_HORN;
      currentClass = classStr;          // "SIREN" 또는 "HORN"
      currentAngle = angleValue;        // int형 각도 저장
      detectedStartTime = millis();     // 탐지 시작 시간 기록

      resetBursts();                    // 기존 LED 패턴 초기화
      patternPhase = 0; sirenPatternStep = 0; sirenRepeatCounter = 0;

      // 디버깅 로그 출력
      Serial.println("[STATE] " + classStr + " → 시각/방향 동작 시작 @ " + angleValue + "도");
    }
    // 그 외 문자열은 무효 처리
    else {
      Serial.println("[WARNING] 유효하지 않은 문자열 수신: " + inputStr);
    }
  }
}


// === INIT 시퀀스 ===
void handleInitPattern(unsigned long now) {
  if (initPhase == 0 && now - initPhaseTime > 1000) {
    setAllArrayLEDsColor(true, false, false);  // 빨강
    Serial.println("[INIT] 빨강 표시");
    initPhase = 1; initPhaseTime = now;
  } else if (initPhase == 1 && now - initPhaseTime > 1000) {
    setAllArrayLEDsColor(false, false, true);  // 파랑
    Serial.println("[INIT] 파랑 표시");
    initPhase = 2; initPhaseTime = now;
  } else if (initPhase == 2 && now - initPhaseTime > 1000) {
    setAllArrayLEDsColor(false, true, false);  // 초록
    Serial.println("[INIT] 초록 표시");
    initPhase = 3; initPhaseTime = now;
  } else if (initPhase >= 3) {
    unsigned long elapsed = now - initPhaseTime;
    bool green = (elapsed / 500) % 2 == 0;  // 0.5초마다 ON/OFF 토글
    setAllArrayLEDsColor(false, green, false);
    Serial.println(green ? "[INIT] 깜빡임 초록 ON" : "[INIT] 깜빡임 초록 OFF");

    if (elapsed > 4500) {  // 총 2.5초 (5회 깜빡임) 후 종료
      setAllArrayLEDsColor(false, false, false); // OFF
      initMode = false;
      Serial.println("[INIT] 완료 및 종료");
    }
  }
}


// === 메인 루프 ===
void loop() {
  unsigned long now = millis();

  // 7초 이벤트 락 해제 조건
  if (eventLock && (now - eventStartTime >= EVENT_DURATION)) {
  eventLock = false;
  Serial.println("[UNLOCKED] 7초 이벤트 종료 → 다음 입력 수락 가능");

  // 자동 정지
  detectedSound = SOUND_NONE;
  soundActive = false;
  resetBursts();
  stopVibration();
  resetArrayLEDs();
  Serial.println("[AUTO] 7초 경과로 자동 종료");
}

  checkSerialInput();

  if (initMode) {
    handleInitPattern(now);
    return;
  }

  if (soundActive && detectedSound == SOUND_SIREN) {
    handleLEDPattern(SOUND_SIREN, now);
    handleSirenVibration(now);
    handleArrayLEDPattern(now);
  } else if (soundActive && detectedSound == SOUND_HORN) {
    handleLEDPattern(SOUND_HORN, now);
    handleHornVibration(now);
    handleArrayLEDPattern(now);
  } else if (detectedSound == SOUND_NONE) {
    setLED_CH1(0, 0, 0);
    setLED_CH2(0, 0, 0);
    stopVibration();
  }
}

void handleLEDPattern(int type, unsigned long now) {
  if (!soundActive) return;
  if (type == SOUND_HORN) {
    if (hornBurst && now - hornStart > 1000) {
      hornBurst = false;
      hornStart = now;
      hornToggle = false;
      resetBursts();
    } else if (!hornBurst && now - hornStart > 3000) {
      hornBurst = true;
      hornStart = now;
      resetBursts();
    }
    if (hornBurst) {
      burst(1, 255, 255, 0);
      burst(2, 255, 255, 0);
    } else {
      if (now - hornTimer >= 300) {
        hornToggle = !hornToggle;
        hornTimer = now;
        int val = hornToggle ? 255 : 0;
        setLED_CH1(val, val, 0);
        setLED_CH2(val, val, 0);
      }
    }
  }
  else if (type == SOUND_SIREN) {
    if (sirenPatternStep == 0) {
      if (now - lastUpdate > 500) {
        lastUpdate = now;
        patternPhase = (patternPhase + 1) % 2;
        resetBursts();
        sirenRepeatCounter++;
      }
      if (patternPhase == 0) burst(1, 255, 0, 0);
      else burst(2, 255, 0, 0);
      if (sirenRepeatCounter >= 4) {
        sirenPatternStep = 1;
        sirenRepeatCounter = 0;
        patternPhase = 0;
      }
    } else if (sirenPatternStep == 1) {
      if (now - lastUpdate > 500) {
        lastUpdate = now;
        patternPhase = (patternPhase + 1) % 2;
        resetBursts();
        sirenRepeatCounter++;
      }
      if (patternPhase == 0) {
        burst(1, 0, 0, 255);
        burst(2, 255, 0, 0);
      } else {
        burst(1, 255, 0, 0);
        burst(2, 0, 0, 255);
      }
      if (sirenRepeatCounter >= 4) {
        sirenPatternStep = 2;
        sirenRepeatCounter = 0;
        patternPhase = 0;
      }
    } else {
      if (now - lastUpdate > 500) {
        lastUpdate = now;
        patternPhase = (patternPhase + 1) % 3;
        if (patternPhase == 0) directionRightFirst = !directionRightFirst;
        resetBursts();
        sirenRepeatCounter++;
      }
      if (patternPhase == 0) {
        if (directionRightFirst) burst(2, 0, 255, 0);
        else burst(1, 0, 255, 0);
      } else if (patternPhase == 1) {
        if (directionRightFirst) burst(1, 0, 255, 0);
        else burst(2, 0, 255, 0);
      } else {
        burst(1, 0, 255, 0);
        burst(2, 0, 255, 0);
      }
      if (sirenRepeatCounter >= 6) {
        sirenPatternStep = 0;
        sirenRepeatCounter = 0;
        patternPhase = 0;
      }
    }
  }
}



void setup() {
  Serial.begin(9600);
  initLEDPin(LED1_R, LED1_G, LED1_B);
  initLEDPin(LED2_R, LED2_G, LED2_B);
  initLEDPin(LED1_PIN_R, LED1_PIN_G, LED1_PIN_B);
  initLEDPin(LED2_PIN_R, LED2_PIN_G, LED2_PIN_B);
  initLEDPin(LED3_PIN_R, LED3_PIN_G, LED3_PIN_B);
  initLEDPin(LED4_PIN_R, LED4_PIN_G, LED4_PIN_B);
  pinMode(MOTOR1, OUTPUT);
  pinMode(MOTOR2, OUTPUT);
  setLED_CH1(0, 0, 0);
  setLED_CH2(0, 0, 0);

  // === 라즈베리로부터 핸드셰이크 대기 ===
  while (!Serial);  // USB 연결 대기
  delay(2000);      // 안정화 대기

  while (true) {
    if (Serial.available() > 0) {
      String msg = Serial.readStringUntil('\n');
      if (msg == "ping") {
        Serial.println("pong");
        break; // 확인되면 루프 빠져나감
      }
    }
  }

}
