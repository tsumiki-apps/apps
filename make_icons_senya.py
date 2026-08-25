# -*- coding: utf-8 -*-
"""つみき&せんや アプリアイコン（作り直し版）
   ・部品を「かたまり」として組み、正方形にして 100×100 の中央に据える
   ・つみき公式ロゴは正本の座標そのまま／線は「絵の幅 × 0.075」
"""
import sys, pathlib; sys.path.insert(0, str(pathlib.Path(__file__).parent))
from _icon_kit import Sym, Logo, compose, render

# ---- 決めた値 --------------------------------------------------------
GROUP = 66.0     # かたまりの一辺（100 のうち）＝ 真ん中にぎゅっと
LOGO  = 0.32     # つみきロゴの倍率（絵の幅 19.2・線 1.44）
GAP_Y = 3.0      # 本体の下端 → ロゴの上端
# 本体の倍率は「かたまりを GROUP にする」ところから逆算する
MAIN  = (GROUP - 56.5*LOGO - GAP_Y) / 68.0

CAL=('<rect x="20" y="26" width="60" height="54" rx="8"/><line x1="20" y1="42" x2="80" y2="42"/>'
     '<line x1="34" y1="18" x2="34" y2="30"/><line x1="66" y1="18" x2="66" y2="30"/>')
SYM = {
  'tsumiki-senya':       CAL+'<path d="M35,60 L46,70 L67,52"/>',
  'tsumiki-senya-kanri': CAL+('<circle cx="41" cy="55" r="5.5"/><path d="M32.5,71 a8.5,9 0 0 1 17,0"/>'
                              '<circle cx="61" cy="55" r="5.5"/><path d="M52.5,71 a8.5,9 0 0 1 17,0"/>'),
}
L = Logo()
OUT = pathlib.Path.home()/'tsumiki-tools'

def build(inner):
    s = Sym(inner, 20,18,80,80)
    mw,mh = s.size(MAIN); lw,lh = L.size(LOGO)
    gx = (mh-mw) + (lh-lw) + GAP_Y          # かたまりが正方形になる よこの空き
    return compose([(s,MAIN,0,0), (L,LOGO,mw+gx,mh+GAP_Y)]), (gx, mw, 60*LOGO*0.075)

if __name__ == '__main__':
    for name, inner in SYM.items():
        (svg, info), (gx, mw, sw) = build(inner)
        render(svg, OUT/f'icon-{name}.png')
        print(f"icon-{name}.png  かたまり {info['W']:.1f}×{info['H']:.1f}  余白 {info['margin'][0]:.1f}"
              f"  本体幅 {mw:.1f}  ロゴ線 {sw:.2f}  すきま よこ{gx:.1f} たて{GAP_Y}")
