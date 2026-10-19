# -*- coding: utf-8 -*-
"""動画同期の中身：調べる・同期・文字起こし・見直し・英訳・字幕画像・音量・書き出し・白背景版。

ffmpeg と mlx-whisper はこの Mac の中で動く（無料）。見直しと英訳は Claude Code の CLI（本人のプランの中）。
A＝人を撮った動画（音は常にこちら）／B＝iPhone・iPad の画面録画（外の音つき）。
offset＝「A の何秒目で B が始まったか」（マイナスなら B のほうが先に始まっている）。
"""
import json
import re
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


READABLE_AUDIO = ("aac", "alac", "mp3", "pcm_s16le", "pcm_s24le", "pcm_f32le", "opus")


def drop_unreadable_audio(path):
    """iPhone 16 以降の空間オーディオ（apple_apac）は無料の ffmpeg で読めず、しかも1本目の音に入る。
    読める音が別にあれば、映像と読める音だけを残して詰め直す（中身はコピー・回転の情報もそのまま）。
    詰め直したら True。読める音が無ければ何もしない（あとで「音が入っていません」になる）。"""
    path = Path(path)
    d = json.loads(run([FFPROBE, "-v", "error", "-print_format", "json", "-show_streams", str(path)]))
    auds = [s for s in d["streams"] if s["codec_type"] == "audio"]
    good = [s for s in auds if s.get("codec_name") in READABLE_AUDIO]
    if not good or len(good) == len(auds):
        return False
    tmp = path.with_name("音の詰め直し.tmp" + path.suffix)   # src_*.* の名前にしない（途中で止まっても元の動画と取り違えない）
    run([FFMPEG, "-y", "-v", "error", "-i", str(path), "-map", "0:v:0", "-map", f"0:{good[0]['index']}",
         "-c", "copy", "-map_metadata", "0", "-movflags", "+faststart", str(tmp)])
    tmp.replace(path)
    return True


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
    """Whisper の区切りを字幕1枚ずつに割る。割るのは言葉の切れ目だけ（breaks）。
    1枚は2行に収まる長さまで。句読点・間（0.6秒以上の無音）・文節の切れ目の順に選ぶ。"""
    out = []
    for seg in segments:
        words = seg.get("words") or [{"word": seg["text"], "start": seg["start"], "end": seg["end"]}]
        text, ts = "", []        # ts[i]＝i 文字目の (始まり, 終わり)。言葉の時刻を字数で割り振る
        gaps = {}                # 文字の位置 → その前の無音の長さ
        prev_end = None
        for w in words:
            t = w["word"]
            if not t.strip():
                continue
            ws, we = float(w["start"]), float(w["end"])
            if prev_end is not None and t.strip():
                gaps[len(text) + (len(t) - len(t.lstrip()))] = ws - prev_end
            n = len(t)
            for k in range(n):
                ts.append((ws + (we - ws) * k / n, ws + (we - ws) * (k + 1) / n))
            text += t
            prev_end = we
        if not text.strip():
            continue
        bk = breaks(text)
        for p, g in gaps.items():
            if g >= 0.6 and p in bk:
                bk[p] = min(bk[p], 0)
        pos = len(text) - len(text.lstrip())
        while pos < len(text):
            rest = text[pos:].strip()
            if not rest:
                break
            if fits_lines(rest, 2):
                cut = len(text)
            else:
                best = None
                for q in sorted(bk):
                    if q <= pos:
                        continue
                    piece = text[pos:q].strip()
                    if len(piece) < 4:
                        continue
                    if not fits_lines(piece, 2):
                        break
                    tail = text[q:].strip()
                    score = bk[q] * 4 + (10 if bk[q] >= 5 else 0) - len(piece) * 0.4 + (6 if len(tail) < 4 else 0)
                    if best is None or score < best[0]:
                        best = (score, q)
                cut = best[1] if best else _hard_cut(text, pos, max_chars)
            piece = text[pos:cut]
            lead = len(piece) - len(piece.lstrip())
            body = piece.strip()
            if body:
                i0, i1 = pos + lead, pos + lead + len(body) - 1
                out.append({"start": ts[i0][0], "end": ts[i1][1], "text": body})
            pos = cut
    for c in out:
        c["text"] = re.sub(r"(?<=[^\x00-\x7f]) (?=[^\x00-\x7f])", "", c["text"]).strip().rstrip("。")
        c["start"], c["end"] = round(float(c["start"]), 2), round(float(c["end"]), 2)
    # 次の字幕と重ならず、短すぎないように
    for i, c in enumerate(out):
        nxt = out[i + 1]["start"] if i + 1 < len(out) else c["end"] + 1
        c["end"] = round(min(max(c["end"], c["start"] + 0.8), nxt), 2)
    return [c for c in out if c["text"]]


def _hard_cut(text, pos, n):
    """切れ目が1つも無いほど長い一続き（英字の長い羅列など）だけ、字数で切る。"""
    q = pos + n
    while q < len(text) and q > pos + 1 and _alnum(text[q - 1]) and _alnum(text[q]):
        q += 1
    return min(q, len(text))


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


_EN_ABBR = {"mr.", "mrs.", "ms.", "dr.", "st.", "no.", "vs.", "etc.", "e.g.", "i.e.", "approx.",
            "u.s.", "jr.", "sr.", "inc.", "co.", "ltd."}
_EN_WEAK = {"a", "an", "the", "to", "of", "and", "or", "but", "in", "on", "at", "for", "with",
            "your", "my", "our", "this", "that", "from", "by", "as"}


def wrap_en(d, text, maxw=W - 2 * 44 - 80):
    """英語を単語の切れ目で折る。字の大きさは変えず、収まる一番少ない行数にして行の長さをそろえる
    （1行目だけ長く、最後に「so,」1語だけ残るような折り方をしない）。何行でも同じ基準で選び、
    収まらなければ行を増やす（1行に戻して縮めることはしない）。
    文の終わり・読点の後で折るのを好み、1語だけの行・冠詞や前置詞で終わる行・
    数字と次の語（「iPhone 14 ｜ Pro」「229,800 ｜ yen」）の間・「Mr.」などの略語の後は避ける。"""
    words = text.split()
    if not words:
        return []
    f = _font(EN_FONT)
    n = len(words)
    memo = {}

    def lw(i, j):
        if (i, j) not in memo:
            memo[(i, j)] = d.textlength(" ".join(words[i:j]), font=f)
        return memo[(i, j)]

    if lw(0, n) <= maxw:
        return [" ".join(words)]

    def brk(j):
        """words[j-1] の後で折るときの罰点（負＝好ましい）。"""
        w = words[j - 1]
        core = w.rstrip("\"')]}”’»")
        low = w.lower()
        p = 0
        if low in _EN_ABBR:
            p += 250
        elif core[-1:] in (".", "?", "!") and not (core[-2:-1].isdigit() and j < n and words[j][:1].isdigit()):
            p -= 300
        elif core[-1:] in (",", ";", ":"):
            p -= 200
        if low in _EN_WEAK:
            p += 150
        if any(ch.isdigit() for ch in w) or words[j][:1].isdigit():
            p += 200
        elif w[:1].isupper() and words[j][:1].isupper() and core == w:
            p += 150                  # 「Pro ｜ Max」「Apple ｜ Watch」固有名詞の続きの中
        return p

    # 前から詰めたときの行数＝収まる一番少ない行数
    k0, i = 0, 0
    while i < n:
        j = i + 1
        while j < n and lw(i, j + 1) <= maxw:
            j += 1
        k0, i = k0 + 1, j
    INF = float("inf")
    for k in (k0, k0 + 1):
        avg = lw(0, n) / k
        # best[m][j]＝最初の j 語を m 行に折ったときの最小の点（行の長さと平均の差＋折り目の罰点）
        best = [[INF] * (n + 1) for _ in range(k + 1)]
        back = [[0] * (n + 1) for _ in range(k + 1)]
        best[0][0] = 0
        for m in range(1, k + 1):
            for j in range(m, n + 1):
                for i in range(m - 1, j):
                    if best[m - 1][i] == INF:
                        continue
                    w = lw(i, j)
                    if w > maxw and j - i > 1:
                        continue              # 1語だけで幅を超えるときだけは許す（_fit が縮める）
                    c = best[m - 1][i] + abs(w - avg) + (400 if j - i == 1 else 0)
                    if j < n:
                        c += brk(j)
                    if c < best[m][j]:
                        best[m][j], back[m][j] = c, i
        if best[k][n] < INF:
            out, j = [], n
            for m in range(k, 0, -1):
                i = back[m][j]
                out.append(" ".join(words[i:j]))
                j = i
            return out[::-1]
    return [" ".join(words)]


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


# ---------- 言葉の切れ目（字幕を割る・折る所） ----------
# 言葉の途中では決して切らない。候補は「句読点の後」「BudouX（文節で区切る Google の道具）の切れ目」
# 「形態素解析（fugashi＋UniDic＝言葉の単位と品詞に分ける）で、自立した言葉が始まる所」だけ。
# 英字・数字の続き（Intelligence・iPhone18Pro・1.48）の中も切らない。

PUNCT = "、。！？!?,，"
_INDEP = {"名詞", "代名詞", "動詞", "形容詞", "副詞", "連体詞", "接続詞", "感動詞", "形状詞", "接頭辞"}
_tools = {}


def _alnum(ch):
    return ch.isascii() and (ch.isalnum() or ch in ".'’-&+")


def _parser():
    if "bx" not in _tools:
        import budoux
        _tools["bx"] = budoux.load_default_japanese_parser()
    return _tools["bx"]


def _tagger():
    if "mc" not in _tools:
        import fugashi
        _tools["mc"] = fugashi.Tagger()
    return _tools["mc"]


def _morphs(text):
    """[(始まりの位置, 終わりの位置, 品詞, 品詞の細分類, 辞書の形)]"""
    out, pos = [], 0
    for w in _tagger()(text):
        sfc = w.surface
        i = text.find(sfc, pos)
        if i < 0:
            continue
        f = w.feature
        out.append((i, i + len(sfc), f.pos1, f.pos2, f.lemma or ""))
        pos = i + len(sfc)
    return out


def breaks(text):
    """折ってよい位置 → 罰点（小さいほど自然）。ここに無い位置では切らない。
    0＝句読点の後／1＝文節の切れ目／2＝助詞・助動詞の後で次の言葉が始まる所／4＝言葉どうしの境（複合語の中など）／6＝英単語の間の空白"""
    bk = {}

    def put(p, v):
        if 0 < p < len(text):
            bk[p] = min(bk.get(p, 99), v)

    ms = _morphs(text)
    forbid = set()
    for k in range(1, len(ms)):
        s0, e0, p0, q0, l0 = ms[k - 1]
        s1, e1, p1, q1, l1 = ms[k]
        if p1 not in _INDEP or q1 in ("助動詞語幹", "数詞") and p0 == "名詞" or p0 == "接頭辞":
            continue
        if (q0 == "数詞" or text[e0 - 1].isdigit()) and p1 in ("名詞", "接尾辞"):
            forbid.add(s1)
            continue       # 「5｜秒」「3｜機種」「2.5｜倍」数字と単位は離さない
        if p1 == "動詞" and l1 in ("為る", "出来る") and p0 == "名詞":
            forbid.add(s1)
            continue       # 「タップ｜する」「確認｜できる」は1つの言葉
        if p1 == "動詞" and p0 in ("助詞", "助動詞") and text[s0:e0] in ("に", "と") and \
                text[s1:e1] in ("つい", "よっ", "より", "対し", "おい", "とっ", "し", "関し", "ついて"):
            forbid.add(s1)
            continue       # 「に｜ついて」「に｜よって」「と｜して」は決まった言い回し
        if p1 == "動詞" and l1 == "言う" and p0 == "助詞" and text[s0:e0] in ("と", "って"):
            v = 5          # 「と｜いう」はなるべく避ける
        elif p1 == "動詞" and q1 == "非自立可能" and p0 in ("助詞", "助動詞") and text[e0 - 1] in "てで":
            v = 3          # 「見て｜いただく」は切れるが、なるべく避ける
        elif p0 in ("助詞", "助動詞", "感動詞", "接続詞", "副詞"):
            v = 2
        elif p0 in ("名詞", "代名詞") and p1 in ("名詞", "接頭辞"):
            v = 4
        else:
            v = 3
        put(s1, v)
    p = 0
    for ph in _parser().parse(text):
        p += len(ph)
        put(p, 1)
    for i, ch in enumerate(text):
        if ch in PUNCT:
            put(i + 1, 0)
        if ch == " " and 0 < i < len(text) - 1:
            if _alnum(text[i - 1]) and _alnum(text[i + 1]):
                put(i, 6)
                put(i + 1, 6)
    # 形態素の途中・助詞や助動詞（「ね」「よ」の1字の感動詞も）の前では切らない（BudouX の候補もここで落とす）
    starts = {m[0]: m for m in ms}
    inside = {i for m in ms for i in range(m[0] + 1, m[1])}
    for q in list(bk):
        m = starts.get(q) or starts.get(q + 1 if text[q] == " " else -1)
        if q in inside or q in forbid or m and (m[2] in ("助詞", "助動詞", "接尾辞") or m[2] == "感動詞" and m[1] - m[0] == 1) \
                and text[q - 1] not in PUNCT:
            del bk[q]
    # 英字・数字の続きの中・行頭に来てはいけない字の前は消す
    kata = lambda ch: 0x30A1 <= ord(ch) <= 0x30FA or ch in "ーヽヾ・"
    for q in list(bk):
        a, b = text[q - 1], text[q]
        if _alnum(a) and _alnum(b) or kata(a) and kata(b) or b in PUNCT + "ーっゃゅょぁぃぅぇぉッャュョァィゥェォ」』）)":
            del bk[q]
        elif a in "「『（(":
            del bk[q]
    # 空白の前と後は同じ所（後ろに寄せて片方だけ残す）
    for q in sorted(bk):
        if text[q] == " " and q + 1 in bk:
            bk[q + 1] = min(bk[q + 1], bk.pop(q))
        elif text[q] == " ":
            bk[q + 1] = bk.pop(q)
    return {q: v for q, v in bk.items() if 0 < q < len(text)}


def _tw(text, size=CAP_FONT):
    if "draw" not in _tools:
        _tools["draw"] = ImageDraw.Draw(Image.new("L", (1, 1)))
    if ("font", size) not in _tools:
        _tools[("font", size)] = _font(size)
    return _tools["draw"].textlength(text, font=_tools[("font", size)])


CAP_MAXW = W - 2 * 44 - 80     # 字幕の1行が使える幅（札の内側）
CAP_SQUEEZE = 1.05             # 行を増やさずに済むなら、この割合まで字を少し縮めて（_fit）収める


def fits_lines(text, n):
    """text を言葉の切れ目で n 行以内に折ったとき、どの行も幅に収まるか。"""
    return all(_tw(l) <= CAP_MAXW for l in wrap(text, n))


def wrap(text, maxlines=3):
    """字幕を行に折る。言葉の切れ目（breaks）だけで折り、1行に収まるなら1行。
    2行なら幅がそろい罰点が小さい所。どこで折ってもはみ出すときは行を増やす（最大 maxlines）。"""
    text = " ".join(text.split())   # 改行は空白に（PIL は改行を測れない）
    if not text or _tw(text) <= CAP_MAXW:
        return [text]
    bk = breaks(text)
    qs = sorted(bk)
    best = None
    # 2行：両方収まる中で、罰点＋長さの差が小さいもの
    for q in qs:
        l1, l2 = text[:q].strip(), text[q:].strip()
        w1, w2 = _tw(l1), _tw(l2)
        over = max(w1, w2) - CAP_MAXW
        score = (max(w1, w2) > CAP_MAXW * CAP_SQUEEZE) * 1e6 + over * (over > 0) * 10 + bk[q] * 60 + abs(w1 - w2) * 0.35
        if best is None or score < best[0]:
            best = (score, [l1, l2])
    if best and best[0] < 1e6 or maxlines <= 2 or not qs:
        return best[1] if best else [text]
    # 3行：2か所で折る
    best3 = None
    for i, q1 in enumerate(qs):
        for q2 in qs[i + 1:]:
            ls = [text[:q1].strip(), text[q1:q2].strip(), text[q2:].strip()]
            ws = [_tw(l) for l in ls]
            over = max(ws) - CAP_MAXW
            score = (over > 0) * 1e6 + over * (over > 0) * 10 + (bk[q1] + bk[q2]) * 60 + (max(ws) - min(ws)) * 0.25
            if best3 is None or score < best3[0]:
                best3 = (score, ls)
    return best3[1] if best3 and best3[0] < best[0] else best[1]


def caption_image(text, path, en=None):
    """一番下に重ねる白い札の字幕（1080×1920 の透明画像）。札の下の端を CAP_BOTTOM にそろえる。"""
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    lines = wrap(text)
    # 英語は字の大きさを変えず、収まる一番少ない行数で長さをそろえて折る
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


FF_SPEEDS = (2, 4, 8)                         # 早送りの速さ（倍）


def clean_ff(ff, dur):
    """早送りの区間をそろえる：時刻順・動画の長さの中・0.3秒未満は捨てる・重なりはつなぐ（速さは前の区間）。"""
    out = []
    for r in sorted(ff or [], key=lambda r: float(r["start"])):
        s, e = max(0.0, float(r["start"])), min(float(dur), float(r["end"]))
        sp = int(r.get("speed", 4))
        sp = sp if sp in FF_SPEEDS else 4
        if e - s < 0.3:
            continue
        if out and s <= out[-1]["end"]:
            out[-1]["end"] = round(max(out[-1]["end"], e), 3)
        else:
            out.append({"start": round(s, 3), "end": round(e, 3), "speed": sp})
    return out


def ff_caps(caps, ff):
    """早送りの区間では音を消すので、その区間の字幕は出さない。
    半分以上が区間に入る字幕は落とし、はみ出しているだけの字幕は区間の外へ縮める。"""
    out = []
    for c in caps:
        s, e = c["start"], c["end"]
        inside = sum(max(0.0, min(e, r["end"]) - max(s, r["start"])) for r in ff)
        if e - s <= 0 or inside >= (e - s) * 0.5:
            continue
        for r in ff:
            if r["start"] <= s < r["end"]:
                s = r["end"]
            if r["start"] < e <= r["end"]:
                e = r["start"]
        if e - s >= 0.3:
            out.append({**c, "start": s, "end": e})
    return out


def ff_duration(dur, ff):
    """早送りをかけたあとの長さ。"""
    return dur - sum((r["end"] - r["start"]) * (1 - 1 / r["speed"]) for r in ff)


def ff_filters(ff):
    """早送りの区間を (映像の setpts の式, 音のつなぎ方) にする。
    映像：区間の中の時刻を 1/速さ に縮める（後ろはその分だけ前へ）→ fps=30 で余ったコマを間引く。
    音：区間の外はそのまま、区間の中は「縮めたあとの長さ」の無音にして、順につなぐ。"""
    terms = "+".join(f"clip(T-{r['start']:.3f},0,{r['end'] - r['start']:.3f})*{1 - 1 / r['speed']:.6f}"
                     for r in ff)
    vexpr = f"setpts='(T-({terms}))/TB',fps=30"
    segs, t = [], 0.0
    for r in ff:
        if r["start"] > t:
            segs.append((t, r["start"], False))
        segs.append((r["start"], r["start"] + (r["end"] - r["start"]) / r["speed"], True))
        t = r["end"]
    segs.append((t, None, False))
    n = len(segs)
    parts = [f"[an]asplit={n}" + "".join(f"[as{i}]" for i in range(n))]
    for i, (s, e, mute) in enumerate(segs):
        end = f":end={e:.3f}" if e is not None else ""
        parts.append(f"[as{i}]atrim=start={s:.3f}{end},asetpts=PTS-STARTPTS"
                     + (",volume=0" if mute else "") + f"[at{i}]")
    parts.append("".join(f"[at{i}]" for i in range(n)) + f"concat=n={n}:v=0:a=1[aout]")
    return vexpr, ";".join(parts)


def render(job_dir, a_path, b_path, a_info, b_info, offset, title, caps, out_path, progress=None, ff=None):
    """書き出す。ff＝早送りの区間（書き出しと同じ時間軸）。返り値＝書き出した動画の長さ（秒）。"""
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
    # 早送りの区間は確認の動画（映像の頭が0秒＝書き出しと同じ時間軸）で押した時刻なので、そのまま使う
    ff = clean_ff(ff or [], dur)
    caps = ff_caps([{**c, "start": c["start"] + al, "end": c["end"] + al} for c in caps], ff)
    track = build_caption_track(caps, dur, job_dir / "caps")
    out_dur = ff_duration(dur, ff)

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
        f"[v4][cap]overlay=0:0:eof_action=pass,format=yuv420p[vo];"
        f"[1:a]{loudness_filter(measure_loudness(a_path))}[an]"
    )
    if ff:
        vexpr, achain = ff_filters(ff)
        # 音の時刻を書き出しの0秒からに（音が映像より遅れて始まる動画は頭を無音で埋める）してから切り分ける
        fc = fc.replace("[an]", ",aresample=48000:async=1:first_pts=0[an]")
        fc += f";[vo]{vexpr}[out];" + achain
    else:
        fc = fc.replace("[vo]", "[out]").replace("[an]", "[aout]")
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
           "-t", f"{out_dur:.3f}",
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
                progress(min(int(line.split("=")[1]) / 1e6 / out_dur, 1.0))
            except ValueError:
                pass
    rc = p.wait()
    th.join(5)
    if rc != 0:
        raise RuntimeError("".join(errbuf)[-1500:].strip() or f"ffmpeg が止まりました（{rc}）")
    return out_dur


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
    lex = load_lexicon(learn_dir)
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
    _write_lexicon(learn_dir, lex)
    return lex


def load_lexicon(learn_dir):
    """読めない（書きかけ・壊れた）ときは空として続ける。作業は止めない（ログから作り直せる）。"""
    p = Path(learn_dir) / "覚えた言葉.json"
    try:
        lex = json.loads(p.read_text())
        if isinstance(lex, dict) and isinstance(lex.get("pairs"), list):
            return lex
    except (OSError, ValueError):
        pass
    return {"pairs": [], "removed": []}


def _write_lexicon(learn_dir, lex):
    """一時ファイルに書いてから入れ替える（学習は動画同期と横動画字幕の2つが書くので、書きかけを読ませない）。"""
    p = Path(learn_dir) / "覚えた言葉.json"
    tmp = p.with_name(f".覚えた言葉.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(lex, ensure_ascii=False, indent=1))
    tmp.replace(p)


def remove_pair(learn_dir, a, b):
    lex = load_lexicon(learn_dir)
    lex["removed"] = [x for x in lex.get("removed", []) if x != [a, b]] + [[a, b]]
    _write_lexicon(learn_dir, lex)
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
    res = json.loads(r.stdout)
    if res.get("is_error"):     # 利用枠切れなどは終了コード0でも is_error で返る
        raise RuntimeError(str(res.get("result") or "Claude がエラーを返しました")[:300])
    text = res.get("result", "")
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
# 訳は日本語の文をかぎにして job に控える。前後の流れを読ませるため全部を訳させ、
# 控えに無い字幕の訳だけを足す（訳してある字幕・本人が直した英語は変えない）。

TRANSLATE_PROMPT = """You translate Japanese subtitles of an Apple Store product demo video (title: {title}) into English.
- Natural, concise spoken English for on-screen subtitles. Keep each one short (ideally under 60 characters)
- Use Apple's official English names for products and features (e.g. iPhone 18 Pro, Portrait mode, Dynamic Island, Camera Control)
- Drop fillers ("はい", "そうそう", "えー") but keep the meaning; never add information
- If a line is only a filler, still include it with "en": ""
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
    res = json.loads(r.stdout)
    if res.get("is_error"):     # 利用枠切れなどは終了コード0でも is_error で返る
        raise RuntimeError(str(res.get("result") or "Claude がエラーを返しました")[:300])
    text = res.get("result", "")
    m = re.search(r"\[.*\]", text, re.S)
    out = {}
    for s in (json.loads(m.group(0)) if m else []):
        try:
            i, en = int(s["i"]), " ".join(str(s.get("en", "")).split())
        except (KeyError, ValueError, TypeError):
            continue
        if 0 <= i < len(caps):
            out[caps[i]["text"]] = en     # ""＝口ぐせだけで訳さない字幕
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


INTRO_HOLD, INTRO_FADE = 3.5, 0.6     # 冒頭のサムネイルを出す秒数・本編へ重ねて切り替える秒数


def probe_duration(path):
    r = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                       capture_output=True, text=True, check=True)
    return float(r.stdout.strip())


def add_intro(body, image, dst, body_dur=None, progress=None):
    """冒頭に縦長のサムネイル（W×H）を INTRO_HOLD 秒出し、INTRO_FADE 秒かけて本編へ重ねて切り替える。
    本編は頭から全部使う（切り替えの間に本編の頭が透けて始まる）。音はサムネイルの間は無音、本編の頭で短く立ち上げる。
    返り値＝できた動画の長さ（秒）＝INTRO_HOLD＋本編の長さ。"""
    body_dur = body_dur or probe_duration(body)
    total = INTRO_HOLD + body_dur
    fc = (f"[0:v]scale={W}:{H}:out_color_matrix=bt709:out_range=tv,format=yuv420p,setsar=1,fps=30,"
          f"trim=duration={INTRO_HOLD + INTRO_FADE:.3f},settb=AVTB[i];"
          f"[1:v]fps=30,scale={W}:{H},format=yuv420p,setsar=1,settb=AVTB[b];"
          f"[i][b]xfade=transition=fade:duration={INTRO_FADE}:offset={INTRO_HOLD}[out];"
          f"[1:a]aresample=48000,adelay={round(INTRO_HOLD * 1000)}:all=1,"
          f"afade=t=in:st={INTRO_HOLD}:d={INTRO_FADE}[aout]")
    cmd = [FFMPEG, "-y", "-v", "error", "-progress", "pipe:1", "-nostats",
           "-loop", "1", "-framerate", "30", "-i", str(image), "-i", str(body),
           "-filter_complex", fc, "-map", "[out]", "-map", "[aout]", "-t", f"{total:.3f}",
           "-c:v", "h264_videotoolbox", "-b:v", "6M", "-profile:v", "high",
           "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
           "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(dst)]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    errbuf = []
    import threading
    th = threading.Thread(target=lambda: errbuf.append(p.stderr.read()), daemon=True)
    th.start()
    for line in p.stdout:
        if line.startswith("out_time_us=") and progress:
            try:
                progress(min(int(line.split("=")[1]) / 1e6 / total, 1.0))
            except ValueError:
                pass
    rc = p.wait()
    th.join(5)
    if rc != 0:
        raise RuntimeError("".join(errbuf)[-1500:].strip() or f"ffmpeg が止まりました（{rc}）")
    return total
