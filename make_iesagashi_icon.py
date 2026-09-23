# -*- coding: utf-8 -*-
"""家さがしの調べもの（iesagashi.html）のアイコンを作る。
つみきのアプリアイコンの作法＝黒背景＋白い線画・中央・たっぷり余白（Preferences/app-icon-design）。
絵＝家の輪郭に、右下から虫めがね。
実行: python3 make_iesagashi_icon.py
"""
from _icon_kit import render, measure

SW = 4.5
BODY = ('<path d="M26 50L48 31L70 50"/>'
        '<path d="M31 46V72H52"/>'
        '<circle cx="63" cy="63" r="9"/>'
        '<path d="M69.5 69.5L76 76"/>')
X0, Y0, X1, Y1 = 26.0, 31.0, 76.0, 76.0
H = SW / 2
SCALE = 62 / (X1 - X0 + SW)
w, h = (X1 - X0) * SCALE + SW, (Y1 - Y0) * SCALE + SW
dx = (100 - w) / 2 - (X0 * SCALE - H)
dy = (100 - h) / 2 - (Y0 * SCALE - H)
svg = (f'<g transform="translate({dx:.2f},{dy:.2f}) scale({SCALE:.4f})" fill="none" stroke="#ffffff" '
       f'stroke-width="{SW/SCALE:.3f}" stroke-linecap="round" stroke-linejoin="round">{BODY}</g>')
out = render(svg, "icons/icon-iesagashi.png")
m = measure(out)
print("できた:", out, "余白", tuple(round(float(v), 2) for v in m["margin"]), "かたまり", m["blobs"])
