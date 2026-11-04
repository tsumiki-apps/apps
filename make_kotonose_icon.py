# -*- coding: utf-8 -*-
"""ことのせのアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白（Preferences/app-icon-design）。
絵＝写真の枠と下の白い帯（このアプリの仕上がりの形）＋帯の上に「ほめる」の星（本人が4案から選んだ・2026-11-04）。
※ Private のアプリなので Appleロゴ・つみきロゴは入れない。
実行: python3 make_kotonose_icon.py
"""
import math
from _icon_kit import render, measure

cx, cy = 50, 40.5
star = ' '.join(f'{cx+(13 if i%2==0 else 6)*math.cos(math.pi*i/5-math.pi/2):.2f},'
                f'{cy+1.2+(13 if i%2==0 else 6)*math.sin(math.pi*i/5-math.pi/2):.2f}' for i in range(10))
svg = ('<g fill="none" stroke="#ffffff" stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round">'
       '<rect x="17" y="21" width="66" height="58" rx="8"/>'
       '<rect x="26" y="63" width="48" height="8" rx="3"/>'
       f'<polygon points="{star}"/></g>')

out = render(svg, "icons/icon-kotonose.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v), 2) for v in m["margin"]), "差", round(float(m["diff"]), 2))
