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
# 形：人の動画を画面全体に敷き、タイトルと字幕は白い札にして上に重ねる（本人が選んだ案3）
MAIN = (0, 0, W, H)                 # 人の動画の枠 x, y, w, h
PIP_W, PIP_H, PIP_R, PIP_B = 300, 650, 36, 8   # 小窓（iPhone 縦）の幅・高さ・角丸・フチ
PIP_MAX_W, PIP_MAX_H = 520, 650     # 小窓が取れる最大の幅・高さ（画面録画の比率に合わせてこの中に収める）
PIP_RIGHT, PIP_BOTTOM = 36, 1500    # 小窓の右の余白・下の端（日英の字幕の札の上に置く）
CAP_FONT, CAP_LINE = 54, 16         # 字幕の字の大きさ・1行の字数
EN_FONT = 36                        # 英語の字幕の字の大きさ（日本語の下に小さく）
INK_MID = (91, 85, 74)
CAP_BOTTOM = 70                     # 字幕の札の下の余白
PLATE = (255, 255, 255, 230)        # 札の色（白・少しだけ透ける）
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
    """下地（白）。人の動画が全面に乗るので、映像の外にはみ出したときだけ見える。"""
    Image.new("RGB", (W, H), (255, 255, 255)).save(path)


def _plate_size(d, lines, size, sub=(), padx=44, pady=26):
    lh, slh = int(size * 1.38), int(EN_FONT * 1.36)
    gap = 8 if sub else 0
    return lh * len(lines) + gap + slh * len(sub) + pady * 2


def _plate(d, cx, top, lines, size, padx=44, pady=26, radius=None, sub=()):
    """白い札に墨の字を真ん中そろえで置く（sub＝下に小さく添える英語の行）。返り値＝札の下の端。"""
    lh, slh = int(size * 1.38), int(EN_FONT * 1.36)
    maxw = W - 2 * padx - 80
    fonts = [_fit(d, ln, size, maxw) for ln in lines]
    sfonts = [_fit(d, ln, EN_FONT, maxw) for ln in sub]
    tw = max([d.textlength(ln, font=fn) for ln, fn in zip(lines, fonts)] +
             [d.textlength(ln, font=fn) for ln, fn in zip(sub, sfonts)])
    h = _plate_size(d, lines, size, sub, padx, pady)
    w = int(tw + padx * 2)
    r = radius if radius is not None else min(h // 2, 44)
    d.rounded_rectangle([cx - w // 2, top, cx + w // 2, top + h], radius=r, fill=PLATE)
    for k, (ln, fn) in enumerate(zip(lines, fonts)):
        d.text((cx, top + pady + k * lh + lh // 2), ln, font=fn, fill=INK + (255,), anchor="mm")
    y0 = top + pady + lh * len(lines) + (8 if sub else 0)
    for k, (ln, fn) in enumerate(zip(sub, sfonts)):
        d.text((cx, y0 + k * slh + slh // 2), ln, font=fn, fill=INK_MID + (255,), anchor="mm")
    return top + h


def wrap_en(d, text, maxw=W - 2 * 44 - 80, maxlines=2):
    """英語を単語の切れ目で折る（2行まで。収まらなければ最後の行は _fit が縮める）。"""
    words, lines, cur = text.split(), [], ""
    f = _font(EN_FONT)
    for w in words:
        t = (cur + " " + w).strip()
        if d.textlength(t, font=f) <= maxw or not cur:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    if len(lines) > maxlines:
        lines = lines[:maxlines - 1] + [" ".join(lines[maxlines - 1:])]
    return lines


def make_title(title, path):
    """上のタイトルの札（透明の画像）。"""
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    _plate(ImageDraw.Draw(im), W // 2, 52, [title], 56, padx=52, pady=18)
    im.save(path)


def pip_size(b_info=None):
    """画面録画の縦横比から小窓の大きさを決める（iPhone 縦＝細長い・iPad 縦＝3:4 前後・横向き＝横長）。
    縦長は高さ 650 を基準に、幅が PIP_MAX_W を超えるなら幅で決める。角丸は短い辺に比例。"""
    a = (b_info or {}).get("w", PIP_W) / max((b_info or {}).get("h", PIP_H), 1)
    if a <= 0:
        a = PIP_W / PIP_H
    h = PIP_MAX_H
    w = h * a
    if w > PIP_MAX_W:
        w, h = PIP_MAX_W, PIP_MAX_W / a
    w, h = int(round(w / 2) * 2), int(round(h / 2) * 2)
    r = max(12, round(min(w, h) * 0.12))
    return w, h, r


def pip_rect(size=(PIP_W, PIP_H, PIP_R)):
    w, h, _ = size
    return W - PIP_RIGHT - w, PIP_BOTTOM - h


def make_pip_assets(plate_path, mask_path, size=(PIP_W, PIP_H, PIP_R)):
    """小窓のフチ（黒い角丸）と、映像を角丸に切る型。"""
    pw, ph, pr = size
    plate = Image.new("RGBA", (pw + PIP_B * 2, ph + PIP_B * 2), (0, 0, 0, 0))
    ImageDraw.Draw(plate).rounded_rectangle(
        [0, 0, plate.width - 1, plate.height - 1], radius=pr + PIP_B, fill=(12, 11, 9, 255))
    plate.save(plate_path)
    mask = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, pw - 1, ph - 1], radius=pr, fill=255)
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


def caption_image(text, path, en=None):
    """一番下に重ねる白い札の字幕（1080×1920 の透明画像）。札の下の端を CAP_BOTTOM にそろえる。"""
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    lines = wrap(text)
    sub = wrap_en(d, en) if en else []
    h = _plate_size(d, lines, CAP_FONT, sub)
    _plate(d, W // 2, H - CAP_BOTTOM - h, lines, CAP_FONT, sub=sub)
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
        caption_image(c["text"], p, c.get("en"))
        lines += [f"file '{p}'", f"duration {e - s:.3f}"]
        t = e
    lines += [f"file '{blank}'", f"duration {max(dur - t, 0.1):.3f}", f"file '{blank}'"]
    txt = folder / "track.txt"
    txt.write_text("\n".join(lines) + "\n")
    return txt


# ---------- 書き出し ----------

LOUD_I, LOUD_TP, LOUD_LRA = -16.0, -1.5, 11.0   # 音の大きさの目標（スマホ向けの標準・LUFS）


def measure_loudness(path):
    """人の動画の音の大きさを測る（1回目）。返り値は loudnorm の測定値、測れなければ None。"""
    r = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", str(path), "-vn",
                        "-af", f"loudnorm=I={LOUD_I}:TP={LOUD_TP}:LRA={LOUD_LRA}:print_format=json",
                        "-f", "null", "-"], capture_output=True, text=True)
    t = r.stderr
    try:
        d = json.loads(t[t.rindex("{"):t.rindex("}") + 1])
        if float(d["input_i"]) < -70:      # ほぼ無音（測れない）
            return None
        return d
    except (ValueError, KeyError):
        return None


def loudness_filter(m):
    """2回目：測った値を使い、音色を変えずに全体の音量だけを目標へそろえる（小さければ上げ、大きすぎれば下げる）。"""
    if not m:
        return "anull"
    return (f"loudnorm=I={LOUD_I}:TP={LOUD_TP}:LRA={LOUD_LRA}:linear=true"
            f":measured_I={m['input_i']}:measured_TP={m['input_tp']}:measured_LRA={m['input_lra']}"
            f":measured_thresh={m['input_thresh']}:offset={m['target_offset']},aresample=48000")


def render(job_dir, a_path, b_path, a_info, b_info, offset, title, caps, out_path, progress=None):
    job_dir = Path(job_dir)
    bg, plate, mask = job_dir / "bg.png", job_dir / "plate.png", job_dir / "mask.png"
    ttl = job_dir / "title.png"
    make_background(title, bg)
    make_title(title, ttl)
    psize = pip_size(b_info)
    make_pip_assets(plate, mask, psize)
    PW, PH, _ = psize
    dur = a_info["dur"]
    # 字幕の時刻は A の音の頭が0秒（文字起こしの都合）。書き出しの時間軸へ直す
    al = a_info.get("alead", 0.0)
    track = build_caption_track([{**c, "start": c["start"] + al, "end": c["end"] + al} for c in caps],
                                dur, job_dir / "caps")

    mx, my, mw, mh = MAIN
    px, py = pip_rect(psize)
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
        f"[2:v]fps=30,scale={PW}:{PH}:force_original_aspect_ratio=increase,"
        f"crop={PW}:{PH},{hdr_filter(b_info)}setsar=1,format=yuva420p[pv];"
        f"[4:v]format=gray,scale={PW}:{PH}[pm];"
        f"[pv][pm]alphamerge[pip];"
        f"[0:v][main]overlay={mx}:{my}:shortest=1[v1];"
        f"[v1][3:v]overlay={px - PIP_B}:{py - PIP_B}:enable='{show}'[v2];"
        f"[v2][pip]overlay={px}:{py}:eof_action=pass:enable='{show}'[v3];"
        f"[6:v]format=rgba[ttl];"
        f"[v3][ttl]overlay=0:0[v4];"
        f"[5:v]format=rgba[cap];"
        f"[v4][cap]overlay=0:0:eof_action=pass,format=yuv420p[out];"
        f"[1:a]{loudness_filter(measure_loudness(a_path))}[aout]"
    )
    cmd = [FFMPEG, "-y", "-v", "error", "-progress", "pipe:1", "-nostats",
           "-loop", "1", "-framerate", "30", "-i", str(bg),
           "-i", str(a_path),
           *b_in,
           "-loop", "1", "-i", str(plate),
           "-loop", "1", "-i", str(mask),
           "-f", "concat", "-safe", "0", "-i", str(track),
           "-loop", "1", "-i", str(ttl),
           "-filter_complex", fc,
           "-map", "[out]", "-map", "[aout]",
           "-t", f"{dur:.3f}",
           "-c:v", "h264_videotoolbox", "-b:v", "6M",   # 2分半で約115MB（iPhone に落とすのが軽く）
           "-profile:v", "high",
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


# ---------- 字幕の見直し（反証役） ----------
# 自動の字幕を Claude に読ませ、誤変換・聞き間違い・文として不自然な所だけを直す案を出させる。
# Claude Code の CLI を使う＝本人の Claude のプランの中で動く（追加の料金はかからない・5時間枠を少し使う）。
# 設定・フック・道具は読み込まない（Daily への記録や他の作業を起こさない）。直すかどうかは画面で本人が選ぶ。

CLAUDE = "/opt/homebrew/bin/claude"
REVIEW_PROMPT = """あなたは字幕の校正係です。下はデモ動画（題：{title}）の自動文字起こしの字幕です。
誤変換・聞き間違い・文字の抜け・文として意味が通らない所だけを直してください。
- 話し言葉の言い回し（「〜なんですよ」「そうそう」など）は残す。言い換えや要約はしない
- 製品名・機能名は Apple の正式な表記に（例：iPhone 18 Pro、ポートレートモード、Dynamic Island）
- 直す必要がない字幕は出さない
{glossary}
返事は JSON の配列だけ。各要素は {{"i": 字幕の番号, "after": 直した字幕, "why": 理由を12字以内}}。

字幕：
{lines}"""


def review_captions(caps, title, lex=None, timeout=300):
    """返り値：[{"start", "before", "after", "why"}]（直す案があるものだけ）"""
    import re
    words = []
    for p in (lex or {}).get("pairs", []):
        if p["to"] not in words:
            words.append(p["to"])
    glossary = ("- 本人がこれまでに直した言葉：" + "、".join(words[:40])) if words else ""
    lines = "\n".join(f"{i}: {c['text']}" for i, c in enumerate(caps))
    prompt = REVIEW_PROMPT.format(title=title, glossary=glossary, lines=lines)
    work = Path.home() / "Movies" / "動画同期" / ".review"   # CLAUDE.md を拾わない空の場所で動かす
    work.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([CLAUDE, "-p", "--tools", "", "--setting-sources", "", "--no-session-persistence",
                        "--model", "sonnet", "--output-format", "json"],
                       input=prompt, capture_output=True, text=True, timeout=timeout, cwd=work)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout)[-500:] or "Claude が答えませんでした")
    text = json.loads(r.stdout).get("result", "")
    m = re.search(r"\[.*\]", text, re.S)
    if not m:
        return []
    out = []
    for s in json.loads(m.group(0)):
        try:
            i = int(s["i"])
            after = " ".join(str(s["after"]).split())
        except (KeyError, ValueError, TypeError):
            continue
        if 0 <= i < len(caps) and after and after != caps[i]["text"]:
            out.append({"start": caps[i]["start"], "before": caps[i]["text"],
                        "after": after, "why": str(s.get("why", ""))[:20]})
    return out


# ---------- 英語の字幕 ----------
# 書き出す直前に、仕上がった日本語の字幕を Claude で英訳する（直した後の日本語と必ずそろう）。
# 訳は日本語の文をかぎにして job に控え、変わった字幕だけ訳し直す。

TRANSLATE_PROMPT = """You translate Japanese subtitles of an Apple Store product demo video (title: {title}) into English.
- Natural, concise spoken English for on-screen subtitles. Keep each one short (ideally under 60 characters)
- Use Apple's official English names for products and features (e.g. iPhone 18 Pro, Portrait mode, Dynamic Island, Camera Control)
- Drop pure fillers ("はい", "そうそう", "えー") but keep the meaning; never add information
- Use the surrounding lines only as context; translate every numbered line
Reply with a JSON array only: [{{"i": number, "en": "English"}}].

Lines:
{lines}"""


def translate_captions(caps, title, timeout=300):
    """返り値：{日本語: 英語}"""
    import re
    if not caps:
        return {}
    lines = "\n".join(f"{i}: {c['text']}" for i, c in enumerate(caps))
    work = Path.home() / "Movies" / "動画同期" / ".review"
    work.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([CLAUDE, "-p", "--tools", "", "--setting-sources", "", "--no-session-persistence",
                        "--model", "sonnet", "--output-format", "json"],
                       input=TRANSLATE_PROMPT.format(title=title, lines=lines),
                       capture_output=True, text=True, timeout=timeout, cwd=work)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout)[-500:] or "Claude が答えませんでした")
    text = json.loads(r.stdout).get("result", "")
    m = re.search(r"\[.*\]", text, re.S)
    out = {}
    for s in (json.loads(m.group(0)) if m else []):
        try:
            i, en = int(s["i"]), " ".join(str(s["en"]).split())
        except (KeyError, ValueError, TypeError):
            continue
        if 0 <= i < len(caps) and en:
            out[caps[i]["text"]] = en
    return out


# ---------- 白背景版 ----------
# 仕上がった動画の構図はそのままに、白い地の上に少し小さく置き、角を少しだけ丸くする。

WHITE_M, WHITE_R = 48, 36    # 左右の余白・角丸


def make_white(src, dst, dur, progress=None):
    iw = W - WHITE_M * 2
    ih = round(iw * H / W / 2) * 2          # 9:16 のまま
    x, y = WHITE_M, (H - ih) // 2
    mask = Path(dst).with_name("white_mask.png")
    m = Image.new("L", (iw, ih), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, iw - 1, ih - 1], radius=WHITE_R, fill=255)
    m.convert("RGB").save(mask)
    fc = (f"color=c=white:s={W}x{H}:r=30[bg];"
          f"[0:v]scale={iw}:{ih},format=yuva420p[v];"
          f"[1:v]format=gray,scale={iw}:{ih}[m];[v][m]alphamerge[r];"
          f"[bg][r]overlay={x}:{y}:shortest=1,format=yuv420p[out]")
    cmd = [FFMPEG, "-y", "-v", "error", "-progress", "pipe:1", "-nostats",
           "-i", str(src), "-loop", "1", "-i", str(mask),
           "-filter_complex", fc, "-map", "[out]", "-map", "0:a?", "-t", f"{dur:.3f}",
           "-c:v", "h264_videotoolbox", "-b:v", "6M", "-profile:v", "high",
           "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
           "-c:a", "copy", "-movflags", "+faststart", str(dst)]
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
    mask.unlink(missing_ok=True)
    if rc != 0:
        raise RuntimeError("".join(errbuf)[-1500:].strip() or f"ffmpeg が止まりました（{rc}）")
