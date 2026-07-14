# -*- coding: utf-8 -*-
"""ぴずかご（issho.html）専用アイコン生成。
紙地(#F4F2EE)に墨(#242321)の細線で描いた「かご＋お豆2粒」。
ヘッダーのインラインSVGロゴと同じ意匠。make_icons.py（絵文字×グラデ）ではなく
これ専用スクリプトで作る。実行: python3 make_issho_icon.py
"""
from PIL import Image, ImageDraw

SS = 4; S = 180; N = S * SS; U = N / 24.0
PAPER = (244, 242, 238); INK = (36, 35, 33)
OY = -0.4                      # 視覚中心をわずかに上へ


def _P(x, y): return (x * U, y * U)


def _stroke(d, points, width):
    pts = [_P(x, y + OY) for x, y in points]
    d.line(pts, fill=INK, width=int(round(width)), joint="curve")
    r = width / 2
    for px, py in (pts[0], pts[-1]):
        d.ellipse([px - r, py - r, px + r, py + r], fill=INK)   # 丸キャップ


def _quad(p0, p1, p2, steps=48):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1])
            for t in (i / steps for i in range(steps + 1))]


def make(path="icons/icon-issho.png"):
    img = Image.new("RGB", (N, N), PAPER)
    d = ImageDraw.Draw(img)
    sw = 0.98 * U
    _stroke(d, _quad((8.2, 11), (12, 5.4), (15.8, 11)), sw)                 # 取っ手
    _stroke(d, [(3.6, 11), (20.4, 11)], sw)                                 # ふち
    _stroke(d, [(5, 11), (6.4, 18.6), (6.9, 19.9), (8, 20.4), (16, 20.4),
                (17.1, 19.9), (17.6, 18.6), (19, 11)], sw)                  # 本体
    _stroke(d, [(5.9, 15.2), (18.1, 15.2)], sw * 0.8)                       # 横の編み
    _stroke(d, [(9, 11.6), (8.4, 20.0)], sw * 0.8)
    _stroke(d, [(12, 11.6), (12, 20.4)], sw * 0.8)
    _stroke(d, [(15, 11.6), (15.6, 20.0)], sw * 0.8)
    for cx, cy, r in [(9.9, 10.0, 0.8), (14.1, 10.0, 0.8)]:                 # ぴず（お豆）2粒
        x0, y0 = _P(cx - r, cy - r + OY); x1, y1 = _P(cx + r, cy + r + OY)
        d.ellipse([x0, y0, x1, y1], fill=INK)
    img = img.resize((S, S), Image.LANCZOS)
    img.save(path, "PNG")
    return path


if __name__ == "__main__":
    print("✓", make())
