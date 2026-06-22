# -*- coding: utf-8 -*-
"""つみきTOPのアプリアイコン(icon-index.png)を、TOPタイトル横のロゴと同じ
アイソメトリック積み木(立体・モノクロ)で生成する。
make_icons_mono.py の outline 版とは別に、index だけこの立体版で上書きする。
画面(index.html)のインラインSVGと座標・色を完全に一致させること。
"""
import os
os.environ.setdefault("DYLD_LIBRARY_PATH", "/opt/homebrew/lib")
import io
import cairosvg
from PIL import Image

SIZE = 180          # iPhone @3x
RENDER = 540        # 3倍でレンダ→縮小
OUT = "icons/icon-index.png"
BG = "#242321"      # ページのink(タイトル横バッジと同じ)

BLOCKS = (
    # 左下の積み木
    '<polygon points="20,53.5 35,61 35,76 20,68.5" fill="#8E877D"/>'
    '<polygon points="50,53.5 35,61 35,76 50,68.5" fill="#BDB6AC"/>'
    '<polygon points="35,46 50,53.5 35,61 20,53.5" fill="#F4F2EE"/>'
    # 右下の積み木
    '<polygon points="50,53.5 65,61 65,76 50,68.5" fill="#8E877D"/>'
    '<polygon points="80,53.5 65,61 65,76 80,68.5" fill="#BDB6AC"/>'
    '<polygon points="65,46 80,53.5 65,61 50,53.5" fill="#F4F2EE"/>'
    # 上の積み木
    '<polygon points="35,31.5 50,39 50,54 35,46.5" fill="#8E877D"/>'
    '<polygon points="65,31.5 50,39 50,54 65,46.5" fill="#BDB6AC"/>'
    '<polygon points="50,24 65,31.5 50,39 35,31.5" fill="#F4F2EE"/>'
)

svg = (
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
    f'width="{RENDER}" height="{RENDER}">'
    f'<rect x="0" y="0" width="100" height="100" fill="{BG}"/>'
    f'<g stroke="{BG}" stroke-width="2" stroke-linejoin="round">{BLOCKS}</g></svg>'
)

png = cairosvg.svg2png(bytestring=svg.encode("utf-8"),
                       output_width=RENDER, output_height=RENDER)
img = Image.open(io.BytesIO(png)).convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
img.save(OUT, "PNG")
print("✓", OUT)
