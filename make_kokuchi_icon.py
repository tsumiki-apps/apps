# -*- coding: utf-8 -*-
"""告知づくりのアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白。
絵＝貼り紙とピン（掲示板に貼る告知）。Appleロゴは入れない（2026-11-08 本人の指示）。
大きさと線はロゴなしのアイコン（せんや）とそろえる＝かたまりの一辺 62・仕上がりの線 4.05。
実行: python3 make_kokuchi_icon.py
"""
from _icon_kit import Sym, compose, render, measure

BODY = ('<path d="M26 22h48a4 4 0 0 1 4 4v52a4 4 0 0 1-4 4H26a4 4 0 0 1-4-4V26a4 4 0 0 1 4-4z"/>'
        '<path d="M36 42h28"/><path d="M36 54h28"/><path d="M36 66h16"/>'
        '<circle cx="50" cy="22" r="6"/>')
BOX = (22, 16, 78, 82)
SIDE, LINE = 62, 4.05

# かたまりの長辺が SIDE になる倍率を探す（線の太さは仕上がりで LINE にそろえる）
lo, hi = 0.2, 2.0
for _ in range(60):
    s = (lo + hi) / 2
    w, h = Sym(BODY, *BOX, sw=LINE / s).size(s)
    lo, hi = (s, hi) if max(w, h) <= SIDE else (lo, s)
s = lo
svg, _ = compose([(Sym(BODY, *BOX, sw=LINE / s), s, 0, 0)])

out = render(svg, "icons/icon-kokuchi.png")
m = measure(out)
print("できた:", out)
print("余白(左,上,右,下):", tuple(round(float(v), 2) for v in m["margin"]), "差", round(float(m["diff"]), 2), "塊", m["blobs"])
