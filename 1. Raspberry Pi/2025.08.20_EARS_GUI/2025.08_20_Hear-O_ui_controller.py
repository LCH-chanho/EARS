# 2025.08_20_Hear-O_ui_controller.py (각종 기능 액션을 정의)
# ===== hearo_ui_fixed_800x480_fixed_with_rules_verticals_no_buttons.py =====
# - BT 전송: Siren/Horn 케이스 유지
# - Arduino 전송: SIREN/HORN 대문자 유지
# - STT 텍스트는 BT로 더 이상 전송하지 않음 (_on_stt_finished에서 주석 처리)
# - 그 외 기존 기능은 동일 (RX 드레인, STT 7초 자동 숨김 등)
# - 7인치 화면 완전 덮기: 최상단(WindowStaysOnTopHint) + FullScreen 재적용 타이머
# - 상태표시줄 비가시화
# - 자동실행 Autostart 엔트리 생성(ensure_autostart)
# - 스플래시가 끝난 "이후"에만 무거운 초기화 시작(모델/오디오/카메라/Tx 등) → HELLO GIF 끊김 완화
# - 마이크 토글: 클릭 시 마이크 GIF ON + SPEAK 이미지 표시, 다시 클릭 시 OFF + SPEAK 숨김
#   (STT는 토글 ON에서 1회 수행, 기존 로직 유지)

import os, sys, io, wave, time, serial
from queue import Queue

# ====== 자동실행 설정 상수 ======
AUTOSTART_ENABLE = True  # 부팅 후 자동실행을 원치 않으면 False
AUTOSTART_NAME = "hearo-ui.desktop"

from PySide6.QtCore import Qt, QRect, QTimer, Signal, Slot, QThread, QObject
from PySide6.QtGui import QPixmap, QMovie, QPainter, QPen, QFont
from PySide6.QtWidgets import QApplication, QMainWindow, QLabel, QMenuBar, QStatusBar, QWidget, QPushButton

# 라즈베리 X11
os.environ.setdefault("QT_QPA_PLATFORM", "xcb")
os.environ.setdefault("DISPLAY", ":0")

import sounddevice as sd
from google.cloud import speech
from hi import DetectionWorker, CameraWorker, SingleShotSTTWorker
from tuning import find as MicFind

# ===== 경로 =====
HEARO_ANIM      = "/home/yong/projects/ears_system/Image/hearo_logo_merged_v5_black.gif"
ICON_STILL      = "/home/yong/projects/ears_system/Image/mike.png"
ICON_GIF        = "/home/yong/projects/ears_system/Image/new_mike.gif"
RESULT_IMG      = "/home/yong/projects/ears_system/Image/speak.png"
WAVE_ICON_STILL = "/home/yong/projects/ears_system/Image/wave33.png"
WAVE_ICON_GIF   = "/home/yong/projects/ears_system/Image/new_wave.gif"
DIRECTION_ICON  = "/home/yong/projects/ears_system/Image/direction_1.png"
SOUND_ICON      = "/home/yong/projects/ears_system/Image/sound_1.jpg"
HELLO_GIF       = "/home/yong/projects/ears_system/Image/new_hello.gif"

HEARO_ANIM_RECT      = (205, 33, 400, 400)
MIC_TOGGLE_RECT      = (738, 405, 48, 48)
WAVE_TOGGLE_RECT     = (11,    0, 53, 53)
RESULT_IMAGE_RECT    = (7,   395, 60, 70)
SOUND_ICON_RECT      = (354,   0, 53, 53)
DIRECTION_ICON_RECT  = (533,   5, 43, 43)
HELLO_GIF_RECT       = (205, 105, 420, 250)
GREEN_CIRCLE_RECT    = (509, 208, 38, 38)
WAVE_BOTTOM_Y = WAVE_TOGGLE_RECT[1] + WAVE_TOGGLE_RECT[3]
MIC_TOP_Y     = 395

# ==== 백엔드 설정 ====
os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "/home/yong/stt_project/speech_stt_key.json"
CLASS_NAMES = ['Horn', 'None', 'Siren']
MODEL_PATH = "/home/yong/projects/ears_system/CNN_Model/gamma_cnn_main5_timeframe"
CLASS_ID_MAP = { 'INIT': "INIT", 'None': "NONE", 'Siren': "SIREN", 'Horn': "HORN" }  # Arduino 전용 토큰

DETECT_DEVICE = 'voicehat'
STT_DEVICE    = 'uacdemo'
MIC_SAMPLE_RATE   = 48000
MODEL_SAMPLE_RATE = 44100
SAMPLE_RATE_STT   = 48000
STT_DURATION      = 5
WIN_TIME = 0.025
HOP_TIME = 0.010
N_FILTERS = 64
FMIN = 50
SEGMENT_SECONDS = 0.6

CAMERA_FRONT = '/dev/webcam_front'
CAMERA_LEFT  = '/dev/webcam_left'
CAMERA_BACK  = '/dev/webcam_back'
CAMERA_RIGHT = '/dev/webcam_right'

# ==== 통신 포트 ====
ARDUINO_PORT = '/dev/ttyACM0'
BAUDRATE = 9600
try:
    arduino = serial.Serial(ARDUINO_PORT, BAUDRATE, timeout=0, write_timeout=0.1)
    time.sleep(2)
    print(f"[아두이노 연결] {ARDUINO_PORT}")
except Exception as e:
    print(f"[아두이노 실패] {e}")
    arduino = None

try:
    bt_serial = serial.Serial('/dev/ttyAMA0', baudrate=9600, timeout=0, write_timeout=0.1)
    print("[블루투스 연결] HC-06 OK")
except Exception as e:
    print(f"[블루투스 실패] {e}")
    bt_serial = None

# ==== 전송 워커(QThread) (백업용 큐) ====
class TxWorker(QObject):
    sig_error = Signal(str)
    def __init__(self, bt, arduino):
        super().__init__()
        self.bt = bt
        self.arduino = arduino
        self.q = Queue()
        self._run = True
    @Slot()
    def loop(self):
        while self._run:
            try:
                kind, payload = self.q.get(timeout=0.01)
            except Exception:
                continue
            try:
                if kind == "bt" and self.bt:
                    self.bt.write(payload)
                    try: self.bt.flush()
                    except: pass
                elif kind == "arduino" and self.arduino:
                    self.arduino.write(payload)
                    try: self.arduino.flush()
                    except: pass
            except Exception as e:
                self.sig_error.emit(f"TX 오류: {e}")
    @Slot()
    def stop(self):
        self._run = False

# ==== STT 장치 탐색 ====
def _resolve_device(name_or_index):
    try:
        devices = sd.query_devices()
        for i, d in enumerate(devices):
            if d.get('max_input_channels', 0) > 0 and (str(i) == str(name_or_index) or d.get('name') == name_or_index):
                return i
        low = str(name_or_index).lower()
        for i, d in enumerate(devices):
            if d.get('max_input_channels', 0) > 0 and (low in str(d.get('name','')).lower()):
                return i
    except Exception as e:
        print("[STT 장치 조회 실패]", e)
    return None

# ==== STT 함수 ====
def record_audio():
    idx = _resolve_device(STT_DEVICE)
    if idx is None:
        raise RuntimeError("STT 장치 인식 실패 — sd.query_devices()로 이름/인덱스를 확인하세요.")
    rec = sd.rec(int(STT_DURATION * SAMPLE_RATE_STT),
                 samplerate=SAMPLE_RATE_STT,
                 channels=1, dtype='int16', device=idx)
    sd.wait()
    return rec

def convert_to_wav_bytes(audio_np):
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE_STT)
        wf.writeframes(audio_np.tobytes())
    buf.seek(0)
    return buf.read()

def recognize_audio(wav_bytes):
    try:
        client = speech.SpeechClient()
        audio = speech.RecognitionAudio(content=wav_bytes)
        config = speech.RecognitionConfig(
            encoding=speech.RecognitionConfig.AudioEncoding.LINEAR16,
            sample_rate_hertz=SAMPLE_RATE_STT,
            language_code="ko-KR"
        )
        response = client.recognize(config=config, audio=audio)
        for result in response.results:
            return result.alternatives[0].transcript
    except Exception as e:
        print(f"[STT 실패] {e}")
    return ""

# ==== GUI 위젯 ====
class SimpleToggleLabel(QLabel):
    toggled = Signal(bool)
    def __init__(self, still_path, gif_path, *a, **kw):
        super().__init__(*a, **kw)
        self._still = QPixmap(still_path)
        self._movie = QMovie(gif_path)
        self._movie.setCacheMode(QMovie.CacheAll)
        self._movie.finished.connect(self._movie.start)
        self._movie.frameChanged.connect(self.update)
        self._show_gif = False
        self.setStyleSheet("background: transparent;")
        self.setAlignment(Qt.AlignCenter)

    # 필요 시 코드에서 강제로 GIF/정지 전환할 수 있게 제공(기존 동작엔 영향 없음)
    def set_gif(self, show: bool):
        if show and not self._show_gif:
            self._show_gif = True
            self._movie.start()
            self.update()
            self.toggled.emit(True)
        elif (not show) and self._show_gif:
            self._show_gif = False
            self._movie.stop()
            self.update()
            self.toggled.emit(False)

    def mousePressEvent(self, e):
        if e.button() == Qt.LeftButton:
            self._show_gif = not self._show_gif
            if self._show_gif: self._movie.start()
            else: self._movie.stop()
            self.update()
            self.toggled.emit(self._show_gif)

    def paintEvent(self, _):
        p = QPainter(self); r = self.rect()
        if self._show_gif:
            frame = self._movie.currentPixmap()
            p.drawPixmap(r, frame if not frame.isNull() else self._still)
        else:
            p.drawPixmap(r, self._still)
        p.end()

class ClickableLabel(QLabel):
    clicked = Signal()
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.setStyleSheet("background: transparent;")
        self.setAlignment(Qt.AlignCenter)
    def mousePressEvent(self, e):
        if e.button() == Qt.LeftButton:
            self.clicked.emit()

class MovieLabel(QLabel):
    def __init__(self, gif_path: str, loop=True, parent=None, cache_mode=QMovie.CacheAll, defer_start=False, *a, **kw):
        super().__init__(parent, *a, **kw)
        self.setScaledContents(True)
        self.setStyleSheet("background: transparent;")
        self.movie = QMovie(gif_path)
        self.movie.setCacheMode(cache_mode)
        if loop:
            self.movie.finished.connect(self.movie.start)
        self.setMovie(self.movie)
        if defer_start:
            QTimer.singleShot(0, self.movie.start)  # 이벤트 루프 한 틱 뒤 시작
        else:
            self.movie.start()

class HRule(QWidget):
    def __init__(self, y: int, thickness: int = 2, *a, **kw):
        super().__init__(*a, **kw)
        self.setGeometry(0, y, 800, thickness)
        self._thickness = thickness
        self.setAttribute(Qt.WA_TransparentForMouseEvents, True)
        self.setStyleSheet("background: transparent;")
    def paintEvent(self, _):
        p = QPainter(self); p.setPen(QPen(Qt.white, self._thickness))
        p.drawLine(0, 0, self.width(), 0); p.end()

class VRule(QWidget):
    def __init__(self, x: int, y0: int, y1: int, thickness: int = 2, *a, **kw):
        super().__init__(*a, **kw)
        if y1 < y0: y0, y1 = y1, y0
        self.setGeometry(x, y0, thickness, y1 - y0)
        self._thickness = thickness
        self.setAttribute(Qt.WA_TransparentForMouseEvents, True)
        self.setStyleSheet("background: transparent;")
    def paintEvent(self, _):
        p = QPainter(self); p.setPen(QPen(Qt.white, self._thickness))
        p.drawLine(0, 0, 0, self.height()); p.end()

class InvisibleButton(QPushButton):
    def __init__(self, parent, rect: QRect):
        super().__init__(parent)
        self.setGeometry(rect)
        self.setStyleSheet("background-color: transparent; border: none;")
        self.setFocusPolicy(Qt.NoFocus)
        self.setCursor(Qt.PointingHandCursor)
        self._clicks = 0
        self._window = QTimer(self); self._window.setSingleShot(True); self._window.setInterval(2000)
        self._window.timeout.connect(self._reset_clicks)
        self.pressed.connect(self._on_pressed)
    def _on_pressed(self):
        if not self._window.isActive():
            self._clicks = 0; self._window.start()
        self._clicks += 1
        if self._clicks >= 5: QApplication.instance().quit()
    def _reset_clicks(self): self._clicks = 0

class Ui_MainWindow(object):
    def setupUi(self, MainWindow):
        MainWindow.setFixedSize(800, 480)
        self.centralwidget = QWidget(MainWindow); MainWindow.setCentralWidget(self.centralwidget)
        bg = QLabel(self.centralwidget); bg.setGeometry(0,0,800,480); bg.setStyleSheet("background:#000;")
        self.hearo_anim = MovieLabel(HEARO_ANIM, loop=True, parent=self.centralwidget)
        self.hearo_anim.setGeometry(QRect(*HEARO_ANIM_RECT))
        self.menubar = QMenuBar(MainWindow); MainWindow.setMenuBar(self.menubar)
        self.statusbar = QStatusBar(MainWindow); MainWindow.setStatusBar(self.statusbar)
        # 상태바는 화면에 표시하지 않음(완전 키오스크)
        self.statusbar.setVisible(False)

# ==== 메인 앱 ====
class App(QMainWindow):
    camera_request = Signal(str, int)

    def __init__(self):
        super().__init__()

        # 7인치 화면 완전 덮기: 프레임 제거 + 최상단 + 좌상단 고정
        flags = self.windowFlags() | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        self.setWindowFlags(flags)
        self.move(0, 0)

        self.ui = Ui_MainWindow(); self.ui.setupUi(self)
        # 메시지는 보되 상태바는 보이지 않음
        self.statusBar().showMessage("편집 제거 · 백엔드 연동")

        # 표시 라벨
        self.camera_label = QLabel(self.ui.centralwidget)
        self.camera_label.setStyleSheet("background:black;")
        self.camera_label.setScaledContents(True)
        self.camera_label.hide()

        self.stt_label = QLabel(self.ui.centralwidget)
        self.stt_label.setGeometry(80, 405, 600, 48)
        self.stt_label.setStyleSheet("color:white; background:transparent; font-size:16px;")
        self.stt_label.setText("")
        self.stt_label.hide()

        # UI 구성(스플래시 중 숨김)
        self._build_main_ui(visible=False)
        self._build_splash()

        # ---- 무거운 초기화 객체들은 일단 None으로 두고, 스플래시 종료 뒤에 시작 ----
        self.det_thread = None
        self.cam_thread = None
        self.det = None
        self.cam = None
        self.tx_thread = None
        self.tx = None
        self._rx_timer = None

        # STT(단발성)
        self.stt_thread = None
        self.stt_worker = None
        self._stt_busy = False
        self._stt_hide_timer = QTimer(self); self._stt_hide_timer.setSingleShot(True)

        # 상태
        self._camera_active = False
        self._frozen_detection = False
        self._frozen_class = None
        self._frozen_angle = None

        # 시작 시 STT 장치 힌트(가벼움)
        if _resolve_device(STT_DEVICE) is None:
            self.statusBar().showMessage("STT 장치(uacdemo) 미인식 — sd.query_devices() 확인 필요")

        # 카메라 영역(가벼움)
        self._apply_camera_bounds()

    # ===== 스플래시 =====
    def _build_splash(self):
        self._hide_all_main_widgets()
        # 스플래시만 CacheNone + defer_start로 부드럽게
        self.splash = MovieLabel(HELLO_GIF, loop=False, parent=self.ui.centralwidget,
                                 cache_mode=QMovie.CacheNone, defer_start=True)
        self.splash.setGeometry(QRect(*HELLO_GIF_RECT))
        self.splash.raise_()
        self.ui.hearo_anim.hide()

        # 3초 안전망 타임아웃
        self._splash_fallback = QTimer(self); self._splash_fallback.setSingleShot(True)
        self._splash_fallback.timeout.connect(self._on_splash_finished)
        self._splash_fallback.start(3000)

        self.splash.movie.finished.connect(self._on_splash_finished)
        self.splash.show()

    def _hide_all_main_widgets(self):
        if hasattr(self, "_ui_after_splash"):
            for w in self._ui_after_splash: w.hide()
        self.camera_label.hide(); self.stt_label.hide(); self.ui.hearo_anim.hide()
        if hasattr(self, "result_img"): self.result_img.hide()

    def _show_all_main_widgets(self):
        if hasattr(self, "_ui_after_splash"):
            for w in self._ui_after_splash: w.show()
        self.ui.hearo_anim.show()

    def _on_splash_finished(self):
        # 스플래시 종료 처리
        if hasattr(self, "splash") and self.splash.isVisible():
            self.splash.movie.stop(); self.splash.hide(); self.splash.deleteLater()
        try:
            if hasattr(self, "_splash_fallback") and self._splash_fallback.isActive():
                self._splash_fallback.stop()
        except: pass

        # 메인 위젯 표시
        self._show_all_main_widgets()

        # 스플래시 끝난 뒤 약간의 여유(300ms) 후 무거운 초기화 시작 → 프레임 안정
        QTimer.singleShot(300, self._start_heavy_init)

    # 스플래시 종료 "후" 무거운 초기화(모델 로드/오디오/카메라/Tx/RX타이머/아두이노 핸드셰이크)
    def _start_heavy_init(self):
        if self.det_thread is not None:
            return  # 중복 방지

        # 감지/카메라 스레드/워커
        self.det_thread = QThread(self)
        self.cam_thread = QThread(self)
        self.det = DetectionWorker(MODEL_PATH, MIC_SAMPLE_RATE, MODEL_SAMPLE_RATE, SEGMENT_SECONDS,
                                   WIN_TIME, HOP_TIME, N_FILTERS, FMIN, DETECT_DEVICE, MicFind, CLASS_NAMES)
        self.cam = CameraWorker()
        self.det.moveToThread(self.det_thread)
        self.cam.moveToThread(self.cam_thread)
        self.det_thread.started.connect(self.det.start)
        self.det.sig_detection.connect(self.on_detection)
        self.camera_request.connect(self.cam.start_capture)
        self.cam.sig_frame.connect(self.on_cam_frame)
        self.cam.sig_done.connect(self.on_cam_done)
        self.det.sig_status.connect(lambda s: print("[DET]", s))
        self.det.sig_error.connect(lambda e: print("[DET-ERR]", e))
        self.cam.sig_error.connect(lambda e: print("[CAM-ERR]", e))
        self.det_thread.start()
        self.cam_thread.start()

        # 전송 워커(백업 큐)
        self.tx_thread = QThread(self)
        self.tx = TxWorker(bt_serial, arduino)
        self.tx.moveToThread(self.tx_thread)
        self.tx_thread.started.connect(self.tx.loop)
        self.tx.sig_error.connect(lambda e: self.statusBar().showMessage(e))
        self.tx_thread.start()

        # (중요) 주기적 RX 드레인: 아두이노 + BT (50Hz)
        self._rx_timer = QTimer(self)
        self._rx_timer.setInterval(20)
        self._rx_timer.timeout.connect(self._drain_serial_rx)
        self._rx_timer.start()

        # 아두이노 핸드셰이크 — 스플래시 끝난 뒤 수행
        self._handshake_and_init()

    # ===== 메인 UI =====
    def _add_side_text(self, right_of_vrule: QWidget, anchor_rect, text, max_w=160, h=16, x_pad=6):
        ax, ay, aw, ah = anchor_rect
        vx = right_of_vrule.geometry().x() + right_of_vrule.width()
        rx = vx + x_pad
        ry = ay + (ah - h) // 2
        if rx + max_w > 800: max_w = max(40, 800 - rx)
        lbl = QLabel(self.ui.centralwidget)
        lbl.setGeometry(QRect(rx, ry, max_w, h)); lbl.setText(text)
        lbl.setAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        lbl.setStyleSheet("color:#fff; background:transparent;")
        f = QFont(); f.setPointSize(9); lbl.setFont(f); lbl.setWordWrap(False); lbl.raise_()
        return lbl

    def _build_main_ui(self, visible: bool):
        widgets = []
        self.mic = SimpleToggleLabel(ICON_STILL, ICON_GIF, self.ui.centralwidget)
        self.mic.setGeometry(QRect(*MIC_TOGGLE_RECT)); widgets.append(self.mic)
        self.wave = SimpleToggleLabel(WAVE_ICON_STILL, WAVE_ICON_GIF, self.ui.centralwidget)
        self.wave.setGeometry(QRect(*WAVE_TOGGLE_RECT)); widgets.append(self.wave)

        self.result_img = QLabel(self.ui.centralwidget)
        self.result_img.setGeometry(QRect(*RESULT_IMAGE_RECT))
        self.result_img.setStyleSheet("background:transparent;")
        self.result_img.setPixmap(QPixmap(RESULT_IMG).scaled(self.result_img.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation))
        self.result_img.hide()

        # MIC 토글 → STT + SPEAK 토글 (원래 동작 유지)
        self.mic.toggled.connect(self._on_mic_clicked_for_stt)

        self.sound_icon = ClickableLabel(self.ui.centralwidget)
        self.sound_icon.setGeometry(QRect(*SOUND_ICON_RECT))
        self.sound_icon.setPixmap(QPixmap(SOUND_ICON).scaled(SOUND_ICON_RECT[2], SOUND_ICON_RECT[3], Qt.KeepAspectRatio, Qt.SmoothTransformation))
        widgets.append(self.sound_icon)

        self.direction_icon = ClickableLabel(self.ui.centralwidget)
        self.direction_icon.setGeometry(QRect(*DIRECTION_ICON_RECT))
        self.direction_icon.setPixmap(QPixmap(DIRECTION_ICON).scaled(DIRECTION_ICON_RECT[2], DIRECTION_ICON_RECT[3], Qt.KeepAspectRatio, Qt.SmoothTransformation))
        widgets.append(self.direction_icon)

        self.rule_wave_bottom = HRule(y=WAVE_BOTTOM_Y, parent=self.ui.centralwidget)
        self.rule_mic_top     = HRule(y=MIC_TOP_Y,     parent=self.ui.centralwidget)
        widgets.extend([self.rule_wave_bottom, self.rule_mic_top])

        wave_right_x = WAVE_TOGGLE_RECT[0] + WAVE_TOGGLE_RECT[2]
        self.v_wave_r = VRule(x=wave_right_x + 5, y0=0, y1=WAVE_BOTTOM_Y, parent=self.ui.centralwidget)
        sound_left_x  = SOUND_ICON_RECT[0]
        sound_right_x = SOUND_ICON_RECT[0] + SOUND_ICON_RECT[2]
        self.v_sound_l = VRule(x=sound_left_x - 5, y0=0, y1=WAVE_BOTTOM_Y, parent=self.ui.centralwidget)
        self.v_sound_r = VRule(x=sound_right_x + 5, y0=0, y1=WAVE_BOTTOM_Y, parent=self.ui.centralwidget)
        dir_left_x  = DIRECTION_ICON_RECT[0]
        dir_right_x = DIRECTION_ICON_RECT[0] + DIRECTION_ICON_RECT[2]
        self.v_dir_l = VRule(x=dir_left_x - 5, y0=0, y1=WAVE_BOTTOM_Y, parent=self.ui.centralwidget)
        self.v_dir_r = VRule(x=dir_right_x + 5, y0=0, y1=WAVE_BOTTOM_Y, parent=self.ui.centralwidget)
        widgets.extend([self.v_wave_r, self.v_sound_l, self.v_sound_r, self.v_dir_l, self.v_dir_r])

        # ==== 텍스트 표시용 라벨(초기 기본값 표시) ====
        self.wave_caption  = self._add_side_text(self.v_wave_r, WAVE_TOGGLE_RECT, "후방 감지 센서", max_w=140)
        self.sound_caption = self._add_side_text(self.v_sound_r, SOUND_ICON_RECT, "소리 종류", max_w=120)
        self.dir_caption   = self._add_side_text(self.v_dir_r, DIRECTION_ICON_RECT, "소리 방향", max_w=120)

        # 아이콘 클릭 시 보이기/숨기기 토글 (기본 표시)
        self.sound_icon.clicked.connect(lambda: self.sound_caption.setVisible(not self.sound_caption.isVisible()))
        self.direction_icon.clicked.connect(lambda: self.dir_caption.setVisible(not self.dir_caption.isVisible()))

        # WAVE: 토글 On이면 숨김, Off이면 표시
        self.wave.toggled.connect(lambda is_on: self.wave_caption.setVisible(not is_on))

        for lbl in (self.wave_caption, self.sound_caption, self.dir_caption):
            lbl.raise_()

        self._ui_after_splash = widgets + [self.wave_caption, self.sound_caption, self.dir_caption]
        for w in self._ui_after_splash: (w.show() if visible else w.hide())

        # 숨김 버튼(5클릭 종료)
        gx, gy, gw, gh = GREEN_CIRCLE_RECT
        self.hidden_button = InvisibleButton(self.ui.centralwidget, QRect(gx, gy, gw, gh))
        self.hidden_button.raise_(); self.hidden_button.show()

    # ===== 카메라 표시영역: 두 가로선 사이(세로), 가로 전폭(0~800) =====
    def _apply_camera_bounds(self):
        left = 0
        right = 800
        top_pad = 2
        bottom_pad = 2
        y = WAVE_BOTTOM_Y + top_pad
        h = max(1, MIC_TOP_Y - y - bottom_pad)
        self.camera_label.setGeometry(QRect(left, y, right - left, h))

    # ===== (중요) 주기적 RX 드레인: 아두이노 + BT =====
    def _drain_serial_rx(self):
        try:
            if arduino and arduino.in_waiting:
                arduino.read(arduino.in_waiting)  # 모두 버리기
        except: pass
        try:
            if bt_serial and bt_serial.in_waiting:
                bt_serial.read(bt_serial.in_waiting)  # 모두 버리기
        except: pass

    # ===== 전송 페이로드 생성 (분리) =====
    def _build_payloads(self, pred_class: str, angle):
        # Arduino: 대문자 토큰
        token_arduino = CLASS_ID_MAP.get(pred_class, "NONE")
        try:
            ang = int(angle) % 360
        except Exception:
            ang = 0
        msg_arduino = f"{token_arduino},{ang}\n".encode('utf-8')

        # BT: 원문 케이스 (Siren/Horn)
        cls_bt = pred_class if pred_class in ("Siren", "Horn") else "None"
        msg_bt = f"{cls_bt},{ang}\n".encode('utf-8')

        print(f"[TX-READY] {token_arduino},{ang}")
        return msg_arduino, msg_bt

    # ===== 즉시 전송 함수(직접 write+flush, 실패 시 큐 폴백) =====
    def _send_arduino_now(self, payload: bytes):
        self._drain_serial_rx()  # 전송 직전 RX 드레인
        try:
            if arduino:
                arduino.write(payload)
                try: arduino.flush()
                except: pass
                print(f"[ARDUINO<=] {payload!r}")
                return True
        except Exception as e:
            self.statusBar().showMessage(f"아두이노 전송 오류: {e}")
        if hasattr(self, 'tx') and self.tx: self.tx.q.put(("arduino", payload))
        return False

    def _send_bt_now(self, payload: bytes):
        self._drain_serial_rx()  # 전송 직전 RX 드레인
        try:
            if bt_serial:
                bt_serial.write(payload)
                try: bt_serial.flush()
                except: pass
                print(f"[BT<=] {payload!r}")
                return True
        except Exception as e:
            self.statusBar().showMessage(f"BT 전송 오류: {e}")
        if hasattr(self, 'tx') and self.tx: self.tx.q.put(("bt", payload))
        return False

    # ===== MIC 클릭 → STT 1회 + SPEAK 토글 (원래 로직 유지) =====
    @Slot(bool)
    def _on_mic_clicked_for_stt(self, is_on: bool):
        if not is_on:
            # 토글 OFF: SPEAK 숨김, STT 중단 로직은 기존과 동일(별도 취소 없음)
            self.result_img.hide()
            return

        # 토글 ON: 마이크 GIF는 SimpleToggleLabel이 이미 ON, SPEAK 표시 후 1회 STT
        self.result_img.show()

        if self._stt_busy:
            self.statusBar().showMessage("STT 진행 중...")
            return
        if _resolve_device(STT_DEVICE) is None:
            self.statusBar().showMessage("STT 장치(uacdemo) 미인식 — sd.query_devices() 확인 필요")
            # 사용자가 토글 ON 했지만 장치가 없으면 즉시 되돌려줌
            try:
                self.mic.set_gif(False)
            except Exception:
                pass
            self.result_img.hide()
            return

        self._stt_busy = True
        if self.det:  # 스플래시 중 보호
            self.det.set_audio_enabled(False)
            self.det.reset_buffer()

        self.stt_thread = QThread(self)
        self.stt_worker = SingleShotSTTWorker(record_audio, convert_to_wav_bytes, recognize_audio)
        self.stt_worker.moveToThread(self.stt_thread)
        self.stt_thread.started.connect(self.stt_worker.start_once)
        self.stt_worker.sig_text.connect(self._on_stt_finished)
        self.stt_worker.sig_error.connect(lambda e: self._on_stt_finished(f"(STT 오류: {e})"))
        self.stt_thread.start()

    @Slot(str)
    def _on_stt_finished(self, text):
        text = (text or "").strip()
        if text:
            self.stt_label.setText(text)
            self.stt_label.show()
            # 7초 뒤 자동 숨김 (새 결과 오면 리셋)
            try:
                if self._stt_hide_timer.isActive():
                    self._stt_hide_timer.stop()
            except: pass
            self._stt_hide_timer.timeout.connect(self.stt_label.hide)
            self._stt_hide_timer.start(7000)
            # (요구사항) STT 텍스트를 BT로 전송
            self._send_bt_now(f"text={text}\n".encode('utf-8'))

        # 원래 동작: STT 종료 후에도 마이크 GIF/SPEAK 이미지는 사용자가 다시 누를 때까지 유지
        if self.det:
            self.det.reset_buffer()
            self.det.set_audio_enabled(True)
        try:
            self.stt_thread.quit(); self.stt_thread.wait(1500)
        except: pass
        self.stt_thread = None; self.stt_worker = None
        self._stt_busy = False

    # ===== 카메라 콜백 =====
    @Slot(object)
    def on_cam_frame(self, qimg):
        self.camera_label.setPixmap(QPixmap.fromImage(qimg))

    @Slot()
    def on_cam_done(self):
        self._camera_active = False
        self.camera_label.hide()
        self.ui.hearo_anim.show()

        # 표시 리셋(다음 감지 대기)
        self.sound_caption.setText("소리 종류")
        self.dir_caption.setText("소리 방향")
        self._frozen_detection = False
        self._frozen_class = None
        self._frozen_angle = None

        if self.det:
            self.det.reset_buffer()
            self.det.set_audio_enabled(True)
        self.statusBar().showMessage("카메라 종료 — 감지 재개")

    # ===== 감지 시그널: 전송 → 카메라 → GUI =====
    @Slot(str, float, int)
    def on_detection(self, pred_class, prob, angle):
        # 스플래시 중(워커 시작 전) 보호
        if self.det is None:
            return

        # 이미 카메라 동작 중이면 새 이벤트는 무시(7초 윈도우)
        if self._camera_active or self._frozen_detection:
            return

        # 임계 체크(클래스별) + None 무시
        thr_map = {'Horn': 0.94, 'Siren': 0.94}
        if pred_class not in thr_map or prob < thr_map[pred_class]:
            return

        # === 1) 먼저 전송 (Arduino/BT 각각 형식 분리) ===
        payload_arduino, payload_bt = self._build_payloads(pred_class, angle)
        self._send_arduino_now(payload_arduino)
        self._send_bt_now(payload_bt)

        # === 2) 카메라 즉시 시작 ===
        cam_path, _ = self._select_camera_safe(angle)
        if cam_path:
            self.det.set_audio_enabled(False)  # 카메라 동안 감지 정지(마이크 STT에는 영향 없음)
            self.det.reset_buffer()
            self._apply_camera_bounds()
            self.ui.hearo_anim.hide()
            self.camera_label.show()
            self._camera_active = True
            self.statusBar().showMessage("카메라 동작(7초)")
            self.camera_request.emit(cam_path, 7000)

        # === 3) GUI 텍스트 즉시 갱신 ===
        try:
            ang = int(angle) % 360
            ang_text = f"{ang}°"
        except Exception:
            ang_text = ""
        self.sound_caption.setText(f"{pred_class}")
        self.dir_caption.setText(ang_text)

        # 라치: 이번 7초 동안 같은 이벤트 재처리 방지
        self._frozen_detection = True
        self._frozen_class = pred_class
        self._frozen_angle = ang_text

    # ===== 각도 안전 정규화 + 카메라 선택 =====
    def _select_camera_safe(self, angle):
        try:
            angle = int(angle) % 360
        except Exception:
            angle = 0
        if 0 <= angle <= 90:   return CAMERA_FRONT, "전방좌측"
        if 91 <= angle <= 180: return CAMERA_LEFT,  "후방좌측"
        if 181 <= angle <= 270:return CAMERA_BACK,  "후방우측"
        if 271 <= angle <= 360:return CAMERA_RIGHT, "전방우측"
        return None, "잘못된 각도"

    # ===== 스플래시/아두이노 =====
    def _handshake_and_init(self):
        if not arduino: return
        try:
            ok = False
            for _ in range(10):
                arduino.write(b'ping\n'); time.sleep(0.2)
                if arduino.in_waiting:
                    res = arduino.readline().decode('utf-8', 'ignore').strip()
                    if res == 'pong': ok = True; break
            print("[아두이노 핸드셰이크]", "성공" if ok else "실패")
            if ok:
                arduino.write(b"INIT\n"); time.sleep(0.05); arduino.reset_input_buffer()
        except Exception as e:
            print("[아두이노 핸드셰이크 오류]", e)

    def closeEvent(self, e):
        try:
            if self.det: self.det.set_audio_enabled(False)
        except: pass
        try:
            if self.cam: self.cam.sig_done.disconnect()
        except: pass
        try:
            if self.det_thread: self.det_thread.quit(); self.det_thread.wait(1500)
        except: pass
        try:
            if self.cam_thread: self.cam_thread.quit(); self.cam_thread.wait(1500)
        except: pass
        if self.stt_thread:
            try: self.stt_thread.quit(); self.stt_thread.wait(1500)
            except: pass
        try:
            if self.tx: self.tx.stop()
            if self.tx_thread: self.tx_thread.quit(); self.tx_thread.wait(1500)
        except: pass
        super().closeEvent(e)

# ===== Autostart 엔트리 생성 유틸 =====
def ensure_autostart():
    """
    사용자의 그래픽 세션 시작 시 본 스크립트를 자동 실행하도록
    ~/.config/autostart/hearo-ui.desktop 을 생성합니다.
    이미 존재하면 덮어쓰지 않고 그대로 둡니다. (지연 없이 즉시 실행)
    """
    if not AUTOSTART_ENABLE:
        return
    try:
        home = os.path.expanduser("~")
        autostart_dir = os.path.join(home, ".config", "autostart")
        os.makedirs(autostart_dir, exist_ok=True)

        desktop_path = os.path.join(autostart_dir, AUTOSTART_NAME)
        if os.path.exists(desktop_path):
            return  # 이미 있으면 그대로 둠

        # 현재 파이썬과 스크립트 경로 자동 감지
        py = sys.executable or "/usr/bin/python3"
        script = os.path.abspath(sys.argv[0])

        exec_line = (
            f"/bin/sh -lc '"
            f"export QT_QPA_PLATFORM=xcb DISPLAY=:0; "
            f"\"{py}\" \"{script}\"'"
        )

        content = [
            "[Desktop Entry]",
            "Type=Application",
            "Name=Hear-O UI",
            "Comment=Launch Hear-O UI controller on login",
            f"Exec={exec_line}",
            "X-GNOME-Autostart-enabled=true"
        ]
        with open(desktop_path, "w", encoding="utf-8") as f:
            f.write("\n".join(content) + "\n")
        print(f"[AUTOSTART] 생성됨: {desktop_path}")
    except Exception as e:
        print(f"[AUTOSTART] 생성 실패: {e}")

if __name__ == "__main__":
    # Autostart 엔트리 보장(옵션)
    ensure_autostart()

    app = QApplication(sys.argv)
    # (선택) 전역 커서 숨김이 필요하면 주석 해제
    # app.setOverrideCursor(Qt.BlankCursor)

    win = App()

    # 완전 전체화면으로 표시(상태바/패널까지 덮음)
    win.showFullScreen()

    # 일부 환경(패널이 앞에 다시 뜨는 경우) 대비: 0.5초 뒤 FullScreen + raise 재적용
    QTimer.singleShot(500, lambda: (
        win.setWindowState(win.windowState() | Qt.WindowFullScreen),
        win.raise_()
    ))

    sys.exit(app.exec())



