# -*- coding: utf-8 -*-
"""各HTMLの viewport メタ直後に apple-touch-icon と短い表示名を注入。
二重注入を防ぐため、既に apple-touch-icon があるファイルはスキップ。
"""
import re

# app名: ホーム画面に表示する短い名前
TITLES = {
    "index":       "つみき",
    "cooking":     "ゆずごはん",
    "credit":      "クレジット明細",
    "forecast":    "資産予測",
    "grownote":    "GROWノート",
    "kouban":      "香盤メーカー",
    "nps":         "NPS計算",
    "money":       "残高計算",
    "recap":       "Recap",
    "schedule":    "予定変換",
    "recognition": "Recognition",
    "reflection":  "振り返り",
    "team5whys":   "5Whys",
    "tsunagu":     "ツナグ",
    "hitokoma":    "ひとこま",
    "hitonowa":    "ひとのわ",
}

VIEWPORT_RE = re.compile(r'(<meta\s+name="viewport"[^>]*>)', re.IGNORECASE)

for name, title in TITLES.items():
    path = f"{name}.html"
    html = open(path, encoding="utf-8").read()
    if "apple-touch-icon" in html:
        print(f"- {path}: 既に注入済み・スキップ")
        continue
    block = (
        '\\1\n'
        f'<link rel="apple-touch-icon" href="icons/icon-{name}.png">\n'
        f'<meta name="apple-mobile-web-app-title" content="{title}">'
    )
    new = VIEWPORT_RE.sub(block, html, count=1)
    if new == html:
        print(f"! {path}: viewport が見つからず注入できませんでした")
        continue
    open(path, "w", encoding="utf-8").write(new)
    print(f"✓ {path}: icon-{name}.png / 「{title}」")
