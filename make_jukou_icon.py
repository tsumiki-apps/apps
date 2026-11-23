# -*- coding: utf-8 -*-
"""受講率ノートのアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白。
絵＝チェックの並び（済んだ2行にチェック・まだの1行は丸。本人が案5を選択 2026-11-23）。
大きさと線はロゴなしのアイコン（告知づくり）とそろえる＝かたまりの長辺 62・仕上がりの線 4.05。
実行: python3 make_jukou_icon.py
"""
from _icon_kit import Sym, compose, render, measure

BODY = ('<path d="M14 24l6 6 11-12"/><path d="M42 24h44"/>'   # 済んだ（チェック）
        '<path d="M14 50l6 6 11-12"/><path d="M42 50h32"/>'
        '<circle cx="22" cy="76" r="7"/><path d="M42 76h20"/>')  # まだ（丸）
BOX = (14, 18, 86, 83)
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
