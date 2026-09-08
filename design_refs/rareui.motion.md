# Rare UI（動きの参照メモ）

- **出典**: https://www.rareui.com/ ／ ソース https://github.com/swamimalode07/rare-ui
- **ライセンス**: MIT（写してよい。移植コードに出典1行を残す）
- **取得日**: 2026-09-08（★877・その日も更新されている生きた本）
- **中身**: React + Motion（framer-motion）の単一ファイル部品が19点。shadcn CLI で入れる前提。
- **これは refero-styles の採取物ではない。** refero は「配色・角丸・影の体系」、こちらは「動きの作り方」。
  したがって `*.design.md` ではなく `*.motion.md` に置いた。

> **つみきは単一HTML＋素のJS。React も Motion も入っていないので、コードはそのままでは使えない。**
> 借りるのは**考え方と数値**。**移植ずみの動く見本＝隣の `rareui.motion.demo.html`（コピー元はここ）**
> ／ 同じものが `~/つみき出力/道具としらべ/RareUI移植見本_2026-09-08.html` にもある（スマホで見る用）。

---

## 1. 採る（つみきに効く）

### ① ぐにゃりタブ（Gooey nav）— いちばんの収穫
選ばれた札だけが群れから離れ、**離れぎわに「首」が伸びて切れる**。
つみきのこれまでの gooey は `filter: blur() + contrast()`（＝すき間の窓は22px前後）。あれは
にじむ・重い・上に載る文字が汚れる。**Rare UI はフィルタを使わず、すき間にSVGの曲線を1枚置く。**

```js
// すき間 gap のとき、2本の二次ベジェで「くびれ」を描く
const NECK_BREAK = 0.22;               // すき間が「間隔×0.22」を超えたら首は消える
function neckPath(gap, span){
  if (!(gap > 0)) return '';
  const waist = 100 * (1 - gap / (span * NECK_BREAK));
  if (waist <= 0) return '';
  const start = span - gap, mid = start + gap / 2;
  return `M${start} 0 Q${mid} ${100-waist} ${span} 0 L${span} 100 Q${mid} ${waist} ${start} 100 Z`;
}
```
- SVG は `width=span` `viewBox="0 0 span 100"` `preserveAspectRatio="none"`、札の `right:100%` に置く。
- 首の色は `<linearGradient>` で **左の札の色 → 右の札の色**。だから活性札の色にそのまま溶ける。
- 閉じている継ぎ目の margin は **0 ではなく −1px**。0 だと髪の毛線が透ける。
- 角丸は「継ぎ目が開いているか」で 12px / 0px を切り替える。開いた側だけ丸くなる。
- **にじまない・文字が汚れない・フィルタ0**。つみきの液体メニューはこの方式に置き換える価値がある。
  （つみきリモートの液体メニューは `git revert 3557a49` で戻せる保留状態 → 再挑戦するならこの方式で）

### ② その場で確かめる削除（Delete button）
`confirm()` の置き換え。**`~/制作物` の HTML 53本が `confirm(` を使っている**（2026-09-08 実測）。
ゴミ箱のフタが −35° 開き、缶の胴が身をかがめ、右に ✓ と ✕ が出てくる。画面が飛ばない。

- フタ：`transform-box:view-box; transform-origin:3px 6px;` で −35°。
  **`transform-box:view-box` が要る。** 無いと軸が図形自身の箱になって回転がずれる（移植中に踏んだ）。
- 缶：`d` 属性を書き換える。`M19 {top}v{20-top}a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V{top}` の `top` を 6 → 13.5。
- ✓✕ は 0.07秒ずつ遅らせて出す（staggerChildren 0.07）。
- **つみきに移すときの直し**：本家の丸は28px。**つみきは44pxルール**なので、見た目30pxの丸を
  44pxの透明ボタンで包む（`transform:scale()` は当たり判定を変えないので、8幅チェックは
  `getBoundingClientRect` ではなく `offsetHeight` で測ること）。

### ③ くるくる回る数字（Animated counter）
桁がドラムのように回る。**肝は上下のぼかしマスク**。止まっている桁はくっきり、回る桁だけ流れる。

```css
mask-image: linear-gradient(to bottom,
  rgba(0,0,0,0) 0%, rgba(0,0,0,.06) 5.5%, rgba(0,0,0,.5) 11%, rgba(0,0,0,.94) 16.5%,
  #000 22%, #000 78%,
  rgba(0,0,0,.94) 83.5%, rgba(0,0,0,.5) 89%, rgba(0,0,0,.06) 94.5%, rgba(0,0,0,0) 100%);
```
- 直線のフェードだと「硬い切れ目」に見える。**段階を刻んだフェードにするのが本家の要点。**
- 桁の柱は 0..9 のあとに **もう1枚 0 を置く**。9→0 が「前へ回って」着地する。
- 行の高さは文字の1.5倍。マスクの 22%〜78% がちょうど文字の高さになる。
- 効きどころ：genka / hiyou / chiritsumo / check-money の合計金額。

### ④ 割れる時間入力（Duration picker）
ふだんは1つのかたまり、編集に入ると3つに割れて角が丸くなる。**「いま編集中」を色ではなく形で言う。**
- すき間 8px、内側の角丸は 0 → 12px を openness に比例させる。余白も 3px → 12px。
- **ばねの「速度」を横ゆれに写している**：`gapVelocity` を [-70,0,70] → [-3,0,3] px に写し、
  さらに別のばねで均す。割れる勢いで中身が少しよろける。ここが上手い。
- 範囲外の数字を打つと `errorX.jump(6)` で軽く弾く（エラー文言を出さない）。

### ⑤ プロダクトキー入力（OTP input）
1文字ずつ下から転がり込む。そろうと**緑の枠が SVG の `stroke-dashoffset` で「描かれる」**、
違えば赤くふるえる。→ `inject_license.py` のキー入力ゲートにそのまま使える。

### ⑥ 表面のトークン（全部品で共通）
| 本家 | 値 | つみきでは |
|---|---|---|
| SURFACE | `#F4F4F9` / dark `#262626` | `--surface` |
| GLYPH | `#868593` / dark `#9B9AA7` | `--sub` |
| ACCENT | `#FC4C01` / `#FF5F2E` | `--accent`（`#b06f26`）※同じ暖色系なので素直に入る |
| LIFT | 影3枚重ね | 下記 |
| 基準ばね | `stiffness 200 / damping 28 / mass 1` | 迷ったらこれ |

```css
/* 「持ち上がり」＝0.5pxの輪郭 + 3pxのやわらかい影 + 上端の白いハイライト */
--lift: 0 .5px 1px rgba(0,0,0,.05), 0 1px 3px rgba(0,0,0,.08), inset 0 .5px 0 rgba(255,255,255,.9);
```
- 角は `figma-squircle`（JSでpathを作る）。**つみきは JS を足さずに
  `@supports (corner-shape: squircle){ ... }` で足すだけにする。**未対応ブラウザは普通の角丸のまま。
- `prefers-reduced-motion` を**全部品が律儀に見ている**。移植でも落とさない。

---

## 2. 採らない（理由つき）

| 部品 | 見送る理由 |
|---|---|
| Fluid Orb / Matrix orb | WebGL。**墨の流体シミュ（`ink-fluid.js`）には触らない**決まりがあるし、スマホで電池を食う |
| Proximity Sidebar | マウスのY座標との距離で目盛りが伸びる＝**指では死ぬ**。つみきはスマホが主 |
| Gravity Letters | 文字が降り積もる物理。アプリの用がない。**IG投稿の素材としてなら面白い** |
| Grid Reveal | 画像の読み込み演出。つみきに重い画像読み込みがない |
| GitHub activity / Code Block | 用途なし |
| Folder component | 飾り。中身が増えない |
| Family Drawer | `vaul` 依存で丸ごとは使えない。ただし**考え方は採る**＝<br>中身の高さの差が大きいほど不透明度の時間を長くする（0.15〜0.27秒、差÷500）。ドロワーの中で画面が入れ替わるとき効く |
| Bounce sidebar / Hook sidebar | つみきに縦の目次を持つ画面が今はない。説明書ページを作るなら候補 |

---

## 3. 移植するときの落とし穴（実際に踏んだ）

1. **`transform-box:view-box` を忘れると SVG の回転軸がずれる。**
2. **ブラウザペインは常に非表示扱いなので rAF が止まる。** ばねもJSトゥイーンも進まない。
   見本には `window.__pump(ms)` を用意して手でコマを送る。CSSトランジションは
   `el.getAnimations().forEach(a=>a.currentTime=800)` で進める。
3. **`transform:scale()` は当たり判定を変えない。** 44pxチェックは `offsetHeight` で測る。
4. 本家の丸ボタンは28px。**つみきの44pxルールに合わせて包み直すこと。**
5. 首（gooey）が見えるのは**すき間が 4.4px 未満のあいだだけ**（span 20 × 0.22）。
   スクリーンショットで捕まえたければコマ送りで2コマ目あたりを狙う。
