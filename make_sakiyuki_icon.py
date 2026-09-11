# -*- coding: utf-8 -*-
"""さきゆき（資産の見通しグラフ）のアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白（Preferences/app-icon-design）。
絵＝「先行き」＝ 縦軸と横軸の上を、あとになるほど傾きが強くなって伸びていく線と、その先の点。
分割払いが終わると毎月の残りが増えて、グラフが立ち上がっていく様子をそのまま描いた。
※ Private のアプリなので Appleロゴ・つみきロゴは入れない。
実行: python3 make_sakiyuki_icon.py
"""
from _icon_kit import render, measure

SW = 4.5                 # 100座標での線幅（ほかのアイコンと同じ）
H  = SW / 2
SCALE = 1.28             # ほかのアイコンと同じくらいの「かたまり」の大きさに合わせる
R_DOT = 3.4

AX0, AY0, AX1, AY1 = 28.0, 28.0, 72.0, 72.0      # 軸（左上の端と右下の端）
body = (f'<path d="M{AX0} {AY0} V{AY1} H{AX1}"/>'
        '<path d="M37 62 L48 57.5 L58 50 L66 38"/>'
        f'<circle cx="66" cy="38" r="{R_DOT}" fill="#ffffff" stroke="none"/>')

# 見た目（線のふとさこみ）の外接矩形を出して、かたまりごと中央へ据える
L, R = AX0 - H, AX1 + H
T, B = AY0 - H, AY1 + H
w, h = (R-L)*SCALE, (B-T)*SCALE
dx, dy = (100-w)/2 - L*SCALE, (100-h)/2 - T*SCALE

svg = (f'<g transform="translate({dx:.2f},{dy:.2f}) scale({SCALE})" fill="none" stroke="#ffffff" '
       f'stroke-width="{SW/SCALE:.3f}" stroke-linecap="round" stroke-linejoin="round">{body}</g>')

out = render(svg, "icons/icon-sakiyuki.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v),2) for v in m["margin"]))
print("絵の大きさ:", tuple(round(float(v),2) for v in m["size"]))
print("白いかたまりの数:", m["blobs"], "（2＝軸・線と先の点。軸と線は触れていない）")
