# -*- coding: utf-8 -*-
"""つみき&せんや のアプリアイコンを作る（180px PNG・2本）
   方針＝ Preferences/app-icon-design.md：黒背景 #1c1c1c ／ 白の線画1個 ／ 中央 ／ round ／ 100座標 sw6
   右下＝ つみき公式ロゴ（Preferences/tsumiki-official-logo.md の座標をそのままコピー・簡略化しない）
   ⚠️ cairosvg が壊れている（libcairo-2.dll を探しに行く）ので Chrome ヘッドレスで描く。
"""
import sys, pathlib; sys.path.insert(0, str(pathlib.Path(__file__).parent))
from _senya_icon_lib import render, main_sym, tsumiki_badge
import _senya_icon_group as _grp

CAL = ('<rect x="20" y="26" width="60" height="54" rx="8"/>'
       '<line x1="20" y1="42" x2="80" y2="42"/>'
       '<line x1="34" y1="18" x2="34" y2="30"/>'
       '<line x1="66" y1="18" x2="66" y2="30"/>')
SYM = {
  # スタッフ用＝カレンダーにチェック（自分の希望を出す）
  'tsumiki-senya':       CAL + '<path d="M35,60 L46,70 L67,52"/>',
  # 店長用＝カレンダーに人が2人（みんなの希望を見る）
  #   ⚠️ 前は「ただの格子」で、てっぱりのアイコンとほぼ同じだった。
  #      店長画面は v1 で表をやめてカレンダーにしたので、絵も実態に合わせる。
  'tsumiki-senya-kanri': CAL + ('<circle cx="41" cy="55" r="5.5"/><path d="M32.5,71 a8.5,9 0 0 1 17,0"/>'
                                '<circle cx="61" cy="55" r="5.5"/><path d="M52.5,71 a8.5,9 0 0 1 17,0"/>'),
}
# ⚠️ 本体とロゴが重ならないよう、外接矩形を数式で出して決めた（2026-08-25）。
#    本体の絵＝x20-80 / y18-80（＋線の半分3）／ ロゴ＝幅60*sc・高さ52*sc（＋線の半分）。
#    この値で すきま 6.5・本体の左余白9.0/上余白9.2・ロゴの右下余白5.2。
# ===== 配置：本体とロゴを「1つのかたまり」として、真ん中に余白均等で置く =====
# ⚠️ 目で置かない。かたまりの外接矩形を数式で出し、100×100 の中央に据える。
#    ・かたまりが正方形になるよう、よこの空き gx を たての空き gy から逆算する
#    ・その結果、上下左右の余白が同じ値になる（実測 11.5 / 11.5 / 11.8 / 11.8）
MAIN_SCALE  = 0.76      # 本体の倍率（見た目 50.2 × 51.7）
BADGE_SCALE = 0.34      # ロゴの倍率（絵の幅 20.4・線 1.53 ＝ 正本と同じ比 0.075）
GAP_Y       = 6.0       # 本体の下端 → ロゴの上端

OUT = pathlib.Path.home()/'tsumiki-tools'
place = _grp.place(MAIN_SCALE, BADGE_SCALE, GAP_Y)
print(f"かたまり {place['W']:.1f}×{place['H']:.1f} / "
      f"余白 {place['margin'][0]:.1f},{place['margin'][1]:.1f},"
      f"{place['margin'][2]:.1f},{place['margin'][3]:.1f} / "
      f"すきま よこ{place['gap_x']:.1f} たて{place['gap_y']:.1f} / ロゴの線 {place['sw']:.2f}")

for name, sym in SYM.items():
    body = main_sym(sym, shrink=(place['dx'], place['dy'], MAIN_SCALE)) + tsumiki_badge(
        BADGE_SCALE, right=place['right'], bottom=place['bottom'], sw_visible=place['sw'])
    p = OUT/f'icon-{name}.png'
    render(body, p)
    print('作った', p)
