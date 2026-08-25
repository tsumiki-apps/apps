# -*- coding: utf-8 -*-
"""つみき&せんや のアプリアイコンを作る（180px PNG・2本）
   方針＝ Preferences/app-icon-design.md：黒背景 #1c1c1c ／ 白の線画1個 ／ 中央 ／ round ／ 100座標 sw6
   右下＝ つみき公式ロゴ（Preferences/tsumiki-official-logo.md の座標をそのままコピー・簡略化しない）
   ⚠️ cairosvg が壊れている（libcairo-2.dll を探しに行く）ので Chrome ヘッドレスで描く。
"""
import sys, pathlib; sys.path.insert(0, str(pathlib.Path(__file__).parent))
from _senya_icon_lib import render, main_sym, tsumiki_badge

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
SHIFT = (-6.0, -4.0, 0.88)
# ⚠️ 線の太さは「絵の幅に対する比」で決める。正本＝幅60に対して線4.5＝比 0.075。
#    ここを固定値（3.2）にしたら 比0.178 ＝ 2.4倍太くなり、白い塊に潰れた（2026-08-25）。
LOGO_RATIO = 0.075                      # 正本と同じ比
# kn（下敷き）は不要になった＝本体とロゴが本当に離れているため。
# 下敷きを敷かずに済むかどうかが「重なっていない」ことの証拠になる。
BADGE = dict(sc=0.34, right=94, bottom=94)   # 絵の幅 60*0.34 = 20.4 → 線 1.53

OUT = pathlib.Path.home()/'tsumiki-tools'
for name, sym in SYM.items():
    art_w = 60 * BADGE['sc']
    body = main_sym(sym, shrink=SHIFT) + tsumiki_badge(
        BADGE['sc'], right=BADGE['right'], bottom=BADGE['bottom'],
        sw_visible=art_w * LOGO_RATIO)      # 下敷きなし
    p = OUT/f'icon-{name}.png'
    render(body, p)
    print('作った', p)
