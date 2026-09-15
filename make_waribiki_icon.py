# -*- coding: utf-8 -*-
"""割引電卓のアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白（Preferences/app-icon-design）。
絵＝電卓の本体と表示窓、キーの場所に「%」。
アプリの見出しの小さなロゴも同じ座標（waribiki.html の #i-logo）。
※ Private のアプリなので Appleロゴ・つみきロゴは入れない。
実行: python3 make_waribiki_icon.py
"""
from _icon_kit import render, measure

SW = 4.5                 # 100座標での仕上がりの線幅（ほかのアイコンと同じ）
H  = SW / 2
BODY = ('<rect x="28" y="20" width="44" height="60" rx="8"/>'
        '<rect x="36" y="29" width="28" height="12" rx="3"/>'
        '<circle cx="41" cy="55" r="3.5"/>'
        '<circle cx="59" cy="70" r="3.5"/>'
        '<path d="M60 52L40 73"/>')
X0, Y0, X1, Y1 = 28.0, 20.0, 72.0, 80.0          # 絵の範囲

SCALE = 62 / (Y1 - Y0 + SW)                      # たての長辺を 62 にそろえる（つみ木と同じくらいの塊）
w, h = (X1 - X0) * SCALE + SW, (Y1 - Y0) * SCALE + SW
dx = (100 - w) / 2 - (X0 * SCALE - H)
dy = (100 - h) / 2 - (Y0 * SCALE - H)

svg = (f'<g transform="translate({dx:.2f},{dy:.2f}) scale({SCALE:.4f})" fill="none" stroke="#ffffff" '
       f'stroke-width="{SW/SCALE:.3f}" stroke-linecap="round" stroke-linejoin="round">{BODY}</g>')

out = render(svg, "icons/icon-waribiki.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v), 2) for v in m["margin"]), "差", round(float(m["diff"]), 2))
print("絵の大きさ:", tuple(round(float(v), 2) for v in m["size"]))
