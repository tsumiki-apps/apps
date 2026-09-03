# -*- coding: utf-8 -*-
"""つみきTOPのアプリアイコン(icon-index.png)を、TOPタイトル横のロゴと同じ
アイソメトリック積み木(立体・モノクロ)で生成する。
make_icons_mono.py の outline 版とは別に、index だけこの立体版で上書きする。
画面(index.html)のインラインSVGと座標・色を完全に一致させること。
"""
import io, pathlib, shutil, subprocess, tempfile
from PIL import Image

# cairosvg は libcairo が入っておらず動かないため、Chrome ヘッドレスで描く
# （_icon_kit.py と同じやり方）
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

SIZE = 180          # iPhone @3x
RENDER = 540        # 3倍でレンダ→縮小
OUT = "icons/icon-index.png"
BG = "#242321"      # ページのink(タイトル横バッジと同じ)

STROKE = "#F4F2EE"  # 白線（紙色）。各面は背景色で塗り、後ろの稜線を隠す
BLOCKS = (
    # 左下の積み木
    '<polygon points="35,46 50,53.5 35,61 20,53.5"/>'
    '<polygon points="20,53.5 35,61 35,76 20,68.5"/>'
    '<polygon points="50,53.5 35,61 35,76 50,68.5"/>'
    # 右下の積み木
    '<polygon points="65,46 80,53.5 65,61 50,53.5"/>'
    '<polygon points="50,53.5 65,61 65,76 50,68.5"/>'
    '<polygon points="80,53.5 65,61 65,76 80,68.5"/>'
    # 上の積み木（最前面：背景塗りで後ろの線を隠す）
    '<polygon points="50,24 65,31.5 50,39 35,31.5"/>'
    '<polygon points="35,31.5 50,39 50,54 35,46.5"/>'
    '<polygon points="65,31.5 50,39 50,54 65,46.5"/>'
)

svg = (
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
    f'width="{RENDER}" height="{RENDER}">'
    f'<rect x="0" y="0" width="100" height="100" fill="{BG}"/>'
    f'<g fill="{BG}" stroke="{STROKE}" stroke-width="4.5" '
    f'stroke-linejoin="round" stroke-linecap="round">{BLOCKS}</g></svg>'
)

d = pathlib.Path(tempfile.mkdtemp())
html = d / "i.html"
html.write_text(
    f'<!doctype html><meta charset="utf-8">'
    f'<style>html,body{{margin:0;background:{BG}}}svg{{display:block}}</style>{svg}',
    encoding="utf-8")
shot = d / "s.png"
subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
                f"--screenshot={shot}", f"--window-size={RENDER},{RENDER}",
                f"file://{html}"], capture_output=True)
img = Image.open(shot).convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
img.save(OUT, "PNG")
shutil.rmtree(d, ignore_errors=True)
print("✓", OUT)
