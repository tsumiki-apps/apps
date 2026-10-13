# -*- coding: utf-8 -*-
"""動画同期・横動画字幕のホーム画面アイコン（180×180）。
   つみきのアイコンの型（黒地に白い線画1個・右下に小さく Apple ロゴ＝仕事用）。
   動画同期＝縦長の画面、横動画字幕＝横長の画面。どちらも再生の三角と字幕の線。
   実行： douga-sync/.venv/bin/python make_icons_video.py   → douga-sync/ と yoko-jimaku/ の apple-touch-icon.png
"""
import pathlib
import _icon_kit as K

# Apple ロゴ（make_icons_mono.py と同じ形・24×24 座標）
APPLE_PATH = (
    "M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 "
    "3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 "
    "3.043 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 "
    "1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 "
    "1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 "
    "2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 "
    "1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 "
    "1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"
)

HERE = pathlib.Path(__file__).resolve().parent


class Apple:
    """Apple ロゴ（塗り）。24 座標の見た目の範囲。"""
    box = (3.23, 0.0, 20.03, 24.0)

    def size(self, s):
        return ((self.box[2] - self.box[0]) * s, (self.box[3] - self.box[1]) * s)

    def svg(self, s, left, top):
        dx, dy = left - self.box[0] * s, top - self.box[1] * s
        return (f'<g transform="translate({dx:.3f},{dy:.3f}) scale({s})" fill="{K.LINE}" stroke="none">'
                f'<path d="{APPLE_PATH}"/></g>')


def screen(w, h):
    """角丸の画面＋再生の三角＋下に字幕の線1本（w×h の箱）。線が詰まらないよう中は2つだけ。"""
    cx, cy = w / 2, h * 0.38
    t = min(w, h) * 0.16
    tri = f'<path d="M{cx - t * 0.8:.1f},{cy - t:.1f} L{cx + t:.1f},{cy:.1f} L{cx - t * 0.8:.1f},{cy + t:.1f} Z"/>'
    y1, l1 = h * 0.76, min(w * 0.28, 14)
    line = f'<path d="M{cx - l1:.1f},{y1:.1f} H{cx + l1:.1f}"/>'
    body = f'<rect x="0" y="0" width="{w}" height="{h}" rx="{min(w, h) * 0.18:.1f}"/>' + tri + line
    return K.Sym(body, 0, 0, w, h)


def build(sym, s, out, apple_s=0.55, gap=3.0):
    """本体の右下に Apple ロゴ。重ねず、かたまりごと中央へ。"""
    bw, bh = sym.size(s)
    aw, ah = Apple().size(apple_s)
    parts = [(sym, s, 0, 0), (Apple(), apple_s, bw + gap, bh - ah)]
    svg, info = K.compose(parts)
    K.render(svg, out)
    m = K.measure(out)
    print(out.relative_to(HERE), "余白", [round(x, 1) for x in m["margin"]], "塊", m["blobs"])


if __name__ == "__main__":
    build(screen(40, 70), 0.80, HERE / "douga-sync" / "apple-touch-icon.png")
    build(screen(72, 44), 0.78, HERE / "yoko-jimaku" / "apple-touch-icon.png")
