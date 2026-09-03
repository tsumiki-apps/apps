#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
refero_tokens.py — refero styles の designSystem を「つみき」のCSS変数に写す

つかいかた（人が選んだURLを1本だけ渡す）:
    python3 refero_tokens.py https://styles.refero.design/style/<UUID> --name notion
    python3 refero_tokens.py 保存した.html --name notion
    python3 refero_tokens.py designSystem.json --name notion
    ... --memo    で ~/制作物/design_refs/<name>.design.md も書き出す
    ... --raw X.json  で designSystem の生JSONを保存

やらないこと（意図的に実装していない）:
  * 一括取得モードは無い。URLは1回に1本だけ。カタログのミラーは作らない。
  * /api/ は叩かない（styles.refero.design の robots.txt が Disallow）。
  * つみきに無い変数名は発明しない。対応表に無いものは出力しない。
  * フォント本体・ロゴ・画像は取らない。借りるのは数値と方針だけ。
  * Zen Maru Gothic（ブランド書体）は上書きしない。--sans/--serif は出力しない。

出力される変数（これで全部）:
  --paper --bg --card --surface --surface-2
  --ink --ink-mid --ink-soft --sub --muted
  --line --line-2 --hair
  --accent --accent-2 --accent-wash --accent-soft
  --good --warn --good-wash --warn-wash（refero側で見つかったときだけ）
  --shadow --radius
"""

import argparse
import colorsys
import datetime
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(HERE, "design_refs", "_cache")
REFS_DIR = os.path.join(HERE, "design_refs")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36")
STYLE_URL = re.compile(
    r"^https://styles\.refero\.design/style/"
    r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/?$")


# ---------------------------------------------------------------- 色のたすうけ

def hex2rgb(h):
    h = h.strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) == 8:          # #rrggbbaa は透明度を捨てる
        h = h[:6]
    if len(h) != 6 or not re.fullmatch(r"[0-9a-fA-F]{6}", h):
        raise ValueError("hexではない: %r" % h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def rgb2hex(rgb):
    return "#%02x%02x%02x" % tuple(max(0, min(255, int(round(c)))) for c in rgb)


def _lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(h):
    r, g, b = hex2rgb(h)
    return 0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b)


def contrast(fg, bg):
    """WCAG のコントラスト比（1.0〜21.0）"""
    a, b = luminance(fg), luminance(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def to_hls(h):
    r, g, b = [c / 255.0 for c in hex2rgb(h)]
    return colorsys.rgb_to_hls(r, g, b)      # (h, l, s)


def from_hls(hh, ll, ss):
    r, g, b = colorsys.hls_to_rgb(hh, max(0.0, min(1.0, ll)), max(0.0, min(1.0, ss)))
    return rgb2hex((r * 255, g * 255, b * 255))


def set_light(h, ll):
    hh, _, ss = to_hls(h)
    return from_hls(hh, ll, ss)


def mix(a, b, t):
    """a を b に t（0〜1）だけ寄せる"""
    ra, rb = hex2rgb(a), hex2rgb(b)
    return rgb2hex([ra[i] + (rb[i] - ra[i]) * t for i in range(3)])


def ensure_contrast(fg, bg, target=4.5, step=0.02):
    """fg を bg から遠ざけて target 以上にする。戻り値 (hex, 直したか)"""
    if contrast(fg, bg) >= target:
        return fg, False
    darker = luminance(bg) > 0.35        # 明るい地なら文字を暗く、暗い地なら明るく
    hh, ll, ss = to_hls(fg)
    for _ in range(60):
        ll = ll - step if darker else ll + step
        if ll <= 0 or ll >= 1:
            break
        cand = from_hls(hh, ll, ss)
        if contrast(cand, bg) >= target:
            return cand, True
    return ("#000000" if darker else "#ffffff"), True


def is_grayish(h, sat=0.18):
    return to_hls(h)[2] <= sat


# ------------------------------------------------------------------ 取得と抽出

def fetch_html(url):
    """人が選んだURLを1本だけ取りに行く。一括取得の口は用意しない。"""
    m = STYLE_URL.match(url.strip())
    if not m:
        sys.exit("エラー: https://styles.refero.design/style/<UUID> の形だけ受け付けます。\n"
                 "       （/api/ は robots.txt が Disallow。一覧の一括取得もしません）")
    uuid = m.group(1).lower()
    os.makedirs(CACHE_DIR, exist_ok=True)
    cached = os.path.join(CACHE_DIR, uuid + ".html")
    if os.path.exists(cached) and os.path.getsize(cached) > 10000:
        sys.stderr.write("・取得ずみの控えを使います: %s\n" % cached)
        return open(cached, encoding="utf-8", errors="replace").read(), url
    sys.stderr.write("・取りに行きます（1本だけ）: %s\n" % url)
    time.sleep(1.0)                       # 連打しない
    p = subprocess.run(["curl", "-s", "-L", "--max-time", "40", "-A", UA, url],
                       capture_output=True)
    html = p.stdout.decode("utf-8", "replace")
    if p.returncode != 0 or len(html) < 5000:
        sys.exit("エラー: 取得できませんでした（curl rc=%s / %d bytes）。"
                 "取れなかったので、ここで止まります。" % (p.returncode, len(html)))
    open(cached, "w", encoding="utf-8").write(html)
    return html, url


def extract_design_system(html):
    """HTML内の Next.js ペイロードから designSystem を切り出す"""
    s = html.replace('\\"', '"').replace("\\\\", "\\")
    i = s.find('"designSystem":')
    if i < 0:
        sys.exit("エラー: designSystem が見つかりません。ページの作りが変わったかもしれません。"
                 "（取れなかった、と正直に報告してください）")
    start = s.find("{", i)
    depth = 0
    end = -1
    for j in range(start, len(s)):
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                end = j + 1
                break
    if end < 0:
        sys.exit("エラー: designSystem の括弧が閉じていません。")
    return json.loads(s[start:end])


# ------------------------------------------------------------------ 役割の判定

ROLE_RULES = [
    # (バケツ名, 加点キーワード)
    ("border", ["border", "divider", "hairline", "rule line", "separator",
                "stroke", "outline", "keyline", "table line"]),
    ("primary", ["primary text", "headline", "heading", "display type", "title",
                 "primary ink", "main text", "body copy and headings"]),
    ("body", ["body text", "paragraph", "body copy", "running text"]),
    ("muted", ["muted", "secondary text", "helper", "caption", "placeholder",
               "tertiary", "meta text", "label text", "subdued", "de-emphasi",
               "timestamp", "footnote"]),
    ("good", ["success", "positive", "confirmation", "healthy", "gain", "growth"]),
    ("warn", ["warning", "caution", "alert", "error", "danger", "destructive",
              "negative", "loss"]),
]


def bucket_of(role_text):
    t = (role_text or "").lower()
    best, score = None, 0
    for name, words in ROLE_RULES:
        s = sum(1 for w in words if w in t)
        if s > score:
            best, score = name, s
    return best


# ------------------------------------------------------------------ 変換の本体

class Mapper:
    def __init__(self, ds, src_url, name):
        self.ds = ds
        self.url = src_url
        self.name = name
        self.notes = []          # 出力CSSに残すコメント
        self.unassigned = []     # 使わなかった色
        self.adjust = []         # コントラストで直した記録
        self.warnings = []       # 人が見て判断すべきこと

    # -- 素材の取り出し ------------------------------------------------
    def surfaces(self):
        out = {}
        for s in self.ds.get("surfaces") or []:
            try:
                hexv = rgb2hex(hex2rgb(s.get("hex", "")))
            except Exception:
                continue
            lv = s.get("level")
            if isinstance(lv, int) and lv not in out:
                out[lv] = (hexv, s.get("name", ""), s.get("purpose", ""))
        return out

    def colors(self):
        out = []
        for c in self.ds.get("colors") or []:
            try:
                hexv = rgb2hex(hex2rgb(c.get("hex", "")))
            except Exception:
                continue
            out.append({
                "hex": hexv,
                "name": c.get("name", ""),
                "role": c.get("role", ""),
                "group": (c.get("group") or "").lower(),
                "bucket": bucket_of(c.get("role", "")),
            })
        return out

    # -- ライトの一式 --------------------------------------------------
    def build_light(self):
        surf = self.surfaces()
        cols = self.colors()
        used = set()

        def take(c):
            used.add(c["hex"] + c["name"])
            return c["hex"]

        v = {}

        # 面（surfaces level 0/1/2）。無ければ neutral の明るい順で補う。
        neutrals = sorted([c for c in cols if c["group"] == "neutral"],
                          key=lambda c: -luminance(c["hex"]))
        light_pool = [c["hex"] for c in neutrals if luminance(c["hex"]) > 0.55]

        def surface_at(level, fallback_idx, label):
            if level in surf:
                hexv, nm, _ = surf[level]
                self.notes.append("%s = surfaces[level %d] %s %s" % (label, level, hexv, nm))
                return hexv
            if fallback_idx < len(light_pool):
                self.warnings.append("surfaces に level %d が無く、明るい neutral で代用した" % level)
                return light_pool[fallback_idx]
            self.warnings.append("surfaces に level %d が無く、導出した" % level)
            return None

        paper = surface_at(0, 0, "--paper/--bg")
        card = surface_at(1, 1, "--card/--surface")
        s2 = surface_at(2, 2, "--surface-2")

        # 暗いテーマのサイトだと surfaces がそのまま暗い。ライトの器としては使えない。
        self.src_theme = (self.ds.get("theme") or "").lower()
        if paper is None:
            paper = "#ffffff"
        if card is None:
            card = mix(paper, "#ffffff", 0.6) if luminance(paper) < 0.9 else "#ffffff"
            self.notes.append("--card/--surface = 導出（paper を白へ寄せた）")
        if s2 is None:
            s2 = mix(card, "#000000", 0.045)
            self.notes.append("--surface-2 = 導出（card をわずかに沈めた）")
        # level 2 が原色のカード（Notion の黄など）だと面として使えない
        if not is_grayish(s2, 0.30) and is_grayish(paper, 0.30):
            self.warnings.append("surfaces level 2 が有彩色（%s）なので、面としては使わず導出値にした" % s2)
            self.unassigned.append((s2, surf.get(2, ("", "", ""))[1], "surfaces level 2（有彩色のため面に不採用）"))
            s2 = mix(card, "#000000", 0.045)

        v["--paper"] = v["--bg"] = paper
        v["--card"] = v["--surface"] = card
        v["--surface-2"] = s2

        # 文字色。paper と card の暗いほうを地とみなして測る。
        ground = paper if luminance(paper) <= luminance(card) else card

        prim = [c for c in cols if c["bucket"] == "primary"]
        body = [c for c in cols if c["bucket"] == "body"]
        mut = [c for c in cols if c["bucket"] == "muted"]
        dark_neutrals = sorted([c for c in cols if c["group"] == "neutral"
                                and contrast(c["hex"], ground) >= 3.0],
                               key=lambda c: -contrast(c["hex"], ground))

        def pick(cands, fallback_rank):
            for c in cands:
                if c["hex"] + c["name"] not in used:
                    return c
            if fallback_rank < len(dark_neutrals):
                return dark_neutrals[fallback_rank]
            return None

        c_ink = pick(sorted(prim, key=lambda c: -contrast(c["hex"], ground)), 0)
        if c_ink is None:
            v["--ink"] = "#111111"
            self.warnings.append("Primary text にあたる色が無く、#111111 を置いた")
        else:
            v["--ink"] = take(c_ink)
            self.notes.append('--ink = %s %s ← "%s"' % (c_ink["hex"], c_ink["name"], c_ink["role"][:70]))

        # 本文・補助。body → muted の順に、コントラストの高い順で割り当てる。
        ramp = [c for c in sorted(body + mut, key=lambda c: -contrast(c["hex"], ground))
                if c["hex"] + c["name"] not in used]
        slots = ["--ink-mid", "--ink-soft", "--sub", "--muted"]
        for i, slot in enumerate(slots):
            if i < len(ramp):
                c = ramp[i]
                v[slot] = take(c)
                self.notes.append('%s = %s %s ← "%s"' % (slot, c["hex"], c["name"], c["role"][:60]))
            else:
                # 足りない分は ink を地へ寄せて作る
                t = [0.22, 0.36, 0.34, 0.46][i]
                v[slot] = mix(v["--ink"], ground, t)
                self.notes.append("%s = 導出（ink を地へ %d%% 寄せた）" % (slot, int(t * 100)))

        # 罫線。有彩色の「アクセント罫」は全部の罫線に塗ると事故るので採らない。
        border_cands = [c for c in cols if c["bucket"] == "border"
                        and c["hex"] + c["name"] not in used]
        for c in border_cands:
            if not is_grayish(c["hex"], 0.25):
                self.warnings.append(
                    "%s %s は罫線と書いてあるが有彩色。--line には入れず未割当にした" % (c["hex"], c["name"]))
        borders = sorted([c for c in border_cands if is_grayish(c["hex"], 0.25)],
                         key=lambda c: contrast(c["hex"], ground))   # 薄い順
        # 薄い順に hair → line → line-2 を当てる
        if len(borders) >= 3:
            picks = {"--hair": borders[0], "--line": borders[1], "--line-2": borders[2]}
        elif len(borders) == 2:
            picks = {"--line": borders[0], "--line-2": borders[1]}
        elif len(borders) == 1:
            picks = {"--line": borders[0]}
        else:
            picks = {}
        for slot in ("--line", "--line-2", "--hair"):
            if slot in picks:
                c = picks[slot]
                v[slot] = take(c)
                self.notes.append('%s = %s %s ← "%s"' % (slot, c["hex"], c["name"], c["role"][:60]))
        base_line = v.get("--line") or mix(paper, v["--ink"], 0.12)
        if "--line" not in v:
            v["--line"] = base_line
            self.notes.append("--line = 導出（paper に ink を 12% 混ぜた）")
        if "--line-2" not in v:
            v["--line-2"] = mix(base_line, v["--ink"], 0.30)
            self.notes.append("--line-2 = 導出（line を ink へ 30% 寄せた）")
        if "--hair" not in v:
            v["--hair"] = mix(base_line, paper, 0.55)
            self.notes.append("--hair = 導出（line を paper へ 55% 寄せた）")

        # ブランド色
        brands = [c for c in cols if c["group"] == "brand" and c["hex"] + c["name"] not in used]
        if not brands:
            brands = [c for c in cols if c["group"] == "accent" and not is_grayish(c["hex"])
                      and c["hex"] + c["name"] not in used]
            if brands:
                self.warnings.append("group:brand が無かったので accent の有彩色を --accent に使った")
        if brands:
            v["--accent"] = take(brands[0])
            self.notes.append('--accent = %s %s ← "%s"' % (brands[0]["hex"], brands[0]["name"], brands[0]["role"][:60]))
        else:
            v["--accent"] = v["--ink"]
            self.warnings.append("ブランド色が見つからず、--accent に ink を置いた（要・手当て）")

        v["--accent-wash"] = mix(v["--accent"], paper, 0.92)
        v["--accent-soft"] = mix(v["--accent"], paper, 0.80)
        self.notes.append("--accent-wash / --accent-soft = 導出（accent を paper に 92% / 80% 寄せた）")

        # --accent-2 は つみきでは 83箇所中79が color:（＝文字色）。
        # 「別の色相」ではなく「accent の濃い方」を入れる。地は accent-wash（いちばん危ない側）。
        v["--accent-2"] = self.pick_accent2(cols, used, v["--accent"], v["--accent-wash"], take)

        # 成否の色。refero 側に無いことが多い。無ければ出力しない＝既存値を残す。
        for slot, bucket in (("--good", "good"), ("--warn", "warn")):
            got = [c for c in cols if c["bucket"] == bucket and c["hex"] + c["name"] not in used]
            if got:
                v[slot] = take(got[0])
                v[slot + "-wash"] = mix(got[0]["hex"], paper, 0.88)
                self.notes.append("%s = %s %s（-wash は導出）" % (slot, got[0]["hex"], got[0]["name"]))
            else:
                self.notes.append("%s / %s-wash = refero側に無し。既存値をそのまま残す（出力しない）" % (slot, slot))

        # 影と角丸
        elev = self.ds.get("elevation") or []
        card_e = next((e for e in elev if "card" in (e.get("element") or "").lower()), None)
        if card_e is None and elev:
            card_e = elev[0]
            self.warnings.append("elevation に Card が無く、先頭の「%s」を --shadow に使った" % elev[0].get("element"))
        if card_e and card_e.get("style"):
            v["--shadow"] = card_e["style"]
            self.notes.append("--shadow = elevation「%s」" % card_e.get("element"))
        else:
            self.notes.append("--shadow = refero側に無し。既存値をそのまま残す（出力しない）")

        radius = ((self.ds.get("spacing") or {}).get("radius") or {})
        if radius.get("cards"):
            v["--radius"] = radius["cards"]
            self.notes.append("--radius = spacing.radius.cards（%s）" % radius["cards"])
        else:
            self.notes.append("--radius = refero側に無し。既存値をそのまま残す（出力しない）")

        # コントラストを実測して直す（読みやすさを refero の見た目より優先）
        for slot in ["--ink", "--ink-mid", "--ink-soft", "--sub", "--muted"]:
            if slot not in v:
                continue
            worst_bg = paper if luminance(paper) <= luminance(card) else card
            fixed, changed = ensure_contrast(v[slot], worst_bg, 4.5)
            if changed:
                self.adjust.append((slot, v[slot], fixed,
                                    round(contrast(v[slot], worst_bg), 2),
                                    round(contrast(fixed, worst_bg), 2)))
                v[slot] = fixed

        # --accent は つみきでは文字色としても163箇所使われている。
        # 読みやすさを refero の見た目より優先し、paper 上で 4.5:1 まで濃くする。
        if "--accent" in v:
            brand_hex = v["--accent"]
            fixed, changed = ensure_contrast(brand_hex, paper, 4.5)
            if changed:
                self.adjust.append(("--accent", brand_hex, fixed,
                                    round(contrast(brand_hex, paper), 2),
                                    round(contrast(fixed, paper), 2)))
                v["--accent"] = fixed
                self.notes.append("--accent = %s（もとのブランド色 %s は paper 上 %.2f:1 で足りない）"
                                  % (fixed, brand_hex, contrast(brand_hex, paper)))
                # 濃くした accent に合わせて wash / soft / accent-2 を作り直す
                v["--accent-wash"] = mix(v["--accent"], paper, 0.92)
                v["--accent-soft"] = mix(v["--accent"], paper, 0.80)
                v["--accent-2"] = ensure_contrast(v["--accent"], v["--accent-wash"], 4.5)[0]

        # 使わなかった色
        for c in cols:
            if c["hex"] + c["name"] not in used:
                self.unassigned.append((c["hex"], c["name"], c["role"]))

        self.ground = ground
        return v

    def on_accent_note(self, accent, ground, mode):
        """accent を塗りに使ったとき、その上に置ける文字色を測って伝える"""
        w = contrast("#ffffff", accent)
        b = contrast(ground, accent)
        if w >= 4.5:
            return "%s: --accent %s の塗りの上は白文字でよい（%.2f:1）" % (mode, accent, w)
        if b >= 4.5:
            return ("%s: --accent %s の塗りの上に**白文字は %.2f:1 で足りない**。"
                    "濃い文字（--paper %s なら %.2f:1）に切り替えること" % (mode, accent, w, ground, b))
        return ("%s: --accent %s は塗りに使うと白（%.2f:1）も濃い文字（%.2f:1）も 4.5 に届かない。"
                "ボタン地には使わないこと" % (mode, accent, w, b))

    def pick_accent2(self, cols, used, accent, wash, take):
        """--accent-2（ほぼ文字色）。accent と同系で、wash の上で 4.5:1 を満たす濃い色。"""
        ah = to_hls(accent)[0]
        same_family = []
        for c in cols:
            if c["hex"] + c["name"] in used or c["group"] not in ("brand", "accent"):
                continue
            if is_grayish(c["hex"]):
                continue
            dh = abs(to_hls(c["hex"])[0] - ah)
            dh = min(dh, 1.0 - dh)
            if dh <= 0.08 and contrast(c["hex"], wash) >= 4.5:
                same_family.append(c)
        if same_family:
            same_family.sort(key=lambda c: -contrast(c["hex"], wash))
            c = same_family[0]
            self.notes.append('--accent-2 = %s %s（accent と同系・wash上 %.2f:1）'
                              % (c["hex"], c["name"], contrast(c["hex"], wash)))
            return take(c)
        fixed, changed = ensure_contrast(accent, wash, 4.5)
        self.notes.append("--accent-2 = 導出（accent を wash 上 4.5:1 まで濃くした: %s → %s）"
                          % (accent, fixed) if changed else
                          "--accent-2 = accent と同値（そのままで wash 上 4.5:1 を満たす）")
        return fixed

    # -- ダークの一式（ライトから導出）----------------------------------
    def build_dark(self, light):
        # 地の色相は paper から取る（ink が真っ黒だと色相が無意味になるため）
        hue = to_hls(light["--paper"])[0]
        sat = min(0.06, to_hls(light["--paper"])[2])
        d = {}
        d["--paper"] = d["--bg"] = from_hls(hue, 0.07, sat)
        d["--card"] = d["--surface"] = from_hls(hue, 0.115, sat)
        d["--surface-2"] = from_hls(hue, 0.16, sat)
        bg = d["--paper"]
        ink_h, _, ink_s = to_hls(light["--ink"])
        if ink_s < 0.05:            # 真っ黒・真っ白は色相を持たない
            ink_h = hue
        d["--ink"] = from_hls(ink_h, 0.93, min(0.06, ink_s))
        for slot, ll in (("--ink-mid", 0.76), ("--ink-soft", 0.68), ("--sub", 0.70), ("--muted", 0.62)):
            if slot in light:
                hh, _, ss = to_hls(light[slot])
                d[slot] = from_hls(hh, ll, min(ss, 0.14))
        for slot, ll in (("--line", 0.24), ("--line-2", 0.30), ("--hair", 0.19)):
            if slot in light:
                hh, _, ss = to_hls(light[slot])
                d[slot] = from_hls(hh, ll, min(ss, 0.12))
        # ブランド色は暗い地の上で沈むので、必要なだけ持ち上げる
        if "--accent" in light:
            fixed, changed = ensure_contrast(light["--accent"], bg, 4.5)
            d["--accent"] = fixed
            if changed:
                self.adjust.append(("--accent（ダーク）", light["--accent"], fixed,
                                    round(contrast(light["--accent"], bg), 2),
                                    round(contrast(fixed, bg), 2)))
            d["--accent-wash"] = mix(d["--accent"], d["--paper"], 0.86)
            d["--accent-soft"] = mix(d["--accent"], d["--paper"], 0.72)
            # ダークでも --accent-2 は文字色。暗い wash の上で 4.5:1 まで明るくする。
            d["--accent-2"] = ensure_contrast(d["--accent"], d["--accent-wash"], 4.5)[0]

        for slot in ("--good", "--warn"):
            if slot in light:
                d[slot] = ensure_contrast(light[slot], bg, 4.5)[0]
                d[slot + "-wash"] = mix(d[slot], d["--paper"], 0.84)
        if "--shadow" in light:
            d["--shadow"] = "0 1px 2px rgba(0,0,0,.5), 0 8px 24px rgba(0,0,0,.45)"
        if "--radius" in light:
            d["--radius"] = light["--radius"]
        # ダークでも本文の 4.5:1 を守る
        for slot in ["--ink", "--ink-mid", "--ink-soft", "--sub", "--muted"]:
            if slot in d:
                worst = d["--paper"] if luminance(d["--paper"]) >= luminance(d["--card"]) else d["--card"]
                fixed, changed = ensure_contrast(d[slot], worst, 4.5)
                if changed:
                    self.adjust.append((slot + "（ダーク）", d[slot], fixed,
                                        round(contrast(d[slot], worst), 2),
                                        round(contrast(fixed, worst), 2)))
                    d[slot] = fixed
        return d


    # -- 逆側（暗い一式からライトを起こす）------------------------------
    def build_light_from_dark(self, dark):
        hue = to_hls(dark["--paper"])[0]
        sat = min(0.05, to_hls(dark["--paper"])[2])
        v = {}
        v["--paper"] = v["--bg"] = from_hls(hue, 0.975, sat)
        v["--card"] = v["--surface"] = "#ffffff"
        v["--surface-2"] = from_hls(hue, 0.955, sat)
        bg = v["--paper"]
        ink_h, _, ink_s = to_hls(dark["--ink"])
        if ink_s < 0.05:
            ink_h = hue
        v["--ink"] = from_hls(ink_h, 0.09, min(0.06, ink_s))
        for slot, ll in (("--ink-mid", 0.34), ("--ink-soft", 0.40),
                         ("--sub", 0.38), ("--muted", 0.44)):
            if slot in dark:
                hh, _, ss = to_hls(dark[slot])
                v[slot] = from_hls(hh, ll, min(ss, 0.14))
        for slot, ll in (("--line", 0.88), ("--line-2", 0.82), ("--hair", 0.93)):
            if slot in dark:
                hh, _, ss = to_hls(dark[slot])
                v[slot] = from_hls(hh, ll, min(ss, 0.10))
        if "--accent" in dark:
            fixed, changed = ensure_contrast(dark["--accent"], bg, 4.5)
            v["--accent"] = fixed
            if changed:
                self.adjust.append(("--accent（ライト・導出）", dark["--accent"], fixed,
                                    round(contrast(dark["--accent"], bg), 2),
                                    round(contrast(fixed, bg), 2)))
            v["--accent-wash"] = mix(v["--accent"], bg, 0.92)
            v["--accent-soft"] = mix(v["--accent"], bg, 0.80)
            v["--accent-2"] = ensure_contrast(v["--accent"], v["--accent-wash"], 4.5)[0]
        for slot in ("--good", "--warn"):
            if slot in dark:
                v[slot] = ensure_contrast(dark[slot], bg, 4.5)[0]
                v[slot + "-wash"] = mix(v[slot], bg, 0.88)
        if "--shadow" in dark:
            v["--shadow"] = dark["--shadow"]
        if "--radius" in dark:
            v["--radius"] = dark["--radius"]
        for slot in ["--ink", "--ink-mid", "--ink-soft", "--sub", "--muted"]:
            if slot in v:
                worst = bg if luminance(bg) <= luminance(v["--card"]) else v["--card"]
                fixed, changed = ensure_contrast(v[slot], worst, 4.5)
                if changed:
                    self.adjust.append((slot + "（ライト・導出）", v[slot], fixed,
                                        round(contrast(v[slot], worst), 2),
                                        round(contrast(fixed, worst), 2)))
                    v[slot] = fixed
        return v


ORDER = ["--paper", "--bg", "--card", "--surface", "--surface-2",
         "--ink", "--ink-mid", "--ink-soft", "--sub", "--muted",
         "--line", "--line-2", "--hair",
         "--accent", "--accent-2", "--accent-wash", "--accent-soft",
         "--good", "--good-wash", "--warn", "--warn-wash",
         "--shadow", "--radius"]

GROUPS = [("面", ["--paper", "--bg", "--card", "--surface", "--surface-2"]),
          ("文字", ["--ink", "--ink-mid", "--ink-soft", "--sub", "--muted"]),
          ("罫線", ["--line", "--line-2", "--hair"]),
          ("強調", ["--accent", "--accent-2", "--accent-wash", "--accent-soft"]),
          ("成否", ["--good", "--good-wash", "--warn", "--warn-wash"]),
          ("その他", ["--shadow", "--radius"])]


def render_block(vals, indent):
    lines = []
    for label, slots in GROUPS:
        got = [s for s in slots if s in vals]
        if not got:
            continue
        lines.append("%s/* %s */" % (indent, label))
        for s in got:
            lines.append("%s%s:%s;" % (indent, s, vals[s]))
    return "\n".join(lines)


def render_css(m, light, dark, url, today):
    L = []
    L.append("/* ============================================================")
    L.append("   refero styles から写した見た目（%s）" % m.name)
    L.append("   出典: %s" % url)
    L.append("   取得日: %s ／ 生成: refero_tokens.py" % today)
    L.append("   northStar: %s" % (m.ds.get("northStar") or "—"))
    L.append("   もとのサイトの基調: %s" % (m.ds.get("theme") or "—"))
    L.append("   ※ 借りたのは数値と方針だけ。フォント本体・ロゴ・画像は取っていない。")
    L.append("   ※ 書体は上書きしない（--sans/--serif は出力していない）。")
    L.append("      Zen Maru Gothic はそのまま。借りてよいのはサイズ階層・ウェイト・行間・字間だけ。")
    L.append("   ============================================================ */")
    L.append(":root{")
    L.append(render_block(light, "  "))
    L.append("}")
    L.append("")
    if (m.ds.get("theme") or "").lower() == "dark":
        L.append("/* もとが dark 基調のサイト。:root（ライト）のほうが導出値。目視で確認すること。 */")
    else:
        L.append("/* ダークは導出（もとはライト基調のサイト）。目視で確認すること。 */")
    L.append("@media (prefers-color-scheme: dark){")
    L.append('  :root:where(:not([data-theme="light"])){')
    L.append(render_block(dark, "    "))
    L.append("  }")
    L.append("}")
    L.append('html[data-theme="dark"]{')
    L.append(render_block(dark, "  "))
    L.append("}")
    L.append("")
    L.append("/* --- どう写したか -------------------------------------------- */")
    for n in m.notes:
        L.append("/* %s */" % n)
    if m.adjust:
        L.append("/* --- 読みやすさのために直した色（4.5:1 を満たすまで） --------- */")
        for slot, before, after, cb, ca in m.adjust:
            L.append("/* %s: %s (%.2f:1) → %s (%.2f:1) */" % (slot, before, cb, after, ca))
    if m.warnings:
        L.append("/* --- 人が見て決めること -------------------------------------- */")
        for w in m.warnings:
            L.append("/* ! %s */" % w)
    if m.unassigned:
        L.append("/* --- 未割当（捨てずに残す） ---------------------------------- */")
        for hexv, nm, role in m.unassigned:
            L.append("/* 未割当: %s %s — %s */" % (hexv, nm, (role or "")[:90]))
    return "\n".join(L) + "\n"


def render_memo(m, light, dark, url, today):
    ds = m.ds
    sp = ds.get("spacing") or {}
    rad = sp.get("radius") or {}
    L = []
    L.append("# %s（refero styles の参照メモ）" % m.name)
    L.append("")
    L.append("- **出典URL**: %s" % url)
    L.append("- **取得日**: %s" % today)
    L.append("- **northStar**: %s" % (ds.get("northStar") or "—"))
    L.append("- **基調**: %s ／ 業種: %s" % (ds.get("theme") or "—", ds.get("industry") or "—"))
    L.append("")
    L.append("> ロゴ・画像・フォント本体は取っていない。借りるのは数値と方針だけ。")
    L.append("")
    L.append("## 一言でいうと")
    L.append("")
    L.append((ds.get("description") or "—").strip())
    L.append("")
    L.append("## つみきの変数に写した結果（ライト）")
    L.append("")
    L.append("| 変数 | 値 |")
    L.append("|---|---|")
    for s in ORDER:
        if s in light:
            L.append("| `%s` | `%s` |" % (s, light[s]))
    L.append("")
    L.append("## 余白と角丸（そのままは使わない。8幅ルールが優先）")
    L.append("")
    L.append("| 項目 | 値 |")
    L.append("|---|---|")
    for k, label in (("baseUnit", "基本単位"), ("elementGap", "要素の間"),
                     ("sectionGap", "節の間"), ("cardPadding", "カード内"),
                     ("pageMaxWidth", "最大幅")):
        if sp.get(k):
            L.append("| %s | `%s` |" % (label, sp[k]))
    for k, val in rad.items():
        L.append("| 角丸 %s | `%s` |" % (k, val))
    L.append("")
    L.append("## 文字（**本文には使わない**。借りるのは階層だけ）")
    L.append("")
    for t in (ds.get("typography") or []):
        L.append("- **%s**（weight %s ／ 代替: %s）" % (t.get("family", "—"),
                                                    t.get("weight", "—"),
                                                    t.get("substitute", "—")))
        if t.get("sizes"):
            L.append("  - サイズ: %s" % t["sizes"])
        if t.get("lineHeight"):
            L.append("  - 行間: %s" % t["lineHeight"])
        if t.get("letterSpacing"):
            L.append("  - 字間: %s" % t["letterSpacing"])
        if t.get("role"):
            L.append("  - 役目: %s" % t["role"])
    L.append("")
    L.append("> 日本語グリフが無い欧文なので、**本文フォントには採用しない**。")
    L.append("> ブランド書体 Zen Maru Gothic は上書きしない。数字・英字ラベルだけ、")
    L.append("> `substitute` を見て Google Fonts で置き換えてよい。")
    L.append("")
    L.append("## 影")
    L.append("")
    for e in (ds.get("elevation") or []):
        L.append("- **%s**: `%s`" % (e.get("element", "—"), e.get("style", "—")))
    if ds.get("elevationPhilosophy"):
        L.append("")
        L.append("考え方: %s" % ds["elevationPhilosophy"])
    L.append("")
    L.append("## やること / やらないこと（原文）")
    L.append("")
    L.append("**Do**")
    L.append("")
    for d in (ds.get("dos") or []):
        L.append("- %s" % (d if isinstance(d, str) else json.dumps(d, ensure_ascii=False)))
    L.append("")
    L.append("**Don't**")
    L.append("")
    for d in (ds.get("donts") or []):
        L.append("- %s" % (d if isinstance(d, str) else json.dumps(d, ensure_ascii=False)))
    L.append("")
    L.append("## 日本語要約（Do / Don't）")
    L.append("")
    L.append("<!-- ここはスクリプトでは埋められない。skill 側（Claude）が上の原文を訳して埋める。")
    L.append("     埋めていないなら「未記入」と正直に残すこと。 -->")
    L.append("")
    L.append("（未記入）")
    L.append("")
    L.append("## レイアウト・写真の方針（原文）")
    L.append("")
    if ds.get("layout"):
        L.append("- **layout**: %s" % ds["layout"])
    if ds.get("imagery"):
        L.append("- **imagery**: %s" % ds["imagery"])
    L.append("")
    if m.adjust:
        L.append("## 読みやすさのために直した色")
        L.append("")
        L.append("| 変数 | もと | 直した | もとの比 | 直した比 |")
        L.append("|---|---|---|---|---|")
        for slot, before, after, cb, ca in m.adjust:
            L.append("| `%s` | `%s` | `%s` | %.2f:1 | %.2f:1 |" % (slot, before, after, cb, ca))
        L.append("")
    if m.warnings:
        L.append("## 人が見て決めること")
        L.append("")
        for w in m.warnings:
            L.append("- %s" % w)
        L.append("")
    if m.unassigned:
        L.append("## 未割当の色（捨てずに残す）")
        L.append("")
        L.append("| hex | 名前 | 役割 |")
        L.append("|---|---|---|")
        for hexv, nm, role in m.unassigned:
            L.append("| `%s` | %s | %s |" % (hexv, nm, (role or "").replace("|", "／")[:120]))
        L.append("")
    return "\n".join(L) + "\n"


SUMMARY_HEAD = "## 日本語要約（Do / Don\'t）"


def carry_over_summary(path, new_memo):
    """作り直すとき、手で書いた「日本語要約」を消さずに引き継ぐ。戻り値 (本文, 引き継いだか)"""
    if not os.path.exists(path):
        return new_memo, False
    old = open(path, encoding="utf-8").read()
    if SUMMARY_HEAD not in old or SUMMARY_HEAD not in new_memo:
        return new_memo, False

    def section(text):
        i = text.find(SUMMARY_HEAD) + len(SUMMARY_HEAD)
        j = text.find("\n## ", i)
        return i, (j if j >= 0 else len(text))

    oi, oj = section(old)
    body = old[oi:oj]
    if "（未記入）" in body or not body.strip():
        return new_memo, False            # まだ書かれていない＝引き継ぐものが無い
    ni, nj = section(new_memo)
    return new_memo[:ni] + body + new_memo[nj:], True


def main():
    ap = argparse.ArgumentParser(
        description="refero styles の1本を、つみきのCSS変数に写す（一括取得はしない）")
    ap.add_argument("target", help="refero の style URL 1本／保存したHTML／designSystem の JSON")
    ap.add_argument("--name", default=None, help="呼び名（design_refs のファイル名になる）")
    ap.add_argument("--memo", action="store_true", help="design_refs/<name>.design.md も書く")
    ap.add_argument("--out", default=None, help="CSSの書き出し先（既定は標準出力）")
    ap.add_argument("--raw", default=None, help="designSystem の生JSONの保存先")
    a = ap.parse_args()

    t = a.target.strip()
    if t.startswith("http"):
        html, url = fetch_html(t)
        ds = extract_design_system(html)
    elif t.endswith(".json"):
        ds = json.load(open(t, encoding="utf-8"))
        if "designSystem" in ds:
            ds = ds["designSystem"]
        url = "(手元のJSON: %s)" % t
    else:
        html = open(t, encoding="utf-8", errors="replace").read()
        ds = extract_design_system(html)
        url = "(手元のHTML: %s)" % t

    name = a.name or re.sub(r"[^0-9A-Za-z一-龥ぁ-んァ-ヶー_-]", "",
                            (ds.get("northStar") or "refero").split()[0]) or "refero"
    today = datetime.date.today().isoformat()

    m = Mapper(ds, url, name)
    base = m.build_light()
    if (ds.get("theme") or "").lower() == "dark":
        # もとが暗い基調のサイト。抜いた値はダーク側に置き、ライトを起こす。
        dark = base
        light = m.build_light_from_dark(dark)
        m.warnings.append("もとが dark 基調のため、:root（ライト）は導出値。"
                          "ダーク側が refero の実値。ライトは必ず目視すること")
    else:
        light = base
        dark = m.build_dark(light)
    if "--accent" in light:
        m.warnings.append(m.on_accent_note(light["--accent"], light["--paper"], "ライト"))
    if "--accent" in dark:
        m.warnings.append(m.on_accent_note(dark["--accent"], dark["--paper"], "ダーク"))
    css = render_css(m, light, dark, url, today)

    if a.raw:
        json.dump(ds, open(a.raw, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        sys.stderr.write("・生JSON: %s\n" % a.raw)
    if a.out:
        open(a.out, "w", encoding="utf-8").write(css)
        sys.stderr.write("・CSS: %s\n" % a.out)
    else:
        sys.stdout.write(css)
    if a.memo:
        os.makedirs(REFS_DIR, exist_ok=True)
        p = os.path.join(REFS_DIR, "%s.design.md" % name)
        memo = render_memo(m, light, dark, url, today)
        kept = carry_over_summary(p, memo)
        open(p, "w", encoding="utf-8").write(kept[0])
        if kept[1]:
            sys.stderr.write("・参照メモ: %s（手で書いた日本語要約は残しました）\n" % p)
        else:
            sys.stderr.write("・参照メモ: %s（Do/Don\'t の日本語要約は未記入。Claude が埋める）\n" % p)

    # 実測値を標準エラーへ（報告にそのまま貼れる形）
    sys.stderr.write("\n【コントラスト実測（ライト）】地=%s\n" % light["--paper"])
    for s in ["--ink", "--ink-mid", "--ink-soft", "--sub", "--muted", "--accent"]:
        if s in light:
            sys.stderr.write("  %-12s %s  %.2f:1  %s\n" % (
                s, light[s], contrast(light[s], light["--paper"]),
                "OK" if contrast(light[s], light["--paper"]) >= 4.5 else "NG(4.5未満)"))
    sys.stderr.write("【コントラスト実測（ダーク）】地=%s\n" % dark["--paper"])
    for s in ["--ink", "--ink-mid", "--ink-soft", "--sub", "--muted", "--accent"]:
        if s in dark:
            sys.stderr.write("  %-12s %s  %.2f:1  %s\n" % (
                s, dark[s], contrast(dark[s], dark["--paper"]),
                "OK" if contrast(dark[s], dark["--paper"]) >= 4.5 else "NG(4.5未満)"))


if __name__ == "__main__":
    main()
