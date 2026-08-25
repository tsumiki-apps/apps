# -*- coding: utf-8 -*-
"""アイコンの右下に つみき公式ロゴ を入れる。
   ⚠️ 座標は Preferences/tsumiki-official-logo.md の正本をそのままコピー（簡略化しない）。
   ⚠️ 各面は「背景と同じ色」で塗る（fill="none" にしない＝立体に見えなくなる）。"""
import subprocess, pathlib, tempfile, shutil
from PIL import Image, ImageDraw, ImageFont
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BG="#1c1c1c"; LINE="#ffffff"

# 公式ロゴの9つの面（正本の points をそのまま）
TSUMIKI_POLYS = (
 '<polygon points="35,46 50,53.5 35,61 20,53.5"/><polygon points="20,53.5 35,61 35,76 20,68.5"/>'
 '<polygon points="50,53.5 35,61 35,76 50,68.5"/><polygon points="65,46 80,53.5 65,61 50,53.5"/>'
 '<polygon points="50,53.5 65,61 65,76 50,68.5"/><polygon points="80,53.5 65,61 65,76 80,68.5"/>'
 '<polygon points="50,24 65,31.5 50,39 35,31.5"/><polygon points="35,31.5 50,39 50,54 35,46.5"/>'
 '<polygon points="65,31.5 50,39 50,54 65,46.5"/>')

def tsumiki_badge(scale, right=93.0, bottom=93.0, sw_visible=3.2, knock=None):
    """絵の実寸は x20..80 / y24..76（60×52）。右下にそろえて置く。"""
    w, h = 60*scale, 52*scale
    tx = right - w - 20*scale
    ty = bottom - h - 24*scale
    sw = sw_visible/scale                      # 見た目の線の太さを一定にする
    pre = ''
    if knock:                                   # 後ろの絵を消す下敷き
        cx, cy = right-w/2, bottom-h/2
        pre = (f'<rect x="{cx-w/2-knock}" y="{cy-h/2-knock}" width="{w+knock*2}" '
               f'height="{h+knock*2}" rx="{knock*1.6}" fill="{BG}" stroke="none"/>')
    return (pre + f'<g transform="translate({tx:.2f},{ty:.2f}) scale({scale})" '
            f'fill="{BG}" stroke="{LINE}" stroke-width="{sw:.2f}" '
            f'stroke-linejoin="round" stroke-linecap="round">{TSUMIKI_POLYS}</g>')

def render(body, out, px=540):
    d=tempfile.mkdtemp(); h=pathlib.Path(d)/'i.html'
    svg=(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="{px}" height="{px}">'
         f'<rect width="100" height="100" fill="{BG}"/>{body}</svg>')
    h.write_text(f'<!doctype html><meta charset="utf-8"><style>html,body{{margin:0;background:{BG}}}'
                 f'svg{{display:block}}</style>'+svg)
    p=pathlib.Path(d)/'s.png'
    subprocess.run([CHROME,"--headless","--disable-gpu","--hide-scrollbars",
                    f"--screenshot={p}",f"--window-size={px},{px}",f"file://{h}"],capture_output=True)
    Image.open(p).convert('RGB').resize((180,180),Image.LANCZOS).save(out)
    shutil.rmtree(d,ignore_errors=True); return out

def main_sym(inner, sw=6, shrink=None):
    g=f'<g fill="none" stroke="{LINE}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round">{inner}</g>'
    if shrink: g=f'<g transform="translate({shrink[0]},{shrink[1]}) scale({shrink[2]})">{g}</g>'
    return g
