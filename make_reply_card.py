#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""お返事カード — お客様への「できるようになりました／ご質問へのお答え」を1枚画像にする道具。

使い方:
    python3 make_reply_card.py <カード.json> [出し先フォルダ]

型は2つ:
    "type": "zoom"  … 画面ひとつを大きく見せ、右に①〜④の説明（1つの機能をしっかり説明する）
    "type": "steps" … 画面3つを横に並べて流れを見せる（やり方・手順の説明）
    "type": "compare" … 「いまできること／まだできないこと」を左右で対比（ご質問へのお答え）

しくみ:
    JSON → HTML を組む → ヘッドレスChromeで撮る → 下の余白を切る（＝はみ出して切れない）
    書体は Zen Maru Gothic（撮影のときだけネットから読む。画像になれば持ち出せる）

出し先には完成PNGと `_もと/`（JSON・HTML・使った画像）を置く。あとから直して撮り直せる。
"""
import json, os, re, shutil, subprocess, sys, tempfile, html as _html
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow が要ります: python3 -m pip install Pillow")

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W = 1080                     # 幅は必ず1080（LINEでいちばんきれいに出る）
TARGET_H = 1440              # 縦3:4。3つの型すべてこの大きさで出す（毎回そろえる）
MIN_H = {"zoom": TARGET_H, "steps": TARGET_H, "compare": TARGET_H}
PAPER = "#F7F5F1"

# 文字数のめやす（超えたら注意を出すだけ・止めない）
LIMIT = {"title": 24, "quote": 62, "note_t": 18, "note_s": 34, "step_t": 14, "step_s": 26, "foot": 30,
         "item_t": 20, "item_s": 36, "ask": 34}

LOGO = """<svg viewBox="0 0 100 100" aria-label="つみき"><rect width="100" height="100" rx="24" fill="#242321"/>
<g fill="#242321" stroke="#F4F2EE" stroke-width="4.5" stroke-linejoin="round" stroke-linecap="round">
<polygon points="35,46 50,53.5 35,61 20,53.5"/><polygon points="20,53.5 35,61 35,76 20,68.5"/><polygon points="50,53.5 35,61 35,76 50,68.5"/>
<polygon points="65,46 80,53.5 65,61 50,53.5"/><polygon points="50,53.5 65,61 65,76 50,68.5"/><polygon points="80,53.5 65,61 65,76 80,68.5"/>
<polygon points="50,24 65,31.5 50,39 35,31.5"/><polygon points="35,31.5 50,39 50,54 35,46.5"/><polygon points="65,31.5 50,39 50,54 65,46.5"/>
</g></svg>"""

CSS = """
:root{--paper:#F7F5F1;--ink:#242321;--sub:#6B6660;--line:#DDD8D0;--accent:#C0533A;--accent-bg:#FBEFEA}
*{margin:0;padding:0;box-sizing:border-box}
html{background:var(--paper)}
body{width:1080px;min-height:__MINH__px;background:var(--paper);color:var(--ink);
  font-family:'Zen Maru Gothic','Hiragino Maru Gothic ProN',-apple-system,sans-serif;
  font-weight:500;display:flex;flex-direction:column}
.bar{height:92px;background:var(--ink);color:#F4F2EE;display:flex;align-items:center;
  gap:18px;padding:0 44px;flex:0 0 auto}
.bar svg{width:46px;height:46px;border-radius:11px}
.bar .nm{font-size:27px;font-weight:700;letter-spacing:.02em}
.bar .dt{margin-left:auto;font-size:21px;color:#B9B4AC;font-weight:400}
.body{flex:1 1 auto;padding:38px 52px 0;display:flex;flex-direction:column}
.kind{align-self:flex-start;background:var(--accent);color:#fff;font-size:20px;font-weight:700;
  padding:7px 20px;border-radius:999px;letter-spacing:.04em}
h1{font-size:__H1__px;font-weight:700;line-height:1.32;margin-top:20px;letter-spacing:-.01em}
.quote{margin-top:20px;border-left:6px solid var(--accent);background:var(--accent-bg);
  padding:16px 24px;border-radius:0 12px 12px 0;font-size:24px;line-height:1.6;color:#5A4A44}
.quote b{font-weight:700;color:var(--accent)}
em{font-style:normal;background:var(--ink);color:#F4F2EE;border-radius:8px;padding:2px 11px;margin:0 3px;
  font-weight:700;display:inline-block}
.foot{flex:0 0 auto;margin-top:auto;background:#EFEBE4;border-top:2px solid var(--line);
  padding:20px 52px;display:flex;align-items:center;gap:16px}
.foot .go{font-size:26px;font-weight:700}
.foot .by{margin-left:auto;font-size:19px;color:var(--sub);text-align:right;line-height:1.4}

/* ── zoom型 ── */
.main{margin-top:28px;display:flex;gap:38px;padding-bottom:28px}
.shot{width:500px;flex:0 0 auto;align-self:flex-start;background:#fff;border:2px solid var(--line);
  border-radius:22px;padding:16px;box-shadow:0 6px 22px rgba(36,35,33,.08);
  display:flex;flex-direction:column;overflow:hidden}
.shot img{width:100%;display:block;border-radius:8px}
.fold{display:flex;align-items:center;gap:12px;margin:12px 2px;color:var(--sub);font-size:19px}
.fold i{flex:1;height:0;border-top:2px dashed var(--line)}
.notes{flex:1 1 auto;display:flex;flex-direction:column;gap:22px;padding-top:4px}
.n{display:flex;gap:15px;align-items:flex-start}
.n .num{flex:0 0 auto;width:40px;height:40px;border-radius:50%;background:var(--accent);color:#fff;
  font-size:23px;font-weight:700;display:flex;align-items:center;justify-content:center;margin-top:1px}
.n .tx{font-size:25px;line-height:1.55}
.n .tx b{font-weight:700}
.n .tx small{display:block;font-size:21px;color:var(--sub);margin-top:4px;line-height:1.5}

/* ── steps型 ── */
.cols{margin-top:24px;display:grid;grid-template-columns:repeat(__NCOL__,1fr);gap:26px;
  padding-bottom:26px}
.col{display:flex;flex-direction:column}
.cap{display:flex;gap:11px;align-items:flex-start;margin-bottom:12px}
.cap .num{flex:0 0 auto;width:34px;height:34px;border-radius:50%;background:var(--accent);color:#fff;
  font-size:20px;font-weight:700;display:flex;align-items:center;justify-content:center}
.cap .tx{font-size:23px;font-weight:700;line-height:1.4;padding-top:2px}
.frame{flex:0 0 auto;height:__FRH__px;background:#fff;border:2px solid var(--line);border-radius:18px;
  padding:10px;box-shadow:0 5px 18px rgba(36,35,33,.07);overflow:hidden}
.frame img{width:100%;height:100%;object-fit:__FIT__;object-position:top center;display:block;border-radius:8px}
.sub{margin-top:11px;font-size:20px;color:var(--sub);line-height:1.5}

/* ── compare型 ── */
.two{margin-top:26px;display:grid;grid-template-columns:1fr 1fr;gap:26px;
  padding-bottom:26px;flex:1 1 auto}
.box{border-radius:18px;padding:24px;border:2px solid;display:flex;flex-direction:column}
.box.ok{background:#fff;border-color:#E7C9BF;box-shadow:0 5px 18px rgba(36,35,33,.06)}
.box.ng{background:#F1EEE9;border-color:var(--line)}
.box h2{font-size:27px;font-weight:700;display:flex;align-items:center;gap:11px;margin-bottom:18px}
.box.ok h2{color:var(--accent)}
.box.ng h2{color:#6B6660}
.mk{flex:0 0 auto;width:36px;height:36px;border-radius:50%;display:flex;align-items:center;
  justify-content:center;font-size:21px;font-weight:700;color:#fff}
.ok .mk{background:var(--accent)}
.ng .mk{background:#A8A29A}
.it{margin-bottom:16px}
.it b{font-size:24px;font-weight:700;line-height:1.45;display:block}
.ng .it b{color:#5C574F}
.it small{font-size:20px;color:var(--sub);line-height:1.5;display:block;margin-top:4px}
.ask{margin-top:auto;padding-top:16px}
.ask span{display:block;background:var(--accent);color:#fff;border-radius:12px;padding:13px 18px;
  font-size:22px;font-weight:700;line-height:1.45}
.shot-s{margin-top:14px;border:2px solid var(--line);border-radius:12px;overflow:hidden;background:#fff}
.shot-s img{width:100%;display:block}
"""


# ────────────────────────────── ことばの手当て
def esc(s):
    """HTMLに入れる。**太字** と 改行 だけ通す。"""
    s = _html.escape(str(s))
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"\[(.+?)\]", r"<em>\1</em>", s)   # [⚙] → 黒いバッジ（押すところ）
    return s.replace("\n", "<br>")


def warn(msg):
    print("⚠️  " + msg)


def check_text(card):
    """文字数と、入ってはいけないもの（宛名）を見る。止めずに知らせるだけ。"""
    def n(s):  # 改行と装飾を除いた字数
        return len(re.sub(r"\*\*|\n", "", str(s)))

    if n(card.get("title", "")) > LIMIT["title"]:
        warn(f'見出しが長い（{n(card["title"])}字／めやす{LIMIT["title"]}字）。結論だけに削る。')
    if n(card.get("quote", "")) > LIMIT["quote"]:
        warn(f'引用が長い（{n(card["quote"])}字／めやす{LIMIT["quote"]}字）。')
    if n(card.get("foot", "")) > LIMIT["foot"]:
        warn(f'足元の一文が長い（{n(card["foot"])}字／めやす{LIMIT["foot"]}字）。')
    for i, x in enumerate(card.get("notes", []), 1):
        if n(x.get("t", "")) > LIMIT["note_t"]:
            warn(f'説明{i}の見出しが長い（{n(x["t"])}字／めやす{LIMIT["note_t"]}字）。')
        if n(x.get("s", "")) > LIMIT["note_s"]:
            warn(f'説明{i}の補足が長い（{n(x["s"])}字／めやす{LIMIT["note_s"]}字）。')
    for i, x in enumerate(card.get("steps", []), 1):
        if n(x.get("t", "")) > LIMIT["step_t"]:
            warn(f'コマ{i}の見出しが長い（{n(x["t"])}字／めやす{LIMIT["step_t"]}字）。')
        if n(x.get("s", "")) > LIMIT["step_s"]:
            warn(f'コマ{i}の一行が長い（{n(x["s"])}字／めやす{LIMIT["step_s"]}字）。')
    for side in ("can", "cannot"):
        box = card.get(side) or {}
        for i, x in enumerate(box.get("items", []), 1):
            if n(x.get("t", "")) > LIMIT["item_t"]:
                warn(f'{side} の{i}つめが長い（{n(x["t"])}字／めやす{LIMIT["item_t"]}字）。')
            if n(x.get("s", "")) > LIMIT["item_s"]:
                warn(f'{side} の{i}つめの補足が長い（{n(x["s"])}字／めやす{LIMIT["item_s"]}字）。')
        if len(box.get("items", [])) > 3:
            warn(f"{side} が4つ以上ある。3つまでに削る。")
    if card.get("type") == "compare" and not (card.get("cannot") or {}).get("ask"):
        warn("「まだできません」を断りで終わらせない。cannot.ask に「お作りできます」の一言を入れる。")
    if len(card.get("notes", [])) > 4:
        warn("説明が5つ以上ある。4つまでに削るか、カードを2枚に分ける。")

    whole = json.dumps(card, ensure_ascii=False)
    for m in set(re.findall(r"[一-龥ぁ-んァ-ヶー]{2,5}(?:さま|様|さん)", whole)):
        warn(f'宛名らしき語「{m}」がカードに入っている。'
             "カードに宛名は書かない（LINEの本文で呼びかける／ほかのお客様にも使い回せなくなる）。")


# ────────────────────────────── 画像の下ごしらえ
def prep_images(card, jdir, workdir):
    """JSONの画像を作業フォルダへ。crop 指定があれば切る。切ったあとの縦横比を返す。"""
    ratios = {}

    def one(spec, idx):
        if isinstance(spec, str):
            spec = {"file": spec}
        src = Path(os.path.expanduser(spec["file"]))
        if not src.is_absolute():
            src = (jdir / src).resolve()
        if not src.exists():
            sys.exit(f"画像が見つかりません: {src}")
        im = Image.open(src)
        c = spec.get("crop")
        if c:
            x0, y0, x1, y1 = (c + [None] * 4)[:4]
            im = im.crop((x0 or 0, y0 or 0, x1 or im.width, y1 or im.height))
        name = f"img{idx}.png"
        im.save(workdir / name)
        ratios[name] = im.height / im.width
        return name

    if card["type"] == "zoom":
        card["_shots"] = [one(s, i) for i, s in enumerate(card["shots"], 1)]
    elif card["type"] == "compare":
        if card.get("shot"):
            card["_shot"] = one(card["shot"], 1)
    else:
        for i, st in enumerate(card["steps"], 1):
            st["_img"] = one(st["img"], i)
    return ratios


# ────────────────────────────── HTMLを組む
def build_html(card, ratios):
    kind = esc(card.get("kind", ""))
    title = esc(card["title"])
    quote = esc(card.get("quote", ""))
    h1 = card.get("title_size", 56 if card["type"] == "zoom" else 52)

    head = f"""<div class="bar">{LOGO}<span class="nm">{esc(card['app'])}</span>
  <span class="dt">{esc(card.get('date',''))}</span></div>
<div class="body">
  <span class="kind">{kind}</span>
  <h1>{title}</h1>
  {'<div class="quote">'+quote+'</div>' if quote else ''}"""

    if card["type"] == "zoom":
        pieces, fold = [], card.get("fold", "つづき")
        for i, f in enumerate(card["_shots"]):
            if i:
                pieces.append(f'<div class="fold"><i></i>{esc(fold)}<i></i></div>')
            pieces.append(f'<img src="{f}" alt="">')
        notes = "".join(
            f'<div class="n"><div class="num">{i}</div><div class="tx"><b>{esc(x["t"])}</b>'
            + (f'<small>{esc(x["s"])}</small>' if x.get("s") else "")
            + "</div></div>"
            for i, x in enumerate(card["notes"], 1))
        body = f'<div class="main"><div class="shot">{"".join(pieces)}</div><div class="notes">{notes}</div></div>'
        ncol, frh, fit = 3, 430, "cover"
    elif card["type"] == "compare":
        def box(side, cls, mark, deftitle):
            d = card.get(side) or {}
            items = "".join(
                f'<div class="it"><b>{esc(x["t"])}</b>'
                + (f'<small>{esc(x["s"])}</small>' if x.get("s") else "") + "</div>"
                for x in d.get("items", []))
            shot = (f'<div class="shot-s"><img src="{card["_shot"]}" alt=""></div>'
                    if cls == "ok" and card.get("_shot") else "")
            ask = f'<div class="ask"><span>{esc(d["ask"])}</span></div>' if d.get("ask") else ""
            return (f'<div class="box {cls}"><h2><span class="mk">{mark}</span>'
                    f'{esc(d.get("title", deftitle))}</h2>{items}{shot}{ask}</div>')
        body = ('<div class="two">'
                + box("can", "ok", "○", "いま、できます")
                + box("cannot", "ng", "△", "まだ、できません") + "</div>")
        ncol, frh, fit = 3, 430, "cover"
    else:
        cols = "".join(
            f'<div class="col"><div class="cap"><div class="num">{i}</div>'
            f'<div class="tx">{esc(x["t"])}</div></div>'
            f'<div class="frame"><img src="{x["_img"]}" alt=""></div>'
            + (f'<div class="sub">{esc(x["s"])}</div>' if x.get("s") else "")
            + "</div>"
            for i, x in enumerate(card["steps"], 1))
        body = f'<div class="cols">{cols}</div>'
        ncol = len(card["steps"])
        # 枠の高さ＝いちばん縦長の画像を幅合わせしたときの高さ（上限480）
        colw = (1080 - 52 * 2 - 26 * (ncol - 1)) / ncol - 24
        frh = min(700, int(max(ratios.values()) * colw) + 20)   # 3:4のぶん枠を大きく取れる
        fit = card.get("fit", "cover")
        rs = list(ratios.values())
        if rs and (max(rs) - min(rs)) / max(rs) > 0.15:
            warn("3枚の縦横比がそろっていない（枠の中で切れます）。crop で高さをそろえてください。")

    foot = f"""<div class="foot"><span class="go">{esc(card.get('foot',''))}</span>
  <span class="by">{esc(card.get('ref',''))}</span></div>"""

    css = (CSS.replace("__MINH__", str(MIN_H[card["type"]])).replace("__H1__", str(h1))
              .replace("__NCOL__", str(ncol)).replace("__FRH__", str(frh)).replace("__FIT__", fit))
    return f"""<!doctype html><html lang="ja"><head><meta charset="utf-8">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Zen+Maru+Gothic:wght@400;500;700&display=swap" rel="stylesheet">
<style>{css}</style></head><body>
{head}
{body}
</div>
{foot}
</body></html>"""


# ────────────────────────────── 撮る・切る
def shoot(html_path, out_png):
    if not Path(CHROME).exists():
        sys.exit("Google Chrome が見つかりません: " + CHROME)
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", f"--window-size={W},4000",
                    "--virtual-time-budget=8000", f"--screenshot={out_png}",
                    "file://" + str(html_path)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    im = Image.open(out_png).convert("RGB")
    paper = tuple(int(PAPER[i:i + 2], 16) for i in (1, 3, 5))
    # 下から、紙色だけの行を落とす（＝中身に合わせて高さが決まる。切れることが起きない）
    px, bottom = im.load(), im.height
    while bottom > 1:
        row = bottom - 1
        if all(px[x, row] == paper for x in range(0, im.width, 7)):
            bottom -= 1
        else:
            break
    im = im.crop((0, 0, im.width, bottom))
    im.save(out_png)
    return im.size, measure_gap(im)


def measure_gap(im):
    """足元の帯のすぐ上に、何も無い余白が何px残っているかを測る。
    中身が薄いと3:4の紙が余ってスカスカに見えるので、機械に数えさせる。"""
    px = im.load()
    paper = tuple(int(PAPER[i:i + 2], 16) for i in (1, 3, 5))
    y = im.height - 1
    while y > 0 and px[5, y] != paper:      # 足元の帯を通り過ぎる
        y -= 1
    gap = 0
    while y > 0 and all(px[x, y] == paper for x in range(0, im.width, 7)):
        gap += 1
        y -= 1
    return gap


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    jpath = Path(sys.argv[1]).expanduser().resolve()
    card = json.loads(jpath.read_text(encoding="utf-8"))
    if card.get("type") not in ("zoom", "steps", "compare"):
        sys.exit('"type" は "zoom" / "steps" / "compare" のどれか')

    check_text(card)

    slug = card.get("slug") or jpath.stem
    outdir = Path(sys.argv[2]).expanduser() if len(sys.argv) > 2 \
        else Path.home() / "つみき出力" / f"{slug}"
    work = outdir / "_もと"
    work.mkdir(parents=True, exist_ok=True)

    ratios = prep_images(card, jpath.parent, work)
    html = build_html(card, ratios)
    (work / "card.html").write_text(html, encoding="utf-8")
    shutil.copy(jpath, work / "card.json")

    png = outdir / f"{slug}.png"
    (w, h), gap = shoot(work / "card.html", png)

    print(f"✓ {png}")
    print(f"  {w}×{h}px（型: {card['type']}）")
    if h > TARGET_H:
        warn(f"縦3:4（{W}×{TARGET_H}）に収まっていない（{h}px＝{h - TARGET_H}px はみ出し）。"
             "中身を削るか、カードを2枚に分けてください。")
    else:
        print("  縦3:4 ちょうどです。")
    gap_limit = 260 if card["type"] == "steps" else 130
    if gap > gap_limit:
        warn(f"足元の上に余白が {gap}px 残っている（スカスカに見える）。"
             "撮影の高さ（jall の h）を上げて画面を縦長に撮る／説明を1行足す／"
             "3コマを2コマにして1つを大きくする、のどれかで埋める。")


if __name__ == "__main__":
    main()
