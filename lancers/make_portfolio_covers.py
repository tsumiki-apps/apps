# -*- coding: utf-8 -*-
"""ランサーズ ポートフォリオのカバー画像（1000x782）を つみきの「紙×墨」で生成する。
右にスマホ実機の枠＋実スクリーンショット、左に見出しと要点を置く。
"""
import io, os
import cairosvg
from PIL import Image, ImageDraw, ImageFont

W, H = 1000, 782
S = 2
PAPER = (244, 242, 238)
INK = (36, 35, 33)
CARD = (251, 250, 247)
LINE = (214, 210, 202)
SUB = (88, 85, 79)

FONT_DISP = "/Library/Fonts/AP-OTF-A1GothicStd-Bold.otf"
FONT_NUM = "/Library/Fonts/Barlow-Bold.ttf"
A = "/System/Library/AssetsV2/com_apple_MobileAsset_Font7"
FONT_BODY = f"{A}/54ef167d6c8e99a69a0d41ce252cc5995ba47580.asset/AssetData/YuGothic-Medium.otf"
FONT_BODB = f"{A}/42062e40d643fdb5bb3fba917212352fb0690de0.asset/AssetData/YuGothic-Bold.otf"

SHOTS = "/Users/ko_dai/tsumiki-portfolio/assets/shots"
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


def logo(px, stroke="#242321", sw=4.5):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
           f'width="{px}" height="{px}"><g fill="#F4F2EE" stroke="{stroke}" '
           f'stroke-width="{sw}" stroke-linejoin="round" stroke-linecap="round">'
           f'{BLOCKS}</g></svg>')
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=px, output_height=px)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def f(path, size):
    return ImageFont.truetype(path, size * S)


def phone(shot, target_h):
    """スクショをスマホの枠に入れて返す（角丸＋細い墨の枠）。"""
    im = Image.open(os.path.join(SHOTS, shot)).convert("RGB")
    w = int(im.width * target_h / im.height)
    im = im.resize((w, target_h), Image.LANCZOS)
    pad, r = 10 * S, 34 * S
    fr = Image.new("RGBA", (w + pad * 2, target_h + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(fr)
    d.rounded_rectangle([0, 0, fr.width - 1, fr.height - 1], r + pad,
                        fill=(36, 35, 33, 255))
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, target_h - 1], r, fill=255)
    fr.paste(im, (pad, pad), mask)
    return fr


def cover(name, kicker, head, bullets, shot):
    im = Image.new("RGB", (W * S, H * S), PAPER)
    d = ImageDraw.Draw(im)
    M = 62 * S

    # 右：スマホ実機
    ph = phone(shot, 630 * S)
    im.paste(ph, (W * S - ph.width - 52 * S, (H * S - ph.height) // 2), ph)

    # 左上：ロゴ
    mark = logo(38 * S, sw=6.5)
    im.paste(mark, (M, 56 * S), mark)
    d.text((M + 46 * S, 64 * S), "つみき", font=f(FONT_DISP, 18), fill=INK)

    # キッカー
    kf = f(FONT_BODB, 14)
    kw = d.textlength(kicker, font=kf)
    d.rectangle([M, 130 * S, M + kw + 24 * S, 130 * S + 31 * S], fill=INK)
    d.text((M + 12 * S, 137 * S), kicker, font=kf, fill=PAPER)

    # 見出し
    y = 186 * S
    hf = f(FONT_DISP, 37)
    for ln in head:
        d.text((M, y), ln, font=hf, fill=INK)
        y += 52 * S

    d.line([M, y + 14 * S, M + 170 * S, y + 14 * S], fill=LINE, width=2 * S)

    # 要点
    y += 46 * S
    bf, tf = f(FONT_BODY, 17), f(FONT_BODB, 17)
    for b in bullets:
        d.ellipse([M + 2 * S, y + 8 * S, M + 9 * S, y + 15 * S], fill=(150, 146, 138))
        d.text((M + 22 * S, y), b, font=(tf if b.startswith("★") else bf),
               fill=(SUB if not b.startswith("★") else INK))
        y += 34 * S

    d.text((M, H * S - 74 * S), "tsumiki-apps.com", font=f(FONT_NUM, 14),
           fill=(150, 146, 138))

    out = os.path.join(OUT, name)
    im.resize((W, H), Image.LANCZOS).save(out, "PNG")
    print("✓", out)


cover("pf-kouban.png", "舞台・稽古／スケジュール",
      ["欠席者を選ぶだけで", "「今日できる場面」が出る"],
      ["各場面の出演者を一度だけ登録", "欠席をタップ → 稽古できる場面を自動抽出",
       "香盤表をA4のPDFで書き出し", "ブラウザだけで動く（インストール不要）"],
      "kouban-ph-today.png")

cover("pf-mazeiro.png", "美容室／ヘアカラー配合",
      ["レシピの比率から、", "必要なグラムを即計算"],
      ["「1：1.5」の比率と作りたい総量を入れるだけ", "2剤（オキシ）の倍率にも対応",
       "総量からの逆算もできる", "混ぜ間違いによる材料のロスを減らす"],
      "mazeiro-ph-two.png")

cover("pf-dakoku.png", "人材派遣／勤怠管理",
      ["現場の打刻から", "請求算定まで一本に"],
      ["労働者用と管理者用、対になる2つのアプリ", "現場はタップで出勤・退勤を記録",
       "会社側は勤務表の集計・書き出し・請求算定まで", "データはクラウドで共有"],
      "dakoku-kanri-ph-table.png")

cover("pf-credit.png", "経理・家計／明細の自動集計",
      ["明細CSVを読み込むだけで", "カテゴリ別に自動集計"],
      ["CSVを放り込むと支出をカテゴリ別に自動集計", "立て替え・分割払いを切り分け",
       "「自分の実質支出」と前月比を自動算出", "手作業の仕分けをゼロにする"],
      "credit-ph-sum.png")

cover("pf-teppari.png", "舞台・稽古／進行管理",
      ["きょう稽古できる場面が", "ひと目でわかるボード"],
      ["キャスト全員のNGを1枚の表に集約", "その日の顔ぶれから、できる場面を自動判定",
       "「あと1人でできる場面」と不足者も表示", "香盤表と同じデータのまま貼り出し用に印刷"],
      "teppari-ph-board.png")
