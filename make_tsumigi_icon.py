# -*- coding: utf-8 -*-
"""つみ木（曜日ごとの幸せなこと）のアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白（Preferences/app-icon-design）。
絵＝「つみ木」＝ 積み木ひとつの上から、双葉の芽が出ている。積み木＋木。
アプリの見出しの小さなロゴも同じ座標（tsumigi.html の .logo）。
※ Private のアプリなので Appleロゴ・つみきロゴは入れない。
実行: python3 make_tsumigi_icon.py
"""
from _icon_kit import render, measure

SW = 4.5                 # 100座標での仕上がりの線幅（ほかのアイコンと同じ）
H  = SW / 2
BODY = ('<rect x="30" y="50" width="40" height="26" rx="5"/>'
        '<path d="M50 50V37"/>'
        '<path d="M50 41C43 41 38 37 37 30C44 30 49 34 50 41Z"/>'
        '<path d="M50 37C50 30 55 25 62 24C62 31 57 37 50 37Z"/>')
X0, Y0, X1, Y1 = 30.0, 24.0, 70.0, 76.0          # 絵の範囲

L, T, R, B = X0 - H, Y0 - H, X1 + H, Y1 + H      # 仮の外接矩形（線の太さは下で倍率に合わせて直す）
SCALE = 62 / (Y1 - Y0 + SW)                      # たての長辺を 62 にそろえる（さきゆきと同じくらいの塊）
w, h = (X1 - X0) * SCALE + SW, (Y1 - Y0) * SCALE + SW
dx = (100 - w) / 2 - (X0 * SCALE - H)
dy = (100 - h) / 2 - (Y0 * SCALE - H)

svg = (f'<g transform="translate({dx:.2f},{dy:.2f}) scale({SCALE:.4f})" fill="none" stroke="#ffffff" '
       f'stroke-width="{SW/SCALE:.3f}" stroke-linecap="round" stroke-linejoin="round">{BODY}</g>')

out = render(svg, "icons/icon-tsumigi.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v), 2) for v in m["margin"]), "差", round(float(m["diff"]), 2))
print("絵の大きさ:", tuple(round(float(v), 2) for v in m["size"]))
print("白いかたまりの数:", m["blobs"], "（1＝積み木と芽がつながっている）")
