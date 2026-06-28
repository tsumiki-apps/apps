# -*- coding: utf-8 -*-
"""ホーム画面用 apple-touch-icon をモノクロ線画で生成する。
お手本の作風＝黒背景(#1c1c1c)＋白い太線の線画(round cap/join)、中央配置。
SVG(100x100座標)を cairosvg で高解像度レンダ→PILで180pxに縮小して書き出す。
旧 make_icons.py(絵文字グラデ版)は残してある。戻したいときはそちらを再実行。
"""
import os
os.environ.setdefault("DYLD_LIBRARY_PATH", "/opt/homebrew/lib")
import io
import cairosvg
from PIL import Image

SIZE = 180          # iPhone @3x 標準サイズ
RENDER = 540        # 3倍でレンダしてから縮小（アンチエイリアス用）
OUT_DIR = "icons"
BG = "#1c1c1c"      # お手本に近い黒
STROKE = "#ffffff"
SW = 6              # 100座標系での線幅（180pxで約10.8px ≒ お手本の太さ）

# name: 線画の中身（SVG 100x100座標）。塗りつぶしの点だけ fill 指定で上書き。
ICONS = {
    # ===== トップ / チェック =====
    # つみき＝積み木（ブロック3個）
    "index": '<rect x="26" y="52" width="22" height="22" rx="4"/>'
             '<rect x="52" y="52" width="22" height="22" rx="4"/>'
             '<rect x="39" y="28" width="22" height="22" rx="4"/>',
    # チェックルーム＝丸チェック
    "check": '<circle cx="50" cy="50" r="24"/><path d="M39,50 L47,58 L62,42"/>',

    # ===== Work =====
    "search": '<circle cx="44" cy="44" r="19"/><line x1="57" y1="57" x2="74" y2="74"/>',
    "nps": '<circle cx="50" cy="50" r="24"/><circle cx="50" cy="50" r="13"/>'
           '<circle cx="50" cy="50" r="3.5" fill="#fff" stroke="none"/>',
    "recap": '<line x1="26" y1="74" x2="74" y2="74"/>'
             '<line x1="35" y1="74" x2="35" y2="56"/>'
             '<line x1="50" y1="74" x2="50" y2="44"/>'
             '<line x1="65" y1="74" x2="65" y2="32"/>',
    # Recognition＝お手本そのものの星
    "recognition": '<path d="M50,26 L55.9,41.9 L72.8,42.6 L59.5,53.1 L64.1,69.4 '
                   'L50,60 L35.9,69.4 L40.5,53.1 L27.2,42.6 L44.1,41.9 Z"/>',
    "grownote": '<path d="M50,74 V50"/>'
                '<path d="M50,57 C40,57 32,51 30,41 C40,41 48,47 50,57 Z"/>'
                '<path d="M50,53 C60,53 68,47 70,37 C60,37 52,43 50,53 Z"/>',
    # 5Whys＝深掘りの連鎖（ジグザグのノード）
    "team5whys": '<circle cx="38" cy="28" r="7"/><circle cx="62" cy="50" r="7"/>'
                 '<circle cx="38" cy="72" r="7"/>'
                 '<line x1="43" y1="32" x2="57" y2="46"/>'
                 '<line x1="57" y1="54" x2="43" y2="68"/>',
    # 振り返り＝ハンドミラー（縦持ち：検索の斜め柄と区別）
    "reflection": '<circle cx="50" cy="38" r="19"/><line x1="50" y1="57" x2="50" y2="78"/>',
    "vault": '<rect x="32" y="48" width="36" height="30" rx="6"/>'
             '<path d="M40,48 V40 a10,10 0 0 1 20,0 V48"/>'
             '<circle cx="50" cy="61" r="3.5" fill="#fff" stroke="none"/>',
    "osusowake": '<rect x="30" y="48" width="40" height="28" rx="3"/>'
                 '<rect x="28" y="38" width="44" height="11" rx="3"/>'
                 '<line x1="50" y1="38" x2="50" y2="76"/>'
                 '<path d="M50,38 C44,30 34,30 36,40 M50,38 C56,30 66,30 64,40"/>',
    "schedule": '<rect x="28" y="32" width="44" height="42" rx="6"/>'
                '<line x1="28" y1="44" x2="72" y2="44"/>'
                '<line x1="40" y1="28" x2="40" y2="38"/>'
                '<line x1="60" y1="28" x2="60" y2="38"/>'
                '<circle cx="40" cy="56" r="2.5" fill="#fff" stroke="none"/>'
                '<circle cx="50" cy="56" r="2.5" fill="#fff" stroke="none"/>'
                '<circle cx="60" cy="56" r="2.5" fill="#fff" stroke="none"/>'
                '<circle cx="40" cy="65" r="2.5" fill="#fff" stroke="none"/>'
                '<circle cx="50" cy="65" r="2.5" fill="#fff" stroke="none"/>',
    "career": '<rect x="28" y="42" width="44" height="32" rx="5"/>'
              '<path d="M42,42 V37 a4,4 0 0 1 4,-4 h8 a4,4 0 0 1 4,4 V42"/>'
              '<line x1="28" y1="56" x2="72" y2="56"/>',
    "interview": '<rect x="42" y="26" width="16" height="30" rx="8"/>'
                 '<path d="M34,48 a16,16 0 0 0 32,0"/>'
                 '<line x1="50" y1="64" x2="50" y2="74"/>'
                 '<line x1="40" y1="74" x2="60" y2="74"/>',
    # メモ帳＝角を折った紙＋3本線
    "memo": '<path d="M32,24 H58 L70,36 V76 H32 Z"/>'
            '<path d="M58,24 V36 H70"/>'
            '<line x1="40" y1="50" x2="62" y2="50"/>'
            '<line x1="40" y1="60" x2="62" y2="60"/>'
            '<line x1="40" y1="70" x2="53" y2="70"/>',

    # ===== Private =====
    # ぶれいん＝パズルのピース1個（考えをパズルで整理）
    "think": '<path d="M30,40 H42 C42,31 54,31 54,40 H66 V52 '
             'C75,52 75,64 66,64 V72 H30 V60 C21,60 21,48 30,48 Z"/>',
    "rashinban": '<circle cx="50" cy="50" r="26"/>'
                 '<path d="M50,32 L58,50 L50,68 L42,50 Z"/>'
                 '<circle cx="50" cy="50" r="3" fill="#fff" stroke="none"/>',
    # カケル＝ゴール旗
    "kakeru": '<line x1="34" y1="26" x2="34" y2="78"/><path d="M34,30 L66,38 L34,50 Z"/>',
    # ゆずわり＝割り勘レシート（破線で分割）
    "yuzuwari": '<path d="M34,26 H66 V72 l-6,-5 l-6,5 l-6,-5 l-6,5 l-6,-5 V26 Z"/>'
                '<line x1="42" y1="38" x2="58" y2="38"/>'
                '<line x1="34" y1="52" x2="66" y2="52" stroke-dasharray="5 5"/>',
    # つぎいつ？＝目覚まし時計
    "tsugi": '<circle cx="50" cy="52" r="22"/>'
             '<line x1="50" y1="52" x2="50" y2="40"/>'
             '<line x1="50" y1="52" x2="60" y2="56"/>'
             '<line x1="33" y1="34" x2="27" y2="28"/>'
             '<line x1="67" y1="34" x2="73" y2="28"/>'
             '<line x1="38" y1="72" x2="32" y2="80"/>'
             '<line x1="62" y1="72" x2="68" y2="80"/>',
    # ゆずごはん＝ゆず(柑橘＋葉)
    "cooking": '<circle cx="46" cy="58" r="21"/>'
               '<path d="M45,38 q1.5,-4 3,0"/>'
               '<path d="M50,37 C58,27 73,28 73,28 C73,28 71,43 58,43 C52,43 49,41 50,37 Z"/>'
               '<line x1="54" y1="38" x2="68" y2="31"/>',
    # ツナグ＝鎖のリンク2つ
    "tsunagu": '<rect x="24" y="40" width="34" height="20" rx="10" transform="rotate(-32 41 50)"/>'
               '<rect x="42" y="40" width="34" height="20" rx="10" transform="rotate(-32 59 50)"/>',
    "tabinoki": '<path d="M52,76 Q49,56 47,44"/>'
                '<path d="M47,42 Q33,34 20,40"/>'
                '<path d="M47,42 Q61,34 74,40"/>'
                '<path d="M47,42 Q40,26 30,20"/>'
                '<path d="M47,42 Q56,26 68,22"/>'
                '<circle cx="47" cy="42" r="3" fill="#fff" stroke="none"/>',
    "yarukoto": '<rect x="30" y="30" width="40" height="40" rx="9"/>'
                '<path d="M40,50 L47,57 L62,40"/>',
    "komame": '<line x1="70" y1="26" x2="44" y2="58"/>'
              '<path d="M36,52 L52,64 L46,76 L30,64 Z"/>'
              '<line x1="40" y1="58" x2="35" y2="69"/>'
              '<line x1="46" y1="62" x2="40" y2="72"/>',
    "kaimono": '<path d="M25,31 H32 L39,60 H66 L71,41 H35"/>'
               '<circle cx="44" cy="70" r="4.5" fill="#fff" stroke="none"/>'
               '<circle cx="63" cy="70" r="4.5" fill="#fff" stroke="none"/>',
    # おぼえりふ＝吹き出し＋セリフ行
    "serifu": '<rect x="26" y="30" width="48" height="34" rx="8"/>'
              '<path d="M40,64 L40,74 L52,64"/>'
              '<line x1="36" y1="42" x2="64" y2="42"/>'
              '<line x1="36" y1="52" x2="58" y2="52"/>',
    # じんせいすごろく＝サイコロ(5の目)
    "jinsei": '<rect x="30" y="30" width="40" height="40" rx="9"/>'
              '<circle cx="40" cy="40" r="3.5" fill="#fff" stroke="none"/>'
              '<circle cx="60" cy="40" r="3.5" fill="#fff" stroke="none"/>'
              '<circle cx="50" cy="50" r="3.5" fill="#fff" stroke="none"/>'
              '<circle cx="40" cy="60" r="3.5" fill="#fff" stroke="none"/>'
              '<circle cx="60" cy="60" r="3.5" fill="#fff" stroke="none"/>',
    # トランプ＝扇状に重ねた2枚
    "trump": '<rect x="30" y="32" width="28" height="40" rx="5" transform="rotate(-12 44 52)"/>'
             '<rect x="44" y="30" width="28" height="40" rx="5" transform="rotate(9 58 50)"/>',
    # みのり＝開いた本
    "minori": '<path d="M50,36 C42,30 30,30 24,34 V68 C30,64 42,64 50,70 '
              'C58,64 70,64 76,68 V34 C70,30 58,30 50,36 Z"/>'
              '<line x1="50" y1="36" x2="50" y2="70"/>',

    # ===== Asset =====
    # ちりつも＝コインの山
    "chiritsumo": '<ellipse cx="50" cy="36" rx="20" ry="7"/>'
                  '<line x1="30" y1="36" x2="30" y2="60"/>'
                  '<line x1="70" y1="36" x2="70" y2="60"/>'
                  '<path d="M30,60 a20,7 0 0 0 40,0"/>'
                  '<path d="M30,44 a20,7 0 0 0 40,0"/>'
                  '<path d="M30,52 a20,7 0 0 0 40,0"/>',
    "credit": '<rect x="26" y="36" width="48" height="30" rx="6"/>'
              '<line x1="26" y1="46" x2="74" y2="46"/>'
              '<line x1="34" y1="58" x2="50" y2="58"/>',
    # 残高計算＝電卓
    "money": '<rect x="32" y="26" width="36" height="48" rx="6"/>'
             '<rect x="38" y="32" width="24" height="9" rx="2"/>'
             '<circle cx="40" cy="51" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="50" cy="51" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="60" cy="51" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="40" cy="62" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="50" cy="62" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="60" cy="62" r="2.6" fill="#fff" stroke="none"/>',
    # 資産予測＝右肩上がりの折れ線
    "forecast": '<path d="M28,30 V72 H74"/>'
                '<path d="M34,64 L46,54 L56,60 L70,38"/>'
                '<path d="M62,38 H70 V46"/>',
    # まいつき＝円グラフ
    "maitsuki": '<circle cx="50" cy="50" r="23"/>'
                '<line x1="50" y1="50" x2="50" y2="27"/>'
                '<line x1="50" y1="50" x2="70" y2="61"/>',
    # ひきおとし＝¥の縦棒が下向き矢印に＝お金が引き落とされる
    "hikiotoshi": '<path d="M40,26 L50,40 L60,26"/>'
                  '<line x1="50" y1="40" x2="50" y2="76"/>'
                  '<line x1="41" y1="48" x2="59" y2="48"/>'
                  '<line x1="41" y1="55" x2="59" y2="55"/>'
                  '<path d="M40,66 L50,76 L60,66"/>',
    # コピペ箱＝コピー(2枚重ね)
    "copybox": '<rect x="38" y="38" width="30" height="34" rx="6"/>'
               '<path d="M32,52 H28 a4,4 0 0 1 -4,-4 V32 a4,4 0 0 1 4,-4 H48 '
               'a4,4 0 0 1 4,4 V38"/>',
}


# 仕事(Apple)で使うアプリ＝右下に小さくAppleロゴ
WORK_APPS = {
    "search", "nps", "recap", "recognition", "grownote", "team5whys",
    "reflection", "vault", "osusowake", "schedule", "career", "interview",
    "memo",
}
# Appleロゴ(silhouette)。24x24座標→右下にscale配置。塗り白。
APPLE_PATH = (
    "M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 "
    "3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 "
    "3.043 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 "
    "1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 "
    "1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 "
    "2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 "
    "1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 "
    "1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"
)


def render(name, inner):
    badge = ""
    if name in WORK_APPS:
        badge = (f'<g transform="translate(77,77) scale(0.55)" fill="{STROKE}" '
                 f'stroke="none"><path d="{APPLE_PATH}"/></g>')
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
        f'width="{RENDER}" height="{RENDER}">'
        f'<rect x="0" y="0" width="100" height="100" fill="{BG}"/>'
        f'<g fill="none" stroke="{STROKE}" stroke-width="{SW}" '
        f'stroke-linecap="round" stroke-linejoin="round">{inner}</g>{badge}</svg>'
    )
    png = cairosvg.svg2png(bytestring=svg.encode("utf-8"),
                           output_width=RENDER, output_height=RENDER)
    img = Image.open(io.BytesIO(png)).convert("RGB")
    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"icon-{name}.png")
    img.save(path, "PNG")
    return path


if __name__ == "__main__":
    for name, inner in ICONS.items():
        print("✓", render(name, inner))
    print(f"\n{len(ICONS)} 個のアイコンを生成しました。")
