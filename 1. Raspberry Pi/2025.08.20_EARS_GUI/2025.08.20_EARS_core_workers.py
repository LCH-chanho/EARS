# ========================== bridge_workers.py ==========================
# - DetectionWorker: 오디오 감지/추론(QThread 워커)
# - CameraWorker   : 카메라 프레임 캡처(QThread 워커, 15fps로 emit)
# - SingleShotSTTWorker: MIC 클릭 시 1회만 STT 수행(QThread 워커)

from PySide6.QtCore import QObject, Signal, Slot
import numpy as np
import cv2, time
from collections import deque
from scipy.signal import resample_poly
import sounddevice as sd
from gammatone.gtgram import gtgram

class DetectionWorker(QObject):
    sig_detection = Signal(str, float, int)  # class, prob, angle
    sig_status = Signal(str)
    sig_error = Signal(str)

    def __init__(self, model_path, mic_rate, model_rate, seg_sec,
                 win_t, hop_t, nfilt, fmin, device_name, mic_tuning_provider, class_names):
        super().__init__()
        self.model_path = model_path
        self.mic_rate = mic_rate
        self.model_rate = model_rate
        self.seg_samples = int(mic_rate * seg_sec)
        self.win_t, self.hop_t, self.nfilt, self.fmin = win_t, hop_t, nfilt, fmin
        self.device_name = device_name
        self.class_names = class_names

        # --- 변경: 샘플 단위 대신 '청크(np.ndarray)' 단위 버퍼
        self.chunks = deque(maxlen=64)    # 최근 오디오 블록들
        self.total_samples = 0            # chunks에 누적된 전체 샘플 수

        self.audio_enabled = True
        self._running = False
        self._target_frames = int(seg_sec / hop_t)
        self.mic_tuning_provider = mic_tuning_provider
        self.mic_tuning = None
        self.model = None
        # 48k -> 44.1k ≈ 147/160
        self.up, self.down = 147, 160

    def _preprocess(self, segment: np.ndarray):
        gtg = gtgram(segment, self.model_rate, self.win_t, self.hop_t, self.nfilt, self.fmin)
        gtg = np.log(gtg + 1e-6)
        if gtg.shape[1] < self._target_frames:
            pad = np.zeros((gtg.shape[0], self._target_frames - gtg.shape[1]), dtype=gtg.dtype)
            gtg = np.concatenate([gtg, pad], axis=1)
        elif gtg.shape[1] > self._target_frames:
            gtg = gtg[:, :self._target_frames]
        return gtg[..., np.newaxis]

    def _cb(self, indata, frames, time_info, status):
        # 정지 중이면 버퍼가 쌓이지 않게 즉시 반환
        if not self._running or not self.audio_enabled:
            return
        try:
            # L 채널을 float32로 복사해 청크로 저장
            ch0 = indata[:, 0].astype(np.float32).copy()
            self.chunks.append(ch0)
            self.total_samples += ch0.shape[0]
        except Exception:
            pass

    @Slot()
    def start(self):
        try:
            import tensorflow as tf
            self.model = tf.keras.models.load_model(self.model_path)
            self.sig_status.emit("모델 로드 완료")
        except Exception as e:
            self.sig_error.emit(f"모델 로드 실패: {e}")
            return

        try:
            self.mic_tuning = self.mic_tuning_provider()
            self.sig_status.emit("DOA 모듈 연결 완료")
        except Exception as e:
            self.sig_error.emit(f"DOA 모듈 연결 실패: {e}")
            return

        self._running = True
        try:
            with sd.InputStream(device=self.device_name,
                                samplerate=self.mic_rate,
                                channels=2,
                                dtype='int32',
                                callback=self._cb,
                                blocksize=self.seg_samples):
                while self._running:
                    if not self.audio_enabled:
                        sd.sleep(5)
                        continue

                    processed_any = False

                    # --- 변경: 누적 샘플 수 기준으로 정확히 seg_samples만큼 추출
                    while self.total_samples >= self.seg_samples:
                        processed_any = True
                        need = self.seg_samples
                        collected = []
                        while need > 0 and self.chunks:
                            block = self.chunks.popleft()
                            n = block.shape[0]
                            if n <= need:
                                collected.append(block)
                                need -= n
                            else:
                                collected.append(block[:need])
                                remain = block[need:]
                                self.chunks.appendleft(remain)
                                need = 0
                        if not collected:
                            break
                        seg = np.concatenate(collected, axis=0)
                        self.total_samples -= self.seg_samples

                        # int32 스케일 → float, 경량 리샘플
                        seg = (seg / (2**31)) * 0.1
                        seg = resample_poly(seg, self.up, self.down).astype(np.float32)

                        x = self._preprocess(seg)[None, ...]
                        try:
                            pred = self.model.predict(x, verbose=0)[0]
                            idx = int(np.argmax(pred))
                            cls = self.class_names[idx]
                            prob = float(pred[idx])
                            angle = getattr(self.mic_tuning, 'direction', 0)
                            try:
                                angle = int(angle) % 360
                            except Exception:
                                angle = 0
                            self.sig_detection.emit(cls, prob, angle)
                        except Exception as e:
                            self.sig_error.emit(f"추론 오류: {e}")
                            break

                    if not processed_any:
                        sd.sleep(5)
        except Exception as e:
            self.sig_error.emit(f"오디오 스트림 오류: {e}")

    @Slot(bool)
    def set_audio_enabled(self, enabled: bool):
        self.audio_enabled = enabled

    @Slot()
    def reset_buffer(self):
        self.chunks.clear()
        self.total_samples = 0

    @Slot()
    def stop(self):
        self._running = False


class CameraWorker(QObject):
    sig_frame = Signal(object)  # QImage
    sig_done = Signal()
    sig_error = Signal(str)

    def __init__(self):
        super().__init__()
        self._running = False

    @Slot(str, int)
    def start_capture(self, device_path: str, duration_ms: int):
        self._running = True
        cap = None
        try:
            cap = cv2.VideoCapture(device_path, cv2.CAP_V4L2)
            if not cap.isOpened():
                self.sig_error.emit(f"카메라 열기 실패: {device_path}")
                self.sig_done.emit()
                return

            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            cap.set(cv2.CAP_PROP_FPS, 30)

            deadline = time.time() + (duration_ms / 1000.0)
            from PySide6.QtGui import QImage
            last_emit = 0.0
            emit_interval = 1.0 / 15.0   # --- 변경: 15fps로 GUI emit 제한

            while self._running and time.time() < deadline:
                ok, frame = cap.read()
                if not ok:
                    continue
                now = time.time()
                if now - last_emit < emit_interval:
                    continue
                last_emit = now

                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                h, w, ch = rgb.shape
                qimg = QImage(rgb.data, w, h, ch * w, QImage.Format_RGB888).copy()
                self.sig_frame.emit(qimg)
        except Exception as e:
            self.sig_error.emit(f"카메라 오류: {e}")
        finally:
            try:
                if cap: cap.release()
            except:
                pass
            self._running = False
            self.sig_done.emit()


class SingleShotSTTWorker(QObject):
    sig_text = Signal(str)
    sig_error = Signal(str)

    def __init__(self, record_fn, to_wav_fn, stt_fn):
        super().__init__()
        self.record_fn = record_fn
        self.to_wav_fn = to_wav_fn
        self.stt_fn = stt_fn

    @Slot()
    def start_once(self):
        try:
            audio_np = self.record_fn()
            wav_bytes = self.to_wav_fn(audio_np)
            text = self.stt_fn(wav_bytes) or ""
            self.sig_text.emit(text)
        except Exception as e:
            self.sig_error.emit(f"STT 오류: {e}")



