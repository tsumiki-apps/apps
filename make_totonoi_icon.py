# -*- coding: utf-8 -*-
"""ととのい（サウナの写真に心拍の記録を重ねる）のアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白（Preferences/app-icon-design）。
絵＝湯気3本の下に、心拍の線。サウナ＋記録。
※ Private のアプリなので Appleロゴ・つみきロゴは入れない。
実行: python3 make_totonoi_icon.py
"""
from _icon_kit import render, measure

SW = 4.5
H  = SW / 2
BODY = ('<path d="M38 24C34 29 42 33 38 39"/>'
        '<path d="M50 24C46 29 54 33 50 39"/>'
        '<path d="M62 24C58 29 66 33 62 39"/>'
        '<path d="M26 60H38L44 48L52 72L58 60H74"/>')
X0, Y0, X1, Y1 = 26.0, 24.0, 74.0, 72.0

SCALE = 62 / (X1 - X0 + SW)
w, h = (X1 - X0) * SCALE + SW, (Y1 - Y0) * SCALE + SW
dx = (100 - w) / 2 - (X0 * SCALE - H)
dy = (100 - h) / 2 - (Y0 * SCALE - H)

svg = (f'<g transform="translate({dx:.2f},{dy:.2f}) scale({SCALE:.4f})" fill="none" stroke="#ffffff" '
       f'stroke-width="{SW/SCALE:.3f}" stroke-linecap="round" stroke-linejoin="round">{BODY}</g>')

out = render(svg, "icons/icon-totonoi.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v), 2) for v in m["margin"]), "差", round(float(m["diff"]), 2))
