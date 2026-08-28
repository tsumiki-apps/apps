# -*- coding: utf-8 -*-
"""まとおと（ダーツの効果音アプリ）のアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白（Preferences/app-icon-design）。
絵＝「的（まと）」＋「音（おと）」＝ 同心円のターゲットと、右へ広がる音の波。
名前そのままの絵にしてある（ダーツ盤を写実に描くと、22pxでは車輪に見えてしまったため）。
※ Private のアプリなので Appleロゴ・つみきロゴは入れない。
実行: python3 make_matooto_icon.py
"""
import math
from _icon_kit import render, measure

SW = 4.5                 # 100座標での線幅（ほかのアイコンと同じ）
H  = SW / 2
SCALE = 0.92             # ほかのアイコンと同じくらいの「かたまり」の大きさに合わせる
R_OUT, R_IN, R_BULL = 22.0, 11.0, 3.2
W1, W2, GAP, DEG = 9.0, 16.0, 7.0, 52.0

def arc(cx, cy, r, deg):
    a0, a1 = math.radians(-deg), math.radians(deg)
    x0, y0 = cx + r*math.cos(a0), cy + r*math.sin(a0)
    x1, y1 = cx + r*math.cos(a1), cy + r*math.sin(a1)
    return f'<path d="M{x0:.2f} {y0:.2f} A{r} {r} 0 0 1 {x1:.2f} {y1:.2f}"/>'

bx = by = 50.0
wx = bx + R_OUT + H + GAP                       # 波の中心x（的のふちから GAP あける＝重ねない）
body = (f'<circle cx="{bx}" cy="{by}" r="{R_OUT}"/>'
        f'<circle cx="{bx}" cy="{by}" r="{R_IN}"/>'
        + arc(wx, by, W1, DEG) + arc(wx, by, W2, DEG)
        + f'<circle cx="{bx}" cy="{by}" r="{R_BULL}" fill="#ffffff" stroke="none"/>')

# 見た目（線のふとさこみ）の外接矩形を出して、かたまりごと中央へ据える
L, R = bx - R_OUT - H, wx + W2 + H
T, B = by - R_OUT - H, by + R_OUT + H
w, h = (R-L)*SCALE, (B-T)*SCALE
dx, dy = (100-w)/2 - L*SCALE, (100-h)/2 - T*SCALE

svg = (f'<g transform="translate({dx:.2f},{dy:.2f}) scale({SCALE})" fill="none" stroke="#ffffff" '
       f'stroke-width="{SW/SCALE:.3f}" stroke-linecap="round" stroke-linejoin="round">{body}</g>')

out = render(svg, "icons/icon-matooto.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v),2) for v in m["margin"]))
print("絵の大きさ:", tuple(round(float(v),2) for v in m["size"]))
print("白いかたまりの数:", m["blobs"], "（5＝外の輪・内の輪・ブル・波2本。どれも触れていない）")
