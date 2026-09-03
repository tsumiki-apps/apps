# linear（refero styles の参照メモ）

- **出典URL**: https://styles.refero.design/style/90ce5883-bb24-4466-93f7-801cd617b0d1
- **取得日**: 2026-09-04
- **northStar**: midnight precision instrument
- **基調**: dark ／ 業種: devtools

> ロゴ・画像・フォント本体は取っていない。借りるのは数値と方針だけ。

## 一言でいうと

Linear's design system is a midnight command center built on near-black surfaces (#08090a) with paper-white type and one electric acid-lime accent (#e4f222) that functions as a functional flashlight — small, high-contrast, and used sparingly to signal action. The interface treats darkness as a substrate rather than a theme: text is crisp white at tight tracking (-0.022em), weights sit in a low 400–510 band rather than bold, and borders are hairline-thin (0.5px) to let geometry do the work that shadows usually would. Components feel precision-machined — 6px and 12px radii, compact 8–12px paddings, and almost no decorative ornament — letting the product UI (issue cards, kanban boards, AI agent panels) be the only visual texture in an otherwise quiet system.

## つみきの変数に写した結果（ライト）

| 変数 | 値 |
|---|---|
| `--paper` | `#f8f9f9` |
| `--bg` | `#f8f9f9` |
| `--card` | `#ffffff` |
| `--surface` | `#ffffff` |
| `--surface-2` | `#f3f4f4` |
| `--ink` | `#171717` |
| `--ink-mid` | `#51555c` |
| `--ink-soft` | `#61656b` |
| `--sub` | `#606061` |
| `--muted` | `#707171` |
| `--line` | `#dedfe3` |
| `--line-2` | `#ced1d4` |
| `--hair` | `#ecedef` |
| `--accent` | `#6d7407` |
| `--accent-2` | `#646a06` |
| `--accent-wash` | `#edeee6` |
| `--accent-soft` | `#dcdec9` |
| `--radius` | `12px` |

## 余白と角丸（そのままは使わない。8幅ルールが優先）

| 項目 | 値 |
|---|---|
| 要素の間 | `8px` |
| 節の間 | `96px` |
| カード内 | `24px` |
| 最大幅 | `1200px` |
| 角丸 cards | `12px` |
| 角丸 pills | `9999px` |
| 角丸 small | `2px` |
| 角丸 badges | `4px` |
| 角丸 inputs | `6px` |
| 角丸 buttons | `6px` |

## 文字（**本文には使わない**。借りるのは階層だけ）

- **Inter Variable**（weight 300, 400, 510, 590 ／ 代替: Inter (variable), or system-ui as fallback）
  - サイズ: 10, 11, 12, 13, 14, 15, 16, 17, 20, 24, 32, 48, 64, 72
  - 行間: 1.0–2.75
  - 字間: -0.022em at 48–72px, -0.012em at 20–32px, -0.011em at 15px, -0.010em at 13–16px
  - 役目: Primary UI and heading typeface — used across nav, body, headings, buttons, cards
- **Berkeley Mono**（weight 400 ／ 代替: JetBrains Mono, IBM Plex Mono, or ui-monospace）
  - サイズ: 12, 14
  - 行間: 1.40–1.71
  - 字間: -0.013em
  - 役目: Code-adjacent UI text — issue IDs (ENG-2703), keyboard shortcuts, monospaced metadata

> 日本語グリフが無い欧文なので、**本文フォントには採用しない**。
> ブランド書体 Zen Maru Gothic は上書きしない。数字・英字ラベルだけ、
> `substitute` を見て Google Fonts で置き換えてよい。

## 影


考え方: Elevation in Linear's system is achieved almost entirely through hairline borders (0.5px #23252a or 1px inset #23252a) and subtle dark drop shadows (rgba(0,0,0,0.4) 0 2px 4px) rather than layered shadow stacks. The visual hierarchy comes from the surface-level progression (#08090a → #0f1011 → #161718 → #23252a) and border definition, not from ambient shadow. The acid-lime CTA button uses an inset shadow stack (0px 5px 2px / 0px 3px 2px / 0px 1px 1px) — the only place in the system where a real shadow is applied to a chrome element.

## やること / やらないこと（原文）

**Do**

- Use Inter Variable with font-feature-settings 'cv01' on, 'ss03' on, 'zero' on — these alternate glyphs define Linear's typographic identity
- Use #e4f222 exclusively for the single primary action per view — never for decoration, never for secondary buttons
- Set body text at 16px Inter weight 400 with line-height 1.5 — larger reading sizes (17px+ at weight 590) are reserved for body emphasis blocks
- Use letter-spacing -0.022em at 48px and above — tight tracking is non-negotiable for display type
- Set card radius to 12px, button radius to 6px, pill radius to 9999px — three radii is the entire radius vocabulary
- Use 0.5px hairline borders (#23252a or #383b3f) instead of shadows for surface separation — Linear's elevation comes from borders and subtle inner shadows
- Keep section gaps at 96px and element gaps at 8px — the 8/12/24/96 spacing ladder is the rhythm

**Don't**

- Do not use bold weights (700+) — Linear's type scale caps at weight 590, the system deliberately avoids heavy display weights
- Do not use decorative gradients on buttons, cards, or text — gradients are reserved for the hero atmospheric floor only
- Do not introduce additional chromatic accent colors as actions — the acid-lime button is the only chromatic UI element
- Do not use large radii (16px+) on cards or panels — 12px is the max card radius in this system
- Do not use shadows to separate cards from the canvas — use hairline borders (#23252a) and inner inset shadows instead
- Do not use chromatic text colors for body copy — all body text sits in the #d0d6e0 / #8a8f98 / #62666d grey scale
- Do not use Berkeley Mono for headings or marketing copy — it is reserved for issue IDs, keyboard shortcuts, and technical metadata

## 日本語要約（Do / Don't）

**やること**

- 塗りの主ボタンは **1画面に1つだけ**。飾りにも二次ボタンにも使わない。
- 本文は 16px・行間 1.5。強調したい段落だけ 17px 以上に上げる。
- 48px 以上の大きな見出しは字間を詰める（-0.022em）。**欧文の話なので、日本語本文には入れない。**
- 角丸は **カード12px・ボタン6px・ピル真円** の3種類だけ。これ以外を作らない。
- 面の切り分けは**影ではなく 0.5px の細い罫線**で行う。
- 余白は 8 / 12 / 24 / 96 の梯子。要素の間8px、節の間96px。

**やらないこと**

- **太いウェイト（700以上）を使わない**。この系はいちばん太くても 590 で止める。
- ボタン・カード・文字に**グラデーションをかけない**。
- **色つきの操作要素を増やさない**。有彩色のUIはライムのボタン1つだけ。
- カードやパネルに**16px以上の角丸をつけない**。
- カードと地を**影で分けない**。細い罫線と内側の陰で分ける。
- **本文に色つきの文字を使わない**。本文はすべて灰の階調に置く。
- 等幅フォントを見出しや宣伝文に使わない。番号・ショートカット・技術的な但し書きだけ。

> つみき側の但し書き：
> ① もとが **dark 基調**のサイト。`:root`（ライト）は導出値なので、ライトは必ず目で見て決めること。
> ② ライムの `#e4f222` はダークで**塗りボタンにすると白文字が 1.23:1** で全く読めない。
>    濃い文字（`--paper`）に切り替える。ライト側は自動で `#6d7407` まで濃くしてあるので白文字でよい。
> ③ 「太いウェイトを使わない」は Zen Maru Gothic には**そのまま当てはまらない**。
>    丸ゴシックは細字だと日本語が痩せて読みにくい。ウェイトは借りず、角丸・余白・罫線だけ借りる。
> ④ 「影を使わない」は refero の方針。つみき既存アプリの `--shadow` を消すかは人が決める。

## レイアウト・写真の方針（原文）

- **layout**: Layout is max-width contained at ~1200px, centered, with full-bleed dark backgrounds extending to viewport edges. The hero is a left-aligned oversized headline (64–72px) paired with a right-aligned link CTA, followed by a large product screenshot that bleeds beyond the max-width slightly. Section rhythm alternates between text-left/image-right 2-column compositions and full-width product showcase bands, separated by 96px vertical gaps. The customer logo strip is a single horizontal row. The page never uses 3-column card grids or masonry — information density stays low, with most sections using generous whitespace and a single focal point per screen. Navigation is a fixed top bar with left-aligned logo and right-aligned links, no sidebar, no mega-menu.
- **imagery**: Linear's visual language is product-screenshot-first: the hero and section illustrations are real Linear app UI captured at full fidelity — issue cards, kanban boards, AI agent panels, command palettes — placed inside framed card containers with hairline borders. No stock photography, no lifestyle imagery, no abstract illustration. Logos appear as a customer strip in neutral grey (#8a8f98) at uniform size. Icons are minimal line-art SVGs in single-color grey scale. The hero screenshot floats on a subtle linear gradient (dark-to-light) that creates atmospheric depth without literal scenery. Every visual element is a functional artifact of the product itself.

## 読みやすさのために直した色

| 変数 | もと | 直した | もとの比 | 直した比 |
|---|---|---|---|---|
| `--ink-soft` | `#62666d` | `#757a82` | 3.45:1 | 4.61:1 |
| `--accent（ライト・導出）` | `#e4f222` | `#6d7407` | 1.17:1 | 4.80:1 |

## 人が見て決めること

- #27a644 Pulse Green は罫線と書いてあるが有彩色。--line には入れず未割当にした
- もとが dark 基調のため、:root（ライト）は導出値。ダーク側が refero の実値。ライトは必ず目視すること
- ライト: --accent #6d7407 の塗りの上は白文字でよい（5.06:1）
- ダーク: --accent #e4f222 の塗りの上に**白文字は 1.23:1 で足りない**。濃い文字（--paper #08090a なら 16.15:1）に切り替えること

## 未割当の色（捨てずに残す）

| hex | 名前 | 役割 |
|---|---|---|
| `#08090a` | Void | Page canvas, full-bleed backgrounds — the default everything sits on |
| `#0f1011` | Carbon | Card surfaces, nav bars — one step above canvas for contained content |
| `#161718` | Obsidian | Elevated surfaces, deeper card panels |
| `#d0d6e0` | Mist | Secondary headings, button text on dark surfaces |
| `#e5e5e6` | Bone | Near-white surface fills, high-contrast button text |
| `#27a644` | Pulse Green | Green outline accent for tags, dividers, and focused UI edges. Use as a supporting accent, not as a status color |
| `#eb5757` | Coral Red | Red wash for highlight backgrounds, decorative bands, and soft emphasis behind content. Use as a supporting accent, not  |
| `#02b8cc` | Signal Teal | Decorative accent, informational icon fills |
| `#6366f1` | Iris Violet | Tag/badge fills — soft chromatic punctuation on tags and labels |
| `#8b5cf6` | Lavender | Secondary tag fills, category indicators |

