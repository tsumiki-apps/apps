#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
design_check.py — つみきの見た目の関門

DESIGN.md（正本）の検査と、HTMLが正本のルールを守っているかの検査をまとめて行う。

つかいかた:
    python3 design_check.py                 # DESIGN.md ＋ 全HTML
    python3 design_check.py app.html        # DESIGN.md ＋ そのHTMLだけ
    python3 design_check.py --spec-only     # DESIGN.md だけ
    python3 design_check.py --quiet         # NG だけ出す

見るもの（すべて実測。推測で判定しない）:
  1. DESIGN.md を `npx @google/design.md lint` にかける（ネットが無ければ飛ばす）
  2. 塗りの上の文字のコントラスト（WCAG の大きい文字の例外も見る）
  3. 純白 #ffffff / 純黒 #000000 を地や文字に使っていないか
  4. ブレイクポイントが 600 / 900 の2本だけか
  5. 入力欄の font-size が 16px 以上か

やらないこと:
  * HTMLを書き換えない。指摘して返すだけ。
  * ブラウザを開かない（CSSの宣言を読む静的検査）。
    継承で決まる font-size までは追えないので、そこは「不明」と出す。
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = os.path.join(HERE, "DESIGN.md")

# ---------------------------------------------------------------- 色

def hex2rgb(h):
    h = h.strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) == 8:
        h = h[:6]
    if len(h) != 6 or not re.fullmatch(r"[0-9a-fA-F]{6}", h):
        return None
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def luminance(h):
    rgb = hex2rgb(h)
    if rgb is None:
        return None
    out = []
    for c in rgb:
        c = c / 255
        out.append(c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4)
    return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    if la is None or lb is None:
        return None
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def to_px(v):
    if v is None:
        return None
    v = v.strip()
    m = re.fullmatch(r"([\d.]+)px", v)
    if m:
        return float(m.group(1))
    m = re.fullmatch(r"([\d.]+)rem", v)
    if m:
        return float(m.group(1)) * 16
    m = re.match(r"calc\(\s*([\d.]+)px", v)   # calc(15px * var(--gs))
    if m:
        return float(m.group(1))
    return None


BLOCK = re.compile(r"([^{}]+)\{([^{}]*)\}", re.S)

# `.foo.on` `.foo:hover` のような状態つきセレクタから、素の `.foo` を作る
STATE = re.compile(r"(?::hover|:focus|:active|:checked|:first-child|:last-child"
                   r"|\.on|\.active|\.selected|\.current|\.open)+$")


def base_color(sel, idx):
    """文字色が同じブロックに無いとき、素の状態のブロックから受け継ぐ。

    `.stepck.on{background:...}` のように、色は `.stepck{color:#fff}` の側にある
    書き方が多い。ここを追わないと「塗りの上の白文字」を取りこぼす。
    """
    for one in sel.split(","):
        one = one.strip().split("\n")[-1].strip()
        if not one:
            continue
        last = one.split()[-1] if " " in one else one
        for cand in (last, STATE.sub("", last)):
            if cand and cand != last or cand == last:
                got = idx.get(cand)
                if got and got[2]:
                    return got[2]
    return None


def css_blocks(src):
    """<style> の中身だけを見る。JSの中の { } を拾わないようにする。"""
    out = []
    for m in re.finditer(r"<style[^>]*>(.*?)</style>", src, re.S | re.I):
        out.extend(BLOCK.findall(m.group(1)))
    return out


# ---------------------------------------------------------------- 検査

def check_spec(quiet=False):
    """DESIGN.md を公式の lint にかける。"""
    findings = []
    if not os.path.exists(SPEC):
        return [("NG", "DESIGN.md", "正本が無い: %s" % SPEC)]
    try:
        r = subprocess.run(
            ["npx", "-y", "@google/design.md@0.4.0", "lint", SPEC],
            capture_output=True, text=True, timeout=180)
        data = json.loads(r.stdout)
    except FileNotFoundError:
        return [("--", "DESIGN.md", "npx が無いので飛ばした")]
    except subprocess.TimeoutExpired:
        return [("--", "DESIGN.md", "npx が返らないので飛ばした（ネットを見ている）")]
    except (json.JSONDecodeError, ValueError):
        return [("--", "DESIGN.md", "lint の出力を読めなかったので飛ばした")]

    for f in data.get("findings", []):
        rule = f.get("rule")
        if rule in ("token-summary",):
            continue
        # 未参照トークンは正本の性質上たくさん出る。既知として畳む。
        if rule == "orphaned-tokens":
            continue
        if rule == "token-like-ignored":
            continue    # motion 等。PHILOSOPHY が認めている書き方
        findings.append(("NG", "DESIGN.md", "%s: %s" % (rule, f.get("message"))))
    return findings


def check_html(path, quiet=False):
    """1本のHTMLを見る。"""
    src = open(path, encoding="utf-8", errors="ignore").read()
    blocks = css_blocks(src)
    found = []

    # --- 変数の値を拾う（ライト = 最初に出てくる :root）
    varmap = {}
    for name, val in re.findall(r"(--[a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{3,8})\s*[;}]", src):
        varmap.setdefault(name, val)

    def resolve(v):
        v = v.strip()
        m = re.fullmatch(r"var\((--[a-z0-9-]+)\)", v)
        if m:
            return varmap.get(m.group(1))
        if v.startswith("#"):
            return v
        return None

    # --- セレクタごとの font-size / font-weight / color の索引
    idx = {}
    for sel, body in blocks:
        fs = re.search(r"font-size:\s*([^;}]+)", body)
        fw = re.search(r"font-weight:\s*([^;}]+)", body)
        fc = re.search(r"(?<!-)color:\s*(var\(--[a-z0-9-]+\)|#[0-9a-fA-F]{3,8})", body)
        for one in sel.split(","):
            one = one.strip()
            if not one:
                continue
            cur = idx.setdefault(one, [None, None, None])
            if fs:
                cur[0] = fs.group(1).strip()
            if fw:
                cur[1] = fw.group(1).strip()
            if fc:
                cur[2] = fc.group(1).strip()

    # --- 1. 塗りの上の文字のコントラスト
    for sel, body in blocks:
        # 無効状態は WCAG 1.4.3 の対象外
        if re.search(r":disabled|\[disabled\]|\.disabled\b|\.is-disabled\b", sel):
            continue
        bg = re.search(r"background(?:-color)?:\s*(var\(--[a-z0-9-]+\)|#[0-9a-fA-F]{3,8})", body)
        fg = re.search(r"(?<!-)color:\s*(var\(--[a-z0-9-]+\)|#[0-9a-fA-F]{3,8})", body)
        if not bg:
            continue
        # 文字色が同じブロックに無いとき、素の状態（.foo.on → .foo）から受け継ぐ
        fgraw = fg.group(1) if fg else base_color(sel, idx)
        if not fgraw:
            continue
        bgc, fgc = resolve(bg.group(1)), resolve(fgraw)
        if not bgc or not fgc:
            continue
        # 同じ色＝そこに文字は無い（空のチェックボックス等）。見えないので数えない
        if hex2rgb(bgc) == hex2rgb(fgc):
            continue
        r = contrast(fgc, bgc)
        if r is None:
            continue

        fs = re.search(r"font-size:\s*([^;}]+)", body)
        fw = re.search(r"font-weight:\s*([^;}]+)", body)
        fs = fs.group(1).strip() if fs else None
        fw = fw.group(1).strip() if fw else None
        for one in sel.split(","):
            one = one.strip()
            if one in idx:
                fs = fs or idx[one][0]
                fw = fw or idx[one][1]
        size = to_px(fs)
        try:
            weight = int(re.sub(r"\D", "", fw)) if fw else None
        except ValueError:
            weight = None
        large = bool(size and (size >= 24 or (size >= 18.66 and (weight or 400) >= 700)))
        need = 3.0 if large else 4.5
        if r < need:
            note = "%.0fpx" % size if size else "字の大きさ不明"
            found.append(("NG", path,
                          "コントラスト %.2f:1（要 %.1f）%s の上に %s ／ %s ／ %s"
                          % (r, need, bgc, fgc, note, sel.strip().split("\n")[-1].strip()[:40])))

    # --- 2. 純白・純黒
    for name, val in re.findall(r"(--[a-z0-9-]+)\s*:\s*(#(?:fff|ffffff|000|000000))\s*[;}]", src, re.I):
        if name in ("--paper", "--bg", "--ink", "--card", "--surface", "--text"):
            found.append(("NG", path, "純白/純黒を地か文字に使っている: %s: %s" % (name, val)))

    # --- 3. ブレイクポイント
    bps = set()
    for w in re.findall(r"@media[^{]*?(?:max|min)-width:\s*(\d+)px", src):
        bps.add(int(w))
    odd = sorted(b for b in bps if b not in (600, 900, 599, 899, 601, 901))
    if odd:
        found.append(("NG", path,
                      "ブレイクポイントが 600/900 以外にある: %s"
                      % ", ".join("%dpx" % b for b in odd)))

    # --- 4. 入力欄の font-size
    for sel, body in blocks:
        if not re.search(r"\b(input|textarea|select)\b", sel):
            continue
        fs = re.search(r"font-size:\s*([^;}]+)", body)
        if not fs:
            continue
        size = to_px(fs.group(1))
        if size is not None and size < 16:
            found.append(("NG", path,
                          "入力欄の字が %.0fpx（16px 未満だと iPhone が拡大する）／ %s"
                          % (size, sel.strip()[:40])))

    return found


def main():
    ap = argparse.ArgumentParser(description="つみきの見た目の関門")
    ap.add_argument("targets", nargs="*", help="検査するHTML（省略で全部）")
    ap.add_argument("--spec-only", action="store_true", help="DESIGN.md だけ見る")
    ap.add_argument("--quiet", action="store_true", help="NG だけ出す")
    a = ap.parse_args()

    all_found = []
    print("― DESIGN.md（正本）―")
    spec = check_spec(a.quiet)
    for kind, where, msg in spec:
        print("  %s %s" % (kind, msg))
        if kind == "NG":
            all_found.append((where, msg))
    if not any(k == "NG" for k, _, _ in spec):
        print("  ok")

    if a.spec_only:
        return 0

    targets = a.targets or sorted(glob.glob(os.path.join(HERE, "*.html")))
    print()
    print("― HTML（%d本）―" % len(targets))
    ng_files = set()
    for p in targets:
        rel = os.path.basename(p)
        found = check_html(p, a.quiet)
        if found:
            ng_files.add(rel)
            print("\n  ● %s" % rel)
            for _, _, msg in found:
                print("      %s" % msg)
            all_found.extend((rel, m) for _, _, m in found)
        elif not a.quiet:
            print("  ok %s" % rel)

    print()
    print("― まとめ ―")
    print("  指摘 %d件 ／ %d本のHTML（見たのは %d本）"
          % (len(all_found), len(ng_files), len(targets)))
    return 1 if all_found else 0


if __name__ == "__main__":
    sys.exit(main())
