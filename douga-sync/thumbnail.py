"""サムネイル（1280×720）を作る：パステルの地・左上に Apple マーク・左に太字の題名・右に端末の枠に入れた画面録画。

    .venv/bin/python thumbnail.py <作業のフォルダ> [出力.png] [--color 0-13] [--at 秒] [--seed 何でも] [--image 画像 --focus 0〜1]
        [--box 左,上,右,下] [--no-island] [--card]

--image：画面録画の代わりに使う画像（公式の写真など）。--box で切り出す範囲、--no-island は画像に元から Dynamic Island が写っているとき、
--card は端末の枠に入れず写真を角丸のカードで置く。動画同期のサーバーは job.json の thumb_image（file・focus・box・island・card）を読んで同じように作る。

画面録画（src_b）から見ばえのする1コマを自動で選ぶ（色の多さ・明暗の幅が大きいコマ。頭と終わりの15%は除く）。
--at で秒を指定するとそのコマを使う。地の色は14色からランダム（--seed を変えると引き直し、--color で指定）。縦長＝iPhone の枠（下は切れる）、横長＝iPad の枠。
"""
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import engine

TW, TH = 1280, 720
# 地の色：見本と同じ、白に近いくすんだパステル（明るさ・鮮やかさをそろえる）。
# 見分けにくい色（ピーチ・アプリコット≒ベージュ、バター≒クリーム）は入れない
COLORS = [
    (242, 217, 191),   # ベージュ
    (200, 218, 219),   # 青灰
    (247, 237, 203),   # クリーム
    (241, 241, 239),   # 薄い灰
    (214, 226, 206),   # セージ
    (241, 214, 210),   # くすんだピンク
    (222, 216, 236),   # ラベンダー
    (208, 230, 222),   # ミント
    (210, 224, 238),   # 空色
    (233, 224, 208),   # 砂
    (226, 221, 228),   # 藤鼠
]
INK = (29, 29, 31)
JP_BOLD = "/System/Library/Fonts/ヒラギノ角ゴシック W7.ttc"
LOGO_FONT = "/System/Library/Fonts/SFNS.ttf"        # U+F8FF が Apple マーク
BEZEL = (22, 22, 24)
EDGE = (88, 88, 92)


def grab(src, t, w=900, info=None):
    vf = f"scale={w}:-2," + (engine.hdr_filter(info) if info else "") + "format=rgb24"   # HDR の録画も書き出しと同じ色に
    raw = subprocess.run([engine.FFMPEG, "-v", "error", "-ss", f"{t:.2f}", "-i", str(src), "-frames:v", "1",
                          "-vf", vf, "-f", "image2pipe", "-vcodec", "png", "-"],
                         capture_output=True, check=True).stdout
    import io
    return Image.open(io.BytesIO(raw)).convert("RGB")


def pick_frame(src, dur, n=14, info=None):
    """見ばえのするコマを選ぶ：色の多さ（彩度）＋明暗の幅。真っ黒・真っ白・ほぼ一色のコマを避ける。"""
    best = None
    for k in range(n):
        t = dur * (0.15 + 0.7 * k / (n - 1))
        im = grab(src, t, 240, info)
        a = np.asarray(im).astype(float)
        rg, yb = a[..., 0] - a[..., 1], (a[..., 0] + a[..., 1]) / 2 - a[..., 2]
        color = np.sqrt(rg.std() ** 2 + yb.std() ** 2) + 0.3 * np.sqrt(rg.mean() ** 2 + yb.mean() ** 2)
        lum = a.mean(axis=2)
        score = color + 0.5 * lum.std() - (40 if lum.mean() < 25 or lum.mean() > 245 else 0)
        if best is None or score > best[0]:
            best = (score, t)
    return best[1]


def wrap_title(text, font, maxw, maxlines=4):
    """題名を言葉の切れ目で折る（日本語は engine.breaks、英語は空白）。行の長さはなるべくそろえる。"""
    d = ImageDraw.Draw(Image.new("L", (1, 1)))
    tw = lambda s: d.textlength(s, font=font)
    if tw(text) <= maxw:
        return [text]
    bk = engine.breaks(text)
    qs = sorted(set(bk) | {i + 1 for i, ch in enumerate(text) if ch == " "})
    for k in range(2, maxlines + 1):
        best = None
        from itertools import combinations
        for cut in combinations(qs, k - 1):
            pts = (0,) + cut + (len(text),)
            ls = [text[pts[i]:pts[i + 1]].strip() for i in range(k)]
            if any(not l for l in ls):
                continue
            ws = [tw(l) for l in ls]
            if max(ws) > maxw:
                continue
            sc = max(ws) + sum(bk.get(c, 2) * 40 + (300 if bk.get(c, 2) >= 4 else 0) for c in cut)   # 複合語の中（予定｜表）は強く避ける
            if best is None or sc < best[0]:
                best = (sc, ls)
        if best:
            return best[1]
    return [text]


def wrap_hard(text, font, maxw):
    """言葉の切れ目ではどうしても入らない題名（長いカタカナ語・空白の無い英字）だけ、字の境目で詰めて折る。"""
    d = ImageDraw.Draw(Image.new("L", (1, 1)))
    lines, cur = [], ""
    for ch in text:
        if cur and d.textlength(cur + ch, font=font) > maxw:
            lines.append(cur.strip())
            cur = ch
        else:
            cur += ch
    return lines + [cur.strip()] if cur.strip() else lines


def clean_title(text):
    """改行は空白に。ヒラギノに無い字（絵文字・Apple マーク・異体字セレクタ）は取り除く（豆腐を出さない）。"""
    text = " ".join(str(text).split())
    out = "".join(ch for ch in text
                  if not (ord(ch) > 0xFFFF or 0xE000 <= ord(ch) <= 0xF8FF or 0xFE00 <= ord(ch) <= 0xFE0F
                          or 0x2600 <= ord(ch) <= 0x27BF or ord(ch) == 0x200D))
    return " ".join(out.split())


def pick_color(job_id, seed):
    """色の番号。作業ごとに順番を混ぜ、seed ごとに次の色へ。前の色と見分けにくい色は飛ばす。"""
    import random
    order = random.Random(str(job_id)).sample(range(len(COLORS)), len(COLORS))
    far = lambda a, b: sum((x - y) ** 2 for x, y in zip(COLORS[a], COLORS[b])) ** 0.5 >= 18
    cur, pos = order[0], 0
    for _ in range(int(seed)):
        for step in range(1, len(order) + 1):
            nxt = order[(pos + step) % len(order)]
            if nxt != cur and far(cur, nxt):
                cur, pos = nxt, (pos + step) % len(order)
                break
    return cur


def rounded(im, r):
    m = Image.new("L", im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, im.width - 1, im.height - 1], radius=r, fill=255)
    return m


def device(shot, portrait, island=True):
    """端末の枠に画面を入れた画像（透明の地）。"""
    if portrait:
        sw = 318
        sh = round(sw * shot.height / shot.width)
        b, r_out, r_in = 12, 58, 47
    else:
        sw = 540
        sh = round(sw * shot.height / shot.width)
        b, r_out, r_in = 18, 34, 18
    W, H = sw + 2 * b, sh + 2 * b
    im = Image.new("RGBA", (W + 6, H + 6), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, W + 5, H + 5], radius=r_out + 3, fill=EDGE)          # 縁の金属
    d.rounded_rectangle([3, 3, W + 2, H + 2], radius=r_out, fill=BEZEL)
    scr = shot.resize((sw, sh), Image.LANCZOS)
    im.paste(scr, (3 + b, 3 + b), rounded(scr, r_in))
    if portrait and island:   # ダイナミックアイランド（画面の画像に元から写っているときは描かない）
        iw, ih = 96, 28
        cx, top = (W + 6) // 2, 3 + b + 12
        d.rounded_rectangle([cx - iw // 2, top, cx + iw // 2, top + ih], radius=ih // 2, fill=(0, 0, 0))
    return im


def shadow(im, blur=18, alpha=70, off=(0, 10)):
    from PIL import ImageFilter
    a = im.split()[-1].point(lambda v: alpha if v else 0)
    sh = Image.new("RGBA", (im.width + 80, im.height + 80), (0, 0, 0, 0))
    sh.paste(Image.new("RGBA", im.size, (0, 0, 0, 255)), (40 + off[0], 40 + off[1]), a)
    return sh.filter(ImageFilter.GaussianBlur(blur))


def from_image(path, focus=0.5, ratio=1206 / 2622, box=None):
    """画面録画の代わりに使う画像（公式の写真など）。box（左,上,右,下）を指定するとその範囲をそのまま使う。
    指定が無ければ iPhone の画面の縦横比で、focus（横の位置 0〜1）を中心に切り出す。"""
    im = Image.open(path).convert("RGB")
    if box:
        return im.crop(box)
    w = min(im.width, round(im.height * ratio))
    x = min(max(round(im.width * focus - w / 2), 0), im.width - w)
    return im.crop((x, 0, x + w, im.height))


def card(im, maxw=560, maxh=600, r=28):
    """公式の写真をそのまま角の丸いカードにする（端末の枠に入れない置き方）。"""
    im = im.copy()
    im.thumbnail((maxw, maxh), Image.LANCZOS)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im, (0, 0), rounded(im, r))
    return out


def make(job_dir, out, color=None, at=None, seed=0, image=None, focus=0.5, box=None, island=True, as_card=False):
    job_dir = Path(job_dir)
    job = json.loads((job_dir / "job.json").read_text())
    src = next(job_dir.glob("src_b.*"))
    bi = job["b_info"]
    if image:   # 画面録画の代わりに指定の画像（公式の写真など）を端末の画面に入れる
        t, shot = None, from_image(image, focus, box=box)
    else:
        t = at if at is not None else pick_frame(src, bi.get("vdur") or bi["dur"], info=bi)
        shot = grab(src, t, info=bi)
    portrait = shot.height > shot.width * 1.05     # 正方形に近い録画は iPad の枠
    if color is None:   # ランダム（作業ごとに色の順番を混ぜ、seed で次の色へ。前と見分けにくい色は飛ばす）
        color = pick_color(job["id"], seed)
    bg = COLORS[color % len(COLORS)]
    im = Image.new("RGBA", (TW, TH), bg + (255,))
    d = ImageDraw.Draw(im)

    dev = card(shot) if as_card else device(shot, portrait, island)
    if as_card:
        x, y = TW - 70 - dev.width, (TH - dev.height) // 2
    elif portrait:
        x, y = TW - 96 - dev.width, max(64, TH - dev.height + 60)   # 下は画面の外へ切れる（短い画面は下から立ち上げる）
    else:
        x, y = TW - 56 - dev.width, (TH - dev.height) // 2 + 20
    sh = shadow(dev)
    im.alpha_composite(sh, (x - 40, y - 40))
    im.alpha_composite(dev, (x, y))

    try:
        d.text((70, 52), "\uf8ff", font=ImageFont.truetype(LOGO_FONT, 54), fill=INK, anchor="lt")
    except OSError:
        pass                                       # マークの字が無い環境ではマークだけ省く
    maxw = x - 70 - 48
    title = clean_title(job["title"]) or "　"
    size = 68
    while True:
        f = ImageFont.truetype(JP_BOLD, size)
        lines = wrap_title(title, f, maxw)
        if all(d.textlength(l, font=f) <= maxw for l in lines):
            break
        if len(wrap_hard(title, f, maxw)) <= 3 and size <= 48:   # 1行に縮めても入らない長いカタカナ語だけ、字の境目で折る
            lines = wrap_hard(title, f, maxw)
            break
        if size <= 40:   # 切れ目ではどうしても入らない → 字の境目で折る（それでも5行を超えるなら失敗にする）
            lines = wrap_hard(title, f, maxw)
            if len(lines) > 5:
                raise ValueError("題名が長すぎてサムネイルに入りません")
            break
        size -= 4
    lh = int(size * 1.42)
    top = (TH - lh * len(lines)) // 2 + 10
    for k, l in enumerate(lines):
        d.text((70, top + k * lh), l, font=f, fill=INK)
    im.convert("RGB").save(out)
    return t


if __name__ == "__main__":
    args = sys.argv[1:]
    color = int(args[args.index("--color") + 1]) if "--color" in args else None
    at = float(args[args.index("--at") + 1]) if "--at" in args else None
    seed = args[args.index("--seed") + 1] if "--seed" in args else 0
    image = args[args.index("--image") + 1] if "--image" in args else None
    focus = float(args[args.index("--focus") + 1]) if "--focus" in args else 0.5
    box = tuple(int(v) for v in args[args.index("--box") + 1].split(",")) if "--box" in args else None
    valued = ("--color", "--at", "--seed", "--image", "--focus", "--box")
    pos = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] not in valued)]
    out = pos[1] if len(pos) > 1 else str(Path(pos[0]) / "サムネイル.png")
    print(make(pos[0], out, color, at, seed, image, focus, box, "--no-island" not in args, "--card" in args))
