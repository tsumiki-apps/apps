#!/usr/bin/env python3
"""
生成AIが出したイラストの色を、つみきサイトの正式パレットに揃える。

やっていること：
  1. 画素ごとに「紙からどの色へ、どれだけ寄っているか」を測る（＝アンチエイリアスの濃度）
  2. その濃度は保ったまま、色だけを正式パレットに置き換える
  → 線のギザギザを壊さずに、色ムラ・背景ノイズだけが消える

使い方：
    python3 色を合わせる.py 入力.png [出力.png]          紙の背景つき
    python3 色を合わせる.py 入力.png 出力.png --透過      背景を透明に

--透過 は「紙からの寄り具合」をそのまま不透明度にするので、
線のギザギザが濁らず、どんな色の背景にも自然に乗ります。
"""
import sys, pathlib
import numpy as np
from PIL import Image

PAPER = np.array([244, 242, 238], float)          # 紙 #F4F2EE
TARGETS = {                                        # 紙以外の正式色
    "ink":      np.array([36, 35, 33], float),     # 墨 #242321
    "ghost":    np.array([190, 185, 176], float),  # 淡墨 #BEB9B0
    "softfill": np.array([241, 205, 187], float),  # 淡朱 #F1CDBB
    "accent":   np.array([209, 78, 38], float),    # 朱 #D14E26
}

def main(src, dst, alpha=False):
    im = np.asarray(Image.open(src).convert("RGB"), float)
    h, w, _ = im.shape
    d = im.reshape(-1, 3) - PAPER                  # 紙からのズレ

    # 各正式色への「射影量 t」と「そこからの外れ具合」を出す
    ts, errs = [], []
    for c in TARGETS.values():
        v = c - PAPER
        t = np.clip((d @ v) / (v @ v), 0, 1)
        errs.append(np.linalg.norm(d - t[:, None] * v, axis=1))
        ts.append(t)
    ts, errs = np.stack(ts), np.stack(errs)

    best = errs.argmin(0)                          # いちばん近い色を選ぶ
    t = ts[best, np.arange(ts.shape[1])]

    # 中間のサーモン色は「薄めた朱」と「淡朱」の見分けがつかない。
    # 朱は線や記号として必ず濃く使うので、薄い朱判定は淡朱に寄せる。
    # （※ この付け替えは、下のノイズ除去より必ず先に行うこと。
    #    順番を逆にすると、紙に戻したはずの背景ノイズが淡朱として復活する）
    names = list(TARGETS)
    ai, si = names.index("accent"), names.index("softfill")
    weak = (best == ai) & (t < 0.70)
    if weak.any():
        best[weak] = si
        t[weak] = ts[si][weak]
        print(f"  薄い朱 {weak.sum():>8,}px を淡朱と判定し直し")

    # ごく薄い画素は「背景のノイズ」とみなして紙に戻す（JPEG由来のムラ取り）
    noise = t < 0.10
    t[noise] = 0.0
    print(f"  背景ノイズ {noise.sum():>8,}px を紙に統一")

    # 色ごとに、線の芯が「濃度100%」になるよう伸ばす（淡墨が薄い等を補正）
    for i, name in enumerate(TARGETS):
        m = (best == i) & (t > 0.35)
        if m.sum() < 50:
            continue
        core = np.percentile(t[m], 98)
        if core < 0.60:   # 芯が薄すぎるものは誤判定の疑い。伸ばすと色が化けるので触らない
            print(f"  {name:9s} {m.sum():>8,}px  芯の濃度 {core:.2f} … 薄いので補正せず")
            continue
        t[best == i] = np.clip(t[best == i] / core, 0, 1)
        print(f"  {name:9s} {m.sum():>8,}px  芯の濃度 {core:.2f} → 1.00")

    tg = np.stack(list(TARGETS.values()))[best]

    if alpha:
        # 「紙からの寄り具合 t」をそのまま不透明度にする。
        # 紙の上に重ねれば元と完全に同じ見え方になり、他の色の背景にも濁らず乗る。
        rgba = np.concatenate([tg, (t * 255)[:, None]], 1)
        img = Image.fromarray(rgba.reshape(h, w, 4).round().clip(0, 255).astype(np.uint8), "RGBA")
        print(f"  透過：不透明な画素 {(t > 0.99).sum():,} / 全 {t.size:,}")
    else:
        out = PAPER + t[:, None] * (tg - PAPER)
        img = Image.fromarray(out.reshape(h, w, 3).round().clip(0, 255).astype(np.uint8))
    img.save(dst)
    print(f"  → {dst}")

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    alpha = "--透過" in sys.argv
    src = pathlib.Path(args[0])
    suffix = "_透過" if alpha else "_色調整"
    dst = pathlib.Path(args[1]) if len(args) > 1 else src.with_stem(src.stem + suffix)
    print(f"{src.name}")
    main(src, dst, alpha)
