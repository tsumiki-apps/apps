# -*- coding: utf-8 -*-
"""告知づくりのアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白。
絵＝告知の画像（16:9の枠）の中にメガホン。
実行: python3 make_kokuchi_icon.py
"""
from _icon_kit import render, measure

svg = ('<g fill="none" stroke="#ffffff" stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round">'
       '<rect x="16" y="27" width="68" height="46" rx="8"/>'
       '<path d="M33 45h6l14-8v26l-14-8h-6z"/>'
       '<path d="M38 55l2 7"/>'
       '<path d="M60 44q4 6 0 12"/><path d="M66 40q8 10 0 20"/></g>')

out = render(svg, "icons/icon-kokuchi.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v), 2) for v in m["margin"]), "差", round(float(m["diff"]), 2))
