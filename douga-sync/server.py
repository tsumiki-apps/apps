# -*- coding: utf-8 -*-
"""動画同期の小さなサーバー（Mac で動かし、iPhone から開く）。

  .venv/bin/python server.py            → http://127.0.0.1:8790
  iPhone からは Tailscale の https://<Macのtailnet名>:8443

作業の置き場は ~/Movies/動画同期/<番号>/（リポジトリの外・iCloud の外）。
"""
import json
import os
import shutil
import re
import threading
import time
import traceback
import uuid
from urllib.parse import unquote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import engine

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("DSYNC_ROOT") or Path.home() / "Movies" / "動画同期")
ROOT.mkdir(parents=True, exist_ok=True)
LEARN = ROOT / "学習"
# 受け付ける名前。DSYNC_HOSTS（カンマ区切り・LaunchAgent で渡す）に tailnet の名前を入れる。
# リポジトリには名前を書かない。未設定なら *.ts.net を通す。
HOSTS = {h.strip() for h in (os.environ.get("DSYNC_HOSTS") or "").split(",") if h.strip()}
MAX_UPLOAD = 8 * 1024 ** 3   # 1本 8GB まで


def host_ok(headers):
    host = (headers.get("Host") or "").rsplit(":", 1)[0]
    if host in ("127.0.0.1", "localhost"):
        return True
    return host in HOSTS if HOSTS else host.endswith(".ts.net")
PORT = int(os.environ.get("DSYNC_PORT") or 8790)
LOCK = threading.Lock()


def jpath(jid):
    if not re.fullmatch(r"\d{8}-\d{6}", jid or ""):
        raise KeyError(jid)
    return ROOT / jid


def load(jid):
    return json.loads((jpath(jid) / "job.json").read_text())


def save(jid, job):
    p = jpath(jid) / "job.json"
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(job, ensure_ascii=False, indent=1))
    tmp.replace(p)


def update(jid, **kw):
    with LOCK:
        job = load(jid)
        job.update(kw)
        save(jid, job)
        return job


class Busy(Exception):
    pass


def background(jid, name, fn, **kw):
    """重い作業を裏で。状態は job.json の busy / error に書く。
    「作業中か見る→作業中にする」を鍵の中で一度に行う（二度押しで2本走らないように）。"""
    with LOCK:
        job = load(jid)
        if job.get("busy"):
            raise Busy(job["busy"])
        job.update(busy=name, error=None, progress=0, **kw)
        save(jid, job)

    def go():
        try:
            fn()
            update(jid, busy=None, error=None)
        except Exception as e:
            traceback.print_exc()
            update(jid, busy=None, error=f"{name}：{e}")
    threading.Thread(target=go, daemon=True).start()


def src(jid, k):
    d = jpath(jid)
    for f in d.glob(f"src_{k}.*"):
        return f
    raise FileNotFoundError("人の動画" if k == "a" else "画面の動画")


# ---------- 各工程 ----------

def do_sync(jid):
    d = jpath(jid)
    a, b = src(jid, "a"), src(jid, "b")
    ia, ib = engine.probe(a), engine.probe(b)
    if not ia["audio"] or not ib["audio"]:
        raise RuntimeError("どちらかの動画に音が入っていません（画面録画はマイクをオンに）")
    update(jid, a_info=ia, b_info=ib, progress=0.1)
    engine.make_proxy(a, d / "proxy_a.mp4", ia)
    update(jid, progress=0.45)
    engine.make_proxy(b, d / "proxy_b.mp4", ib)
    update(jid, progress=0.8)
    off, conf = engine.find_offset(a, b, ia.get("astart", 0), ib.get("astart", 0))
    update(jid, offset=off, auto_offset=off, confidence=conf, progress=1, step=3)


def do_caption(jid):
    d = jpath(jid)
    lex = engine.load_lexicon(LEARN)
    caps = engine.transcribe(src(jid, "a"), d / "a16k.wav", prompt=engine.whisper_prompt(lex))
    caps = engine.apply_lexicon(caps, lex)
    update(jid, captions=caps, captions_shown=json.loads(json.dumps(caps)), step=5)


def do_render(jid):
    d = jpath(jid)
    job = load(jid)
    tmp = d / "完成.tmp.mp4"   # 書き終わってから入れ替える（途中で止まっても壊れた完成版を出さない）
    try:
        engine.render(d, src(jid, "a"), src(jid, "b"), job["a_info"], job["b_info"],
                      job["offset"], job["title"], job.get("captions") or [], tmp,
                      progress=lambda f: update(jid, progress=round(f, 3)))
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
    tmp.replace(d / "完成.mp4")
    update(jid, rendered=time.time(), step=6, saved=False)


def do_photos(jid):
    engine.save_to_photos(str(jpath(jid) / "完成.mp4"))
    update(jid, saved=True)


# ---------- HTTP ----------

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def allowed(self):
        """書き換える要求は、この画面から来たものだけ受ける。
        独自の見出し X-DSync は他のサイトからは付けられない（付けると事前確認が要り、ここは答えない）。
        Host も 127.0.0.1 か tailnet の名前だけ。"""
        return host_ok(self.headers) and self.headers.get("X-DSync") == "1"

    def log_message(self, fmt, *a):
        pass

    def send_json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def send_file(self, path, ctype):
        size = path.stat().st_size
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            if m and m.group(1):
                start = int(m.group(1))
                end = int(m.group(2)) if m.group(2) else size - 1
            elif m and m.group(2):
                start = max(size - int(m.group(2)), 0)
            end = min(end, size - 1)
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(1 << 20, left))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                left -= len(chunk)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not host_ok(self.headers):
            return self.send_json({"error": "forbidden"}, 403)
        try:
            p = self.path.split("?")[0]
            if p in ("/", "/index.html"):
                return self.send_file(HERE / "index.html", "text/html; charset=utf-8")
            if p == "/api/lexicon":
                return self.send_json(engine.load_lexicon(LEARN))
            if p == "/api/jobs":
                jobs = []
                for d in sorted(ROOT.glob("*/job.json"), reverse=True)[:20]:
                    j = json.loads(d.read_text())
                    jobs.append({"id": j["id"], "title": j["title"], "step": j.get("step", 1)})
                return self.send_json(jobs)
            m = re.fullmatch(r"/api/job/([\d-]+)", p)
            if m:
                return self.send_json(load(m.group(1)))
            m = re.fullmatch(r"/files/([\d-]+)/(proxy_a\.mp4|proxy_b\.mp4|完成\.mp4)", unquote(p))
            if m:
                return self.send_file(jpath(m.group(1)) / m.group(2), "video/mp4")
            self.send_json({"error": "not found"}, 404)
        except (KeyError, FileNotFoundError, StopIteration):
            self.send_json({"error": "not found"}, 404)

    def read_body_to(self, f):
        """本文をファイルへ。長さつき・分割送信（chunked）のどちらも受ける。"""
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return True
                left = size
                while left > 0:
                    chunk = self.rfile.read(min(1 << 20, left))
                    if not chunk:
                        return False
                    f.write(chunk)
                    left -= len(chunk)
                self.rfile.readline()
        left = int(self.headers.get("Content-Length") or -1)
        if left < 0 or left > MAX_UPLOAD:
            return False
        while left > 0:
            chunk = self.rfile.read(min(1 << 20, left))
            if not chunk:
                return False
            f.write(chunk)
            left -= len(chunk)
        return True

    def do_PUT(self):
        """動画の受け取り：本文をそのままファイルへ（multipart を使わない）。
        受け取り切ってから古い物と入れ替える（途中で切れても前の動画は残る）。"""
        if not self.allowed():
            return self.send_json({"error": "forbidden"}, 403)
        m = re.fullmatch(r"/api/job/([\d-]+)/upload/([ab])", self.path.split("?")[0])
        if not m:
            return self.send_json({"error": "not found"}, 404)
        jid, k = m.groups()
        part = None
        try:
            d = jpath(jid)
            if load(jid).get("busy"):
                self.close_connection = True
                return self.send_json({"error": "作業中です。終わってから選び直してください"}, 409)
            ext = (self.headers.get("X-Ext") or "mov").lower()
            ext = ext if re.fullmatch(r"[a-z0-9]{2,4}", ext) else "mov"
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_UPLOAD or (n and shutil.disk_usage(d).free < n * 1.2 + 2 * 1024 ** 3):
                self.close_connection = True
                return self.send_json({"error": "大きすぎるか、Mac の空きが足りません"}, 413)
            part = d / f"recv_{k}.{uuid.uuid4().hex}.part"   # 同時に送っても混ざらないよう毎回別の名前
            with open(part, "wb") as f:
                ok = self.read_body_to(f)
            if not ok:
                part.unlink(missing_ok=True)
                self.close_connection = True
                return self.send_json({"error": "途中で切れました。もう一度選んでください"}, 400)
            with LOCK:
                job = load(jid)
                if job.get("busy"):
                    part.unlink(missing_ok=True)
                    return self.send_json({"error": "作業中です"}, 409)
                for old in d.glob(f"src_{k}.*"):
                    old.unlink()
                part.rename(d / f"src_{k}.{ext}")
                drop = ["offset", "auto_offset", "confidence", "rendered", "saved", "learned", "error"]
                if k == "a":   # 字幕は A の音から作るので、B の差し替えでは残す
                    drop += ["captions", "captions_shown"]
                for key in drop:
                    job.pop(key, None)
                job.update({f"has_{k}": True, "step": 2})
                save(jid, job)
            self.send_json(job)
        except (KeyError, FileNotFoundError):
            self.close_connection = True
            self.send_json({"error": "見つかりません"}, 404)
        except Exception as e:
            traceback.print_exc()
            if part:
                part.unlink(missing_ok=True)
            self.close_connection = True
            try:
                self.send_json({"error": str(e)}, 500)
            except OSError:
                pass

    def do_POST(self):
        p = self.path.split("?")[0]
        if not self.allowed():
            return self.send_json({"error": "forbidden"}, 403)
        try:
            if p == "/api/job":
                title = (self.body_json().get("title") or "").strip()[:40] or "デモ"
                while True:
                    jid = time.strftime("%Y%m%d-%H%M%S")
                    try:
                        jpath(jid).mkdir()
                        break
                    except FileExistsError:
                        time.sleep(1)
                job = {"id": jid, "title": title, "step": 2}
                save(jid, job)
                return self.send_json(job)
            if p == "/api/lexicon/remove":
                b = self.body_json()
                return self.send_json(engine.remove_pair(LEARN, b["from"], b["to"]))
            m = re.fullmatch(r"/api/job/([\d-]+)/(\w+)", p)
            if not m:
                return self.send_json({"error": "not found"}, 404)
            jid, act = m.groups()
            job = load(jid)
            body = self.body_json()
            if job.get("busy"):
                return self.send_json({"error": f"{job['busy']}の最中です"}, 409)
            if act == "title":
                # タイトルが変わったら、前の完成版は古い
                t = (body.get("title") or job["title"]).strip()[:40]
                job = update(jid, title=t, **({"rendered": None, "saved": False} if t != job["title"] else {}))
            elif act == "sync":
                if not (job.get("has_a") and job.get("has_b")):
                    return self.send_json({"error": "動画を2本選んでください"}, 400)
                background(jid, "同期", lambda: do_sync(jid))
            elif act == "confirm":
                # 同期を確定。字幕がまだなら文字起こしへ、あればそのまま確認へ
                off = round(float(body["offset"]), 3)
                stale = {"rendered": None, "saved": False} if off != job.get("offset") else {}
                if job.get("captions"):
                    update(jid, offset=off, step=5, **stale)
                else:
                    background(jid, "文字起こし", lambda: do_caption(jid), offset=off, step=4, **stale)
            elif act == "captions":
                caps = [{"start": float(c["start"]), "end": float(c["end"]),
                         "text": " ".join(str(c["text"]).split())} for c in body["captions"]]
                caps = [c for c in caps if c["text"]]
                n = engine.log_corrections(LEARN, jid, job.get("captions_shown") or [], caps)
                # 次に保存したとき同じ直しを二重に数えないよう、今の字幕を「表示した物」に
                job = update(jid, captions=caps, captions_shown=caps, learned=n)
            elif act == "render":
                background(jid, "書き出し", lambda: do_render(jid), rendered=None, saved=False)
            elif act == "photos":
                background(jid, "写真に保存", lambda: do_photos(jid))
            else:
                return self.send_json({"error": "not found"}, 404)
            self.send_json(load(jid))
        except Busy as e:
            self.send_json({"error": f"{e}の最中です"}, 409)
        except (KeyError, FileNotFoundError, StopIteration) as e:
            self.send_json({"error": f"見つかりません {e}"}, 404)
        except Exception as e:
            traceback.print_exc()
            self.send_json({"error": str(e)}, 500)


if __name__ == "__main__":
    # 前回止まったときに busy のまま残った作業を戻す
    for f in ROOT.glob("*/job.json"):
        j = json.loads(f.read_text())
        if j.get("busy"):
            j["busy"], j["error"] = None, "Mac の再起動などで中断しました。もう一度押してください"
            f.write_text(json.dumps(j, ensure_ascii=False, indent=1))
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"動画同期 http://127.0.0.1:{PORT}", flush=True)
    srv.serve_forever()
