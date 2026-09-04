# -*- coding: utf-8 -*-
"""ランサーズ 依頼5584569（MT5対応の自動売買EAの開発依頼）の提案に添付する説明図。

作るのは「構成の説明」「費用の内訳」「決めておく項目」だけ。
フォームの「デザイン等をこの時点で行うことは禁止」に触れないよう、
相手のシステムの画面デザイン（UIモック）は作らない。

  1) ea-kousei.png  … MT5 / EA / 稼働場所 の役割分担と、費用が発生する場所
  2) ea-cost.png    … ご希望の機能 × 実現のしかた × 追加費用（全行0円）
  3) ea-koumoku.png … 着手前に決めておく項目の一覧（＝聞き取りの実演）

再生成: cd ~/制作物/lancers && DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 make_ea_assets.py
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
    "ea-kousei.png", "仕組みのご説明",
    "EAが動く仕組みと、費用が発生する場所",
    "ご依頼文に挙げていただいた機能を、どこが担当するのかで整理しました。",
    [("① MT5（土台）", ["価格データとチャートの土台",
                    "SMA25・SMA100・RSIの線",
                    "線を引くのは表示部品の役目",
                    "EAは値を判定に使うだけです",
                    "起動時に3本を自動で載せます"], "light"),
     ("② EA（お作りする部分）", ["ローソク足の確定を待つ",
                        "条件がそろえばエントリー",
                        "残高からロットを計算",
                        "ストップロスを自動で設定",
                        "スプレッドが広ければ見送り",
                        "指定時刻にポジション決済",
                        "売買のたびにスマホへ通知",
                        "自分の玉だけを見分ける番号"], "dark"),
     ("③ 動かし続ける場所", ["MT5の起動中だけ動きます",
                     "PCをつけっぱなしにする",
                     "またはVPSを借りる",
                     "VPS＝24時間動く貸しPC",
                     "公式は月15ドル（年契約10）",
                     "業者の無料VPSが使える例も"], "light")],
    "毎月かかる費用",
    [("EA本体", "0円"), ("有料ライブラリ", "0円"),
     ("通知機能", "0円・MT5標準"), ("VPS", "月15ドル〜・任意")],
    "※ VPSの料金はMetaQuotes社の公開価格（2026年8月時点）。常時起動できるPCがあれば不要です。")

# ── 2) 費用の内訳 ────────────────────────────────────────────
table_img(
    "ea-cost.png", "費用の内訳",
    "ご希望の機能を、追加費用なしでどう実現するか",
    "ご依頼文に挙げていただいた機能を、一つずつ整理しました。",
    ["ご希望の機能", "実現のしかた", "追加費用"],
    [("任意の時間足で使える", "時間足を固定せず、動かしたチャートの足で判定します", "0円"),
     ("複数銘柄・複数チャートで同時", "チャートごとに番号を分け、玉を取り違えないようにします", "0円"),
     ("SMA25・SMA100・RSIの表示", "EA起動時に3本を自動で載せます。線を引くのは表示部品の役目です", "0円"),
     ("残高を基準にしたロット計算", "業者ごとに違う最小ロット・刻み幅に自動で丸め、発注拒否を防ぎます", "0円"),
     ("ストップロスの設定", "pipsでの固定幅のほか、直近の高値安値からの指定も選べます", "0円"),
     ("スプレッド・価格差での見送り", "発注の直前にもう一度測り、条件を外れていれば見送ります", "0円"),
     ("指定した時刻に決済", "サーバー時間ではなく日本時間で指定できるよう、時差を設定します", "0円"),
     ("エントリー・決済の通知", "MT5標準のスマホ通知を使います。メールの併用も可能です", "0円"),
     ("各種設定をパラメータから変更", "上記のすべてを、EAの設定画面から変更できるようにします", "0円"),
     ("mq5ソースコードの納品", "コメント付きでお渡しします。著作権の譲渡もご相談に応じます", "0円")],
    ["※ 上の表の機能に、有料のライブラリやプラグインは使用しません。追加費用は0円です。",
     "毎月かかる費用は、EAを24時間動かすためのVPS（任意・月15ドル〜）のみです。",
     "エントリー条件の中身は、ご用意されている仕様書を拝見してから確定いたします。"],
    colx=(300, 170), rh=40)

# ── 3) 着手前に決めておく項目 ─────────────────────────────────
table_img(
    "ea-koumoku.png", "着手前の確認",
    "着手前に、決めておきたい項目",
    "ご依頼文からは決まらなかった点です。選んでいただくだけの形にしてあります。",
    ["決めること", "選び方の例（どれか一つ）", "なぜ必要か"],
    [("SMA25と100の関係", "クロスした瞬間／25が100より上にある状態", "判定の回数が大きく変わります"),
     ("終値との位置関係", "条件に入れる／入れない（入れる場合はどちら側か）", "だましを減らせます"),
     ("RSIの期間と基準値", "期間14・基準30/70 など。抜けた瞬間か、その水準か", "入る時機が決まります"),
     ("売り（ショート）", "買いの完全な裏返し／別の条件を使う", "条件式が2組になります"),
     ("「指定した価格差」", "SMAどうしの開き／現在値とSMAの距離", "ご依頼文で未確定の点です"),
     ("ポジションの持ち方", "常に1つまで／複数持つ（ナンピンの有無）", "ロット計算に直結します"),
     ("利確（TP）", "置かない（SLと時刻決済のみ）／置く", "ご依頼文に記載がありません"),
     ("決済の時刻", "日本時間◯時／金曜だけ別扱いにするか", "時差の設定に必要です"),
     ("ロットの決め方", "残高の◯%をリスクに／残高◯万円ごとに0.01", "計算式が変わります")],
    ["※ この表は一例です。ご用意されている仕様書を拝見すれば、多くはそちらで解決すると思います。",
     "専門用語は「用語（＝かんたんに言うと◯◯）」の形で、必ず説明を添えてお送りします。",
     "決まっていない項目はこちらから箇条書きでお出しし、選んでいただくだけの形にします。"],
    colx=(280, 250), rh=44)
