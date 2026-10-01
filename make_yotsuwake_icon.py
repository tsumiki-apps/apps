# -*- coding: utf-8 -*-
"""よつわけ（収入を 6:2:1:1 で分ける）のアイコンを作る。
つみきのアプリアイコンの作法＝黒背景 #1c1c1c ＋ 白い線画・中央・たっぷり余白（Preferences/app-icon-design）。
線幅は 100座標で 4.5（さきゆきと同じ）。円で分ける形は まいつき（円グラフ）と紛れるので使わない。
※ Private のアプリなので Appleロゴ・つみきロゴは入れない。
実行（~/制作物 で）: python3 make_yotsuwake_icon.py [a|b|c] [出力先]   （既定は a ＝ icons/icon-yotsuwake.png）
  a（比較図の1）: 角丸の四角を、見える黒い面積が 6:2:1:1 になるよう区切る（採用）
  b（比較図の2）: 上の硬貨1枚から、4本に分かれて4つの点へ（太さは同じ・点の大きさで 6:2:1:1）
  c（比較図の3）: 大きさの違う積み木4つ（6:2:1:1 の面積）を並べる
"""
import sys
from _icon_kit import render, measure

SW = 4.5
H = SW / 2
W = "#ffffff"

def frame(body, box, size):
    """box＝線の中心で測った絵の範囲。線の太さこみで size（100座標）の大きさにして中央へ"""
    L, T, R, B = box[0]-H, box[1]-H, box[2]+H, box[3]+H
    s = size / max(R-L, B-T)
    dx, dy = (100-(R-L)*s)/2 - L*s, (100-(B-T)*s)/2 - T*s
    return (f'<g transform="translate({dx:.2f},{dy:.2f}) scale({s:.4f})" fill="none" stroke="{W}" '
            f'stroke-width="{SW/s:.3f}" stroke-linecap="round" stroke-linejoin="round">{body}</g>')

def a(x6=26.565, yh=22.205, x1=38.283, rx=5):
    # 0..50 の角丸の四角。区切りの位置は「線の内側に見える黒い面積」が 6:2:1:1 になるよう逆算した
    # （線の中心で 6:2:1:1 に割ると、線の太さのぶん小さい区画ほど痩せて 10:2.7:1:0.86 に見えた）。
    # 角丸は小さめ（rx=5）にして、右下の「1」が角で欠けて左の「1」より小さく見えないようにした。
    body = (f'<rect x="0" y="0" width="50" height="50" rx="{rx}"/>'
            f'<path d="M{x6} 0V50"/><path d="M{x6} {yh}H50"/><path d="M{x1} {yh}V50"/>')
    return frame(body, (0, 0, 50, 50), 54)

def areas(png):
    """黒い区画の画素数を大きい順に（外の背景は除く）"""
    import numpy as np
    from collections import deque
    from PIL import Image
    w = np.array(Image.open(png).convert('L')) > 110
    H, W = w.shape; seen = w.copy(); out = []
    for y in range(H):
        for x in range(W):
            if not seen[y, x]:
                n = 0; edge = False; q = deque([(y, x)]); seen[y, x] = True
                while q:
                    cy, cx = q.popleft(); n += 1
                    if cy in (0, H-1) or cx in (0, W-1): edge = True
                    for ny, nx in ((cy+1, cx), (cy-1, cx), (cy, cx+1), (cy, cx-1)):
                        if 0 <= ny < H and 0 <= nx < W and not seen[ny, nx]:
                            seen[ny, nx] = True; q.append((ny, nx))
                if not edge: out.append(n)
    return sorted(out, reverse=True)

def b():
    # 硬貨（円＋¥の代わりに横線1本）から下へ1本、枝分かれして4つの点
    cx = 25
    body = (f'<circle cx="{cx}" cy="7" r="7"/>'
            f'<path d="M{cx} 14V24"/><path d="M4 30Q4 24 10 24H40Q46 24 46 30"/>'
            f'<path d="M18 24V30"/><path d="M32 24V30"/>')
    dots = ''
    for x, r in ((4, 5.2), (18, 3.6), (32, 2.8), (46, 2.8)):
        dots += f'<circle cx="{x}" cy="{38}" r="{r}" fill="{W}" stroke="none"/>'
    return frame(body + dots, (0-1, 0, 50+1, 43), 56)

def c():
    # 積み木：面積が 6:2:1:1 になる大きさ（一辺 26・15・10.6・10.6）を床に並べ、小さい1つは中の上に積む
    body = ('<rect x="0" y="12" width="26" height="26" rx="4"/>'
            '<rect x="30" y="23" width="15" height="15" rx="3"/>'
            '<rect x="32.2" y="8.4" width="10.6" height="10.6" rx="2.5"/>'
            '<rect x="49" y="27.4" width="10.6" height="10.6" rx="2.5"/>'
            '<path d="M-3 43.5H62.6"/>')
    return frame(body, (-3, 8.4, 62.6, 43.5), 58)

if __name__ == "__main__":
    v = sys.argv[1] if len(sys.argv) > 1 else "a"
    out = sys.argv[2] if len(sys.argv) > 2 else "icons/icon-yotsuwake.png"
    out = render({"a": a, "b": b, "c": c}[v](), out)
    m = measure(out)
    print("できた:", out, "余白(左,上,右,下):", tuple(round(float(x), 1) for x in m["margin"]),
          "白いかたまり:", m["blobs"])
    if v == "a":
        ar = areas(out); k = ar[-1]
        print("黒い区画の画素:", ar, "比:", ":".join(f"{x/k:.2f}" for x in ar))
