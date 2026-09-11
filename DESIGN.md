---
version: alpha
name: つみき
description: ひとりで小さな店や現場をまわす人のための、和紙の帳面のような単一HTMLアプリ群。
colors:
  primary: "{colors.accent}"
  paper: "#f5f4f0"
  surface: "#fffefb"
  surface-2: "#efece5"
  ink: "#1d1a15"
  ink-mid: "#5b554a"
  ink-soft: "#666154"
  sub: "#68645d"
  ghost: "#887f70"
  line: "#e2ded4"
  line-2: "#d8d3c7"
  accent: "#b06f26"
  accent-2: "#8a5a24"
  accent-wash: "#f0e4d1"
  good: "#4c7a51"
  good-wash: "#dde9dd"
  good-ink: "#416845"
  warn: "#b0522a"
  warn-wash: "#f2e0d4"
  warn-ink: "#974624"
  dark-paper: "#0f0d07"
  dark-surface: "#211d14"
  dark-surface-2: "#2b2619"
  dark-ink: "#efe8da"
  dark-ink-mid: "#a89e8b"
  dark-ink-soft: "#9f988a"
  dark-line: "#36301f"
  dark-line-2: "#443d2b"
  dark-accent: "#d59a4d"
  dark-accent-2: "#e0ab63"
  dark-accent-wash: "#362a19"
  dark-good: "#7fae82"
  dark-good-wash: "#23301f"
  dark-warn: "#d9825a"
  dark-warn-wash: "#39251a"
  pigment-1: "#b07a2c"
  pigment-2: "#a3523c"
  pigment-3: "#4c6478"
  pigment-4: "#63764e"
  pigment-5: "#8a6a4e"
  pigment-6: "#6a5878"
  pigment-1-wash: "#f1e8da"
  pigment-2-wash: "#f1dfda"
  pigment-3-wash: "#e0e6eb"
  pigment-4-wash: "#e6ebe0"
  pigment-5-wash: "#ede5de"
  pigment-6-wash: "#e6e2e9"
typography:
  headline-display:
    fontFamily: Zen Maru Gothic
    fontSize: 32px
    fontWeight: 700
    lineHeight: 1.3
  headline-lg:
    fontFamily: Zen Maru Gothic
    fontSize: 24px
    fontWeight: 700
    lineHeight: 1.35
  headline-md:
    fontFamily: Zen Maru Gothic
    fontSize: 20px
    fontWeight: 500
    lineHeight: 1.4
  body-lg:
    fontFamily: Zen Maru Gothic
    fontSize: 17px
    fontWeight: 400
    lineHeight: 1.7
  body-md:
    fontFamily: Zen Maru Gothic
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.7
  label-md:
    fontFamily: Zen Maru Gothic
    fontSize: 14px
    fontWeight: 500
    lineHeight: 1.5
  label-sm:
    fontFamily: Zen Maru Gothic
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
  input:
    fontFamily: Zen Maru Gothic
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  none: 0px
  sm: 8px
  md: 12px
  lg: 20px
  full: 9999px
spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  touch: 44px
  bp-sm: 600px
  bp-lg: 900px
components:
  button-primary:
    backgroundColor: "{colors.accent-2}"
    textColor: "{colors.paper}"
    rounded: "{rounded.md}"
    padding: 12px
    height: 44px
    typography: "{typography.label-md}"
  button-primary-dark:
    backgroundColor: "{colors.dark-accent}"
    textColor: "{colors.ink}"
  button-quiet:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    height: 44px
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: 20px
  input:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    height: 44px
    typography: "{typography.input}"
  chip-selected:
    backgroundColor: "{colors.accent-wash}"
    textColor: "{colors.accent-2}"
    rounded: "{rounded.full}"
    height: 44px
  helper-text:
    textColor: "{colors.ink-mid}"
    typography: "{typography.label-sm}"
  meta-text:
    textColor: "{colors.ink-soft}"
    typography: "{typography.label-sm}"
  divider:
    backgroundColor: "{colors.line}"
    height: 1px
  divider-strong:
    backgroundColor: "{colors.line-2}"
    height: 1px
  banner-good:
    backgroundColor: "{colors.good-wash}"
    textColor: "{colors.good-ink}"
    rounded: "{rounded.sm}"
    padding: 12px
  banner-warn:
    backgroundColor: "{colors.warn-wash}"
    textColor: "{colors.warn-ink}"
    rounded: "{rounded.sm}"
    padding: 12px
  banner-good-dark:
    backgroundColor: "{colors.dark-good-wash}"
    textColor: "{colors.dark-good}"
  banner-warn-dark:
    backgroundColor: "{colors.dark-warn-wash}"
    textColor: "{colors.dark-warn}"
  pill-1:
    backgroundColor: "{colors.pigment-1-wash}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
    typography: "{typography.label-sm}"
  pill-2:
    backgroundColor: "{colors.pigment-2-wash}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
  pill-3:
    backgroundColor: "{colors.pigment-3-wash}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
  pill-4:
    backgroundColor: "{colors.pigment-4-wash}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
  pill-5:
    backgroundColor: "{colors.pigment-5-wash}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
  pill-6:
    backgroundColor: "{colors.pigment-6-wash}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
---

# つみき デザインシステム

## Overview

**和紙でできた、小さな帳面。**

表紙は生成り。角は丸く落としてある。中の罫線は薄墨で、印は黄土の判子ひとつ。
書き込むのは店主ひとりで、毎日それを開く。持ち歩いて、片手で、立ったまま開く。

これがつみきの全アプリの姿。飾りは要らない。読めることと、間違えないことが全部。

- **使う人**: ひとりで小さな店や現場をまわしている人。パソコンは得意でない。
- **感じてほしいこと**: 落ち着き。急かされないこと。自分の道具だと思えること。
- **避けたい印象**: 業務システム。ダッシュボード。SaaSの管理画面。にぎやかな通知。
- **迷ったとき**: 装飾を足すより、余白を足す。色で分けるより、間で分ける。

帳面には帳面のふるまいがある。光らない。影を落とさない。跳ねない。
グラデーションもガラスも無い。名前が「和紙の帳面」であるかぎり、
これらは書かなくても付いてくる。

## Colors

和紙と、和の顔料。無彩色を使わず、すべてにわずかな黄みを含ませる。

- **Paper**（`{colors.paper}`）— 生成りの紙。ページの地。
  **純白 `#ffffff` は使わない。** 紙は白くない。
- **Surface**（`{colors.surface}`）— 紙の上に置いた、もう一枚。カードの地。
- **Ink**（`{colors.ink}`）— 墨。すべての本文。**純黒 `#000000` は使わない。**
- **Ink-mid / Ink-soft** — 薄墨。補助の文字と、日付や単位のような添え物。
  `ink-soft` はもとの `#8f8877` だと**どの地の上でも 4.5 に届かなかった**（2.75〜3.50）ので、
  6つの地すべてで 4.8 以上になるところまで沈めた（現在 `{colors.ink-soft}`）。
  ダーク側も同じ理由で `#847c6c` → `{colors.dark-ink-soft}`。
  **これより薄い文字を新しく作らない。** 薄さは色ではなく、字の大きさと余白で出す。
- **Line / Line-2** — 罫線。有彩色の罫線は引かない。**文字には使わない。**
- **Sub**（`{colors.sub}`）— 古いアプリが使っている補助文字の色（旧語彙）。
  もとの `#77736B` は地によって 3.86〜4.41 で届かなかったので沈めた。
  **新しく作るときは `ink-mid` か `ink-soft` を使う。** `sub` は既存アプリのための名前。
- **Ghost**（`{colors.ghost}`）— 気配だけの薄い色。矢印「›」・ドラッグのつまみ・
  アイコンボタンのような**記号**に使う。もとの `#BEB9B0` は 1.60〜1.95 しか出ず、
  記号としても見えなかったので、**3:1（WCAG 1.4.11・UI部品の最低線）に余裕を持たせた
  3.2 以上**まで沈めた。薄さは保っている。
  **読ませる言葉には使わない。** ラベル・説明・数値はどれだけ小さくても `sub` か `ink-soft`。
- **Accent**（`{colors.accent}`）— 黄土。判子ひとつ。
  **1画面にひとつの、いちばん大事な操作だけ**に使う。
  **`accent` を文字色にしない。** どの地の上でも 4.5 に届かない（3.18〜4.04・実測）。
  洗い色のチップやタグに文字を置くときは `{colors.accent-2}` を使う。
- **Accent-2**（`{colors.accent-2}`）— 濃い黄土。**塗りつぶしのボタンと、色つきの文字はこちら**。
- **Good / Warn**（`{colors.good}` / `{colors.warn}`）— 苔と弁柄。
  信号機の赤緑は使わない。和らげた色で「よい」「気をつけて」を出す。
  **洗い色の帯の上に置く文字は `{colors.good-ink}` / `{colors.warn-ink}`**（濃い側）。
  `{colors.good}` をそのまま `{colors.good-wash}` の上に置くと 3.98:1 で届かない。
- **Pigment 1–6** — 黄土・弁柄・藍・苔・鳶・紫紺。
  費目や分類を色分けするとき、この順に割り当てる。7色目を作らない。
  **顔料そのものを塗りの地にしない。** 実測すると、文字色が色ごとに変わってしまう
  （黄土は墨文字しか乗らず、藍と紫紺は紙色の文字しか乗らず、鳶はどちらも 4.5 に届かない）。
  文字を乗せるときは **`pigment-N-wash`（洗い色）に敷いて、文字は墨**（13.5〜14.3:1）。
  顔料そのものは、凡例の四角・グラフの線・細い印など**文字を乗せない場所**に使う。

ダークは反転ではなく **「夜の帳面」**。同じ紙が、暗いところに置かれている。
`dark-` の付いたトークンを `@media (prefers-color-scheme: dark)` の中で差し替える。

### 塗りつぶしのボタンの色（実測で決めた）

黄土 `{colors.accent}` の上に紙色の文字を置くと **3.71:1** しか出ず、AA（4.5:1）に届かない。
そこで塗りは濃い側を使う。

| | 背景 | 文字 | 実測 |
|---|---|---|---|
| ライト | `{colors.accent-2}` | `{colors.paper}` | **5.35:1** |
| ダーク | `{colors.dark-accent}` | `{colors.ink}`（墨） | **7.07:1** |

ダークは**文字が墨**。夜の帳面では、明るい黄土の上に暗い字を置く。白は乗らない。

## Typography

書体は **Zen Maru Gothic**（丸ゴシック）ひとつ。これがつみきの声そのもの。

落ちる順: `Zen Maru Gothic` → `Hiragino Maru Gothic ProN` → `Hiragino Sans` → `sans-serif`

- 本文は 16px 以上。**入力欄は必ず 16px 以上**（下回ると iOS が勝手に画面を拡大する）。
- ウェイトは 400 / 500 / 700 の3段だけ。細字は日本語だと読みにくい。
- 見出しは本文の 1.5〜2倍まで。5倍にしない。大きさより余白で効かせる。
- **欧文書体をブランド書体として持ち込まない。** 日本語のグリフが無い。
  数字や英字ラベルにどうしても要るときだけ、部分的に使う。
- **漢字は普通に使う。** 読みやすくするつもりで、わざとひらがなに開かない
  （「今」「全部」「追加」「削除」「普段」）。ひらがなが続くと、かえって読みにくい（2026-09-11 本人の指示）。
- **画面の文字は最小限。** ラベルは1〜4文字の名詞にし、説明文は置かない。
  どうしても要る前提は、ⓘ で開く1行に畳む。

## Layout

- **8幅すべてで成立させる**: 320 / 375 / 390 / 430 / 768 / 1024 / 1440 / 1920。
  これが本体。**守るべきは「8幅で崩れないこと」であって、区切りの本数ではない。**
  確かめ方は `python3 check_widths.py <HTML>`。
- **新しく作るときは `{spacing.bp-sm}` と `{spacing.bp-lg}` の2本で足りるように設計する。**
  3本目が欲しくなったら、まず余白とグリッド（`minmax` / `auto-fit`）で解けないか考える。
  ただし**既にあるアプリの段組みを、揃えるためだけに壊さない。**
  実測すると 768 / 760 / 1080 は意図をもって使われていて、
  大画面まで作り込んだもの（つみ時間は 760/1080/1440/1920/2200 の5段）もある。
  8幅で崩れていないなら、それは直す対象ではない。
- 固定 px 幅を作らない。高さは `100dvh`（`100vh` はスマホで下が切れる）。
- 表は `overflow-x:auto` で包む。ページ本体は横スクロールさせない。
- 余白は 4px 刻み。カード内は 20px、要素の間は 8〜16px、節の間は 32px。
- タップできるものは **`{spacing.touch}` 以上**。指で押せる最小。

## Elevation & Depth

影は「紙の重なり」。**黒ではなく墨色で落とす。**

- ライト: `0 1px 2px rgba(40,32,18,.05), 0 10px 26px -16px rgba(40,32,18,.18)`
- ダーク: `0 1px 2px rgba(0,0,0,.3), 0 12px 30px -18px rgba(0,0,0,.65)`

重ねるのは1段だけ。2段目3段目を作らない。
階層は影ではなく `{colors.surface}` → `{colors.surface-2}` の色差で作る。

## Shapes

つみき＝積み木。角は落とすが、丸くしすぎない。

- カード・シート: `{rounded.lg}`（20px）
- ボタン・入力欄: `{rounded.md}`（12px）／ 小さな部品: `{rounded.sm}`（8px）
- チップとアバターだけ `{rounded.full}`
- **同じ画面で角丸と直角を混ぜない。**

## Components

JSを書かずに済む部品は `tn.css` に用意してある（`tn-` 始まりのクラス）。
選択カード・チェック・つまみ・アコーディオン・明細・メーター・チップ・タブ・表。
新しく手書きする前に、まずそこを見る。

- **ボタン** — 高さ `{spacing.touch}` 以上。主役は塗り（上の表の色）、それ以外は `{colors.surface-2}`。
  1画面に塗りボタンは1つ。
- **入力欄** — 16px、高さ `{spacing.touch}`、`{colors.surface}` の地に `{colors.line}` の枠。
- **チップ** — 選ばれているものは `{colors.accent-wash}` の地に `{colors.accent-2}` の文字。
- **つみきロゴ** — 立体（アイソメ）の公式SVGを**座標ごとコピー**する。
  正本 = `~/制作物/index.html` の `<svg class="mark" viewBox="0 0 100 100">`。
- **アイコンとイラスト** — 文字で説明する前に、形で分からせる（2026-09-11 本人の指示）。
  見出し・ボタン・入力欄の頭に線画アイコンを置く。描き方はアプリアイコンと同じ
  （`fill:none`・`stroke:currentColor`・線の端と角は丸）。絵文字で代用しない。
  空の画面には、次にすることが分かる小さな線画を1枚とボタン1つ。
  増減は ↑↓ と符号、単位は「/月」「回」のような短い記号で。アイコンだけのボタンには `aria-label` を付ける。

## Motion

```yaml
motion:
  quick: 120ms
  normal: 200ms
  easing: "cubic-bezier(0.2, 0, 0, 1)"
```

動きは短く、素っ気なく。跳ねない。行き過ぎない。余韻を残さない。

- 押した反応・切り替え: `{motion.quick}`、`{motion.easing}`
- 画面やシートの出入り: `{motion.normal}`、同じカーブ
- 300ms を超えるものを作らない。超えるなら、その演出をやめる。
- `prefers-reduced-motion` を尊重する。すべて 0ms に落とす。

## Do's and Don'ts

- **Do** 本文・補助文字・小さいラベルのコントラストを **4.5:1 以上**、画面で実測する。
- **Do** 塗りボタンの文字色を必ず測る。**黄土 `{colors.accent}` に白文字は 4.08:1 で届かない。**
- **Do** 幅375pxの iframe で確かめる（`--window-size` は嘘をつく）。
- **Do** 入力欄の font-size を 16px 以上にする。
- **Do** タップ対象を `{spacing.touch}` 以上にする。
- **Do** 新しいアプリを作る前に `~/制作物/design_refs/*.design.md` を見る。
- **Do** 文字を減らし、アイコン・イラスト・大きな数字で直感的に操作できるようにする。
- **Do** 漢字は普通に使う。
- **Don't** 純白 `#ffffff` と純黒 `#000000` を地や文字に使う。
- **Don't** `{colors.accent}` を1画面に2つ以上の主役として置く。
- **Don't** `{colors.accent}` を文字色にする（どの地でも 4.5 未満）。色つきの文字は `{colors.accent-2}`。
- **Don't** `{colors.ink-soft}` より薄い文字色を新しく作る。薄さは字の大きさと余白で出す。
- **Don't** `{colors.ghost}` を文字色にする。気配の色であって、読ませる色ではない。
- **Don't** 塗りの上に `color:#fff` を直書きする。トークンで指定する。
- **Don't** 欧文書体を本文やブランド書体に採用する。
- **Don't** 区切りを増やして解決する。まず余白とグリッドで解けないか考える。
- **Don't** 固定 px 幅・`100vh` を使う。
- **Don't** つみきロゴを自作の立方体・絵文字・平面で代用する。
- **Don't** グラデーション・ガラス・発光・大きな影を足す。帳面は光らない。
- **Don't** 操作の説明を画面に長い文で置く。わざとひらがなに開く。

---

## この文書の使い方

```bash
npx @google/design.md lint ~/制作物/DESIGN.md     # 検査（色を足したら必ず通す）
npx @google/design.md export --format css-vars ~/制作物/DESIGN.md
```

`export` で出る変数名には `--color-` が付く（`--color-paper`）。
つみきの既存変数（`--paper`）とは一致しないので、**そのままコピペしない**。
この文書は正本であって、生成器ではない。

- 規格: [google-labs-code/design.md](https://github.com/google-labs-code/design.md)（Apache-2.0・`alpha`）
- 調べた記録: `~/つみき出力/道具としらべ/DESIGN.md標準の調査_2026-09-08.md`
