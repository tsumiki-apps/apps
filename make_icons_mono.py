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
SW = 4.5            # 100座標系での線幅（180pxで約8.1px。細めの線画で軽く見せる）

# name: 線画の中身（SVG 100x100座標）。塗りつぶしの点だけ fill 指定で上書き。
ICONS = {
    # ===== トップ / チェック =====
    # つみき＝積み木（ブロック3個）
    "index": '<rect x="26" y="52" width="22" height="22" rx="4"/>'
             '<rect x="52" y="52" width="22" height="22" rx="4"/>'
             '<rect x="39" y="28" width="22" height="22" rx="4"/>',
    # チェックルーム＝丸チェック
    "check": '<circle cx="50" cy="50" r="24"/><path d="M39,50 L47,58 L62,42"/>',
    # たすくノート＝チェックリスト（Notion風タスク管理）。先頭だけチェック済み
    "tasknote": '<rect x="22" y="26" width="14" height="14" rx="3.5"/>'
                '<path d="M25.6,33 L28.2,35.6 L32.6,30.4"/>'
                '<line x1="45" y1="33" x2="76" y2="33"/>'
                '<rect x="22" y="45" width="14" height="14" rx="3.5"/><line x1="45" y1="52" x2="76" y2="52"/>'
                '<rect x="22" y="64" width="14" height="14" rx="3.5"/><line x1="45" y1="71" x2="76" y2="71"/>',

    # ===== Work =====
    # 打刻（労働者用）＝時計そのもの。つぎいつ？＝ベル付き目覚まし、時給＝時計＋¥ と区別
    "dakoku": '<circle cx="50" cy="50" r="24"/><path d="M50,32 V50 L63,57"/>',
    # 打刻管理（管理者用）＝勤怠管理表のグリッド。カレンダー(上のツメ)とは別物として表で表す
    "dakoku-kanri": '<rect x="22" y="28" width="56" height="46" rx="5"/>'
                    '<line x1="22" y1="41" x2="78" y2="41"/>'
                    '<line x1="22" y1="57.5" x2="78" y2="57.5"/>'
                    '<line x1="40.7" y1="41" x2="40.7" y2="74"/>'
                    '<line x1="59.3" y1="41" x2="59.3" y2="74"/>',
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
    "grownote": '<path d="M50,69 V45"/>'
                '<path d="M50,52 C40,52 32,46 30,36 C40,36 48,42 50,52 Z"/>'
                '<path d="M50,48 C60,48 68,42 70,32 C60,32 52,38 50,48 Z"/>',
    # 5Whys＝深掘りの連鎖（ジグザグのノード）
    "team5whys": '<circle cx="38" cy="28" r="7"/><circle cx="62" cy="50" r="7"/>'
                 '<circle cx="38" cy="72" r="7"/>'
                 '<line x1="43" y1="32" x2="57" y2="46"/>'
                 '<line x1="57" y1="54" x2="43" y2="68"/>',
    # 振り返り＝ハンドミラー（縦持ち：検索の斜め柄と区別）
    "reflection": '<circle cx="50" cy="38" r="19"/><line x1="50" y1="57" x2="50" y2="78"/>',
    "vault": '<rect x="32" y="44" width="36" height="30" rx="6"/>'
             '<path d="M40,44 V36 a10,10 0 0 1 20,0 V44"/>'
             '<circle cx="50" cy="57" r="3.5" fill="#fff" stroke="none"/>',
    "osusowake": '<rect x="30" y="45" width="40" height="28" rx="3"/>'
                 '<rect x="28" y="35" width="44" height="11" rx="3"/>'
                 '<line x1="50" y1="35" x2="50" y2="73"/>'
                 '<path d="M50,35 C44,27 34,27 36,37 M50,35 C56,27 66,27 64,37"/>',
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
    # おきどき＝地平線から昇る朝日（起きる時刻の逆算。つぎ＝目覚まし時計と差別化）
    "okidoki": '<line x1="22" y1="63" x2="78" y2="63"/>'
               '<path d="M35,63 A15,15 0 0 1 65,63"/>'
               '<line x1="50" y1="41" x2="50" y2="32"/>'
               '<line x1="35" y1="47" x2="29" y2="41"/>'
               '<line x1="65" y1="47" x2="71" y2="41"/>'
               '<line x1="30" y1="73" x2="70" y2="73"/>',
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
    # みんなわり＝1枚のレシートが3人に分かれる（ゆずわり＝ふたり用と対で、こちらは大人数）
    "minnawari": '<path d="M37,18 H63 V42 l-4.33,-3 -4.33,3 -4.33,-3 -4.33,3 -4.33,-3 -4.33,3 V18 Z"/>'
                 '<line x1="43" y1="28" x2="57" y2="28"/>'
                 '<path d="M50,42 V50"/>'
                 '<path d="M50,50 L24,60"/><path d="M50,50 V60"/><path d="M50,50 L76,60"/>'
                 '<circle cx="24" cy="66.5" r="6.5"/>'
                 '<circle cx="50" cy="66.5" r="6.5"/>'
                 '<circle cx="76" cy="66.5" r="6.5"/>',
    # あきま＝カレンダーの中に1つだけ空いている枠（点＝埋まっている日）
    "akima": '<rect x="24" y="30" width="52" height="46" rx="6"/>'
             '<line x1="24" y1="44" x2="76" y2="44"/>'
             '<line x1="37" y1="24" x2="37" y2="34"/>'
             '<line x1="63" y1="24" x2="63" y2="34"/>'
             '<circle cx="34" cy="55.5" r="2.4" fill="#fff" stroke="none"/>'
             '<circle cx="34" cy="66.5" r="2.4" fill="#fff" stroke="none"/>'
             '<circle cx="66" cy="55.5" r="2.4" fill="#fff" stroke="none"/>'
             '<circle cx="66" cy="66.5" r="2.4" fill="#fff" stroke="none"/>'
             '<rect x="44" y="50" width="12" height="22" rx="4"/>',
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
    # まぜいろ＝パレット＋3色の点（アプリ内ヘッダーの線画ロゴを100座標に拡大したもの）
    "mazeiro": '<path d="M50,73.4 a23.4,23.4 0 1 1 23.4,-23.4 '
               'c0,5.2 -3.9,7.8 -7.8,7.8 h-5.2 a6.5,6.5 0 0 0 -5.2,10.4 '
               'c1.3,2.1 0,5.2 -5.2,5.2 z"/>'
               '<circle cx="39.6" cy="44.8" r="4" fill="#fff" stroke="none"/>'
               '<circle cx="50" cy="38.3" r="4" fill="#fff" stroke="none"/>'
               '<circle cx="60.4" cy="44.8" r="4" fill="#fff" stroke="none"/>',
    # さしず＝郵便ポスト（指示を投函するイメージ。丸屋根＋投函口＋支柱）
    "sashizu": '<path d="M31,62 V41 a19,19 0 0 1 38,0 V62 Z"/>'
               '<line x1="41" y1="45" x2="59" y2="45"/>'
               '<line x1="50" y1="62" x2="50" y2="76"/>'
               '<line x1="38" y1="76" x2="62" y2="76"/>',
    # 香盤メーカー＝香盤（稽古スケジュール）。左が時間軸、横バーが時間帯に置かれた場面
    "kouban": '<line x1="22" y1="26" x2="22" y2="74"/>'
              '<line x1="36" y1="34" x2="68" y2="34"/>'
              '<line x1="50" y1="50" x2="78" y2="50"/>'
              '<line x1="36" y1="66" x2="58" y2="66"/>',
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

    # 時給計算＝時計（時間）と¥（報酬）。かけた時間で報酬をわると実質時給
    "jikyu": '<circle cx="40" cy="40" r="21"/>'
             '<path d="M40,27 V40 L49,46"/>'
             '<path d="M62,60 L70,68 L78,60"/>'
             '<path d="M70,68 V80"/>'
             '<line x1="62" y1="71" x2="78" y2="71"/>'
             '<line x1="62" y1="76" x2="78" y2="76"/>',
    # つみじかん＝ストップウォッチ（押して計る）。打刻(ただの時計)・時給計算(時計＋¥)・
    # てまひま(砂時計)と重ならないよう、上のつまみと横のボタンで「計る道具」にする
    "tsumijikan": '<circle cx="50" cy="58" r="23"/>'
                  '<path d="M50,45 V58 L60,64"/>'
                  '<line x1="42" y1="24" x2="58" y2="24"/>'
                  '<line x1="50" y1="24" x2="50" y2="35"/>'
                  '<line x1="69" y1="33" x2="74" y2="28"/>',
    # てまひま＝砂時計（かけた手間・暇そのもの）。時給計算(jikyu)の時計＋¥とは別物にする
    "temahima": '<line x1="31" y1="22" x2="69" y2="22"/>'
                '<line x1="31" y1="78" x2="69" y2="78"/>'
                '<path d="M37,22 V31 L50,47 L63,31 V22"/>'
                '<path d="M37,78 V69 L50,53 L63,69 V78"/>'
                '<circle cx="50" cy="50" r="2.6" fill="#fff" stroke="none"/>',
    # 自由帳／下書き＝1枚の紙に自由な線（形が決まっていない）。
    # メモ帳＝角折れ紙＋まっすぐな3本線、たすくノート＝チェックリスト、とはっきり区別する
    "jiyucho": '<rect x="28" y="22" width="44" height="56" rx="5"/>'
               '<path d="M36,59 C40,37 49,36 51,50 C53,64 62,63 65,41"/>',
    # 学んだこと＝ひらめきの電球（自分のための気づきメモ）
    "manabi": '<path d="M50,20 C38,20 29,29 29,40 C29,48 34,53 38,58 '
              'C40,60.5 41,63 41,66 H59 C59,63 60,60.5 62,58 '
              'C66,53 71,48 71,40 C71,29 62,20 50,20 Z"/>'
              '<line x1="42" y1="73" x2="58" y2="73"/>'
              '<line x1="45" y1="80" x2="55" y2="80"/>',

    # ===== Asset =====
    # 独立ロードマップ＝つみきを段々に積み上げ、頂上にゴール旗（積み上げ×つみき×独立）
    "dokuritsu": '<rect x="16" y="54" width="20" height="20" rx="4"/>'
                 '<rect x="38" y="43" width="20" height="20" rx="4"/>'
                 '<rect x="60" y="32" width="20" height="20" rx="4"/>'
                 '<line x1="70" y1="33" x2="70" y2="15"/>'
                 '<path d="M70,15 L83,19 L70,23 Z" fill="#fff" stroke="none"/>',
    # 声かけメモ＝人に声をかける（人＋吹き出し）。おぼえりふ＝吹き出しだけ、と区別して人を添える
    "koekake": '<circle cx="34" cy="55" r="11"/>'
               '<path d="M18,80 a16,16 0 0 1 32,0"/>'
               '<rect x="52" y="20" width="34" height="26" rx="8"/>'
               '<path d="M62,46 L60,57 L72,46"/>',
    # ちりつも＝コインの山
    "chiritsumo": '<ellipse cx="50" cy="36" rx="20" ry="7"/>'
                  '<line x1="30" y1="36" x2="30" y2="60"/>'
                  '<line x1="70" y1="36" x2="70" y2="60"/>'
                  '<path d="M30,60 a20,7 0 0 0 40,0"/>'
                  '<path d="M30,44 a20,7 0 0 0 40,0"/>'
                  '<path d="M30,52 a20,7 0 0 0 40,0"/>',
    # クレカ明細＝明細レシート（項目行＋合計チェック＋ギザ底）。立て替えを差し引いた「実質支出」が確定して見える
    "credit": '<path d="M33,22 H67 V73"/>'
              '<path d="M33,22 V73"/>'
              '<path d="M33,73 L38.7,78 44.3,73 50,78 55.7,73 61.3,78 67,73"/>'
              '<line x1="39" y1="34" x2="61" y2="34"/>'
              '<line x1="39" y1="42" x2="55" y2="42"/>'
              '<line x1="39" y1="50" x2="61" y2="50"/>'
              '<path d="M40,62 L45,67 54,57"/>',
    # ふたりカード＝共同カードを2人でわける。カード→Y字で2人へ分岐
    "futaricard": '<rect x="34" y="22" width="32" height="21" rx="4"/>'
                  '<line x1="34" y1="29" x2="66" y2="29"/>'
                  '<path d="M50,43 V50"/>'
                  '<path d="M50,50 L37,58"/><path d="M50,50 L63,58"/>'
                  '<circle cx="34" cy="63" r="5.5"/>'
                  '<path d="M26,77 a8,8 0 0 0 16,0"/>'
                  '<circle cx="66" cy="63" r="5.5"/>'
                  '<path d="M58,77 a8,8 0 0 0 16,0"/>',
    # 残高計算＝電卓
    "money": '<rect x="32" y="26" width="36" height="48" rx="6"/>'
             '<rect x="38" y="32" width="24" height="9" rx="2"/>'
             '<circle cx="40" cy="51" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="50" cy="51" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="60" cy="51" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="40" cy="62" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="50" cy="62" r="2.6" fill="#fff" stroke="none"/>'
             '<circle cx="60" cy="62" r="2.6" fill="#fff" stroke="none"/>',
    # げんか＝費目を積み上げた1本の柱（原価の内訳）。
    # 電卓(money)・円グラフ(maitsuki)・折れ線(forecast)・貯金瓶(chiritsumo)と重ならない形にする
    "genka": '<line x1="26" y1="79" x2="74" y2="79"/>'
             '<rect x="37" y="23" width="26" height="52" rx="4"/>'
             '<line x1="37" y1="40" x2="63" y2="40"/>'
             '<line x1="37" y1="57" x2="63" y2="57"/>',
    # おかねのちず＝会計の地図の図法そのもの。上の1本(売上)が、下で2つ(費用と利益)に分かれる。
    # げんか(縦の柱)・recap(棒グラフ)と重ならないよう、横帯2本＋仕切り線で構成する
    "chizu": '<rect x="22" y="29" width="56" height="15" rx="4"/>'
             '<rect x="22" y="56" width="56" height="15" rx="4"/>'
             '<line x1="60" y1="44" x2="60" y2="71"/>',
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
    "copybox": '<rect x="42" y="38" width="30" height="34" rx="6"/>'
               '<path d="M36,52 H32 a4,4 0 0 1 -4,-4 V32 a4,4 0 0 1 4,-4 H52 '
               'a4,4 0 0 1 4,4 V38"/>',
    # 議事録＝書類＋行（メモ）
    "gijiroku": '<rect x="28" y="22" width="44" height="56" rx="6"/>'
                '<line x1="38" y1="40" x2="62" y2="40"/>'
                '<line x1="38" y1="52" x2="62" y2="52"/>'
                '<line x1="38" y1="64" x2="54" y2="64"/>',

    # ===== 旧・色付き/別スタイルから統一線画へ作り直し =====
    # しろふち＝縦(9:16)の写真/動画に白いふち。外わく＝ふち・内わく＝角丸の写真（中に山と太陽）
    "shirofuchi": '<rect x="29" y="14" width="42" height="72" rx="8"/>'
                  '<rect x="37" y="22" width="26" height="56" rx="6"/>'
                  '<circle cx="45" cy="34" r="3"/>'
                  '<path d="M38,71 L48,58 L53,64 L62,53"/>',
    # ひとこま＝撮影情報のフレーム（額縁の中に山＋太陽＝写真を一枚の作品に）
    # つみき画面収録＝説明動画（16:9の枠の中に、話し手の顔がひとつ）
    "rokuga": '<rect x="14" y="28" width="72" height="44" rx="9"/>'
                '<circle cx="66" cy="57" r="7.5"/>'
                '<path d="M28,42 L48,42 M28,52 L42,52"/>',
    "hitokoma": '<rect x="24" y="28" width="52" height="44" rx="5"/>'
                '<circle cx="37" cy="42" r="5"/>'
                '<path d="M28,66 L42,51 L51,59 L63,45 L72,66"/>',
    # いろのこし＝写真の中の一色だけ残す。写真のわく＋中に塗りつぶしのしずく1つ
    # （ひとこま＝わく＋山と太陽、しろふち＝二重わく と見分けがつくように中身を変えた）
    "ironokoshi": '<rect x="24" y="24" width="52" height="52" rx="8"/>'
                  '<path d="M50,36 C50,36 62,48.5 62,56 A12,12 0 0 1 38,56 '
                  'C38,48.5 50,36 50,36 Z" fill="#fff" stroke="none"/>',
    # せいかつの木＝生活費わけ。幹＋丸い樹冠＋地面（ふたりの暮らしが育つ木）
    "seikatsu": '<circle cx="50" cy="42" r="20"/>'
                '<line x1="50" y1="62" x2="50" y2="75"/>'
                '<line x1="40" y1="75" x2="60" y2="75"/>',
    # ぴずかご＝ふたりの共有リスト。買い物かご（持ち手＋格子）
    "issho": '<path d="M30,40 H70 L64,67 H36 Z"/>'
             '<path d="M40,40 C40,31 60,31 60,40"/>'
             '<line x1="41" y1="46" x2="43" y2="61"/>'
             '<line x1="50" y1="46" x2="50" y2="61"/>'
             '<line x1="59" y1="46" x2="57" y2="61"/>',
    # Floor Memo＝書類＋時計（時間つきの記録）
    "floormemo": '<rect x="26" y="26" width="40" height="50" rx="5"/>'
                 '<line x1="34" y1="43" x2="52" y2="43"/>'
                 '<line x1="34" y1="53" x2="52" y2="53"/>'
                 '<line x1="34" y1="63" x2="46" y2="63"/>'
                 '<circle cx="65" cy="35" r="12" fill="#1c1c1c" stroke="none"/>'
                 '<circle cx="65" cy="35" r="12"/>'
                 '<path d="M65,35 V28"/><path d="M65,35 L70,38"/>',
    # ひとのわ＝人脈の相関図。自分(中央の大きめノード)から人が3方向につながる輪
    "hitonowa": '<line x1="50" y1="40.5" x2="50" y2="27.5"/>'
                '<line x1="42.4" y1="55.7" x2="32" y2="63.5"/>'
                '<line x1="57.6" y1="55.7" x2="68" y2="63.5"/>'
                '<circle cx="50" cy="50" r="8.5"/>'
                '<circle cx="50" cy="20" r="6.5"/>'
                '<circle cx="26" cy="68" r="6.5"/>'
                '<circle cx="74" cy="68" r="6.5"/>',
    # ブラックエプロンノート＝エプロン（胸当て＋首ひも＋腰ひも）。
    # ブラックエプロンは「ポケットなし」が特徴なのでポケットは描かない。
    "black-apron": '<path d="M38,31 V47 L27,53 a6,6 0 0 0 -3,5.5 V76 '
                   'a4,4 0 0 0 4,4 H72 a4,4 0 0 0 4,-4 V58.5 '
                   'a6,6 0 0 0 -3,-5.5 L62,47 V31 Z"/>'
                   '<path d="M41,31 V27 a9,9 0 0 1 18,0 V31"/>'
                   '<path d="M24,61 H13"/><path d="M76,61 H87"/>',
    # はかり＝天秤（食べたぶんと動いたぶんを量る）。
    # 円グラフ(maitsuki)・柱(genka)・折れ線(forecast)と重ならない形
    # だっこばかり＝体重計の上の肉球（わんこを抱っこして量る）
    "dakkobakari": '<circle cx="33" cy="33" r="4.2"/><circle cx="43.5" cy="27" r="4.5"/>'
                   '<circle cx="56.5" cy="27" r="4.5"/><circle cx="67" cy="33" r="4.2"/>'
                   '<ellipse cx="50" cy="45" rx="12" ry="9"/>'
                   '<rect x="20" y="60" width="60" height="19" rx="5"/>'
                   '<line x1="41" y1="70" x2="59" y2="70"/>',
    "hakari": '<line x1="28" y1="32" x2="72" y2="32"/>'
              '<line x1="50" y1="32" x2="50" y2="68"/>'
              '<line x1="38" y1="68" x2="62" y2="68"/>'
              '<line x1="28" y1="32" x2="28" y2="40"/>'
              '<line x1="72" y1="32" x2="72" y2="40"/>'
              '<path d="M18,40 Q28,47 38,40"/>'
              '<path d="M62,40 Q72,47 82,40"/>',
    # ていおん＝温度計と湯せんの水面。温度(縦)と湯(波)で低温調理を表す。
    # 天秤(hakari)・折れ線(forecast)・円グラフ(maitsuki)と重ならない形
    # かぐえらび＝ポールに掛かったハンガー（服の収納家具えらび）
    "kagu-erabi": '<line x1="21" y1="34" x2="79" y2="34"/>'
                  '<path d="M50,54 V44 C50,20 33,20 33,42"/>'
                  '<path d="M50,54 L29,73 H71 Z"/>',
    "teion": '<path d="M44,50 L44,30 A6,6 0 0 1 56,30 L56,50 A9,9 0 1 1 44,50 Z"/>'
             '<line x1="50" y1="38" x2="50" y2="56"/>'
             '<path d="M18,79 q8,-5.5 16,0 t16,0 t16,0 t16,0"/>',
}


# 図案本体の中央そろえ用オフセット（100座標系, dx,dy）。
# 外接矩形の中央がアプリの四角の中心に来るよう微調整。バッジは別描画なので動かない。
SHIFT = {
    "career": (0, -3), "chiritsumo": (0, 2), "cooking": (1, -3),
    "kaimono": (2, -1), "kakeru": (0, -2), "okidoki": (0, -2),
    "recap": (0, -3), "recognition": (0, 3), "reflection": (0, 2),
    "sashizu": (0, 1), "seikatsu": (0, 2), "serifu": (0, -2),
    "tabinoki": (3, 2), "tasknote": (1, -2), "think": (2, -2),
    "tsugi": (0, -4), "yuzuwari": (0, 1), "minnawari": (0, 4),
    "dokuritsu": (0, 2), "manabi": (0, -1),
    "koekake": (-2, 0),
}

# 仕事(Apple)で使うアプリ＝右下に小さくAppleロゴ
WORK_APPS = {
    "search", "nps", "recap", "recognition", "grownote", "team5whys",
    "reflection", "vault", "osusowake", "schedule", "career", "interview",
    "memo", "floormemo",
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
    dx, dy = SHIFT.get(name, (0, 0))
    if dx or dy:
        inner = f'<g transform="translate({dx},{dy})">{inner}</g>'
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
