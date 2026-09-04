# -*- coding: utf-8 -*-
"""ランサーズの提案（2026-08-08 の4件）に添付する説明図をまとめて生成する。

作るのは「構成の説明」と「費用・成果物の内訳」だけ。
フォームの「デザイン等をこの時点で行うことは禁止」に触れないよう、
相手のシステムのUI案は作らない。

  1) sim-kousei.png    … 2D画像合成シミュレーター（5583355）の構成
  2) sim-cost.png      … 同・AI背景切り抜きあり／なしの費用差
  3) gantt-deliver.png … ガントチャート生成（5582210）の成果物3点
  4) member-flow.png   … 会員機能（5583418）購入→権限→閲覧の流れ
  5) member-edit.png   … 同・納品後にご自身で編集できる範囲
  6) mf-shikumi.png    … マネーフォワード入力（5584220）の作業の置き換え

再生成: cd ~/制作物/lancers && DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 make_proposal_assets2.py
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

    d.text((M, 116 * S), title, font=f(FONT_DISP, 31), fill=INK)
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
    d.text((x0 + 22 * S, y0 + 20 * S), title, font=f(FONT_DISP, 18), fill=fg)
    y = y0 + 60 * S
    bf = f(FONT_BODY, 14)
    for r in rows:
        if not r:
            y += 29 * S
            continue
        d.ellipse([x0 + 24 * S, y + 7 * S, x0 + 30 * S, y + 13 * S],
                  fill=(MUTE if tone == "light" else (140, 136, 128)))
        d.text((x0 + 40 * S, y), r, font=bf, fill=sub)
        y += 29 * S


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
    top, bot = 250 * S, 560 * S
    gap = 34 * S
    cw = (W * S - M * 2 - gap * 2) // 3
    for i, (t, rows, tone) in enumerate(cards):
        x0 = M + (cw + gap) * i
        card(d, (x0, top, x0 + cw, bot), t, rows, tone)
    mid = (top + bot) // 2
    arrow(d, M + cw + 3 * S, mid)
    arrow(d, M + cw * 2 + gap + 3 * S, mid)
    band(d, M, 610 * S, 748 * S, band_title, band_cols)
    footer(im, d, note)
    im.resize((W, H), Image.LANCZOS).save(os.path.join(OUT, name), "PNG")
    print("✓", name)


def table_img(name, kicker, title, sub, headers, rows, notes, colx=(470, 150)):
    im = Image.new("RGB", (W * S, H * S), PAPER)
    d = ImageDraw.Draw(im)
    M = header(im, d, title, kicker, sub)
    x0, x1 = M, W * S - M
    cx2 = x0 + colx[0] * S
    cx3 = x1 - colx[1] * S
    y = 250 * S
    rh = 52 * S
    d.rectangle([x0, y, x1, y + 44 * S], fill=INK)
    hf = f(FONT_BODB, 14)
    d.text((x0 + 20 * S, y + 12 * S), headers[0], font=hf, fill=PAPER)
    d.text((cx2 + 20 * S, y + 12 * S), headers[1], font=hf, fill=PAPER)
    d.text((cx3 + 20 * S, y + 12 * S), headers[2], font=hf, fill=PAPER)
    y += 44 * S
    bf, nf = f(FONT_BODY, 15), f(FONT_BODB, 15)
    for i, (a, b, c) in enumerate(rows):
        if i % 2 == 0:
            d.rectangle([x0, y, x1, y + rh], fill=CARD)
        d.text((x0 + 20 * S, y + 15 * S), a, font=bf, fill=INK)
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


# ── 1) 2D画像合成シミュレーター：構成 ──────────────────────────
three_cards(
    "sim-kousei.png", "構成のご提案",
    "既存のWordPressサイトに、あとから足す形",
    "サイトは作り替えません。シミュレーターだけを1つの部品として、必要なページに置きます。",
    [("① 既存のWordPress", ["いまのサイトはそのまま", "固定ページに1行貼るだけで表示",
                          "テーマの入れ替えは不要", "既存の表示・SEOに影響しません"], "light"),
     ("② シミュレーター本体", ["ブラウザ内で画像を重ねる", "商品・パーツ画像の選択",
                        "写真のアップロードと配置", "拡大・縮小・移動・リセット",
                        "スマホはタッチ操作に対応"], "dark"),
     ("③ 画像・パーツの管理", ["管理画面から追加・差し替え", "並び順・表示名も変更可",
                       "コードは触りません", "貴社だけで運用できます"], "light")],
    "月額の費用は発生しません",
    [("サーバー", "いまのWordPressのまま"), ("追加の月額", "0円"),
     ("画像処理", "利用者のブラウザ内"), ("納品物", "ソースコード一式")],
    "※ 3Dモデル・360度回転は対象外です（ご要望どおり）。")

# ── 2) 2D画像合成：AI切り抜きあり／なしの費用差 ─────────────────
table_img(
    "sim-cost.png", "費用の内訳",
    "AI背景切り抜き ── あり／なしの費用差",
    "ご質問の「切り抜き機能あり・なしの概算費用」に、実現方法ごとにお答えします。",
    ["実現の方法", "特徴", "追加費用"],
    [("A. 切り抜きなし", "背景が透過済みの画像をご用意いただく", "±0円"),
     ("B. ブラウザ内でAI切り抜き", "利用者の端末で処理。画像は外部に出ません", "+50,000円"),
     ("C. 外部の切り抜きAPI", "精度は高いが、1枚ごとに従量課金が発生", "+30,000円 ＋従量"),
     ("（月額の費用）", "A・Bはゼロ。Cのみ従量課金が継続します", "A/B＝0円")],
    ["おすすめは B です。理由は2つあります。",
     "① 画像が外部サービスへ送られないため、お客様の写真を預からずに済みます。",
     "② 1枚いくらの従量課金が発生しないため、使われるほど有利になります。",
     "※ 切り抜きの精度は素材によって差が出ます。ご発注前にサンプル画像で試験できます。"],
    colx=(470, 190))

# ── 3) ガントチャート生成：成果物3点 ──────────────────────────
three_cards(
    "gantt-deliver.png", "お渡しするもの",
    "プロンプト・手順書・レクチャーの3点をお渡しします",
    "「毎回おなじ形のガントチャートが出る」状態を、担当者が変わっても保てるようにします。",
    [("① 入力シート", ["工事の項目・日数・担当を書く枠", "この枠を埋めるだけで済む形に",
                   "口頭の情報がそのまま入る並び", "現場ごとの写しを作れます"], "light"),
     ("② プロンプト", ["入力シートを貼って実行するだけ", "出力の形を毎回そろえます",
                   "職種の重なり・前後関係を判定", "雨天・材料待ちの調整にも対応"], "dark"),
     ("③ 手順書とレクチャー", ["図解入りの手順書（PDF）", "オンラインで操作のご説明",
                       "うまく出ないときの直し方", "そのまま社内で共有できます"], "light")],
    "この3点で何が変わるか",
    [("いままで", "毎回ゼロから組む"), ("これから", "枠を埋めて実行"),
     ("形のばらつき", "なくなります"), ("引き継ぎ", "手順書で渡せます")],
    "※ 生成結果の最終確認は必ず人が行う前提で設計します。工程の責任判断はAIに委ねません。")

# ── 4) 会員機能：購入から閲覧までの流れ ───────────────────────
three_cards(
    "member-flow.png", "構成のご提案",
    "買った方が、そのまま入れる形にします",
    "事前の会員登録をなくし、ご購入からログインまでを一本につなぎます。",
    [("① 購入", ["Stripeでのご購入は今のまま", "購入ページに入っただけでは",
               "未完了の履歴を作らない導線に", "デジタル商品も同じ扱い"], "light"),
     ("② 自動で権限が付く", ["購入が完了した時点で", "その方に閲覧の権限を付与",
                      "会員登録の手間はなし", "案内メールも自動で送れます"], "dark"),
     ("③ ログインして閲覧", ["右上のログインから入る", "買ったものが一覧で並ぶ",
                      "全6講座＋チャットルーム", "スマホでも同じ見え方"], "light")],
    "重視されている「安定して見続けられること」への備え",
    [("権限の記録", "購入と紐づけて保存"), ("退会・返金時", "権限だけを外せます"),
     ("講座の追加", "貴社の操作だけで可"), ("引き継ぎ", "手順書つきで納品")],
    "※ Stripeの決済そのものの仕様変更は範囲外です。連携部分の設計・実装を担当します。")

# ── 5) 会員機能：納品後にご自身で編集できる範囲 ─────────────────
table_img(
    "member-edit.png", "納品後の運用",
    "納品後、どこまでご自身で編集できるか",
    "「仕組みが分かり、自分で足していける」ことを、いちばん大事なご要望として設計します。",
    ["やりたいこと", "納品後の操作", "コード編集"],
    [("講座を1つ追加する", "管理画面から新規追加", "不要"),
     ("動画・資料を差し替える", "管理画面から差し替え", "不要"),
     ("講座の並び順を変える", "管理画面で並べ替え", "不要"),
     ("新しいデジタル商品を売る", "商品を追加して価格を設定", "不要"),
     ("購入者を確認する", "一覧画面で確認・書き出し", "不要"),
     ("画面の見た目を変える", "文言・色はご自身で／構造の変更はご相談", "一部必要")],
    ["納品時に、この表の操作をそのまま図解した手順書をお渡しします。",
     "作業をご一緒しながら画面共有で説明し、詰まったところだけ手順書に足していきます。",
     "※ 東京都内でお会いしてのレクチャーにも対応できます（神奈川在住のため伺えます）。"],
    colx=(470, 165))

# ── 6) マネーフォワード：作業の置き換え ─────────────────────────
three_cards(
    "mf-shikumi.png", "ご提案",
    "入力を代行するのではなく、入力そのものを減らします",
    "毎月おなじ形の入力が続くのであれば、その手数を先に減らしたほうが、長い目で安くなります。",
    [("いまの流れ", ["紙・PDF・CSVを開く", "1件ずつ目で追って転記",
                 "件数が増えるほど時間も増える", "担当が変わると精度が落ちる"], "light"),
     ("お作りする道具", ["明細ファイルを放り込むだけ", "勘定科目を自動で振り分け",
                   "迷った行だけを手で直す", "マネーフォワードの取込形式で出力"], "dark"),
     ("そのあと", ["確認と修正だけが人の仕事に", "件数が増えても時間は増えにくい",
                "ルールは画面から足せます", "担当が変わっても同じ結果"], "light")],
    "はじめの1本のめやす",
    [("費用", "30,000円（固定）"), ("期間", "7〜10日"),
     ("月額", "0円（縛りなし）"), ("納品", "ソースコード一式")],
    "※ 記帳代行・税務判断は行いません。仕訳ルールはお客様に決めていただきます。")
