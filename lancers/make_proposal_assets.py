# -*- coding: utf-8 -*-
"""ランサーズの提案（kintone配車管理・依頼5582104）に添付する説明図を生成する。

作るのは「構成の説明」と「費用の内訳」だけ。依頼フォームで
「デザイン等をこの時点で行うことは禁止」とされているため、
相手のシステムのUI案は作らない。

  1) sys-kousei.png … kintone と JavaScript の役割分担・費用の発生箇所
  2) sys-cost.png   … 機能ごとの実現手段と追加費用（有料プラグイン不使用の範囲）

再生成: cd ~/制作物/lancers && DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 make_proposal_assets.py
"""
import io
import os

import cairosvg
from PIL import Image, ImageDraw, ImageFont

W, H = 1200, 900
S = 2
PAPER = (244, 242, 238)
INK = (36, 35, 33)
CARD = (251, 250, 247)
LINE = (214, 210, 202)
SUB = (88, 85, 79)
MUTE = (150, 146, 138)

FONT_DISP = "/Library/Fonts/AP-OTF-A1GothicStd-Bold.otf"
FONT_NUM = "/Library/Fonts/Barlow-Bold.ttf"
A = "/System/Library/AssetsV2/com_apple_MobileAsset_Font7"
FONT_BODY = f"{A}/54ef167d6c8e99a69a0d41ce252cc5995ba47580.asset/AssetData/YuGothic-Medium.otf"
FONT_BODB = f"{A}/42062e40d643fdb5bb3fba917212352fb0690de0.asset/AssetData/YuGothic-Bold.otf"

OUT = os.path.dirname(os.path.abspath(__file__))

BLOCKS = (
    '<polygon points="35,46 50,53.5 35,61 20,53.5"/>'
    '<polygon points="20,53.5 35,61 35,76 20,68.5"/>'
    '<polygon points="50,53.5 35,61 35,76 50,68.5"/>'
    '<polygon points="65,46 80,53.5 65,61 50,53.5"/>'
    '<polygon points="50,53.5 65,61 65,76 50,68.5"/>'
    '<polygon points="80,53.5 65,61 65,76 80,68.5"/>'
    '<polygon points="50,24 65,31.5 50,39 35,31.5"/>'
    '<polygon points="35,31.5 50,39 50,54 35,46.5"/>'
    '<polygon points="65,31.5 50,39 50,54 65,46.5"/>'
)


def logo(px, sw=6.5):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
           f'width="{px}" height="{px}"><g fill="#F4F2EE" stroke="#242321" '
           f'stroke-width="{sw}" stroke-linejoin="round" stroke-linecap="round">'
           f'{BLOCKS}</g></svg>')
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=px, output_height=px)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def f(path, size):
    return ImageFont.truetype(path, size * S)


def header(im, d, title, kicker):
    M = 64 * S
    mark = logo(34 * S)
    im.paste(mark, (M, 50 * S), mark)
    d.text((M + 42 * S, 57 * S), "つみき", font=f(FONT_DISP, 17), fill=INK)

    kf = f(FONT_BODB, 13)
    kw = d.textlength(kicker, font=kf)
    d.rectangle([W * S - M - kw - 22 * S, 52 * S, W * S - M, 52 * S + 29 * S], fill=INK)
    d.text((W * S - M - kw - 11 * S, 58 * S), kicker, font=kf, fill=PAPER)

    d.text((M, 116 * S), title, font=f(FONT_DISP, 33), fill=INK)
    d.line([M, 176 * S, W * S - M, 176 * S], fill=LINE, width=2 * S)
    return M


def footer(im, d, note):
    M = 64 * S
    d.text((M, H * S - 52 * S), note, font=f(FONT_BODY, 13), fill=MUTE)
    d.text((W * S - M - d.textlength("tsumiki-apps.com", font=f(FONT_NUM, 13)),
            H * S - 52 * S), "tsumiki-apps.com", font=f(FONT_NUM, 13), fill=MUTE)


def card(d, box, title, rows, tone="light"):
    x0, y0, x1, y1 = box
    fill = CARD if tone == "light" else INK
    fg = INK if tone == "light" else PAPER
    sub = SUB if tone == "light" else (196, 192, 184)
    d.rounded_rectangle([x0, y0, x1, y1], 14 * S, fill=fill,
                        outline=(LINE if tone == "light" else INK), width=2 * S)
    d.text((x0 + 22 * S, y0 + 20 * S), title, font=f(FONT_DISP, 19), fill=fg)
    y = y0 + 62 * S
    bf = f(FONT_BODY, 14)
    for r in rows:
        if not r:                      # 空行は間隔だけ空ける（点を打たない）
            y += 30 * S
            continue
        d.ellipse([x0 + 24 * S, y + 7 * S, x0 + 30 * S, y + 13 * S],
                  fill=(MUTE if tone == "light" else (140, 136, 128)))
        d.text((x0 + 40 * S, y), r, font=bf, fill=sub)
        y += 30 * S


def arrow(d, x, y, w=26):
    """右向きの細い矢印。"""
    d.line([x, y, x + w * S, y], fill=(120, 116, 110), width=2 * S)
    d.polygon([(x + w * S, y - 5 * S), (x + w * S + 9 * S, y), (x + w * S, y + 5 * S)],
              fill=(120, 116, 110))


def make_kousei():
    im = Image.new("RGB", (W * S, H * S), PAPER)
    d = ImageDraw.Draw(im)
    M = header(im, d, "kintone ＋ JavaScript での構成", "構成のご提案")

    d.text((M, 196 * S), "kintone はデータと権限に徹し、配車ボードは JavaScript のカスタムビューとして作ります。",
           font=f(FONT_BODY, 15), fill=SUB)

    top, bot = 250 * S, 560 * S
    gap = 34 * S
    cw = (W * S - M * 2 - gap * 2) // 3

    card(d, (M, top, M + cw, bot), "kintone（データ）", [
        "案件（日付・時間・発着地・積載）", "車両マスタ／ドライバーマスタ",
        "定期便のひな形", "利用者の権限・変更履歴",
        "バックアップ・スマホ閲覧の土台",
    ])
    card(d, (M + cw + gap, top, M + cw * 2 + gap, bot), "JavaScript（配車ボード）", [
        "車両別／ドライバー別タイムライン", "未配車レーンからのドラッグ配車",
        "ドラッグでの車両・時間の変更", "配車状況による色分け",
        "重複チェック（画面＋保存時）",
    ], tone="dark")
    card(d, (M + cw * 2 + gap * 2, top, W * S - M, bot), "使う方", [
        "配車担当者：PCのブラウザだけ", "インストール・設定は不要",
        "kintone の画面からそのまま開く", "",
        "＜フェーズ2＞ドライバーのスマホ確認",
    ])

    mid = (top + bot) // 2
    arrow(d, M + cw + 3 * S, mid)
    arrow(d, M + cw * 2 + gap + 3 * S, mid)

    # 下帯：費用の発生箇所
    by0, by1 = 610 * S, 748 * S
    d.rounded_rectangle([M, by0, W * S - M, by1], 14 * S, fill=CARD,
                        outline=LINE, width=2 * S)
    d.text((M + 26 * S, by0 + 22 * S), "費用が発生するのは、ここだけです",
           font=f(FONT_DISP, 19), fill=INK)
    cols = [
        ("月額・年額", "kintone の利用料のみ"),
        ("有料プラグイン", "使いません（0円）"),
        ("有償ライブラリ", "使いません（0円）"),
        ("納品物", "ソースコード一式"),
    ]
    colw = (W * S - M * 2 - 52 * S) // 4
    for i, (k, v) in enumerate(cols):
        cx = M + 26 * S + colw * i
        d.text((cx, by0 + 70 * S), k, font=f(FONT_BODB, 13), fill=MUTE)
        d.text((cx, by0 + 94 * S), v, font=f(FONT_BODB, 15), fill=INK)

    footer(im, d, "※ kintone で JavaScript カスタマイズを行うには、スタンダードコース以上のご契約が必要です。")
    im.resize((W, H), Image.LANCZOS).save(os.path.join(OUT, "sys-kousei.png"), "PNG")
    print("✓ sys-kousei.png")


ROWS = [
    ("案件・車両・ドライバーの管理", "kintone の標準機能", "0円"),
    ("日／週単位の配車ボード", "JavaScript で自作", "0円"),
    ("車両別／ドライバー別タイムライン", "JavaScript で自作 ※", "0円"),
    ("ドラッグ＆ドロップでの配車・変更", "JavaScript で自作", "0円"),
    ("配車状況による色分け", "CSS / JavaScript", "0円"),
    ("車両・ドライバーの重複チェック", "JavaScript（画面＋保存時）", "0円"),
    ("案件の詳細確認・編集", "kintone 標準 ＋ JavaScript", "0円"),
    ("権限・変更履歴・バックアップ", "kintone の標準機能", "0円"),
]


def make_cost():
    im = Image.new("RGB", (W * S, H * S), PAPER)
    d = ImageDraw.Draw(im)
    M = header(im, d, "有料プラグインを使わずに、どこまでできるか", "費用の内訳")

    d.text((M, 196 * S), "ご要望の機能は、kintone の標準機能と JavaScript の自作で実現できます。",
           font=f(FONT_BODY, 15), fill=SUB)

    x0, x1 = M, W * S - M
    cx2 = x0 + 470 * S
    cx3 = x1 - 150 * S
    y = 250 * S
    rh = 52 * S

    d.rectangle([x0, y, x1, y + 44 * S], fill=INK)
    hf = f(FONT_BODB, 14)
    d.text((x0 + 20 * S, y + 12 * S), "ご希望の機能", font=hf, fill=PAPER)
    d.text((cx2 + 20 * S, y + 12 * S), "実現する手段", font=hf, fill=PAPER)
    d.text((cx3 + 20 * S, y + 12 * S), "追加費用", font=hf, fill=PAPER)
    y += 44 * S

    bf, nf = f(FONT_BODY, 15), f(FONT_BODB, 15)
    for i, (a, b, c) in enumerate(ROWS):
        if i % 2 == 0:
            d.rectangle([x0, y, x1, y + rh], fill=CARD)
        d.text((x0 + 20 * S, y + 15 * S), a, font=bf, fill=INK)
        d.text((cx2 + 20 * S, y + 15 * S), b, font=bf, fill=SUB)
        d.text((cx3 + 20 * S, y + 15 * S), c, font=nf, fill=INK)
        d.line([x0, y + rh, x1, y + rh], fill=LINE, width=1 * S)
        y += rh

    y += 26 * S
    d.rounded_rectangle([x0, y, x1, y + 108 * S], 14 * S, fill=CARD,
                        outline=LINE, width=2 * S)
    d.text((x0 + 24 * S, y + 20 * S),
           "※ FullCalendar の「車両別・ドライバー別の横軸タイムライン」は有償の Premium ライセンスが必要です。",
           font=f(FONT_BODB, 14), fill=INK)
    d.text((x0 + 24 * S, y + 50 * S),
           "　 月額・年額を抑えたいというご方針と衝突するため、この部分は無償の範囲＋自作で組む案を第一にご提案します。",
           font=f(FONT_BODY, 14), fill=SUB)
    d.text((x0 + 24 * S, y + 76 * S),
           "　 特殊な独自環境には依存させず、ソースコード一式を納品します（将来ほかの開発者が読める構成にします）。",
           font=f(FONT_BODY, 14), fill=SUB)

    footer(im, d, "※ 月額・年額で発生するのは kintone の利用料のみです。")
    im.resize((W, H), Image.LANCZOS).save(os.path.join(OUT, "sys-cost.png"), "PNG")
    print("✓ sys-cost.png")


make_kousei()
make_cost()
