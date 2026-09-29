# tn.css と tn.js（正本）

> `~/制作物/CLAUDE.md`（B層）から 2026-09-29 に移した本文。B層には要約だけを残した。

## JSを書かずに済ませる部品（tn.css）と、動きの下ごしらえ（tn.js）
- 選択カード・チェック・つまみ・アコーディオン・ダイアログ・明細・メーター・進捗・チップ・タブ・表・押せる行は
  **`tn.css` に用意してある**。クラスは全部 `tn-` 始まりで、既存アプリのCSSとぶつからない。
  色は `--card/--ink/--sub/--line/--accent/--radius` をそのまま使う（無いアプリでも既定値で動く）。
- 注入は `python3 inject_tn.py <HTML>`（何度でも実行可・古い版は自動で最新に置換）。
  **`tn.css` と `tn.js` を1つのマーカーで一緒に入れる。** 確認 `--check`／取り外し `--remove`。
  見本は `_tn_見本.html`（このページ自体が注入の動作確認）。
- **`tn.js` は CSS で書けない2つだけを持つ**（ぶら下がる名前は `window.TN` の1つ）。
  - `TN.rnd(i,k)` … **決定論の擬似乱数。デモ・架空データで `Math.random()` を使わない**
    （`~/制作物` 直下の HTML 52本がまだ使っている・2026-09-11 実測）。
    リロードのたびに形が変わると、お返事カードもIG投稿も毎回ちがう絵になり、
    「前と同じか」の見比べもできない。`rndIn/pick/shuffle` も同じ理屈で決定論。
  - `TN.reveal(id, fn)` … 見えたら再生・押したらもう一度。**再生前にタイマーを全部消す**
    ので、連打しても積み上がらない（5回押しても走っているのは1本・実測）。
    **画面に寸法が無いところ（Claude のブラウザペインは 0×0・スクショ用ヘッドレス・
    PDF書き出し・`display:none` の iframe）では IntersectionObserver が永久に発火しない。**
    そのまま焼くと図が白いままになるので、寸法が無いときだけ 1.2 秒後に描く保険が入っている。
- 出どころは lieflat-charts の**考え方だけ**（あちらは非商用ライセンスなのでコードは写していない）。
  `rnd` の式は本家をそのまま使うと k=0 で等差の直線になるため、別のかき混ぜに替えてある。
  調査 → `~/Library/Mobile Documents/com~apple~CloudDocs/Kodai/00_Tsumiki/17_調べもの・道具/道具としらべ/lieflat-charts_調査と採用可否_2026-09-08.md`
- **戻るボタンと違い、外部配布(`~/tsumiki-tools`)に入れてもよい**（見た目だけで屋号も戻る導線も含まない）。
- 「どれか1つ選ぶ」を作るとき `classList.toggle('on')` を手書きしない → `.tn-choice` + `:has(:checked)`。
- 出どころは sashimi UI(MIT)の手法を書き直したもの。調査の記録は
  `~/Library/Mobile Documents/com~apple~CloudDocs/Kodai/00_Tsumiki/17_調べもの・道具/道具としらべ/sashimi-ui調査_2026-09-08.html`。
- 必要ブラウザ: `:has()` Safari 15.4+ / `color-mix()` Safari 16.2+（未裏取り）。実機iPhoneでは未検証。
