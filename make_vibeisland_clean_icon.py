# -*- coding: utf-8 -*-
"""「Vibe Island 掃除.app」の macOS アプリアイコン(.icns)をモノクロ線画で生成する。

作風は つみき のホーム画面アイコン（make_icons_mono.py）と同じ:
  黒地(#1c1c1c) ＋ 白い太線の線画(round cap/join)・中央配置。
macOS 用なので、iOS の全面ベタ塗りではなく Big Sur 以降の角丸タイル
（1024中 824＝80%の角丸矩形・周囲は透明）に収めている。

使い方:
  DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 make_vibeisland_clean_icon.py
  → icons/vibeisland-clean.icns を書き出し、掃除.app にインストールする。
"""
import os
import subprocess
import shutil

os.environ.setdefault("DYLD_LIBRARY_PATH", "/opt/homebrew/lib")
import cairosvg  # noqa: E402

BG = "#1c1c1c"
STROKE = "#ffffff"
SW = 4.5                      # 100座標系での線幅（つみき既存アイコンと同じ）
APP = "/Applications/Vibe Island 掃除.app"
OUT_ICNS = "icons/vibeisland-clean.icns"

# 掃除＝ほうき（少し傾けた柄＋台形のブラシ＋毛の線）と、きらめき2つ。
ART = (
    # 柄
    '<line x1="66" y1="20" x2="55" y2="47"/>'
    # ブラシ本体（下に向かって広がる台形）
    '<path d="M44,47 L66,47 L72,72 L38,72 Z"/>'
    # 毛の線
    '<line x1="51" y1="49" x2="48" y2="70"/>'
    '<line x1="59" y1="49" x2="62" y2="70"/>'
    # きらめき（塗り）
    '<path d="M28,30 C29.4,34.6 30.4,35.6 35,37 C30.4,38.4 29.4,39.4 28,44 '
    'C26.6,39.4 25.6,38.4 21,37 C25.6,35.6 26.6,34.6 28,30 Z" fill="#fff" stroke="none"/>'
    '<path d="M36,58 C36.9,61 37.5,61.6 40.5,62.5 C37.5,63.4 36.9,64 36,67 '
    'C35.1,64 34.5,63.4 31.5,62.5 C34.5,61.6 35.1,61 36,58 Z" fill="#fff" stroke="none"/>'
)

SVG = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <rect x="10" y="10" width="80" height="80" rx="18" ry="18" fill="{BG}"/>
  <g transform="translate(10,10) scale(0.8)"
     fill="none" stroke="{STROKE}" stroke-width="{SW}"
     stroke-linecap="round" stroke-linejoin="round">
    {ART}
  </g>
</svg>'''


def render(path, px):
    cairosvg.svg2png(bytestring=SVG.encode("utf-8"), write_to=path,
                     output_width=px, output_height=px)


def main():
    os.makedirs("icons", exist_ok=True)
    iconset = "icons/vibeisland-clean.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)

    for base in (16, 32, 128, 256, 512):
        render(f"{iconset}/icon_{base}x{base}.png", base)
        render(f"{iconset}/icon_{base}x{base}@2x.png", base * 2)

    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT_ICNS], check=True)
    shutil.rmtree(iconset, ignore_errors=True)
    print(f"✅ 生成: {OUT_ICNS}")

    # プレビュー用に単体PNGも残す
    render("icons/vibeisland-clean-512.png", 512)

    dest = f"{APP}/Contents/Resources/AppIcon.icns"
    if os.path.isdir(APP):
        shutil.copyfile(OUT_ICNS, dest)
        subprocess.run(["touch", APP], check=False)
        print(f"✅ インストール: {dest}")
    else:
        print(f"⚠️  アプリが見つかりません: {APP}")


if __name__ == "__main__":
    main()
