# -*- coding: utf-8 -*-
"""ホーム画面用 apple-touch-icon を生成する。
絵文字を Apple Color Emoji で描画し、テーマ色グラデ背景の 180x180 PNG を出力。
"""
import os
from PIL import Image, ImageDraw, ImageFont

EMOJI_FONT = "/System/Library/Fonts/Apple Color Emoji.ttc"
SIZE = 180          # iPhone @3x 標準サイズ
OUT_DIR = "icons"

# app名: (絵文字, 上の色, 下の色)  ※縦グラデーション
APPS = {
    "index":       ("🧱", "#3a93f0", "#0a63c9"),
    "cooking":     ("🍋", "#ffb86b", "#e8843b"),
    "credit":      ("💳", "#5a9bf0", "#2f6fd0"),
    "forecast":    ("📈", "#2fd6b0", "#00a98a"),
    "grownote":    ("🌱", "#5fd87a", "#27a34a"),
    "nps":         ("🎯", "#ff8a8a", "#e85454"),
    "osusowake":   ("🎁", "#ff9a76", "#ef6a45"),
    "money":       ("💰", "#ffc94d", "#f0a319"),
    "recap":       ("📆", "#7d7bf0", "#4f4dd0"),
    "schedule":    ("🗓️", "#5ac8e8", "#1f8fd0"),
    "recognition": ("✨", "#ffd35e", "#f5a623"),
    "reflection":  ("🪞", "#73cffb", "#36a7e8"),
    "team5whys":   ("🌳", "#3fb87a", "#1f8a55"),
    "tsunagu":     ("🌟", "#9b8dff", "#6d5efc"),
    "vault":       ("🔐", "#8a97b5", "#586585"),
    "career":      ("🗂️", "#4db6ac", "#00897b"),
    "tsugi":       ("⏰", "#5fd3c3", "#15a892"),
    "copybox":     ("📋", "#7fa8ff", "#4d6fe0"),
    "tabinoki":    ("🌴", "#3fd4c4", "#0d9488"),
    "yarukoto":    ("✅", "#7c8bff", "#4f5edb"),
    "interview":   ("🎤", "#7b8cff", "#4f5bd5"),
    "check":       ("🔍", "#8fa3c8", "#54648c"),
    "serifu":      ("🎭", "#b08bff", "#7a4ddb"),
    "jinsei":      ("🎲", "#ff8fc8", "#9a6df0"),
    "trump":       ("🃏", "#2fa86b", "#0d6b3f"),
    "yuzuwari":    ("🍋", "#ffe26b", "#f0a319"),
    "kakeru":      ("🏃", "#3ad6c5", "#1f7fe0"),
}


def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def gradient(w, h, top, bottom):
    top, bottom = hex2rgb(top), hex2rgb(bottom)
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        r = round(top[0] + (bottom[0] - top[0]) * t)
        g = round(top[1] + (bottom[1] - top[1]) * t)
        b = round(top[2] + (bottom[2] - top[2]) * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def render_emoji(emoji):
    """Apple Color Emoji を高解像度で描画して透過PNGで返す。"""
    strike = 160  # フォントが持つビットマップサイズ
    font = ImageFont.truetype(EMOJI_FONT, strike)
    layer = Image.new("RGBA", (strike * 2, strike * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.text((strike, strike), emoji, font=font, embedded_color=True, anchor="mm")
    return layer.crop(layer.getbbox())


def make(name, emoji, top, bottom):
    scale = 4  # アンチエイリアス用に4倍で作って縮小
    big = SIZE * scale
    bg = gradient(big, big, top, bottom).convert("RGBA")

    em = render_emoji(emoji)
    target = int(big * 0.60)  # 絵文字は60%サイズ
    ratio = target / max(em.size)
    em = em.resize((round(em.width * ratio), round(em.height * ratio)), Image.LANCZOS)

    # 軽い影を付けて立体感
    shadow = Image.new("RGBA", bg.size, (0, 0, 0, 0))
    sx = (big - em.width) // 2
    sy = (big - em.height) // 2
    bg.alpha_composite(em, (sx, sy))

    out = bg.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"icon-{name}.png")
    out.save(path, "PNG")
    return path


if __name__ == "__main__":
    for name, (emoji, top, bottom) in APPS.items():
        p = make(name, emoji, top, bottom)
        print("✓", p)
