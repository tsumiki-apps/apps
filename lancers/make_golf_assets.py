# -*- coding: utf-8 -*-
"""ランサーズ 依頼5584306（ゴルフスクールの上達レッスンカルテ）の提案に添付する説明図。

作るのは「構成の説明」「費用の比較」「項目の案」だけ。
フォームの「デザイン等をこの時点で行うことは禁止」に触れないよう、
相手のシステムの画面デザイン（UIモック）は作らない。

  1) golf-kousei.png  … iPad入力 → クラウド保管 → 1枚カルテでお渡し の構成
  2) golf-cost.png    … kintoneで作る場合と今回のご提案の、3年分の費用比較
  3) golf-koumoku.png … 上達を数値化する項目と、見える化のしかたの一覧

再生成: cd ~/制作物/lancers && DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 make_golf_assets.py
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


def header(im, d, title, kicker, sub=None):
    M = 64 * S
    mark = logo(34 * S)
    im.paste(mark, (M, 50 * S), mark)
    d.text((M + 42 * S, 57 * S), "つみき", font=f(FONT_DISP, 17), fill=INK)

    kf = f(FONT_BODB, 13)
    kw = d.textlength(kicker, font=kf)
    d.rectangle([W * S - M - kw - 22 * S, 52 * S, W * S - M, 52 * S + 29 * S], fill=INK)
    d.text((W * S - M - kw - 11 * S, 58 * S), kicker, font=kf, fill=PAPER)

    d.text((M, 116 * S), title, font=f(FONT_DISP, 29), fill=INK)
    d.line([M, 176 * S, W * S - M, 176 * S], fill=LINE, width=2 * S)
    if sub:
        d.text((M, 196 * S), sub, font=f(FONT_BODY, 15), fill=SUB)
    return M


def footer(im, d, note):
    M = 64 * S
    d.text((M, H * S - 52 * S), note, font=f(FONT_BODY, 13), fill=MUTE)
    t = "tsumiki-apps.com"
    d.text((W * S - M - d.textlength(t, font=f(FONT_NUM, 13)), H * S - 52 * S),
           t, font=f(FONT_NUM, 13), fill=MUTE)


def card(d, box, title, rows, tone="light"):
    x0, y0, x1, y1 = box
    fill = CARD if tone == "light" else INK
    fg = INK if tone == "light" else PAPER
    sub = SUB if tone == "light" else (196, 192, 184)
    d.rounded_rectangle([x0, y0, x1, y1], 14 * S, fill=fill,
                        outline=(LINE if tone == "light" else INK), width=2 * S)
    d.text((x0 + 22 * S, y0 + 20 * S), title, font=f(FONT_DISP, 17), fill=fg)
    y = y0 + 62 * S
    bf = f(FONT_BODY, 13)
    for r in rows:
        if not r:
            y += 28 * S
            continue
        d.ellipse([x0 + 24 * S, y + 7 * S, x0 + 30 * S, y + 13 * S],
                  fill=(MUTE if tone == "light" else (140, 136, 128)))
        d.text((x0 + 40 * S, y), r, font=bf, fill=sub)
        y += 28 * S


def arrow(d, x, y, w=26):
    d.line([x, y, x + w * S, y], fill=(120, 116, 110), width=2 * S)
    d.polygon([(x + w * S, y - 5 * S), (x + w * S + 9 * S, y), (x + w * S, y + 5 * S)],
              fill=(120, 116, 110))


def band(d, M, y0, y1, title, cols):
    d.rounded_rectangle([M, y0, W * S - M, y1], 14 * S, fill=CARD, outline=LINE, width=2 * S)
    d.text((M + 26 * S, y0 + 22 * S), title, font=f(FONT_DISP, 18), fill=INK)
    colw = (W * S - M * 2 - 52 * S) // max(len(cols), 1)
    for i, (k, v) in enumerate(cols):
        cx = M + 26 * S + colw * i
        d.text((cx, y0 + 68 * S), k, font=f(FONT_BODB, 13), fill=MUTE)
        d.text((cx, y0 + 92 * S), v, font=f(FONT_BODB, 15), fill=INK)


def three_cards(name, kicker, title, sub, cards, band_title, band_cols, note):
    im = Image.new("RGB", (W * S, H * S), PAPER)
    d = ImageDraw.Draw(im)
    M = header(im, d, title, kicker, sub)
    top, bot = 250 * S, 570 * S
    gap = 34 * S
    cw = (W * S - M * 2 - gap * 2) // 3
    for i, (t, rows, tone) in enumerate(cards):
        x0 = M + (cw + gap) * i
        card(d, (x0, top, x0 + cw, bot), t, rows, tone)
    mid = (top + bot) // 2
    arrow(d, M + cw + 3 * S, mid)
    arrow(d, M + cw * 2 + gap + 3 * S, mid)
    band(d, M, 616 * S, 754 * S, band_title, band_cols)
    footer(im, d, note)
    im.resize((W, H), Image.LANCZOS).save(os.path.join(OUT, name), "PNG")
    print("✓", name)


def table_img(name, kicker, title, sub, headers, rows, notes, colx=(470, 150), rh=52):
    im = Image.new("RGB", (W * S, H * S), PAPER)
    d = ImageDraw.Draw(im)
    M = header(im, d, title, kicker, sub)
    x0, x1 = M, W * S - M
    cx2 = x0 + colx[0] * S
    cx3 = x1 - colx[1] * S
    y = 250 * S
    rh = rh * S
    d.rectangle([x0, y, x1, y + 44 * S], fill=INK)
    hf = f(FONT_BODB, 14)
    d.text((x0 + 20 * S, y + 12 * S), headers[0], font=hf, fill=PAPER)
    d.text((cx2 + 20 * S, y + 12 * S), headers[1], font=hf, fill=PAPER)
    d.text((cx3 + 20 * S, y + 12 * S), headers[2], font=hf, fill=PAPER)
    y += 44 * S
    bf, nf = f(FONT_BODY, 14), f(FONT_BODB, 14)
    for i, (a, b, c) in enumerate(rows):
        if i % 2 == 0:
            d.rectangle([x0, y, x1, y + rh], fill=CARD)
        d.text((x0 + 20 * S, y + 15 * S), a, font=nf, fill=INK)
        d.text((cx2 + 20 * S, y + 15 * S), b, font=bf, fill=SUB)
        d.text((cx3 + 20 * S, y + 15 * S), c, font=nf, fill=INK)
        d.line([x0, y + rh, x1, y + rh], fill=LINE, width=1 * S)
        y += rh
    y += 26 * S
    if notes:
        hgt = 30 * S * len(notes) + 26 * S
        d.rounded_rectangle([x0, y, x1, y + hgt], 14 * S, fill=CARD, outline=LINE, width=2 * S)
        yy = y + 16 * S
        for i, n in enumerate(notes):
            d.text((x0 + 24 * S, yy), n, font=f(FONT_BODB if i == 0 else FONT_BODY, 14),
                   fill=INK if i == 0 else SUB)
            yy += 30 * S
    footer(im, d, "")
    im.resize((W, H), Image.LANCZOS).save(os.path.join(OUT, name), "PNG")
    print("✓", name)


# ── 1) 構成図 ────────────────────────────────────────────────
three_cards(
    "golf-kousei.png", "構成のご提案",
    "iPadで入力し、クラウドに貯め、1枚にして生徒さまへ",
    "土台のソフトは使いません。ブラウザで開くだけのカルテとして作ります。",
    [("① iPadで入力する", ["Safariで開くだけ・インストール不要",
                      "ホーム画面に置けばアプリのように",
                      "タップ中心。1レッスン2分以内を目標",
                      "電波の弱い打席でも入力できます",
                      "前回の内容を引き継いで差分だけ直す"], "light"),
     ("② クラウドに保管する", ["コーチが何名でも同じカルテを共有",
                       "つながった時に自動で同期します",
                       "生徒さまごとに履歴が積み上がる",
                       "CSVでいつでも取り出せます",
                       "紙のカルテは手元に残したままで可"], "dark"),
     ("③ 1枚にしてお渡しする", ["レーダーチャートと推移グラフ",
                        "その日のカルテを画像・PDFで書き出し",
                        "LINE・メールでそのまま送れます",
                        "生徒さま側の登録・ログインは不要",
                        "「見える化」が手元に届きます"], "light")],
    "毎月かかる費用",
    [("土台のソフト", "使いません"), ("有料プラグイン", "0円"),
     ("クラウド保管", "0円から"), ("納品物", "ソースコード一式")],
    "※ スイング写真を多く保管される場合のみ、クラウド側の有料プラン（月額4,000円程度）をご検討いただきます。")

# ── 2) 費用の比較 ────────────────────────────────────────────
table_img(
    "golf-cost.png", "費用の比較",
    "kintoneで作る場合と、今回のご提案",
    "タイトルに「Kintone利用可」とございましたので、運用費の違いを先にお示しします。",
    ["費用がかかる箇所", "kintoneで作る場合", "今回のご提案"],
    [("土台のソフト（月額）", "スタンダード 1,800円 × 最低10ユーザー", "0円"),
     ("カスタマイズの前提", "JavaScript対応はスタンダード以上が必須", "契約不要"),
     ("生徒さまへの共有", "ゲスト1名につき 月額1,440円", "画像・PDFで0円"),
     ("1年間の運用費", "216,000円〜（生徒さまへの共有を除く）", "0円〜"),
     ("3年間の運用費", "648,000円〜（同上）", "0円〜")],
    ["※ 金額はサイボウズ社の公開価格（2026年8月時点・税抜）にもとづく試算です。",
     "kintoneが悪いのではなく、コーチ数名の規模では最低10ユーザーの縛りが重く効きます。",
     "また生徒さまにカルテを見せる部分が、ゲスト課金のため事実上ふさがってしまいます。",
     "すでにkintoneをご契約済みでしたら、その上に載せる形でもお作りできます。"],
    colx=(330, 300))

# ── 3) 上達を数値化する項目の案 ───────────────────────────────
table_img(
    "golf-koumoku.png", "中身のご提案",
    "上達を「数値」にするための項目案",
    "紙のカルテを画面に移すだけでは数値になりません。何を残すかの案です。",
    ["残すもの", "コーチの入力のしかた", "見える化"],
    [("スイングの8項目", "グリップ／アドレス／テークバックなどを5段階でタップ", "レーダーチャート"),
     ("計測している数値", "飛距離・ヘッドスピードなど、貴校で測っている項目のみ", "折れ線グラフ"),
     ("できるようになったこと", "一覧からチェックを付けるだけ", "達成リスト"),
     ("今日のひとこと・宿題", "よく使う文を登録しておき、選ぶ＋書き足す", "1枚カルテに掲載"),
     ("スイング写真", "その場で撮って添付（任意）", "前回と並べて表示")],
    ["※ 項目は、いま使っていらっしゃる紙のカルテを拝見してから確定します。",
     "レーダーチャートは「初回・前回・今回」を重ねて描き、伸びた形が見えるようにします。",
     "コーチの方が交代しても、同じ項目・同じ基準でカルテが残ります。",
     "生徒さまの氏名などの個人情報は、必要な項目だけをお預かりする設計にできます。"],
    colx=(330, 300))
