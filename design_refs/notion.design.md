# notion（refero styles の参照メモ）

- **出典URL**: https://styles.refero.design/style/2bf4c61f-de10-4614-ba1b-20c0453bd2a9
- **取得日**: 2026-09-04
- **northStar**: warm paper notebook under afternoon sun
- **基調**: light ／ 業種: productivity

> ロゴ・画像・フォント本体は取っていない。借りるのは数値と方針だけ。

## 一言でいうと

Notion reads like a well-loved paper notebook under afternoon light: a warm off-white canvas (#f6f5f4) that feels tactile rather than clinical, generous sans typography that gives editorial weight to product copy, and color used as sparse punctuation — peachy pills highlight verbs, a single blue anchors the primary action, and a rotating cast of accent hues (coral, amber, sky, midnight) paints the feature card backgrounds like sticky notes. Cards sit on the canvas with 1px hairline borders and 12px corners — no shadows, no chrome — like ruled sections in a Moleskine. Motion is playful and springy, with 200ms ease transitions and bouncy character-mark animations that make the interface feel alive without ever being decorative.

## つみきの変数に写した結果（ライト）

| 変数 | 値 |
|---|---|
| `--paper` | `#f6f5f4` |
| `--bg` | `#f6f5f4` |
| `--card` | `#ffffff` |
| `--surface` | `#ffffff` |
| `--surface-2` | `#f4f4f4` |
| `--ink` | `#000000` |
| `--ink-mid` | `#615d59` |
| `--ink-soft` | `#696969` |
| `--sub` | `#707070` |
| `--muted` | `#6c6c6b` |
| `--line` | `#d8d8d7` |
| `--line-2` | `#979796` |
| `--hair` | `#e8e8e7` |
| `--accent` | `#0070d4` |
| `--accent-2` | `#0065c0` |
| `--accent-wash` | `#e2eaf1` |
| `--accent-soft` | `#c5daee` |
| `--shadow` | `0px 0.7px 1.462px 0px rgb(0% 0% 0%/0.015), 0px 3px 9px 0px rgb(0% 0% 0%/0.03)` |
| `--radius` | `12px` |

## 余白と角丸（そのままは使わない。8幅ルールが優先）

| 項目 | 値 |
|---|---|
| 要素の間 | `8px` |
| 節の間 | `80px` |
| カード内 | `24px` |
| 最大幅 | `1440px` |
| 角丸 cards | `12px` |
| 角丸 pills | `9999px` |
| 角丸 small | `4px` |
| 角丸 buttons | `8px` |

## 文字（**本文には使わない**。借りるのは階層だけ）

- **NotionInter**（weight 400, 500, 600, 700 ／ 代替: Inter）
  - サイズ: 12px, 14px, 16px, 20px, 22px, 24px, 40px, 42px, 48px, 54px, 72px, 96px
  - 行間: 0.83, 1.00, 1.04, 1.14, 1.21, 1.27, 1.33, 1.40, 1.43, 1.50
  - 字間: -0.048em at 96px, -0.036em at 42px, -0.035em at 54px, -0.028em at 72px, -0.011em at 22px, +0.01em at 12px, normal at body sizes
  - 役目: Primary sans-serif — geometric humanist with slight quirks, deployed at 400 for body, 500 for nav/UI, 600-700 for display headings. The type-scale uses aggressive negative letter-spacing at large sizes (-4.6px at 96px, -2px at 72px) that tightens the headline to feel confident and compact rather than airy.
- **Lyon Text**（weight 400 ／ 代替: Source Serif Pro）
  - サイズ: 18px, 32px
  - 行間: 1.25, 1.56
  - 役目: Editorial serif reserved for specific body-text moments and section intros — used sparingly (4 instances) to give voice a literary weight, like a pull-quote in a magazine layout. Functions as a system accent, not a parallel hierarchy.

> 日本語グリフが無い欧文なので、**本文フォントには採用しない**。
> ブランド書体 Zen Maru Gothic は上書きしない。数字・英字ラベルだけ、
> `substitute` を見て Google Fonts で置き換えてよい。

## 影

- **Nav (sticky)**: `0px 0.7px 1.462px 0px rgb(0% 0% 0%/0.015), 0px 3px 9px 0px rgb(0% 0% 0%/0.03)`
- **Product UI Mockup**: `0px 4px 12px rgba(0, 0, 0, 0.1)`

考え方: Elevation is almost entirely absent from content surfaces. Cards do not float — they sit on the canvas like sticky notes, separated only by 1px hairline borders at rgba(0,0,0,0.08). The only shadows in the system appear on the product UI mockup screenshots (to simulate depth within the product frame) and on the navigation bar on scroll. This flatness is a deliberate choice: the interface should feel like paper, not glass.

## やること / やらないこと（原文）

**Do**

- Use #f6f5f4 as the page canvas and #ffffff for card surfaces — never invert this hierarchy by putting a warm card on a white page
- Reserve #0075de for the single primary action per screen; all secondary actions should use ghost (#e6f3fe bg) or text styles
- Apply negative letter-spacing to all display sizes: -4.6px at 96px, -2px at 72px, -1.9px at 54px — body text stays at normal tracking
- Use 1px solid borders at rgba(0,0,0,0.08) instead of shadows to separate cards from the canvas
- Use 12px border-radius for cards and 8px for buttons; reserve 9999px for pills and hero highlight pills only
- Paint feature-block backgrounds with accent hues (#ffb110, #f64932, #62aef0, #02093a) rather than adding borders or shadows to create visual variety
- Keep motion at 200ms with ease timing for hovers and transitions; reserve spring/bounce animations for character marks and hero elements

**Don't**

- Do not use pure #ffffff as the page background — the warm #f6f5f4 canvas is the system's signature warmth
- Do not add shadows to content cards — the system uses hairline borders only, shadows appear only on the product UI mockup and nav bar
- Do not use multiple chromatic button colors in the same view — #0075de is the only filled button; color variety belongs in card backgrounds
- Do not use #000000 at 100% for all text — build hierarchy through alpha (100%, 95%, 60%, 40%) on the same color
- Do not use Lyon Text for UI labels or navigation — it is reserved for editorial body copy moments at 18px
- Do not apply border-radius larger than 12px to rectangular content — pills (9999px) and cards (12px) are the two shapes
- Do not use gradients — the system is strictly flat fills; visual depth comes from the warm-to-white surface contrast and accent card backgrounds

## 日本語要約（Do / Don't）

**やること**

- ページの地は温かい灰白 `#f6f5f4`、カードは純白 `#ffffff`。**この上下を逆にしない**（白い地に温かいカード、はしない）。
- 塗りの主ボタンは1画面に1つだけ。それ以外はゴースト（薄い青地）か文字リンクにする。
- 大きな見出しほど字間を詰める（96pxで -4.6px、72pxで -2px、54pxで -1.9px）。**本文の字間は詰めない。**
- カードと地の切り分けは**影ではなく1pxの罫線**（黒の8%）で行う。
- 角丸はカード12px・ボタン8px。真円（9999px）はピル型の札だけに使う。
- 変化をつけたいときは、枠や影を足すのではなく**カードの地を色で塗る**。
- 動きは200ms・ease。跳ねる動きはキャラクターや主役の要素だけ。

**やらないこと**

- ページの地を**純白にしない**。温かい灰白がこの系のいちばんの特徴。
- 本文カードに**影をつけない**。影はナビと製品モックだけ。
- 同じ画面に**色つきの塗りボタンを何種類も置かない**。塗りは1色だけ。
- 文字色を**全部100%の黒にしない**。同じ色の濃さを変えて階層を作る。
- 見出し用のセリフ体を**UIのラベルやナビに使わない**。
- 四角い内容物に**12pxより大きい角丸をつけない**。形はピルとカードの2つだけ。
- **グラデーションを使わない**。奥行きは「温かい地と白いカードの差」で出す。

> つみき側の但し書き：
> ① 「カードに影をつけない」は refero の方針だが、つみき既存アプリは `--shadow` を使っている。
>    `--shadow` は写してあるので、影を消すかどうかは**アプリごとに人が決める**。
> ② 字間の指定は**欧文の前提**。Zen Maru Gothic の日本語本文には詰めを入れない。
> ③ ブランド色 `#0075de` は paper 上 4.19:1 で足りず、**`#0070d4` に濃くしてある**（4.52:1）。
> ④ ダークで塗りボタンにすると白文字が 3.90:1 で落ちる。ダークだけ濃い文字（`--paper`）にする。

## レイアウト・写真の方針（原文）

- **layout**: Centered, max-width contained at ~1440px. The hero is a centered stack: character-mark row → large two-line headline with an embedded colored pill → subhead → two-button CTA row → large product UI mockup. Below the hero, sections alternate between white-card grids and full-bleed colored accent panels. The logo wall is a centered single-row grid of greyscale partner logos. Feature blocks use a 2-column layout (text left, colored panel right) that alternates left-right between sections. The 'Ask your on-demand assistants' section uses a 2×2 card grid where the top card is full-width and the bottom row splits into two equal columns. Section gaps are generous (~80px) creating a calm vertical rhythm. Navigation is a fixed top bar at 64px height with centered nav items and right-aligned action buttons.
- **imagery**: Illustration-first, photography-free. The visual language is built from flat illustrated character marks (round faces in 2px colored circles), abstract decorative elements (hand-drawn squiggles, sparkles, arrows, flower shapes), and product UI mockups. Character marks appear in the hero as a horizontal row of 7 avatars and scatter across the page as playful punctuation. Product screenshots are the only 'real' visuals — they show the actual Notion interface (kanban boards, document views, AI agent panels) with full chrome and real data. The product mockup in the hero is large, centered, and casts a single drop-shadow to separate it from the canvas. There are no lifestyle photos, no stock imagery, no abstract 3D renders.

## 読みやすさのために直した色

| 変数 | もと | 直した | もとの比 | 直した比 |
|---|---|---|---|---|
| `--sub` | `#757575` | `#707070` | 4.23:1 | 4.55:1 |
| `--muted` | `#717170` | `#6c6c6b` | 4.49:1 | 4.83:1 |
| `--accent` | `#0075de` | `#0070d4` | 4.19:1 | 4.52:1 |
| `--accent（ダーク）` | `#0070d4` | `#0080f3` | 3.80:1 | 4.80:1 |

## 人が見て決めること

- surfaces level 2 が有彩色（#ffb110）なので、面としては使わず導出値にした
- elevation に Card が無く、先頭の「Nav (sticky)」を --shadow に使った
- ライト: --accent #0070d4 の塗りの上は白文字でよい（4.92:1）
- ダーク: --accent #0080f3 の塗りの上に**白文字は 3.90:1 で足りない**。濃い文字（--paper #131211 なら 4.80:1）に切り替えること

## 未割当の色（捨てずに残す）

| hex | 名前 | 役割 |
|---|---|---|
| `#ffb110` | Accent Card Surface | surfaces level 2（有彩色のため面に不採用） |
| `#f6f5f4` | Paper Warmth | Page canvas, hero background, section backgrounds — warm off-white gives the system its tactile analog feel |
| `#ffffff` | Pure White | Card surfaces, elevated panels, logo-wall background, contrast text on dark cards |
| `#111111` | Charcoal | Dark text variant for specific UI moments where pure black would feel too harsh |
| `#e6f3fe` | Sky Tint | Ghost CTA background, soft blue wash for secondary actions, tinted hover states |
| `#ffb110` | Marigold | Hero pill highlights, Agent feature card background, warm accent for callouts — the first color the eye finds |
| `#f64932` | Coral | Decorative card backgrounds, hero pill alternates, warm-to-hot accent in the rotating cast |
| `#e89d01` | Saffron | Body-section accent panels, secondary warm yellow for background washes |
| `#e32d14` | Vermillion | Deep coral for saturated body-section backgrounds, signal-warm accent |
| `#b18164` | Mocha | Warm brown accent for body-section panels — the earthy member of the accent cast |
| `#097fe8` | Signal Blue | Decorative card backgrounds, hero decorative highlights, secondary blue for visual variety |
| `#62aef0` | Sky Wash | Lightest blue in the cast — decorative backgrounds, heading accent highlights, airy washes |

