# -*- coding: utf-8 -*-
"""本体とロゴを「1つのかたまり」として、100×100 の真ん中に余白均等で置く。

 本体の絵      : x20-80 / y18-80（線 6 → 外に3）→ 見た目 66 × 68 の倍率倍
 つみきロゴの絵: 幅60 / 高さ52（線＝幅×0.075）→ 見た目 64.5 × 56.5 の倍率倍
 ロゴは本体の右下へ、よこ gx・たて gy だけ離して置く。
"""
RATIO = 0.075
MAIN_W, MAIN_H = 66.0, 68.0          # 線こみの見た目（倍率1のとき）
BADGE_W, BADGE_H = 60*(1+RATIO), 52+60*RATIO   # = 64.5 × 56.5

def solve(ms, bs, gy, size=None):
    """かたまりが正方形になる gx を出し、真ん中に置いたときの各値を返す"""
    mw, mh = MAIN_W*ms, MAIN_H*ms
    bw, bh = BADGE_W*bs, BADGE_H*bs
    # W = mw+gx+bw, H = mh+gy+bh  → W=H となる gx
    gx = (mh + gy + bh) - (mw + bw)
    W = mw + gx + bw; H = mh + gy + bh
    return dict(mw=mw,mh=mh,bw=bw,bh=bh,gx=gx,gy=gy,W=W,H=H)

def place(ms, bs, gy):
    s = solve(ms,bs,gy)
    W,H = s['W'], s['H']
    left = (100-W)/2; top = (100-H)/2
    # 本体：見た目の左上が (left, top) に来るように
    dx = left - (20-3)*ms
    dy = top  - (18-3)*ms
    main_bb = (left, top, left+s['mw'], top+s['mh'])
    # ロゴ：見た目の右下が (left+W, top+H) に来るように
    sw = 60*bs*RATIO
    right  = left+W - sw/2
    bottom = top+H  - sw/2
    badge_bb = (left+W-s['bw'], top+H-s['bh'], left+W, top+H)
    return dict(dx=dx, dy=dy, ms=ms, bs=bs, sw=sw, right=right, bottom=bottom,
                main=main_bb, badge=badge_bb, W=W, H=H, gx=s['gx'], gy=gy,
                margin=(left, top, 100-(left+W), 100-(top+H)),
                gap_x=badge_bb[0]-main_bb[2], gap_y=badge_bb[1]-main_bb[3])
