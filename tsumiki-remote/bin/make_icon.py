# -*- coding: utf-8 -*-
"""つみきリモートの apple-touch-icon / PWAアイコンを作る。

作法は既存アプリと同じ（make_icons_mono.py と同一）：
  黒背景 #1c1c1c ＋ 白の線画、線幅4.5(100座標系)、round cap/join、中央配置。
図案＝スマホの中にターミナルのプロンプト（>_）。
「手元の端末からターミナルを叩く」をそのまま形にしたもの。

PWA用に 180px と 512px の2枚を public/ に書き出す。
"""
import os
os.environ.setdefault("DYLD_LIBRARY_PATH", "/opt/homebrew/lib")
import io
import cairosvg
from PIL import Image

BG = "#1c1c1c"
STROKE = "#ffffff"
SW = 4.5
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "public")

# 図案の外接は概ね y=22..78。既存アイコン（icon-index など）と同じくらいの
# 占有率に収める。スマホは縦長なので、幅ではなく高さを既存に合わせるのがコツ。
INNER = (
    '<rect x="33" y="22" width="34" height="56" rx="8"/>'   # スマホ本体
    '<line x1="45" y1="30" x2="55" y2="30"/>'               # 受話口
    '<path d="M42,47 L47,52 L42,57"/>'                      # プロンプトの >
    '<line x1="51" y1="57" x2="58" y2="57"/>'               # カーソルの _
)


def render(size, path):
    r = size * 3
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
        f'width="{r}" height="{r}">'
        f'<rect x="0" y="0" width="100" height="100" fill="{BG}"/>'
        f'<g fill="none" stroke="{STROKE}" stroke-width="{SW}" '
        f'stroke-linecap="round" stroke-linejoin="round">{INNER}</g></svg>'
    )
    png = cairosvg.svg2png(bytestring=svg.encode("utf-8"), output_width=r, output_height=r)
    img = Image.open(io.BytesIO(png)).convert("RGB").resize((size, size), Image.LANCZOS)
    img.save(path, "PNG")
    return path


if __name__ == "__main__":
    for size in (180, 512):
        print("✓", render(size, os.path.join(OUT_DIR, f"icon-{size}.png")))
