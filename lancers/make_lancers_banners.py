# -*- coding: utf-8 -*-
"""ランサーズ パッケージ画像（1220x686 / 16:9）を つみきの「紙×墨」で生成する。

- 紙 #F4F2EE / 墨 #242321 / カード #FBFAF7（tsumiki-apps.com のトークンと同一）
- ロゴはサイト・アイコンと同じアイソメトリック積み木（make_index_icon.py と同座標）
- 見出し＝A1ゴシック（墨だまりのある書体）、数字＝Barlow、本文＝游ゴシック
"""
import io, os
try:
    import cairosvg
except OSError:
    # Homebrew の libcairo が dyld の探索パスに載っていない環境がある
    # （2026-08-17 発生）。DYLD_LIBRARY_PATH を足して一度だけ自分を起動し直す。
    import sys, subprocess
    _p = "/opt/homebrew/lib"
    if os.environ.get("DYLD_LIBRARY_PATH") != _p and os.path.isdir(_p):
        sys.exit(subprocess.call([sys.executable] + sys.argv,
                                 env={**os.environ, "DYLD_LIBRARY_PATH": _p}))
    raise
from PIL import Image, ImageDraw, ImageFont

W, H = 1220, 686
S = 2                      # 2倍でレンダ→縮小（文字を締める）
PAPER = (244, 242, 238)    # #F4F2EE
INK   = (36, 35, 33)       # #242321
CARD  = (251, 250, 247)    # #FBFAF7
LINE  = (214, 210, 202)

FONT_DISP = "/Library/Fonts/AP-OTF-A1GothicStd-Bold.otf"
FONT_NUM  = "/Library/Fonts/Barlow-Bold.ttf"
FONT_NUMB = "/Library/Fonts/Barlow-ExtraBold.ttf"
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


def logo(px, fill="#F4F2EE", stroke="#242321", sw=4.5):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
           f'width="{px}" height="{px}">'
           f'<g fill="{fill}" stroke="{stroke}" stroke-width="{sw}" '
           f'stroke-linejoin="round" stroke-linecap="round">{BLOCKS}</g></svg>')
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=px, output_height=px)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def f(path, size):
    return ImageFont.truetype(path, size * S)


def banner(name, head, price, term, sub, kicker):
    im = Image.new("RGB", (W * S, H * S), PAPER)
    d = ImageDraw.Draw(im)
    M = 78 * S                                     # 左右マージン

    # --- 右側：淡い積み木を大きく敷く（紙の質感の代わり） ---
    big = logo(560 * S, fill="#F4F2EE", stroke="#E2DED5", sw=3.2)
    im.paste(big, (W * S - big.width + 40 * S, H * S - big.height + 46 * S), big)

    # --- 上部：ロゴ＋屋号 ---
    mark = logo(46 * S, fill=PAPER_HEX, stroke="#242321", sw=6.5)
    im.paste(mark, (M, 52 * S), mark)
    d.text((M + 56 * S, 62 * S), "つみき", font=f(FONT_DISP, 21), fill=INK)
    d.text((M + 56 * S, 89 * S), "TSUMIKI", font=f(FONT_NUM, 11), fill=(140, 136, 128))

    # --- キッカー（小さなラベル） ---
    kx, ky = M, 152 * S
    kf = f(FONT_BODB, 15)
    kw = d.textlength(kicker, font=kf)
    d.rectangle([kx, ky, kx + kw + 26 * S, ky + 34 * S], fill=INK)
    d.text((kx + 13 * S, ky + 7 * S), kicker, font=kf, fill=PAPER)

    # --- 見出し（2行・A1ゴシック） ---
    y = 212 * S
    hf = f(FONT_DISP, 56)
    for ln in head:
        d.text((M, y), ln, font=hf, fill=INK)
        y += 78 * S

    # --- 罫線 ---
    y += 10 * S
    d.line([M, y, M + 300 * S, y], fill=LINE, width=2 * S)

    # --- 数字（価格・納期） ---
    y += 34 * S
    pf, pl = f(FONT_NUMB, 52), f(FONT_BODB, 17)
    d.text((M, y + 6 * S), price[0], font=pl, fill=(120, 116, 108))
    px = M + d.textlength(price[0], font=pl) + 10 * S
    d.text((px, y - 12 * S), price[1], font=pf, fill=INK)
    px += d.textlength(price[1], font=pf) + 6 * S
    d.text((px, y + 6 * S), price[2], font=pl, fill=INK)

    tx = M + 470 * S
    d.line([tx - 40 * S, y - 8 * S, tx - 40 * S, y + 42 * S], fill=LINE, width=2 * S)
    d.text((tx, y + 6 * S), term[0], font=pl, fill=(120, 116, 108))
    # 納期は和字（日／週間／なし）を含むので和文書体で組む
    tvf = f(FONT_DISP, 38)
    d.text((tx + (d.textlength(term[0], font=pl) + 10 * S if term[0] else 0), y - 4 * S),
           term[1], font=tvf, fill=INK)

    # --- 下部：補足 ---
    d.text((M, H * S - 108 * S), sub, font=f(FONT_BODY, 19), fill=(88, 85, 79))
    d.text((M, H * S - 72 * S), "tsumiki-apps.com", font=f(FONT_NUM, 15),
           fill=(150, 146, 138))

    out = os.path.join(OUT, name)
    im.resize((W, H), Image.LANCZOS).save(out, "PNG")
    print("✓", out)


PAPER_HEX = "#F4F2EE"

banner("lancers-pkg1.png",
       ["エクセルの手作業を、", "1つ消す。"],
       ("", "30,000", "円〜"), ("最短", "7日"),
       "いま使っているエクセル1つを、その現場だけの入力画面に置き換えます。",
       "エクセルの置き換え")

banner("lancers-pkg2.png",
       ["既製品が合わない仕事に、", "専用の1本を。"],
       ("固定価格", "162,000", "円〜"), ("", "2〜4週間"),
       "ソース納品・月額の縛りなし。着手後に金額は変わりません。",
       "専用アプリ開発")

banner("lancers-pkg3.png",
       ["作って終わりに、", "しない。"],
       ("月額", "10,000", "円〜"), ("", "縛りなし"),
       "いつでも解約できます。解約しても、アプリは止まりません。",
       "見守り・改修")


# ---------------------------------------------------------------- ヘッダー
def header(name="lancers-header.png"):
    """プロフィールヘッダー（2560x840・推奨サイズ）。
    スマホでは左右が切れるので、要素は中央寄りに置き、端50pxは空ける。"""
    HW, HH = 2560, 840
    s = 1                                   # 実寸で描く（十分大きい）
    im = Image.new("RGB", (HW, HH), PAPER)
    d = ImageDraw.Draw(im)

    def ft(path, size):
        return ImageFont.truetype(path, size)

    # 右手前にだけ積み木（左に置くとロゴと重なって濁る）
    b1 = logo(760, fill=PAPER_HEX, stroke="#E4E0D7", sw=3.0)
    im.paste(b1, (HW - 760, HH - 690), b1)

    M = 300                                  # 中央寄せぎみの左マージン

    mark = logo(64, fill=PAPER_HEX, stroke="#242321", sw=6.5)
    im.paste(mark, (M, 118), mark)
    d.text((M + 78, 130), "つみき", font=ft(FONT_DISP, 30), fill=INK)
    d.text((M + 78, 170), "TSUMIKI", font=ft(FONT_NUM, 15), fill=(140, 136, 128))

    d.text((M, 268), "現場に合わせた専用アプリを、固定価格で。",
           font=ft(FONT_DISP, 78), fill=INK)
    d.text((M, 396),
           "エクセルの手作業を、その現場だけの画面に置き換えます。",
           font=ft(FONT_BODY, 31), fill=(88, 85, 79))

    # 3つの約束をチップで
    x, y = M, 496
    for label in ("着手後、金額は変わりません", "ソースコード一式を納品",
                  "月額の縛りなし"):
        f_ = ft(FONT_BODB, 25)
        w = d.textlength(label, font=f_)
        d.rounded_rectangle([x, y, x + w + 48, y + 66], 8,
                            fill=CARD, outline=LINE, width=2)
        d.text((x + 24, y + 17), label, font=f_, fill=INK)
        x += w + 48 + 20

    d.line([M, 632, M + 250, 632], fill=LINE, width=2)
    d.text((M, 664), "tsumiki-apps.com", font=ft(FONT_NUM, 25),
           fill=(150, 146, 138))

    out = os.path.join(OUT, name)
    im.save(out, "PNG")
    print("✓", out, f"{HW}x{HH}")


header()


banner("lancers-pkg4.png",
       ["現場用と管理用、", "対になるアプリを2本。"],
       ("", "250,000", "円〜"), ("", "30日〜"),
       "現場はタップで1回。会社側は集計・書き出し・請求算定まで。",
       "2本セット＋クラウド同期")


# ================================================================ 墨ベタ地版
# 2026-08-17：検索結果の格子の中で沈まないように、紙×墨を「反転」する。
#   ・地を墨ベタにし、文字を紙色で白抜き
#   ・検索語をいちばん大きく（旧版の見出し56px → 104px＝約2倍）
#     …検索結果のカードは実寸で280px程度に縮む。104pxでようやく約24px相当になる
#   ・実績バッジは0件なので焼けない。代わりに「自作53本」等の数字をチップで入れる
#   ・価格はランサーズがカード下段に自動で出すので、画像には焼かない（面積の無駄）
# 旧版（紙地）は lancers-pkg*.png のまま残し、こちらは -ink 付きで別に出力する。

INK_BG   = (36, 35, 33)       # 地＝墨
INK_TINT = (52, 50, 47)       # 地に敷く積み木（わずかに明るい墨）
ON_INK   = (244, 242, 238)    # 紙色の白抜き文字
ON_INK_D = (196, 191, 182)    # 一段落とした白抜き（補足行）
CHIP_LN  = (110, 105, 97)     # チップの罫


def _fit(d, text, path, size, max_w):
    """max_w に収まるまで1ptずつ縮めたフォントを返す（はみ出し防止）。"""
    while size > 8:
        fo = f(path, size)
        if d.textlength(text, font=fo) <= max_w:
            return fo
        size -= 1
    return f(path, size)


def banner_ink(name, term, lines, chips, chip_lead=True):
    """墨ベタ地×白抜きのパッケージ画像。

    term      : 検索語（いちばん大きく出す。パッケージのタイトル冒頭【】と揃える）
    lines     : 補足2行（つみきの言葉）
    chips     : 下段の数字チップ3つ
    chip_lead : 先頭チップを紙ベタ（＝いちばん強く）にするか
    """
    im = Image.new("RGB", (W * S, H * S), INK_BG)
    d = ImageDraw.Draw(im)
    M = 78 * S
    MAXW = W * S - M * 2

    # --- 右下に積み木を敷く（地の単調さを消す・墨の中の墨） ---
    big = logo(560 * S, fill="#242321", stroke="#34322F", sw=3.4)
    im.paste(big, (W * S - big.width + 44 * S, H * S - big.height + 50 * S), big)

    # --- 上部：ロゴ＋屋号（紙色に反転） ---
    mark = logo(44 * S, fill="#242321", stroke=PAPER_HEX, sw=6.5)
    im.paste(mark, (M, 50 * S), mark)
    d.text((M + 54 * S, 58 * S), "つみき", font=f(FONT_DISP, 21), fill=ON_INK)
    d.text((M + 54 * S, 85 * S), "TSUMIKI", font=f(FONT_NUM, 11), fill=(132, 127, 119))

    # --- 検索語（この画像でいちばん大きい要素） ---
    tf = _fit(d, term, FONT_DISP, 104, MAXW)
    d.text((M, 168 * S), term, font=tf, fill=ON_INK)

    # --- 紙色の帯（検索語の下に敷いて視線を止める） ---
    bw = min(d.textlength(term, font=tf), MAXW)
    d.rectangle([M, 322 * S, M + bw, 322 * S + 9 * S], fill=ON_INK)

    # --- 補足2行 ---
    y = 366 * S
    for ln in lines:
        lf = _fit(d, ln, FONT_DISP, 54, MAXW)
        d.text((M, y), ln, font=lf, fill=ON_INK_D)
        y += 72 * S

    # --- 下段：数字チップ3つ（先頭だけ紙ベタで強く） ---
    x, cy = M, 556 * S
    for i, label in enumerate(chips):
        cf = f(FONT_BODB, 34)
        w = d.textlength(label, font=cf)
        solid = chip_lead and i == 0
        d.rounded_rectangle([x, cy, x + w + 46 * S, cy + 62 * S], 8 * S,
                            fill=ON_INK if solid else None,
                            outline=None if solid else CHIP_LN, width=2 * S)
        d.text((x + 23 * S, cy + 14 * S), label, font=cf,
               fill=INK_BG if solid else ON_INK)
        x += w + 46 * S + 18 * S

    d.text((M, H * S - 52 * S), "tsumiki-apps.com", font=f(FONT_NUM, 15),
           fill=(132, 127, 119))

    out = os.path.join(OUT, name)
    im.resize((W, H), Image.LANCZOS).save(out, "PNG")
    print("✓", out)


# ① 30,000円〜（パッケージID 1337703）
banner_ink("lancers-pkg1-ink.png", "Excel業務効率化",
           ["エクセルの手作業を1つ、", "その現場だけの画面に置き換える。"],
           ("自作53本", "固定価格", "最短7日"))

# ② 162,000円〜（パッケージID 1337704）
banner_ink("lancers-pkg2-ink.png", "業務システム開発",
           ["既製品が合わない仕事に、", "現場専用の1本を。"],
           ("自作53本", "固定価格", "2〜4週間"))

# ③ 250,000円〜（パッケージID 1337723）
# ⚠️ タイトルの【】は②と同じ「業務システム開発」だが、画像まで同じ語にすると
#    検索結果で②と見分けがつかず「同じ出品が2つ」に見える。画像だけ「業務自動化」
#    （8/14調査で上位が使っていた検索語のひとつ）に振って、絵として区別する。
banner_ink("lancers-pkg3-ink.png", "業務自動化",
           ["現場用と管理用、", "対になるアプリ2本をクラウドで。"],
           ("自作53本", "固定価格", "2本セット"))

# ④ 10,000円〜（パッケージID 1337705）
banner_ink("lancers-pkg4-ink.png", "保守・改修",
           ["作って終わりに、しない。", "見守りと小さな改修を月額で。"],
           ("自作53本", "縛りなし", "いつでも解約"))
