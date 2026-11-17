import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

from PySide6.QtCore import Qt, QThread, QUrl, Signal
from PySide6.QtGui import QFont
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QFileDialog,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QSlider,
    QSplitter,
    QVBoxLayout,
    QWidget,
)


def resource_bin_dir() -> Path:
    if hasattr(sys, "_MEIPASS"):
        p = Path(sys._MEIPASS) / "bin"
        if p.exists():
            return p
    local = Path(__file__).resolve().parent / "bin"
    return local


def find_exe(name: str) -> str:
    bdir = resource_bin_dir()
    candidate = bdir / name
    if candidate.exists():
        return str(candidate)
    return name


def app_data_dir() -> Path:
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    else:
        base = Path.home() / "Library" / "Application Support"
    root = base / "TikhiyText"
    (root / "Models").mkdir(parents=True, exist_ok=True)
    (root / "Work").mkdir(parents=True, exist_ok=True)
    return root


def fmt_clock(ms: int) -> str:
    sec = max(0, ms // 1000)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h > 0 else f"{m:02d}:{s:02d}"


def fmt_srt(ms: int) -> str:
    ms = max(0, ms)
    h, rem = divmod(ms, 3_600_000)
    m, rem = divmod(rem, 60_000)
    s, rem_ms = divmod(rem, 1_000)
    return f"{h:02d}:{m:02d}:{s:02d},{rem_ms:03d}"


class ModelDownloadThread(QThread):
    progress = Signal(int, str)
    done = Signal(bool, str)

    URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"

    def run(self):
        dest = app_data_dir() / "Models" / "ggml-small.bin"
        tmp = dest.with_suffix(".part")
        try:
            def hook(blocks, block_size, total):
                if total > 0:
                    pct = min(int(blocks * block_size * 100 / total), 99)
                    self.progress.emit(pct, f"Скачивание модели Whisper Small: {pct}%")

            urllib.request.urlretrieve(self.URL, str(tmp), reporthook=hook)
            tmp.replace(dest)
            self.progress.emit(100, "Модель установлена!")
            self.done.emit(True, str(dest))
        except Exception as e:
            if tmp.exists():
                tmp.unlink(missing_ok=True)
            self.done.emit(False, str(e))


class TranscribeThread(QThread):
    progress = Signal(int, str)
    done = Signal(list)
    failed = Signal(str)

    def __init__(self, source: Path, model: Path, lang: str, beam: int):
        super().__init__()
        self.source = source
        self.model = model
        self.lang = lang
        self.beam = beam
        self._proc = None
        self._cancelled = False

    def cancel(self):
        self._cancelled = True
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()

    def run(self):
        ffmpeg = find_exe("ffmpeg.exe" if os.name == "nt" else "ffmpeg")
        whisper = find_exe("whisper-cli.exe" if os.name == "nt" else "whisper-cli")
        creationflags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

        with tempfile.TemporaryDirectory(dir=str(app_data_dir() / "Work")) as tmp:
            tmp_dir = Path(tmp)
            wav = tmp_dir / "audio.wav"
            out_base = tmp_dir / "result"

            self.progress.emit(5, "Извлечение аудио (16kHz WAV)…")
            p1 = subprocess.run(
                [ffmpeg, "-nostdin", "-y", "-i", str(self.source), "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav)],
                capture_output=True,
                text=True,
                creationflags=creationflags,
            )
            if p1.returncode != 0 or not wav.exists():
                self.failed.emit(p1.stderr[-500:] or "Ошибка ffmpeg при извлечении аудио")
                return

            if self._cancelled:
                self.failed.emit("Отменено")
                return

            self.progress.emit(20, "Расшифровка речи (Whisper)…")
            cmd = [
                whisper,
                "-m", str(self.model),
                "-f", str(wav),
                "-l", self.lang,
                "-t", str(max(2, (os.cpu_count() or 4) // 2)),
                "-bs", str(self.beam),
                "-bo", str(self.beam),
                "-oj",
                "-of", str(out_base),
                "-pp",
            ]
            try:
                self._proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    creationflags=creationflags,
                )
                last_err = []
                for line in self._proc.stdout:
                    if self._cancelled:
                        break
                    last_err.append(line.strip())
                    last_err = last_err[-10:]
                    m = re.search(r"progress\s*=\s*(\d+)%", line)
                    if m:
                        pct = 20 + int(int(m.group(1)) * 0.78)
                        self.progress.emit(min(pct, 98), f"Расшифровка: {m.group(1)}%")

                rc = self._proc.wait()
                if self._cancelled:
                    self.failed.emit("Отменено")
                    return
                json_path = out_base.with_suffix(".json")
                if rc != 0 or not json_path.exists():
                    self.failed.emit("\n".join(last_err) or f"whisper-cli ошибка (код {rc})")
                    return

                data = json.loads(json_path.read_text(encoding="utf-8"))
                segments = []
                for item in data.get("transcription", []):
                    txt = (item.get("text") or "").strip()
                    if not txt:
                        continue
                    offs = item.get("offsets") or {}
                    segments.append({
                        "start_ms": int(offs.get("from", 0)),
                        "end_ms": int(offs.get("to", 0)),
                        "text": txt,
                    })
                self.progress.emit(100, "Готово!")
                self.done.emit(segments)
            except Exception as e:
                self.failed.emit(str(e))


class TranscriberWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Расшифровщик — Антон Белый")
        self.resize(1040, 680)
        self.setAcceptDrops(True)

        self.current_file: Path | None = None
        self.segments: list[dict] = []
        self.transcribe_thread: TranscribeThread | None = None
        self.dl_thread: ModelDownloadThread | None = None

        self.player = QMediaPlayer(self)
        self.audio_out = QAudioOutput(self)
        self.player.setAudioOutput(self.audio_out)

        self.setStyleSheet("""
            QMainWindow, QWidget { background-color: #0a0e17; color: #f8fafc; font-family: 'Segoe UI', sans-serif; }
            QLineEdit, QComboBox, QListWidget {
                background-color: #121826; border: 1px solid rgba(255,255,255,0.10);
                border-radius: 8px; padding: 7px 10px; color: #f8fafc; font-size: 13px;
            }
            QPushButton {
                background-color: #1a2335; border: 1px solid rgba(255,255,255,0.12);
                border-radius: 8px; padding: 8px 14px; color: #f8fafc; font-weight: 600;
            }
            QPushButton:hover { background-color: #243047; }
            QPushButton#primaryBtn { background-color: #2ed19e; color: #080c12; border: none; }
            QPushButton#primaryBtn:hover { background-color: #4be0b2; }
            QProgressBar {
                background-color: #121826; border: 1px solid rgba(255,255,255,0.08);
                border-radius: 6px; text-align: center; height: 18px;
            }
            QProgressBar::chunk { background-color: #2ed19e; border-radius: 5px; }
        """)

        root = QWidget()
        self.setCentralWidget(root)
        main_layout = QVBoxLayout(root)
        main_layout.setContentsMargins(18, 14, 18, 12)
        main_layout.setSpacing(12)

        # Top Bar
        top = QHBoxLayout()
        title = QLabel("Расшифровщик")
        title.setFont(QFont("Segoe UI", 18, QFont.Bold))
        top.addWidget(title)
        top.addStretch()

        self.lang_box = QComboBox()
        self.lang_box.addItems(["Русский (ru)", "Авто (auto)"])
        self.speed_box = QComboBox()
        self.speed_box.addItems(["Быстро (beam=1)", "Баланс (beam=2)", "Точно (beam=5)"])
        self.model_box = QComboBox()
        self.model_box.setMinimumWidth(180)
        self.refresh_models()

        open_btn = QPushButton("＋ Открыть файл")
        open_btn.setObjectName("primaryBtn")
        open_btn.clicked.connect(self.open_file_dialog)

        top.addWidget(QLabel("Язык:"))
        top.addWidget(self.lang_box)
        top.addWidget(QLabel("Режим:"))
        top.addWidget(self.speed_box)
        top.addWidget(QLabel("Модель:"))
        top.addWidget(self.model_box)
        top.addWidget(open_btn)
        main_layout.addLayout(top)

        # Model Download Banner (if no model found)
        self.model_banner = QHBoxLayout()
        self.dl_model_btn = QPushButton("⬇ Скачать модель Whisper Small (466 МБ)")
        self.dl_model_btn.setObjectName("primaryBtn")
        self.dl_model_btn.clicked.connect(self.download_model)
        self.model_banner_lbl = QLabel("Локальная модель Whisper не найдена:")
        self.model_banner_lbl.setStyleSheet("color: #fbbf24;")
        self.model_banner.addWidget(self.model_banner_lbl)
        self.model_banner.addWidget(self.dl_model_btn)
        self.model_banner.addStretch()
        main_layout.addLayout(self.model_banner)
        self.update_model_banner()

        # Progress bar
        prog_row = QHBoxLayout()
        self.progress = QProgressBar()
        self.status_lbl = QLabel("Перетащите аудио или видеофайл (MP4, MOV, MP3, WAV, M4A) в это окно")
        self.status_lbl.setStyleSheet("color: #94a3b8; font-size: 12px;")
        self.cancel_btn = QPushButton("Стоп")
        self.cancel_btn.setEnabled(False)
        self.cancel_btn.clicked.connect(self.cancel_task)
        prog_row.addWidget(self.progress, 1)
        prog_row.addWidget(self.cancel_btn)
        main_layout.addLayout(prog_row)
        main_layout.addWidget(self.status_lbl)

        # Splitter: Left (Player + Transcript), Right (Export + Stop-frames)
        splitter = QSplitter(Qt.Horizontal)

        left = QWidget()
        left_l = QVBoxLayout(left)
        left_l.setContentsMargins(0, 0, 10, 0)

        self.video_widget = QVideoWidget()
        self.video_widget.setMinimumHeight(200)
        self.video_widget.hide()
        self.player.setVideoOutput(self.video_widget)
        left_l.addWidget(self.video_widget)

        # Player controls
        p_row = QHBoxLayout()
        self.play_btn = QPushButton("▶")
        self.play_btn.setFixedWidth(44)
        self.play_btn.clicked.connect(self.toggle_play)
        self.time_lbl = QLabel("00:00 / 00:00")
        self.time_lbl.setStyleSheet("font-family: Consolas, monospace; font-size: 12px; color: #94a3b8;")
        self.seek_slider = QSlider(Qt.Horizontal)
        self.seek_slider.sliderMoved.connect(lambda v: self.player.setPosition(v))
        self.rate_box = QComboBox()
        self.rate_box.addItems(["1.0x", "1.25x", "1.5x", "2.0x"])
        self.rate_box.currentTextChanged.connect(lambda t: self.player.setPlaybackRate(float(t.replace("x", ""))))

        self.toggle_vid_btn = QPushButton("Видео")
        self.toggle_vid_btn.clicked.connect(self.toggle_video)
        self.snap_btn = QPushButton("📸 Стоп-кадр")
        self.snap_btn.clicked.connect(self.capture_current_frame)

        p_row.addWidget(self.play_btn)
        p_row.addWidget(self.time_lbl)
        p_row.addWidget(self.seek_slider, 1)
        p_row.addWidget(self.rate_box)
        p_row.addWidget(self.toggle_vid_btn)
        p_row.addWidget(self.snap_btn)
        left_l.addLayout(p_row)

        self.search_input = QLineEdit()
        self.search_input.setPlaceholderText("🔍 Поиск по тексту расшифровки…")
        self.search_input.textChanged.connect(self.render_segments)
        left_l.addWidget(self.search_input)

        self.seg_list = QListWidget()
        self.seg_list.itemClicked.connect(self.on_segment_clicked)
        left_l.addWidget(self.seg_list, 1)

        right = QWidget()
        right.setFixedWidth(250)
        right_l = QVBoxLayout(right)
        right_l.setContentsMargins(10, 0, 0, 0)
        right_l.setSpacing(8)

        exp_lbl = QLabel("Экспорт и данные")
        exp_lbl.setFont(QFont("Segoe UI", 13, QFont.Bold))
        right_l.addWidget(exp_lbl)

        copy_btn = QPushButton("📋 Копировать весь текст")
        copy_btn.clicked.connect(self.copy_all)
        right_l.addWidget(copy_btn)

        for fmt in ("TXT", "Markdown", "SRT", "VTT"):
            b = QPushButton(f"⬇ Сохранить {fmt}")
            b.clicked.connect(lambda _, f=fmt: self.export_format(f))
            right_l.addWidget(b)

        right_l.addSpacing(14)
        data_btn = QPushButton("📂 Папка данных")
        data_btn.clicked.connect(self.open_data_dir)
        clear_btn = QPushButton("🗑 Очистить кэш")
        clear_btn.clicked.connect(self.clear_cache)
        right_l.addWidget(data_btn)
        right_l.addWidget(clear_btn)
        right_l.addStretch()

        author_lbl = QLabel("Антон Белый")
        author_lbl.setAlignment(Qt.AlignCenter)
        author_lbl.setStyleSheet("color: #64748b; font-size: 11px;")
        right_l.addWidget(author_lbl)

        splitter.addWidget(left)
        splitter.addWidget(right)
        splitter.setStretchFactor(0, 1)
        main_layout.addWidget(splitter, 1)

        self.player.positionChanged.connect(self.on_pos_changed)
        self.player.durationChanged.connect(self.on_dur_changed)

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event):
        urls = [Path(u.toLocalFile()) for u in event.mimeData().urls() if u.isLocalFile()]
        if urls:
            self.start_file(urls[0])

    def refresh_models(self):
        self.model_box.clear()
        models_dir = app_data_dir() / "Models"
        for p in sorted(models_dir.glob("*.bin")):
            mb = p.stat().st_size // (1024 * 1024)
            self.model_box.addItem(f"{p.stem} ({mb} МБ)", str(p))

    def update_model_banner(self):
        has_model = self.model_box.count() > 0
        self.model_banner_lbl.setVisible(not has_model)
        self.dl_model_btn.setVisible(not has_model)

    def download_model(self):
        self.dl_model_btn.setEnabled(False)
        self.dl_thread = ModelDownloadThread()
        self.dl_thread.progress.connect(lambda p, m: (self.progress.setValue(p), self.status_lbl.setText(m)))
        self.dl_thread.done.connect(self.on_model_downloaded)
        self.dl_thread.start()

    def on_model_downloaded(self, ok: bool, msg: str):
        self.dl_model_btn.setEnabled(True)
        if ok:
            self.refresh_models()
            self.update_model_banner()
            self.status_lbl.setText("Модель готова! Перетащите файл для расшифровки.")
        else:
            QMessageBox.warning(self, "Ошибка загрузки модели", msg)

    def open_file_dialog(self):
        path, _ = QFileDialog.getOpenFileName(self, "Выберите аудио или видео", "", "Медиафайлы (*.mp4 *.mov *.m4v *.mkv *.mp3 *.wav *.m4a *.aac)")
        if path:
            self.start_file(Path(path))

    def start_file(self, path: Path):
        if self.model_box.count() == 0:
            QMessageBox.information(self, "Нужна модель", "Сначала нажмите «Скачать модель Whisper Small».")
            return
        self.current_file = path
        self.player.setSource(QUrl.fromLocalFile(str(path)))
        if path.suffix.lower() in {".mp4", ".mov", ".m4v", ".mkv"}:
            self.video_widget.show()

        model_path = Path(self.model_box.currentData())
        lang = "ru" if self.lang_box.currentIndex() == 0 else "auto"
        beam = [1, 2, 5][self.speed_box.currentIndex()]

        self.cancel_btn.setEnabled(True)
        self.progress.setValue(2)
        self.status_lbl.setText(f"Обработка: {path.name}")
        self.transcribe_thread = TranscribeThread(path, model_path, lang, beam)
        self.transcribe_thread.progress.connect(lambda p, m: (self.progress.setValue(p), self.status_lbl.setText(m)))
        self.transcribe_thread.done.connect(self.on_transcribed)
        self.transcribe_thread.failed.connect(self.on_failed)
        self.transcribe_thread.start()

    def cancel_task(self):
        if self.transcribe_thread:
            self.transcribe_thread.cancel()

    def on_transcribed(self, segments: list):
        self.cancel_btn.setEnabled(False)
        self.segments = segments
        self.render_segments()
        self.status_lbl.setText(f"✅ Готово: {len(segments)} фрагментов")

    def on_failed(self, msg: str):
        self.cancel_btn.setEnabled(False)
        self.status_lbl.setText("❌ " + msg[:100])
        if msg != "Отменено":
            QMessageBox.warning(self, "Расшифровщик", msg)

    def render_segments(self):
        q = self.search_input.text().strip().lower()
        self.seg_list.clear()
        for seg in self.segments:
            if q and q not in seg["text"].lower():
                continue
            it = QListWidgetItem(f"[{fmt_clock(seg['start_ms'])}]  {seg['text']}")
            it.setData(Qt.UserRole, seg["start_ms"])
            self.seg_list.addItem(it)

    def on_segment_clicked(self, item: QListWidgetItem):
        ms = item.data(Qt.UserRole)
        if ms is not None:
            self.player.setPosition(int(ms))
            self.player.play()
            self.play_btn.setText("⏸")

    def toggle_play(self):
        if self.player.playbackState() == QMediaPlayer.PlayingState:
            self.player.pause()
            self.play_btn.setText("▶")
        else:
            self.player.play()
            self.play_btn.setText("⏸")

    def toggle_video(self):
        self.video_widget.setVisible(not self.video_widget.isVisible())

    def on_pos_changed(self, pos: int):
        self.seek_slider.setValue(pos)
        dur = self.player.duration()
        self.time_lbl.setText(f"{fmt_clock(pos)} / {fmt_clock(dur)}")

    def on_dur_changed(self, dur: int):
        self.seek_slider.setRange(0, max(1, dur))

    def capture_current_frame(self):
        if not self.current_file:
            return
        sec = max(0.0, self.player.position() / 1000.0)
        ffmpeg = find_exe("ffmpeg.exe" if os.name == "nt" else "ffmpeg")
        out_dir = self.current_file.parent / "Стоп-кадры"
        out_dir.mkdir(parents=True, exist_ok=True)
        ts = fmt_clock(int(sec * 1000)).replace(":", "-")
        dest = out_dir / f"{self.current_file.stem}_{ts}.jpg"
        creationflags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        res = subprocess.run([ffmpeg, "-y", "-ss", f"{sec:.3f}", "-i", str(self.current_file), "-frames:v", "1", "-q:v", "2", str(dest)], capture_output=True, creationflags=creationflags)
        if res.returncode == 0 and dest.exists():
            self.status_lbl.setText(f"📸 Стоп-кадр сохранён: {dest.name}")
        else:
            QMessageBox.warning(self, "Стоп-кадр", "Не удалось снять кадр из этого файла.")

    def copy_all(self):
        if not self.segments:
            return
        text = "\n".join(s["text"] for s in self.segments)
        QApplication.clipboard().setText(text)
        self.status_lbl.setText("📋 Весь текст скопирован в буфер обмена")

    def export_format(self, fmt: str):
        if not self.segments or not self.current_file:
            return
        ext = "md" if fmt == "Markdown" else fmt.lower()
        dest = self.current_file.with_name(f"{self.current_file.stem} — расшифровка.{ext}")
        if fmt == "TXT":
            out = "\n".join(f"[{fmt_clock(s['start_ms'])}]  {s['text']}" for s in self.segments)
        elif fmt == "Markdown":
            out = f"# {self.current_file.stem}\n\n" + "\n\n".join(f"**[{fmt_clock(s['start_ms'])}]** {s['text']}" for s in self.segments)
        elif fmt == "SRT":
            out = "\n\n".join(f"{i+1}\n{fmt_srt(s['start_ms'])} --> {fmt_srt(s['end_ms'])}\n{s['text']}" for i, s in enumerate(self.segments))
        else:
            out = "WEBVTT\n\n" + "\n\n".join(f"{fmt_srt(s['start_ms']).replace(',', '.')} --> {fmt_srt(s['end_ms']).replace(',', '.')}\n{s['text']}" for s in self.segments)
        dest.write_text(out, encoding="utf-8")
        self.status_lbl.setText(f"💾 Сохранено: {dest.name}")

    def open_data_dir(self):
        d = app_data_dir()
        if os.name == "nt":
            os.startfile(str(d))
        else:
            subprocess.Popen(["open", str(d)])

    def clear_cache(self):
        w = app_data_dir() / "Work"
        for item in w.iterdir():
            shutil.rmtree(item, ignore_errors=True)
        self.status_lbl.setText("🗑 Временный кэш очищен")


if __name__ == "__main__":
    app = QApplication(sys.argv)
    win = TranscriberWindow()
    win.show()
    sys.exit(app.exec())
