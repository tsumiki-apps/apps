# -*- coding: utf-8 -*-
"""動画同期の中身：調べる・同期・文字起こし・字幕画像・書き出し・写真へ。

全部この Mac の中で動く（ffmpeg と mlx-whisper・どちらも無料）。
A＝人を撮った動画（音は常にこちら）／B＝iPhone の画面録画（外の音つき）。
offset＝「A の何秒目で B が始まったか」（マイナスなら B のほうが先に始まっている）。
"""
import json
import os
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.signal import correlate

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
FONT = next((p for p in (
    os.path.expanduser("~/Library/Fonts/ZenMaruGothic-Bold.ttf"),
    "/Library/Fonts/ZenMaruGothic-Bold.ttf",
    "/System/Library/Fonts/ヒラギノ丸ゴ ProN W4.ttc",
) if os.path.exists(p)))
WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"

# 書き出しの寸法（1080×1920・縦）
W, H = 1080, 1920
TITLE_H = 200                       # 上の帯
MAIN = (72, TITLE_H, 936, 1664)     # 人の動画の枠 x, y, w, h（9:16 ならそのまま収まる）
PIP_W, PIP_H, PIP_M, PIP_R, PIP_B = 300, 650, 28, 36, 8   # 小窓の幅・高さ・余白・角丸・フチ
CAP_FONT, CAP_LINE = 58, 15         # 字幕の字の大きさ・1行の字数
SR = 8000                           # 同期に使う音の標本化周波数


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout)[-1500:])
    return r.stdout


def probe(path):
    """長さ・縦横（回転を反映）・HLG かどうか。"""
    d = json.loads(run([FFPROBE, "-v", "error", "-print_format", "json",
                        "-show_streams", "-show_format", str(path)]))
    v = next((s for s in d["streams"] if s["codec_type"] == "video"), None)
    a = next((s for s in d["streams"] if s["codec_type"] == "audio"), None)
    if not v:
        raise RuntimeError("映像が入っていません")
    w, h = v["width"], v["height"]
    rot = 0
    for sd in v.get("side_data_list", []):
        if "rotation" in sd:
            rot = int(sd["rotation"])
    if abs(rot) % 180 == 90:
        w, h = h, w
    def st(x):
        try:
            return float(x.get("start_time") or 0)
        except (TypeError, ValueError):
            return 0.0
    vdur = float(v.get("duration") or d["format"]["duration"])
    fst = st(d["format"])
    return {
        "dur": float(d["format"]["duration"]),
        "vdur": vdur,
        # 音が映像より遅れて始まる分（音の配列の0秒＝映像のこの秒）
        "astart": round(st(a) - st(v), 4) if a else 0.0,
        # ffmpeg はファイル全体の始まり（音と映像の早いほう）を0秒に置く。そこから映像・音が何秒あとか
        "vlead": round(st(v) - fst, 4),
        "alead": round(st(a) - fst, 4) if a else 0.0,
        "w": w, "h": h,
        "hlg": v.get("color_transfer") in ("arib-std-b67", "smpte2084"),
        "audio": a is not None,
    }


def hdr_filter(info):
    """iPhone の HDR（HLG）を普通の色へ。HLG は SDR でもそれなりに見える作りなので、
    色域だけ BT.2020→BT.709 に寄せる（無料の ffmpeg に zscale が無いための近似）。"""
    if not info.get("hlg"):
        return ""
    return ("colorspace=all=bt709:iprimaries=bt2020:itrc=bt2020-10:ispace=bt2020ncl"
            ":irange=tv:range=tv:format=yuv420p,")


def make_proxy(src, dst, info):
    """スマホで確認する用の軽い動画（高さ 640・H.264）。"""
    vf = "scale=-2:640," + hdr_filter(info) + "format=yuv420p"
    run([FFMPEG, "-y", "-v", "error", "-i", str(src), "-vf", vf,
         "-c:v", "h264_videotoolbox", "-b:v", "1500k", "-c:a", "aac", "-b:a", "96k",
         "-movflags", "+faststart", str(dst)])


def load_audio(src, sr=SR):
    raw = subprocess.run([FFMPEG, "-v", "error", "-i", str(src), "-vn", "-ac", "1",
                          "-ar", str(sr), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def _envelope(x, sr, hop):
    """声の出だし（音の立ち上がり）の並び。マイクが違っても形がそろう。"""
    x = x - np.mean(x)
    x = np.diff(x, prepend=0)                     # 低い唸りを弱める
    n = len(x) // hop
    e = np.sqrt(np.mean(x[: n * hop].reshape(n, hop) ** 2, axis=1) + 1e-12)
    e = np.log(e)
    d = np.maximum(np.diff(e, prepend=e[0]), 0)  # 立ち上がりだけ
    return (d - d.mean()) / (d.std() + 1e-9)


def find_offset(a_path, b_path, a_start=0.0, b_start=0.0):
    """音を照らし合わせて offset（秒）と確からしさ（0〜1）を返す。
    粗く（100分の1秒刻み）合わせてから、元の波形で ±60ms を細かく詰める。"""
    a, b = load_audio(a_path), load_audio(b_path)
    if len(a) < SR or len(b) < SR:
        raise RuntimeError("音が短すぎます")
    hop = SR // 100
    ea, eb = _envelope(a, SR, hop), _envelope(b, SR, hop)
    c = correlate(ea, eb, mode="full", method="fft")
    lags = np.arange(-len(eb) + 1, len(ea))
    i = int(np.argmax(c))
    coarse = lags[i] * hop / SR
    # 確からしさ：1番の山と、そこから1秒以上離れた2番の山の差
    far = np.abs(lags - lags[i]) > 100
    second = c[far].max() if far.any() else 0
    conf = float(np.clip((c[i] - second) / (abs(c[i]) + 1e-9) * 2.5, 0, 1))

    # 細かく：元の波形を ±60ms の範囲で照らす
    lag0 = int(round(coarse * SR))
    win = int(0.06 * SR)
    best, best_v = lag0, -np.inf
    a0 = a - a.mean()
    b0 = b - b.mean()
    for lag in range(lag0 - win, lag0 + win + 1, 2):
        if lag >= 0:
            x, y = a0[lag:], b0
        else:
            x, y = a0, b0[-lag:]
        n = min(len(x), len(y), SR * 60)          # 重なりの最初の60秒で十分
        if n < SR:
            continue
        # 片方のマイクの極性が逆でも合うよう絶対値で見る
        v = abs(float(np.dot(x[:n], y[:n]) / (np.linalg.norm(x[:n]) * np.linalg.norm(y[:n]) + 1e-9)))
        if v > best_v:
            best, best_v = lag, v
    # 細かい段の山が低い（残響などで波形が似ていない）ときは粗い値を信じる
    if best_v < 0.15:
        best = lag0
    # 音の配列の時刻 → 映像の時刻へ（音が遅れて始まる動画のずれを足し引き）
    return round(best / SR + a_start - b_start, 3), round(conf, 2)


# ---------- 文字起こし ----------

def transcribe(a_path, wav_path, prompt=None):
    """A の音を文字にする。返り値：[{start,end,text}]（字幕1枚ずつ）
    prompt＝覚えた用語（出てくる言葉を先に教えると聞き取りが正しくなる）"""
    run([FFMPEG, "-y", "-v", "error", "-i", str(a_path), "-vn", "-ac", "1", "-ar", "16000",
         str(wav_path)])
    import mlx_whisper
    r = mlx_whisper.transcribe(str(wav_path), path_or_hf_repo=WHISPER_MODEL,
                               language="ja", word_timestamps=True,
                               condition_on_previous_text=False,
                               initial_prompt=prompt)
    return split_captions(r["segments"])


def split_captions(segments, max_chars=CAP_LINE * 2):
    """長い区切りを、言葉の時刻を使って2行以内に割る。"""
    out = []
    for seg in segments:
        words = seg.get("words") or [{"word": seg["text"], "start": seg["start"], "end": seg["end"]}]
        buf, st = "", None
        for w in words:
            t = w["word"].strip()
            if not t:
                continue
            if st is None:
                st = w["start"]
            buf += t
            end = w["end"]
            cut = len(buf) >= max_chars or (len(buf) >= CAP_LINE and t[-1] in "。、！？!?")
            if cut:
                out.append({"start": st, "end": end, "text": buf})
                buf, st = "", None
        if buf:
            out.append({"start": st, "end": seg["end"], "text": buf})
    for c in out:
        c["text"] = c["text"].strip().rstrip("。")
        c["start"], c["end"] = round(float(c["start"]), 2), round(float(c["end"]), 2)
    # 次の字幕と重ならず、短すぎないように
    for i, c in enumerate(out):
        nxt = out[i + 1]["start"] if i + 1 < len(out) else c["end"] + 1
        c["end"] = round(min(max(c["end"], c["start"] + 0.8), nxt), 2)
    return [c for c in out if c["text"]]


# ---------- 画像（タイトル・字幕・小窓のフチ） ----------

def _font(size):
    return ImageFont.truetype(FONT, size)


INK = (29, 26, 21)
PAPER = (255, 254, 251)


def _fit(draw, text, size, maxw):
    while size > 24 and draw.textlength(text, font=_font(size)) > maxw:
        size -= 2
    return _font(size)


def make_background(title, path):
    """黒い地＋上の帯のタイトル。"""
    im = Image.new("RGB", (W, H), (12, 11, 9))
    d = ImageDraw.Draw(im)
    f = _fit(d, title, 64, W - 120)
    d.text((W // 2, TITLE_H // 2 + 4), title, font=f, fill=PAPER, anchor="mm")
    im.save(path)


def pip_rect():
    mx, my, mw, mh = MAIN
    x = mx + mw - PIP_M - PIP_W
    y = my + mh - PIP_M - PIP_H
    return x, y


def make_pip_assets(plate_path, mask_path):
    """小窓のフチ（黒い角丸）と、映像を角丸に切る型。"""
    plate = Image.new("RGBA", (PIP_W + PIP_B * 2, PIP_H + PIP_B * 2), (0, 0, 0, 0))
    ImageDraw.Draw(plate).rounded_rectangle(
        [0, 0, plate.width - 1, plate.height - 1], radius=PIP_R + PIP_B, fill=(12, 11, 9, 255))
    plate.save(plate_path)
    mask = Image.new("L", (PIP_W, PIP_H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, PIP_W - 1, PIP_H - 1], radius=PIP_R, fill=255)
    mask.convert("RGB").save(mask_path)


def _kind(ch):
    o = ord(ch)
    if 0x3041 <= o <= 0x309F:
        return "h"          # ひらがな
    if 0x30A0 <= o <= 0x30FF:
        return "k"          # カタカナ・ー
    if 0x4E00 <= o <= 0x9FFF:
        return "c"          # 漢字
    return "o"


def wrap(text, n=CAP_LINE):
    """2行に。言葉の途中で切らないよう、句読点のあと・ひらがなから漢字やカタカナへ
    変わるところ（「新しい｜スケジュール帳」）を候補にし、真ん中に近い所で折る。"""
    text = " ".join(text.split())   # 改行は空白に（PIL は改行を測れない）
    if len(text) <= n:
        return [text]
    mid = len(text) // 2
    cands = []
    for i in range(1, len(text)):
        a, b = text[i - 1], text[i]
        if a in "、。 　！？":
            cands.append((i, 0))
        elif _kind(a) == "h" and _kind(b) in "kco":
            cands.append((i, 1))
    ok = [c for c in cands if max(c[0], len(text) - c[0]) <= n + 3]
    if ok:
        cut = min(ok, key=lambda c: (abs(c[0] - mid) + c[1] * 2))[0]
    else:
        cut = mid
    return [text[:cut].strip(), text[cut:].strip()]


def caption_image(text, path):
    """映像に重ねる白い字＋墨のフチ（1080×1920 の透明画像）。小窓の上に置く。"""
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    lines = wrap(text)
    mx, my, mw, mh = MAIN
    _, py = pip_rect()
    bottom = py - 36
    lh = int(CAP_FONT * 1.32)
    for k, line in enumerate(lines):
        f = _fit(d, line, CAP_FONT, mw - 60)
        y = bottom - (len(lines) - k) * lh + lh // 2
        d.text((mx + mw // 2, y), line, font=f, fill=PAPER, anchor="mm",
               stroke_width=7, stroke_fill=INK)
    im.save(path)


def build_caption_track(caps, dur, folder):
    """字幕の画像を時刻どおりに並べた1本（concat の台本）を作る。"""
    folder = Path(folder)
    folder.mkdir(exist_ok=True)
    blank = folder / "blank.png"
    Image.new("RGBA", (W, H), (0, 0, 0, 0)).save(blank)
    lines, t = ["ffconcat version 1.0"], 0.0
    for i, c in enumerate(sorted(caps, key=lambda c: c["start"])):
        s, e = max(c["start"], t), min(c["end"], dur)
        if e - s < 0.05:
            continue
        if s - t > 0.01:
            lines += [f"file '{blank}'", f"duration {s - t:.3f}"]
        p = folder / f"c{i:04d}.png"
        caption_image(c["text"], p)
        lines += [f"file '{p}'", f"duration {e - s:.3f}"]
        t = e
    lines += [f"file '{blank}'", f"duration {max(dur - t, 0.1):.3f}", f"file '{blank}'"]
    txt = folder / "track.txt"
    txt.write_text("\n".join(lines) + "\n")
    return txt


# ---------- 書き出し ----------

def render(job_dir, a_path, b_path, a_info, b_info, offset, title, caps, out_path, progress=None):
    job_dir = Path(job_dir)
    bg, plate, mask = job_dir / "bg.png", job_dir / "plate.png", job_dir / "mask.png"
    make_background(title, bg)
    make_pip_assets(plate, mask)
    dur = a_info["dur"]
    # 字幕の時刻は A の音の頭が0秒（文字起こしの都合）。書き出しの時間軸へ直す
    al = a_info.get("alead", 0.0)
    track = build_caption_track([{**c, "start": c["start"] + al, "end": c["end"] + al} for c in caps],
                                dur, job_dir / "caps")

    mx, my, mw, mh = MAIN
    px, py = pip_rect()
    # 時刻の基準：offset は「A の映像の何秒目で B の映像が始まるか」。
    # 書き出しの時間軸は A のファイルの始まりが0秒なので、A の映像は vlead 秒あとに始まる。
    # B もファイルの始まりが0秒として読まれるので、B の映像の頭（vlead）を差し引いてずらす。
    da, dv = a_info.get("vlead", 0.0), b_info.get("vlead", 0.0)
    b_start = offset + da
    b_end = b_start + b_info.get("vdur", b_info["dur"])
    show = f"between(t,{max(b_start, 0):.3f},{b_end:.3f})"
    shift = offset + da - dv
    if shift >= 0:
        b_in = ["-itsoffset", f"{shift:.3f}", "-i", str(b_path)]
    else:
        b_in = ["-ss", f"{-shift:.3f}", "-i", str(b_path)]

    fc = (
        f"[1:v]fps=30,scale={mw}:{mh}:force_original_aspect_ratio=increase,"
        f"crop={mw}:{mh},{hdr_filter(a_info)}setsar=1[main];"
        f"[2:v]fps=30,scale={PIP_W}:{PIP_H}:force_original_aspect_ratio=increase,"
        f"crop={PIP_W}:{PIP_H},{hdr_filter(b_info)}setsar=1,format=yuva420p[pv];"
        f"[4:v]format=gray,scale={PIP_W}:{PIP_H}[pm];"
        f"[pv][pm]alphamerge[pip];"
        f"[0:v][main]overlay={mx}:{my}:shortest=1[v1];"
        f"[v1][3:v]overlay={px - PIP_B}:{py - PIP_B}:enable='{show}'[v2];"
        f"[v2][pip]overlay={px}:{py}:eof_action=pass:enable='{show}'[v3];"
        f"[5:v]format=rgba[cap];"
        f"[v3][cap]overlay=0:0:eof_action=pass,format=yuv420p[out]"
    )
    cmd = [FFMPEG, "-y", "-v", "error", "-progress", "pipe:1", "-nostats",
           "-loop", "1", "-framerate", "30", "-i", str(bg),
           "-i", str(a_path),
           *b_in,
           "-loop", "1", "-i", str(plate),
           "-loop", "1", "-i", str(mask),
           "-f", "concat", "-safe", "0", "-i", str(track),
           "-filter_complex", fc,
           "-map", "[out]", "-map", "1:a?",
           "-t", f"{dur:.3f}",
           "-c:v", "h264_videotoolbox", "-b:v", "10M", "-profile:v", "high",
           "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
           "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(out_path)]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    errbuf = []
    import threading
    th = threading.Thread(target=lambda: errbuf.append(p.stderr.read()), daemon=True)
    th.start()
    for line in p.stdout:
        if line.startswith("out_time_us=") and progress:
            try:
                progress(min(int(line.split("=")[1]) / 1e6 / dur, 1.0))
            except ValueError:
                pass
    rc = p.wait()
    th.join(5)
    if rc != 0:
        raise RuntimeError("".join(errbuf)[-1500:].strip() or f"ffmpeg が止まりました（{rc}）")


def save_to_photos(path):
    """Mac の写真アプリへ取り込む（iCloud 写真なら iPhone にも届く）。"""
    script = ('tell application "Photos"\n'
              f'  import {{POSIX file "{path}"}} skip check duplicates true\n'
              'end tell')
    run(["osascript", "-e", script], timeout=600)


# ---------- 直した字幕から学ぶ ----------
# 修正ログ（jsonl）と、そこから作る「覚えた言葉」（置き換え表＋Whisper に渡す用語）。
# 全部この Mac の中。提出の操作は要らない（書き出すときに自動で記録）。

import difflib
import time as _time


def diff_pairs(before, after):
    """1枚の字幕で「どこをどう直したか」を (前, 後) の組で返す。"""
    sm = difflib.SequenceMatcher(None, before, after, autojunk=False)
    pairs = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op != "replace":
            continue
        core = i2 - i1   # 直された元の字数（前後の字を足す前）。1字なら誤爆しやすい
        # 1字だけの直しは前後の字を足して、別の場所で誤爆しにくくする
        if i2 - i1 == 1 and j2 - j1 == 1:
            if i1 > 0 and j1 > 0 and before[i1 - 1] == after[j1 - 1]:
                i1, j1 = i1 - 1, j1 - 1
            if i2 < len(before) and j2 < len(after) and before[i2] == after[j2]:
                i2, j2 = i2 + 1, j2 + 1
        a, b = before[i1:i2], after[j1:j2]
        if 1 <= len(a) <= 20 and 1 <= len(b) <= 20:
            pairs.append((a, b, core))
    return pairs


def log_corrections(learn_dir, job_id, shown, edited):
    """表示した字幕と直した字幕を比べてログへ。返り値＝記録した件数。"""
    learn_dir = Path(learn_dir)
    learn_dir.mkdir(parents=True, exist_ok=True)
    by_start = {round(c["start"], 2): c["text"] for c in edited}
    rows = []
    for c in shown:
        new = by_start.get(round(c["start"], 2))
        if new is None or new == c["text"]:
            continue
        rows.append({"t": _time.strftime("%Y-%m-%d %H:%M"), "job": job_id,
                     "before": c["text"], "after": new, "pairs": diff_pairs(c["text"], new)})
    if rows:
        with open(learn_dir / "修正ログ.jsonl", "a") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        rebuild_lexicon(learn_dir)
    return len(rows)


def rebuild_lexicon(learn_dir):
    """ログから置き換え表を作り直す。消した物（removed）は戻さない。"""
    learn_dir = Path(learn_dir)
    lex_path = learn_dir / "覚えた言葉.json"
    lex = json.loads(lex_path.read_text()) if lex_path.exists() else {"pairs": [], "removed": []}
    removed = {tuple(x) for x in lex.get("removed", [])}
    count = {}
    log = learn_dir / "修正ログ.jsonl"
    if log.exists():
        for line in log.read_text().splitlines():
            for pr in json.loads(line).get("pairs", []):
                a, b = pr[0], pr[1]
                core = pr[2] if len(pr) > 2 else len(a)
                n, c0 = count.get((a, b), (0, core))
                count[(a, b)] = (n + 1, min(c0, core))
    # 逆向きの組（A→B と B→A）がある＝本人が戻した。どちらも使わない
    pairs = [{"from": a, "to": b, "n": n, "core": c} for (a, b), (n, c) in count.items()
             if (a, b) not in removed and (b, a) not in count]
    pairs.sort(key=lambda p: -p["n"])
    lex = {"pairs": pairs, "removed": [list(x) for x in removed]}
    lex_path.write_text(json.dumps(lex, ensure_ascii=False, indent=1))
    return lex


def load_lexicon(learn_dir):
    p = Path(learn_dir) / "覚えた言葉.json"
    return json.loads(p.read_text()) if p.exists() else {"pairs": [], "removed": []}


def remove_pair(learn_dir, a, b):
    lex = load_lexicon(learn_dir)
    lex["removed"] = [x for x in lex.get("removed", []) if x != [a, b]] + [[a, b]]
    Path(learn_dir, "覚えた言葉.json").write_text(json.dumps(lex, ensure_ascii=False, indent=1))
    return rebuild_lexicon(learn_dir)


def apply_lexicon(caps, lex):
    """覚えた置き換えを当てる（元の文に1回だけ・長い物から。置き換えた先をもう一度置き換えない）。
    置き換える元が1字（す→した など）は使わない。元の直しが1字（ちは→ちわ）なら2回以上直したものだけ。"""
    import re
    rules = {p["from"]: p["to"] for p in lex.get("pairs", [])
             if len(p["from"]) >= 2 and (p.get("core", 1) >= 2 or p["n"] >= 2)}
    if not rules:
        return caps
    pat = re.compile("|".join(re.escape(k) for k in sorted(rules, key=len, reverse=True)))
    for c in caps:
        c["text"] = pat.sub(lambda m: rules[m.group(0)], c["text"])
    return caps


def whisper_prompt(lex, limit=40):
    """直した後の言葉を「出てくる用語」として Whisper に先に渡す。
    ※ condition_on_previous_text=False なので効くのは最初の約30秒だけ。主な効き目は置き換えのほう。"""
    words = []
    for p in lex.get("pairs", []):
        w = p["to"].strip("、。 　")
        # 前後の字を足しただけの切れ端（「ちわ」など）は渡さない。2字以上を直した言葉だけ
        if min(p.get("core", 1), len(p["from"])) >= 2 and len(w) >= 2 and w not in words:
            words.append(w)
    return ("用語：" + "、".join(words[:limit]) + "。") if words else None
