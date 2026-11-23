# -*- coding: utf-8 -*-
"""受講率ノートのアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白。
絵＝軸の上を右上がりに進む折れ線と、途中に立てた小さな旗（その日のコメント）。
大きさと線はロゴなしのアイコン（告知づくり）とそろえる＝かたまりの長辺 62・仕上がりの線 4.05。
実行: python3 make_jukou_icon.py
"""
from _icon_kit import Sym, compose, render, measure

BODY = ('<path d="M14 18v66h72"/>'                       # 軸
        '<path d="M24 70l16-14 12 8 26-30"/>'            # 右上がりの折れ線
        '<path d="M52 64V22"/><path d="M52 22h14l-4 6 4 6H52"/>')  # 旗（コメントの日）
BOX = (14, 18, 86, 84)
SIDE, LINE = 62, 4.05
lo, hi = 0.2, 2.0
for _ in range(60):
    s = (lo + hi) / 2
    w, h = Sym(BODY, *BOX, sw=LINE / s).size(s)
    lo, hi = (s, hi) if max(w, h) <= SIDE else (lo, s)
s = lo
svg, _ = compose([(Sym(BODY, *BOX, sw=LINE / s), s, 0, 0)])
out = render(svg, "icons/icon-jukou.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v), 2) for v in m["margin"]), "差", round(float(m["diff"]), 2), "塊", m["blobs"])
