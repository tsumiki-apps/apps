# -*- coding: utf-8 -*-
"""いつつ / こえがき の apple-touch-icon（モノクロ線画）を追加生成する。
既存の make_icons_mono.py の render() をそのまま再利用して、作風を統一する。
"""
from make_icons_mono import render

NEW = {
    # いつつ＝ブランドマークの5つの点（小→大→小）。1日を5つに。
    "itsutsu": '<circle cx="24" cy="50" r="4"   fill="#fff" stroke="none"/>'
               '<circle cx="37" cy="50" r="6.5" fill="#fff" stroke="none"/>'
               '<circle cx="50" cy="50" r="9"   fill="#fff" stroke="none"/>'
               '<circle cx="63" cy="50" r="6.5" fill="#fff" stroke="none"/>'
               '<circle cx="76" cy="50" r="4"   fill="#fff" stroke="none"/>',
    # こえがき＝声の波形（音声入力キーボード）。中央そろえのバー。
    "koegaki": '<line x1="30" y1="42" x2="30" y2="58"/>'
               '<line x1="40" y1="32" x2="40" y2="68"/>'
               '<line x1="50" y1="26" x2="50" y2="74"/>'
               '<line x1="60" y1="34" x2="60" y2="66"/>'
               '<line x1="70" y1="44" x2="70" y2="56"/>',
}

if __name__ == "__main__":
    for name, inner in NEW.items():
        print("✓", render(name, inner))
