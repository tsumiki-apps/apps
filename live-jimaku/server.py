# -*- coding: utf-8 -*-
"""ライブ字幕の小さなサーバー（Mac で動かし、Mac のブラウザか iPhone で見る）。

YouTube の生配信（字幕が無いものでも）の音を Mac で取り、mlx-whisper で文字にして
大きな文字の画面に流す。全部この Mac の中で動く（無料）。

  ../douga-sync/.venv/bin/python server.py   → http://127.0.0.1:8798
  iPhone からは Tailscale の https://<Macのtailnet名>:8445

流れ：yt-dlp（配信の音）→ ffmpeg（16kHz・1ch）→ 区切り（静かな所 or 最長12秒）→ Whisper
  ・区切る前も約1.5秒ごとに「仮」の字幕を出す（話している途中が見える）
  ・覚えた言葉（動画同期・横動画字幕と同じ ~/Movies/動画同期/学習/）の置き換えも効かせる
記録は ~/Movies/ライブ字幕/<日付 時刻> <題名>.txt（リポジトリの外・iCloud の外）。
"""
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import traceback
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "yoko-jimaku"))
import engine  # noqa: E402  覚えた言葉（load_lexicon / apply_lexicon）を借りる

ROOT = Path(os.environ.get("LJ_ROOT") or Path.home() / "Movies" / "ライブ字幕")
ROOT.mkdir(parents=True, exist_ok=True)
LEARN = Path(os.environ.get("LJ_LEARN") or Path.home() / "Movies" / "動画同期" / "学習")
HOSTS = {h.strip() for h in (os.environ.get("LJ_HOSTS") or "").split(",") if h.strip()}
PORT = int(os.environ.get("LJ_PORT") or 8798)
YTDLP = "/opt/homebrew/bin/yt-dlp"
FFMPEG = "/opt/homebrew/bin/ffmpeg"
MODEL = "mlx-community/whisper-large-v3-turbo"

SR = 16000
MIN_SEC = 2.5        # これより短いうちは区切らない
MAX_SEC = 12.0       # これを超えたら静かでなくても区切る
SILENT_SEC = 0.6     # 静かな時間がこれだけ続いたら区切る
PARTIAL_EVERY = 1.5  # 仮の字幕を出す間隔（秒）
QUIET_RMS = 0.006    # これより小さい音は「静か」

# Whisper が無音や音楽で作りがちな決まり文句（中身の無い行）
HALLU = re.compile(r"^(ご視聴ありがとうございました|ご清聴ありがとうございました|チャンネル登録.*|"
                   r"お疲れ様でした|字幕.*|ありがとうございました|\(.*\)|（.*）|[。、！？…\s]*)$")

STATE = {"running": False, "url": "", "title": "", "status": "idle", "error": "",
         "started": 0, "file": ""}
LINES = []          # [{id, t, text}]  確定した行
PARTIAL = {"text": ""}
LOCK = threading.Lock()
SUBS = set()        # SSE の購読者（queue）
WORKER = {"thread": None, "stop": None, "procs": []}


def host_ok(headers):
    host = (headers.get("Host") or "").rsplit(":", 1)[0]
    if host in ("127.0.0.1", "localhost"):
        return True
    return host in HOSTS if HOSTS else host.endswith(".ts.net")


def publish(ev):
    data = json.dumps(ev, ensure_ascii=False)
    for q in list(SUBS):
        try:
            q.put_nowait(data)
        except queue.Full:
            pass


def set_status(status, error=""):
    with LOCK:
        STATE["status"] = status
        STATE["error"] = error
    publish({"type": "state", "state": snapshot_state()})


def snapshot_state():
    with LOCK:
        return dict(STATE)


# ---------- 文字起こし ----------

_whisper_lock = threading.Lock()


def whisper(audio, prompt=None):
    import mlx_whisper
    with _whisper_lock:
        r = mlx_whisper.transcribe(audio, path_or_hf_repo=MODEL, language="ja",
                                   condition_on_previous_text=False,
                                   initial_prompt=prompt, verbose=None)
    text = "".join(s["text"] for s in r.get("segments", [])
                   if s.get("no_speech_prob", 0) < 0.6
                   and s.get("compression_ratio", 0) < 2.4).strip()
    # 同じ言葉のくり返し（Whisper の癖）は1回にまとめる
    text = re.sub(r"(.{2,30}?)\1{2,}", r"\1", text)
    # 音の長さに対して字が多すぎる＝くり返しの残り。秒あたり12字まで
    limit = int(len(audio) / SR * 12) + 10
    if len(text) > limit:
        text = text[:limit].rstrip() + "…"
    if HALLU.match(text):
        return ""
    return text


def fix_words(text, lex):
    if not text or not lex:
        return text
    caps = [{"text": text}]
    try:
        engine.apply_lexicon(caps, lex)
    except Exception:
        pass
    return caps[0]["text"]


def chrome_url():
    """Chrome の前のウィンドウで開いているタブの URL（YouTube のときだけ）。"""
    try:
        r = subprocess.run(
            ["osascript", "-e",
             'tell application "Google Chrome" to get URL of active tab of front window'],
            capture_output=True, text=True, timeout=10)
        out = r.stdout.strip()
        if r.returncode:
            print("chrome_url:", r.stderr.strip(), flush=True)
    except Exception as e:
        print("chrome_url:", e, flush=True)
        return ""
    return out if re.match(r"https://(www\.|m\.)?youtube\.com/(watch|live)", out) or \
        out.startswith("https://youtu.be/") else ""


def get_title(url):
    try:
        out = subprocess.run([YTDLP, "--no-warnings", "--skip-download", "--print", "title", url],
                             capture_output=True, text=True, timeout=30).stdout.strip()
        return out.splitlines()[0] if out else ""
    except Exception:
        return ""


def safe_name(s):
    s = re.sub(r'[\\/:*?"<>|\n\r\t]', " ", s).strip()
    return s[:60] or "配信"


def run(url, stop):
    lex = {}
    try:
        lex = engine.load_lexicon(LEARN)
    except Exception:
        pass
    # 用語の先渡し（initial_prompt）は短い区切りだとくり返しを起こしやすいので使わない。
    # 覚えた言葉は置き換えのほうだけ効かせる
    prompt = None
    title = get_title(url)
    stamp = datetime.now().strftime("%Y-%m-%d %H%M")
    # 生配信の題名は末尾に開始日時が付く（「… 2026-10-22 21:25」）。ファイル名では重ねない
    short = re.sub(r"\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}$", "", title)
    path = ROOT / f"{stamp} {safe_name(short)}.txt"
    with LOCK:
        STATE.update(title=title, file=path.name)
    set_status("connecting")

    # 音だけを一番軽い形で取る。生配信は今の位置から始まる
    yt = subprocess.Popen([YTDLP, "--no-warnings", "-q", "-f", "bestaudio/worst", "-o", "-", url],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    ff = subprocess.Popen([FFMPEG, "-v", "error", "-i", "pipe:0", "-vn", "-ac", "1", "-ar", str(SR),
                           "-f", "s16le", "pipe:1"],
                          stdin=yt.stdout, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    yt.stdout.close()
    WORKER["procs"] = [yt, ff]

    buf = np.zeros(0, dtype=np.float32)
    quiet = 0.0
    last_partial = time.time()
    got_audio = False
    step = int(SR * 0.1) * 2   # 0.1秒ずつ読む（16bit）
    with path.open("a", encoding="utf-8") as log:
        if title:
            log.write(f"# {title}\n# {url}\n\n")
        while not stop.is_set():
            raw = ff.stdout.read(step)
            if not raw:
                break
            if not got_audio:
                got_audio = True
                set_status("listening")
            x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
            buf = np.concatenate([buf, x])
            rms = float(np.sqrt(np.mean(x * x))) if len(x) else 0.0
            quiet = quiet + len(x) / SR if rms < QUIET_RMS else 0.0
            sec = len(buf) / SR

            cut = sec >= MAX_SEC or (sec >= MIN_SEC and quiet >= SILENT_SEC)
            if cut:
                loud = float(np.sqrt(np.mean(buf * buf)))
                text = fix_words(whisper(buf, prompt), lex) if loud >= QUIET_RMS else ""
                buf = np.zeros(0, dtype=np.float32)
                quiet = 0.0
                PARTIAL["text"] = ""
                if text:
                    with LOCK:
                        line = {"id": len(LINES) + 1, "t": time.time(), "text": text}
                        LINES.append(line)
                    log.write(f"[{datetime.now():%H:%M:%S}] {text}\n")
                    log.flush()
                    publish({"type": "line", "line": line})
                else:
                    publish({"type": "partial", "text": ""})
                last_partial = time.time()
            elif sec >= 1.0 and time.time() - last_partial >= PARTIAL_EVERY and quiet < SILENT_SEC:
                last_partial = time.time()
                text = fix_words(whisper(buf, prompt), lex)
                if text != PARTIAL["text"]:
                    PARTIAL["text"] = text
                    publish({"type": "partial", "text": text})
            elif sec < MIN_SEC and quiet >= SILENT_SEC * 3:
                # 黙っている間は音をためない（話し出しの頭だけ少し残す）
                buf = buf[-int(SR * 0.3):]

    err = ""
    if not stop.is_set():
        try:
            err = (yt.stderr.read() or b"").decode("utf-8", "replace").strip().splitlines()
            err = err[-1] if err else ""
        except Exception:
            err = ""
    for p in (yt, ff):
        try:
            p.kill()
        except Exception:
            pass
    WORKER["procs"] = []
    with LOCK:
        STATE["running"] = False
    if stop.is_set():
        set_status("stopped")
    elif not got_audio:
        set_status("error", err or "配信の音を取れませんでした")
    else:
        set_status("ended", err)


def start(url):
    stop_worker()
    with LOCK:
        LINES.clear()
        STATE.update(running=True, url=url, title="", error="", started=time.time(), file="")
    PARTIAL["text"] = ""
    publish({"type": "reset"})
    stop = threading.Event()

    def guarded():
        try:
            run(url, stop)
        except Exception as e:
            traceback.print_exc()
            with LOCK:
                STATE["running"] = False
            set_status("error", str(e))

    t = threading.Thread(target=guarded, daemon=True)
    WORKER.update(thread=t, stop=stop)
    t.start()


def stop_worker():
    if WORKER["stop"]:
        WORKER["stop"].set()
    for p in WORKER["procs"]:
        try:
            p.kill()
        except Exception:
            pass
    t = WORKER["thread"]
    if t and t.is_alive():
        t.join(timeout=20)


def valid_url(u):
    try:
        p = urlparse(u)
    except Exception:
        return False
    return p.scheme == "https" and (p.hostname or "").endswith(("youtube.com", "youtu.be"))


# ---------- HTTP ----------

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False)
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not host_ok(self.headers):
            return self.send(403, {"error": "host"})
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            return self.send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/apple-touch-icon.png" and (HERE / "apple-touch-icon.png").exists():
            return self.send(200, (HERE / "apple-touch-icon.png").read_bytes(), "image/png")
        if path == "/api/state":
            with LOCK:
                lines = list(LINES)
            return self.send(200, {"state": snapshot_state(), "lines": lines,
                                   "partial": PARTIAL["text"]})
        if path == "/api/chrome":
            return self.send(200, {"url": chrome_url()})
        if path == "/api/text":
            with LOCK:
                lines = list(LINES)
                st = dict(STATE)
            head = (f"{st['title']}\n{st['url']}\n\n" if st["title"] else "")
            body = head + "\n".join(
                f"[{datetime.fromtimestamp(l['t']):%H:%M:%S}] {l['text']}" for l in lines) + "\n"
            name = (st["file"] or "ライブ字幕.txt")
            from urllib.parse import quote
            return self.send(200, body, "text/plain; charset=utf-8",
                             {"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}"})
        if path == "/api/events":
            q = queue.Queue(maxsize=500)
            SUBS.add(q)
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Accel-Buffering", "no")
                self.end_headers()
                self.wfile.write(b": hi\n\n")
                self.wfile.flush()
                while True:
                    try:
                        data = q.get(timeout=15)
                        self.wfile.write(f"data: {data}\n\n".encode("utf-8"))
                    except queue.Empty:
                        self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                SUBS.discard(q)
            return
        return self.send(404, {"error": "not found"})

    def do_POST(self):
        if not host_ok(self.headers):
            return self.send(403, {"error": "host"})
        path = urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(min(n, 10000)) or b"{}")
        except Exception:
            data = {}
        if path == "/api/start":
            url = (data.get("url") or "").strip()
            if not valid_url(url):
                return self.send(400, {"error": "YouTube の URL を入れてください"})
            threading.Thread(target=start, args=(url,), daemon=True).start()
            return self.send(200, {"ok": True})
        if path == "/api/stop":
            threading.Thread(target=stop_worker, daemon=True).start()
            return self.send(200, {"ok": True})
        return self.send(404, {"error": "not found"})


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    srv.daemon_threads = True
    print(f"ライブ字幕 http://127.0.0.1:{PORT}", flush=True)
    srv.serve_forever()
