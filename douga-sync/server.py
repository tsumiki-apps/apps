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
import thumbnail

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
    for f in (a, b):   # 空間オーディオ（読めない音）が1本目に入った iPhone の動画を、読める音だけに
        engine.drop_unreadable_audio(f)
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
    update(jid, captions=caps, captions_shown=json.loads(json.dumps(caps)), review=[], review_error=None, en={})
    do_review(jid)
    do_translate(jid, caps, load(jid)["title"])   # 確認の画面で英語も見られるように先に訳す
    update(jid, step=5)


def do_review(jid):
    """字幕の見直し（反証役）。失敗しても字幕の確認には進める（理由だけ残す）。"""
    update(jid, busy="見直し")
    job = load(jid)
    try:
        sug = engine.review_captions(job.get("captions") or [], job["title"], engine.load_lexicon(LEARN))
        update(jid, review=sug, review_error=None)
    except Exception as e:
        traceback.print_exc()
        update(jid, review=[], review_error=str(e)[:200])


def do_render(jid):
    d = jpath(jid)
    job = load(jid)
    # 英語の字幕：訳が無い字幕があるときだけ Claude に頼む（訳してある字幕・本人が直した英語はそのまま）
    caps = job.get("captions") or []
    en = do_translate(jid, caps, job["title"])
    update(jid, busy="書き出し")
    job["captions"] = [{**c, "en": en.get(c["text"]) or None} for c in caps]
    tmp = d / "本編.tmp.mp4"   # 書き終わってから入れ替える（途中で止まっても壊れた完成版を出さない）
    try:
        out_dur = engine.render(d, src(jid, "a"), src(jid, "b"), job["a_info"], job["b_info"],
                      job["offset"], job["title"], job["captions"], tmp,
                      progress=lambda f: update(jid, progress=round(f, 3)), ff=job.get("ff"))
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
    tmp.replace(d / "本編.mp4")
    link_body(d)                                  # 冒頭ができるまでは本編をそのまま完成として見せる
    (d / "完成_白.mp4").unlink(missing_ok=True)   # 前の白背景版は古いので消す
    update(jid, rendered=time.time(), step=6, white=None, out_dur=round(out_dur, 3), body_dur=round(out_dur, 3),
           intro=False, intro_error=None)
    try:   # サムネイルと冒頭も一緒に（失敗しても書き出しは成功のまま＝冒頭の無い本編が完成になる）
        update(jid, busy="サムネイル")
        do_thumb(jid)
    except Exception as e:
        traceback.print_exc()
        update(jid, thumb_error=str(e)[:200])
        return
    do_intro(jid)


def link_body(d):
    """完成.mp4 を本編.mp4 と同じ中身に（ハードリンク。冒頭つきの完成は後で別のファイルに書いて入れ替える）。"""
    tmp = d / "完成.link.mp4"
    tmp.unlink(missing_ok=True)
    os.link(d / "本編.mp4", tmp)
    tmp.replace(d / "完成.mp4")


def do_intro(jid):
    """完成＝冒頭に縦長のサムネイルを3.5秒出してから本編へ。失敗したら本編のまま（理由は intro_error に）。
    本編.mp4 が無い前の作業は、冒頭の無い完成.mp4 を本編として使う。"""
    d = jpath(jid)
    job = load(jid)
    body, img = d / "本編.mp4", d / "サムネイル_縦.png"
    if not body.exists():
        if job.get("intro") or not (d / "完成.mp4").exists():
            raise RuntimeError("本編がありません。もう一度書き出してください")
        os.replace(d / "完成.mp4", body)
        link_body(d)
    if not img.exists():
        raise RuntimeError("縦長のサムネイルがありません")
    update(jid, busy="冒頭", progress=0)
    tmp = d / "完成.tmp.mp4"
    try:
        total = engine.add_intro(body, img, tmp, job.get("body_dur") or (None if job.get("intro") else job.get("out_dur")),
                                 progress=lambda f: update(jid, progress=round(f, 3)))
    except Exception as e:
        traceback.print_exc()
        tmp.unlink(missing_ok=True)
        update(jid, intro_error=str(e)[:200])
        return
    tmp.replace(d / "完成.mp4")
    (d / "完成_白.mp4").unlink(missing_ok=True)
    update(jid, rendered=time.time(), white=None, intro=True, intro_error=None, out_dur=round(total, 3),
           body_dur=round(total - engine.INTRO_HOLD, 3))


def do_thumb(jid, reroll=False):
    """サムネイル（1280×720 と縦長の 1080×1920）。使うコマは1回目に選んで覚え、色を変えるときは色だけ引き直す。
    job.json の thumb_image（作業フォルダの画像と切り出し方）があれば、画面録画の代わりにそれを使う。"""
    d = jpath(jid)
    job = load(jid)
    seed = int(job.get("thumb_seed") or 0) + (1 if reroll else 0)
    tmp = d / "サムネイル.tmp.png"
    ti = job.get("thumb_image") or {}
    kw = {}
    if ti.get("file") and (d / ti["file"]).exists():
        kw = dict(image=d / ti["file"], focus=ti.get("focus", 0.5), box=tuple(ti["box"]) if ti.get("box") else None,
                  island=ti.get("island", True), as_card=ti.get("card", False))
    tmpv = d / "サムネイル_縦.tmp.png"
    try:   # 横長（16:9）と縦長（9:16・動画の冒頭に入れる）。色・画面は同じ
        at = thumbnail.make(d, tmp, seed=seed, at=job.get("thumb_at"), **kw)
        thumbnail.make(d, tmpv, seed=seed, at=at if at is not None else job.get("thumb_at"), vertical=True, **kw)
    except Exception:
        tmp.unlink(missing_ok=True)
        tmpv.unlink(missing_ok=True)
        raise
    tmp.replace(d / "サムネイル.png")
    tmpv.replace(d / "サムネイル_縦.png")
    update(jid, thumb=time.time(), thumb_v=True, thumb_seed=seed, thumb_error=None,
           **({"thumb_at": round(at, 2)} if at is not None else {}))


def do_translate(jid, caps, title):
    """足りない英訳だけを足す。返り値＝{日本語: 英語}（""＝口ぐせだけで訳さない字幕）。"""
    job = load(jid)
    en = {k: v for k, v in (job.get("en") or {}).items() if any(c["text"] == k for c in caps)}
    missing = [c for c in caps if c["text"] not in en]
    if not missing:
        update(jid, en=en, en_error=None)
        return en
    update(jid, busy="英訳")
    try:
        new = engine.translate_captions(caps, title)
        en.update({k: v for k, v in new.items() if k not in en})
        lack = sum(1 for c in caps if c["text"] not in en)
        update(jid, en=en, en_error=(f"{lack}件の英訳が足りません" if lack else None))
    except Exception as e:
        traceback.print_exc()
        update(jid, en=en, en_error=str(e)[:200])
    return en


def do_white(jid):
    d = jpath(jid)
    job = load(jid)
    tmp = d / "完成_白.tmp.mp4"
    try:
        engine.make_white(d / "完成.mp4", tmp, job.get("out_dur") or job["a_info"]["dur"],
                          progress=lambda f: update(jid, progress=round(f, 3)))
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
    tmp.replace(d / "完成_白.mp4")
    update(jid, white=time.time())


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

    def send_file(self, path, ctype, download=None):
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
        if download:
            from urllib.parse import quote
            self.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{quote(download)}")
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
            if p in ("/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"):
                return self.send_file(HERE / "apple-touch-icon.png", "image/png")   # ホーム画面のアイコン
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
            m = re.fullmatch(r"/files/([\d-]+)/(proxy_a\.mp4|proxy_b\.mp4|完成\.mp4|完成_白\.mp4|サムネイル\.png|サムネイル_縦\.png)", unquote(p))
            if m:
                name = None
                if "dl=1" in (self.path.split("?", 1) + [""])[1]:
                    # 保存用：タイトルの名前で「ダウンロード」として渡す（iPhone はファイルに入る）
                    name = re.sub(r'[\\/:*?"<>|]', "_", load(m.group(1))["title"]).strip() or "動画"
                    if "白" in m.group(2):
                        name += "_白背景"
                    if m.group(2).endswith(".png"):
                        name += "_サムネイル" + ("_縦" if "縦" in m.group(2) else "") + ".png"
                    else:
                        name += ".mp4"
                png = m.group(2).endswith(".png")
                return self.send_file(jpath(m.group(1)) / m.group(2), "image/png" if png else "video/mp4", download=name)
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
                for old in d.glob(f"元の動画_{k}.*"):   # 前の動画の詰め直し前の控え
                    old.unlink()
                part.rename(d / f"src_{k}.{ext}")
                drop = ["offset", "auto_offset", "confidence", "rendered", "learned", "error", "thumb", "thumb_v", "thumb_at", "intro", "intro_error", "body_dur"]
                if k == "a":   # 字幕は A の音から作るので、B の差し替えでは残す
                    drop += ["captions", "captions_shown", "ff"]
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
                job = update(jid, title=t, **({"rendered": None, "thumb": None} if t != job["title"] else {}))
            elif act == "sync":
                if not (job.get("has_a") and job.get("has_b")):
                    return self.send_json({"error": "動画を2本選んでください"}, 400)
                background(jid, "同期", lambda: do_sync(jid))
            elif act == "confirm":
                # 同期を確定。字幕がまだなら文字起こしへ、あればそのまま確認へ
                off = round(float(body["offset"]), 3)
                stale = {"rendered": None} if off != job.get("offset") else {}
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
                # 見直しの案は、画面で残したもの（まだ選んでいないもの）だけ持ち越す
                keep = body.get("review")
                extra = {"review": keep} if isinstance(keep, list) else {}
                if isinstance(body.get("en"), dict):   # 画面で直した英語も控える
                    extra["en"] = {str(k): " ".join(str(v).split()) for k, v in body["en"].items()
                                   if any(c["text"] == k for c in caps)}
                job = update(jid, captions=caps, captions_shown=caps, learned=n, **extra)
            elif act == "ff":
                # 早送りの区間（字幕と同じ時刻の基準）。変えるたびにすぐ控える
                ff = [{"start": float(r["start"]), "end": float(r["end"]), "speed": int(r.get("speed", 4))}
                      for r in body.get("ff") or []]
                ff = engine.clean_ff(ff, job["a_info"]["dur"])
                stale = {"rendered": None} if ff != (job.get("ff") or []) else {}   # 区間が変われば完成版は古い
                job = update(jid, ff=ff, **stale)
            elif act == "thumb":
                if not job.get("rendered"):
                    return self.send_json({"error": "先に書き出してください"}, 400)
                reroll = bool(body.get("reroll"))
                background(jid, "サムネイル", lambda: (do_thumb(jid, reroll), do_intro(jid)))
            elif act == "white":
                if not job.get("rendered"):
                    return self.send_json({"error": "先に書き出してください"}, 400)
                background(jid, "白背景", lambda: do_white(jid))
            elif act == "review":
                if body.get("captions") is not None:
                    caps = [{"start": float(c["start"]), "end": float(c["end"]),
                             "text": " ".join(str(c["text"]).split())} for c in body["captions"]]
                    update(jid, captions=[c for c in caps if c["text"]])
                if isinstance(body.get("en"), dict):
                    update(jid, en={str(k): " ".join(str(v).split()) for k, v in body["en"].items()})
                background(jid, "見直し", lambda: do_review(jid))
            elif act == "render":
                background(jid, "書き出し", lambda: do_render(jid))
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
