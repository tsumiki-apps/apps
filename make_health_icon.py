# -*- coding: utf-8 -*-
"""からだ帳（Apple Watch のヘルスケアを1枚で見る）のアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白（Preferences/app-icon-design）。
絵＝ハートの中を心拍の線が横切る。線はハートの輪郭につながっているので、白いかたまりは1つ。
※ Private のアプリなので Appleロゴ・つみきロゴは入れない。
実行: python3 make_health_icon.py
"""
from _icon_kit import render, measure

SW = 4.5
H  = SW / 2
BODY = ('<path d="M50 78C50 78 22 62 22 42C22 32 29 25 37.5 25C43 25 47.5 28 50 32.5C52.5 28 57 25 62.5 25C71 25 78 32 78 42C78 62 50 78 50 78Z"/>'
        '<path d="M22.5 47H37L42 38L48 57L53 44L56 47H77.5"/>')
X0, Y0, X1, Y1 = 22.0, 25.0, 78.0, 78.0

SCALE = 62 / (X1 - X0 + SW)                      # よこの長辺を 62 にそろえる
w, h = (X1 - X0) * SCALE + SW, (Y1 - Y0) * SCALE + SW
dx = (100 - w) / 2 - (X0 * SCALE - H)
dy = (100 - h) / 2 - (Y0 * SCALE - H)

svg = (f'<g transform="translate({dx:.2f},{dy:.2f}) scale({SCALE:.4f})" fill="none" stroke="#ffffff" '
       f'stroke-width="{SW/SCALE:.3f}" stroke-linecap="round" stroke-linejoin="round">{BODY}</g>')

out = render(svg, "icons/icon-health.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v), 2) for v in m["margin"]), "差", round(float(m["diff"]), 2))
print("絵の大きさ:", tuple(round(float(v), 2) for v in m["size"]))
print("白いかたまりの数:", m["blobs"], "（1＝ハートと心拍の線がつながっている）")
