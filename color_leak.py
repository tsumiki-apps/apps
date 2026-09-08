#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""color_leak.py — 単一HTMLに「決めた色」以外が混ざっていないか調べる

なにをするか:
    :root{...} と @media (prefers-color-scheme: dark) で宣言した CSS 変数を
    「決めた色（＝色板）」とみなす。そのうえでファイル全体を読み、
    var(...) を通さずに直に書かれた色を拾って3つに分ける。

      ✗ 色漏れ   … 色板に無い**有彩色**。refero-styles で写した配色が崩れる原因。
      △ 直書き   … 値は色板と同じなのに var() を使っていない。差し替えのとき取り残される。
      ・ 無彩色   … 白・黒・灰の直書き（影の rgba(0,0,0,.1) など）。多くは許容。

    「見た目が合っているか」は目で見ないと分からないが、
    「決めた色以外が混ざっているか」は機械で落とせる。そこだけを受け持つ。

つかいかた:
    python3 color_leak.py <HTML> [<HTML> ...]     調べる（✗ が1つでもあれば終了コード1）
    python3 color_leak.py --all <HTML>            無彩色もぜんぶ並べる
    python3 color_leak.py --parts <HTML>          tn.css/tn.js の注入ブロックも対象にする

    既定で見ないもの: 注入ブロック（tsumiki-native-parts / tsumiki-back-button）、
    つみきの公式ロゴSVG（class="mark"・座標ごとコピーする決まり）、コメントの中。
    どれも機械が管理しているか、手で色を変えてはいけない場所。

    どうしても直書きが要るとき（動的に色相を回す演出など）は、その行に
    `/* 色ok: 理由 */` と書く。見逃すが、件数と理由は必ず報告に出る。

出どころ:
    lieflat-charts の validate.mjs が「選んだ配色に無い色値が1つでもあれば FAIL」を
    やっていたのを、つみきの変数体系に合わせて書き直したもの（コードは写していない）。
    refero-styles の手順5（8幅で検証する）と並べて使う。
"""
import argparse
import re
import sys
from pathlib import Path

# ── 見なくてよいもの ────────────────────────────────────────────
# 機械が入れて機械が入れ替えるブロック。手で色を直しても次の注入で消えるので見ない。
PARTS_RE = re.compile(
    r"<!-- tsumiki-native-parts(?: [^>]*)? -->.*?<!-- /tsumiki-native-parts -->"
    r"|<!-- tsumiki-back-button -->.*?<!-- /tsumiki-back-button -->",
    re.DOTALL,
)
# つみきの公式ロゴSVG。**座標ごとコピーする決まり（A層P0）なので色を差し替えない。**
# だから検査の対象から外す。ロゴを見つける目印は class="mark" と、公式の2色。
LOGO_RE = re.compile(
    r"<svg[^>]*class=[\"'][^\"']*\bmark\b[^\"']*[\"'][^>]*>.*?</svg>", re.DOTALL | re.IGNORECASE)

COMMENT_RES = [
    re.compile(r"/\*.*?\*/", re.DOTALL),      # CSS / JS のブロックコメント
    re.compile(r"<!--(?!\s*/?tsumiki).*?-->", re.DOTALL),  # HTMLコメント
]

# ── 色の書き方 ──────────────────────────────────────────────────
HEX_RE = re.compile(r"#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b")
FUNC_RE = re.compile(r"\b(?:rgb|rgba|hsl|hsla)\(\s*[^)]{1,80}\)")
# 色名は「color: red」のように色のプロパティに付いているときだけ拾う（本文の"red"を誤検出しない）
PROP = (r"(?:color|background|background-color|border-color|border-top-color|"
        r"border-bottom-color|border-left-color|border-right-color|outline-color|"
        r"fill|stroke|caret-color|accent-color|text-decoration-color)")
# 直後が "-" や "(" のものは関数名（repeating-linear-gradient など）。色名ではない。
NAMED_RE = re.compile(PROP + r"\s*:\s*([a-zA-Z]{3,20})\b(?![-(])")
NAMED_OK = {  # 色ではない値。見逃してよい
    "inherit", "initial", "unset", "revert", "none", "transparent", "currentcolor",
    "auto", "var", "linear", "radial", "conic", "url", "rgb", "rgba", "hsl", "hsla",
    "color", "light", "dark", "canvastext", "field", "fieldtext", "buttontext",
}

# 変数の宣言行（ここは色板そのものなので、漏れとして数えない）
DECL_RE = re.compile(r"--[A-Za-z0-9_-]+\s*:\s*([^;}]+)")


def strip_ignored(text, keep_parts):
    """見ないところを同じ長さの空白に置き換える（行番号をずらさないため）。"""
    def blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))

    if not keep_parts:
        text = PARTS_RE.sub(blank, text)
    text = LOGO_RE.sub(blank, text)
    for rx in COMMENT_RES:
        text = rx.sub(blank, text)
    return text


def norm(literal):
    """色の書き方をそろえる。返り値は (r, g, b) か None。"""
    s = literal.strip().lower()
    if s.startswith("#"):
        h = s[1:]
        if len(h) in (3, 4):
            h = "".join(c * 2 for c in h[:3])
        h = h[:6]
        if len(h) != 6:
            return None
        try:
            return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
        except ValueError:
            return None
    m = re.match(r"rgba?\(\s*([^)]+)\)", s)
    if m:
        parts = re.split(r"[,\s/]+", m.group(1).strip())
        nums = []
        for p in parts[:3]:
            if p.endswith("%"):
                try:
                    nums.append(round(float(p[:-1]) * 255 / 100))
                except ValueError:
                    return None
            else:
                try:
                    nums.append(int(round(float(p))))
                except ValueError:
                    return None
        return tuple(nums) if len(nums) == 3 else None
    return None   # hsl は色板との突き合わせをしない（値だけ報告する）


def is_gray(rgb):
    return rgb is not None and rgb[0] == rgb[1] == rgb[2]


def palette_of(text):
    """:root などで宣言された変数の値を集める＝これが「決めた色」。"""
    pal = set()
    raw = set()
    for m in DECL_RE.finditer(text):
        value = m.group(1)
        for lit in HEX_RE.findall(value) + FUNC_RE.findall(value):
            raw.add(lit.strip().lower())
            rgb = norm(lit)
            if rgb:
                pal.add(rgb)
    return pal, raw


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def scan(path, keep_parts, show_all):
    src = Path(path).read_text(encoding="utf-8")
    body = strip_ignored(src, keep_parts)
    lines = src.split("\n")

    pal, pal_raw = palette_of(body)

    # 変数の宣言そのものの位置は、あとで「宣言か使用か」を見分けるのに使う
    decl_spans = [(m.start(), m.end()) for m in DECL_RE.finditer(body)]

    def in_decl(i):
        return any(a <= i < b for a, b in decl_spans)

    leaks, hardcoded, grays = [], [], []
    waived = []          # 「色ok:」と理由を書いて、わざと見逃したもの

    def record(i, lit):
        if in_decl(i):
            return                       # 色板の宣言そのもの
        ln = line_of(body, i)
        text = lines[ln - 1].strip()
        # 同じ行に「色ok: 理由」と書いてあれば、わざとの直書きとして見逃す。
        # ただし黙って減らさない。件数と理由を必ず報告に出す。
        m = re.search(r"色ok\s*[:：]\s*([^*/]*)", lines[ln - 1])
        if m:
            waived.append((ln, lit, m.group(1).strip()[:50]))
            return
        if len(text) > 90:
            text = text[:88] + "…"
        if len(lit) > 34:
            lit = lit[:32] + "…"
        rgb = norm(lit)
        if rgb is None:
            leaks.append((ln, lit, text))          # hsl など。突き合わせできないので要確認
        elif rgb in pal:
            hardcoded.append((ln, lit, text))
        elif is_gray(rgb):
            grays.append((ln, lit, text))
        else:
            leaks.append((ln, lit, text))

    for m in HEX_RE.finditer(body):
        record(m.start(), m.group(0))
    for m in FUNC_RE.finditer(body):
        record(m.start(), m.group(0))
    for m in NAMED_RE.finditer(body):
        name = m.group(1)
        if name.lower() in NAMED_OK:
            continue
        ln = line_of(body, m.start())
        text = lines[ln - 1].strip()
        leaks.append((ln, name, text[:88]))

    # ── 報告 ──
    print(f"\n■ {path}")
    print(f"  決めた色: {len(pal)}色（:root などの変数宣言から）")
    if not pal:
        print("  ! 変数の宣言が見つかりません。色板が無いファイルは判定できません。")

    if leaks:
        print(f"\n  ✗ 色漏れ {len(leaks)}件 — 色板に無い色が直に書かれています")
        for ln, lit, text in sorted(leaks):
            print(f"     {path}:{ln}  {lit}")
            print(f"        {text}")
    if hardcoded:
        print(f"\n  △ 直書き {len(hardcoded)}件 — 値は合っているが var() を通していません")
        for ln, lit, text in sorted(hardcoded)[: None if show_all else 12]:
            print(f"     {path}:{ln}  {lit}")
        if not show_all and len(hardcoded) > 12:
            print(f"     … ほか {len(hardcoded)-12}件（--all で全部）")
    if grays:
        if show_all:
            print(f"\n  ・ 無彩色 {len(grays)}件 — 白・黒・灰の直書き（影などは多くは許容）")
            for ln, lit, text in sorted(grays):
                print(f"     {path}:{ln}  {lit}")
        else:
            print(f"\n  ・ 無彩色の直書き {len(grays)}件（影など。--all で並べる）")

    if waived:
        print(f"\n  … わざとの直書き {len(waived)}件（「色ok:」の申告あり）")
        for ln, lit, why in sorted(waived):
            print(f"     {path}:{ln}  {lit} — {why}")

    if not leaks and not hardcoded:
        print("  ✓ 色漏れなし")
    return len(leaks)


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--all", action="store_true", help="無彩色・直書きも全部並べる")
    ap.add_argument("--parts", action="store_true", help="tn.css/tn.js の注入ブロックも見る")
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args()

    if a.help or not a.paths:
        print(__doc__)
        sys.exit(0)

    total = 0
    for p in a.paths:
        if not Path(p).exists():
            print(f"! {p}: ファイルがありません")
            continue
        total += scan(p, a.parts, a.all)

    print()
    if total:
        print(f"✗ 合計 {total}件の色漏れ。refero-styles で写した配色が崩れます。")
        sys.exit(1)
    print("✓ 色漏れはありません。")


if __name__ == "__main__":
    main()
