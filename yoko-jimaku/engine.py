# -*- coding: utf-8 -*-
"""横動画字幕の中身：調べる・文字起こし・見直し・英訳・字幕画像・音量・早送り・書き出し。

動画同期（../douga-sync）と同じ作り。違いは、動画が1本（16:9 の横動画）で、書き出しが 1920×1080 の横なこと。
ffmpeg と mlx-whisper はこの Mac の中で動く（無料）。見直しと英訳は Claude Code の CLI（本人のプランの中）。
"""
import json
import re
import os
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
FONT = next((p for p in (
    os.path.expanduser("~/Library/Fonts/ZenMaruGothic-Bold.ttf"),
    "/Library/Fonts/ZenMaruGothic-Bold.ttf",
    "/System/Library/Fonts/ヒラギノ丸ゴ ProN W4.ttc",
) if os.path.exists(p)))
WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"

# 書き出しの寸法（1920×1080・横）
W, H = 1920, 1080
# 形：動画を画面全体に敷き（16:9 でなければ黒い帯で収め、切らない）、タイトルと字幕は白い札にして上に重ねる
CAP_FONT, CAP_LINE = 50, 20         # 字幕の字の大きさ・1行の字数（横長でも1行は読める長さに抑える）
EN_FONT = 32                        # 英語の字幕の字の大きさ（日本語の下に小さく）
TITLE_FONT, TITLE_TOP = 48, 40      # タイトルの字の大きさ・上の余白
INK_MID = (91, 85, 74)
CAP_BOTTOM = 44                     # 字幕の札の下の余白
PLATE = (255, 255, 255, 230)        # 札の色（白・少しだけ透ける）


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
    """スマホで確認する用の軽い動画（高さ 540・H.264）。"""
    vf = "scale=-2:540," + hdr_filter(info) + "format=yuv420p"
    run([FFMPEG, "-y", "-v", "error", "-i", str(src), "-vf", vf,
         "-c:v", "h264_videotoolbox", "-b:v", "1500k", "-c:a", "aac", "-b:a", "96k",
         "-movflags", "+faststart", str(dst)])


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


def _plate_size(d, lines, size, sub=(), padx=44, pady=26):
    lh, slh = int(size * 1.38), int(EN_FONT * 1.36)
    gap = 8 if sub else 0
    return lh * len(lines) + gap + slh * len(sub) + pady * 2


def _plate(d, cx, top, lines, size, padx=44, pady=26, radius=None, sub=(), maxw=None):
    """白い札に墨の字を真ん中そろえで置く（sub＝下に小さく添える英語の行）。返り値＝札の下の端。
    maxw＝1行の幅の上限（超える行は字を縮める）。"""
    lh, slh = int(size * 1.38), int(EN_FONT * 1.36)
    maxw = maxw or W - 2 * padx - 80
    fonts = [_fit(d, ln, size, maxw) for ln in lines]
    sfonts = [_fit(d, ln, EN_FONT, max(maxw, EN_MAXW)) for ln in sub]
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


def wrap_en(d, text, maxw=None, maxlines=2):
    """英語を単語の切れ目で折る（2行まで。収まらなければ最後の行は _fit が縮める）。"""
    maxw = maxw or EN_MAXW
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
    _plate(ImageDraw.Draw(im), W // 2, TITLE_TOP, [title], TITLE_FONT, padx=52, pady=18)
    im.save(path)


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


CAP_MAXW = 1000                # 字幕の1行が使える幅（札の内側・約20字）。画面いっぱいに伸ばすと目で追いにくい
EN_MAXW = 1400                 # 英語の1行が使える幅
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
    """一番下に重ねる白い札の字幕（1920×1080 の透明画像）。札の下の端を CAP_BOTTOM にそろえる。"""
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    lines = wrap(text)
    # 日本語が3行のときは英語を1行にし、札が画面の下を覆いすぎないようにする
    sub = wrap_en(d, en, maxlines=1 if len(lines) >= 3 else 2) if en else []
    h = _plate_size(d, lines, CAP_FONT, sub)
    # 少しはみ出す行（CAP_SQUEEZE の分）は字を縮めて CAP_MAXW に収める
    _plate(d, W // 2, H - CAP_BOTTOM - h, lines, CAP_FONT, sub=sub, maxw=CAP_MAXW)
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


def render(job_dir, a_path, a_info, title, caps, out_path, progress=None, ff=None):
    """書き出す。ff＝早送りの区間（書き出しと同じ時間軸）。返り値＝書き出した動画の長さ（秒）。"""
    job_dir = Path(job_dir)
    ttl = job_dir / "title.png"
    make_title(title, ttl)
    dur = a_info["dur"]
    # 字幕の時刻は音の頭が0秒（文字起こしの都合）。書き出しの時間軸（ファイルの始まりが0秒）へ直す
    al = a_info.get("alead", 0.0)
    # 早送りの区間は確認の動画（映像の頭が0秒＝書き出しと同じ時間軸）で押した時刻なので、そのまま使う
    ff = clean_ff(ff or [], dur)
    caps = ff_caps([{**c, "start": c["start"] + al, "end": c["end"] + al} for c in caps], ff)
    track = build_caption_track(caps, dur, job_dir / "caps")
    out_dur = ff_duration(dur, ff)

    # 黒い下地に動画を重ねる（映像が音より遅れて始まる動画でも、0秒から絵が出る）。
    # 16:9 でない動画は縮めて真ん中に置き、余りは黒い帯（切らない）
    fc = (
        f"color=c=black:s={W}x{H}:r=30[bg];"
        f"[0:v]fps=30,scale={W}:{H}:force_original_aspect_ratio=decrease,"
        f"{hdr_filter(a_info)}setsar=1[main];"
        f"[bg][main]overlay=(W-w)/2:(H-h)/2:shortest=1[v1];"
        f"[2:v]format=rgba[ttl];"
        f"[v1][ttl]overlay=0:0[v2];"
        f"[1:v]format=rgba[cap];"
        f"[v2][cap]overlay=0:0:eof_action=pass,format=yuv420p[vo];"
        f"[0:a]{loudness_filter(measure_loudness(a_path))}[an]"
    )
    if ff:
        vexpr, achain = ff_filters(ff)
        # 音の時刻を書き出しの0秒からに（音が映像より遅れて始まる動画は頭を無音で埋める）してから切り分ける
        fc = fc.replace("[an]", ",aresample=48000:async=1:first_pts=0[an]")
        fc += f";[vo]{vexpr}[out];" + achain
    else:
        fc = fc.replace("[vo]", "[out]").replace("[an]", "[aout]")
    cmd = [FFMPEG, "-y", "-v", "error", "-progress", "pipe:1", "-nostats",
           "-i", str(a_path),
           "-f", "concat", "-safe", "0", "-i", str(track),
           "-loop", "1", "-i", str(ttl),
           "-filter_complex", fc,
           "-map", "[out]", "-map", "[aout]",
           "-t", f"{out_dur:.3f}",
           "-c:v", "h264_videotoolbox", "-b:v", "8M",   # 1080p の横。2分半で約150MB
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
    work = Path(os.environ.get("YJ_ROOT") or Path.home() / "Movies" / "横動画字幕") / ".review"   # CLAUDE.md を拾わない空の場所で動かす
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
    work = Path(os.environ.get("YJ_ROOT") or Path.home() / "Movies" / "横動画字幕") / ".review"
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
