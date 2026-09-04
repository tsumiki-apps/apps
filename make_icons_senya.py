# -*- coding: utf-8 -*-
"""せんや アプリアイコン（2026-08-27 版）
   ・ユーザー指示により **つみき公式ロゴは入れない**（せんやのみの例外）
   ・シンボル1個を「かたまり」として 100×100 の中央に据える
   ・線の太さは「仕上がりの幅（100座標）」でそろえる＝2つ並べたとき重さが揃う
"""
import sys, pathlib; sys.path.insert(0, str(pathlib.Path(__file__).parent))
from _icon_kit import Sym, compose, render, measure

GROUP = 62.0   # かたまりの一辺（100 のうち）
LINE  = 4.05   # 仕上がりの線幅（100座標）。2026-08-27「少し細く」で 4.65 → 4.05

SYM = {
  # スタッフ用＝働ける日に○を出す人（人＋チェック）
  'tsumiki-senya': (
      '<circle cx="40" cy="43" r="13"/><path d="M14,88 a26,24 0 0 1 52,0"/>'
      '<path d="M60,27 L70,37 L88,15"/>', (14,15,88,88)),
  # 店長用＝スタッフの名簿を見る（クリップボード＋ふたり）
  'tsumiki-senya-kanri': (
      '<rect x="19" y="22" width="62" height="62" rx="9"/>'
      '<path d="M40,22 v-4 a4,4 0 0 1 4,-4 h12 a4,4 0 0 1 4,4 v4"/>'
      '<circle cx="41" cy="49" r="5.5"/><path d="M32.5,66 a8.5,9 0 0 1 17,0"/>'
      '<circle cx="60" cy="49" r="5.5"/><path d="M51.5,66 a8.5,9 0 0 1 17,0"/>', (19,14,81,84)),
}
OUT = pathlib.Path.home()/'tsumiki-tools'

def build(body, box):
    m0 = max(box[2]-box[0], box[3]-box[1])
    sw = LINE*m0/(GROUP-LINE)               # 仕上がりを LINE にそろえる逆算
    s  = Sym(body, *box, sw=sw)
    w,h = s.size(1.0); sc = GROUP/max(w,h)
    svg, info = compose([(s,sc,0,0)])
    return svg, info, sw, sc

if __name__ == '__main__':
    for name,(body,box) in SYM.items():
        svg, info, sw, sc = build(body, box)
        p = OUT/f'icon-{name}.png'; render(svg, p); m = measure(p)
        print(f"icon-{name}.png  かたまり {info['W']:.1f}×{info['H']:.1f}"
              f"  仕上がり線 {sw*sc:.2f}  余白 " + "/".join(f"{v:.1f}" for v in m['margin'])
              + f"  塊 {m['blobs']}")
