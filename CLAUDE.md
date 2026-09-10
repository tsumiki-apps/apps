# 制作物（つみき）— AI作業ルール（B層・このリポジトリだけ）

ここは Kodai の「つみき」アプリ群（単一HTMLアプリ＋一部 Supabase 同期）の作業ディレクトリ。
**共通ルール（事故防止の核・報告の作法・個人情報・ディレクトリ地図）は `~/.claude/CLAUDE.md`（A層）にある。**
ここには**このリポジトリでしか意味を持たないもの**だけを書く。同じ文章をA層と二重に持たない。

> **A層カナリア: A-20260831**
> この行の直前に「Kodai の共通ルール（A層）」の内容が見えていなければ、
> `~/.claude/CLAUDE.md` が読まれていない。**その場合は作業を止めて Kodai に伝える。**

## 1. 置き場は「外部に使わせるか？」で決める（4系統）
| 行き先 | パス / URL | 使うとき | 戻るボタン |
|---|---|---|---|
| 仕事（Apple）で同僚に | 別アカウント `teamkit-tools` = teamkit-tools.github.io | 仕事用URLに屋号「つみき」を出さない。`gh auth switch --user teamkit-tools` →**終わったら tsumiki-apps に戻す** | — |
| 外部向け（無料も有料も） | `~/tsumiki-tools` = tools.tsumiki-apps.com | 少しでも外部に見せる/渡す/使わせるなら**必ずこれ** | 注入しない |
| 自分専用 | ここ（apps）= tsumiki-apps.github.io/apps/ | 自分だけが使う | **注入する** |
| 会社の顔 | `~/tsumiki-portfolio` = tsumiki-apps.com | ポートフォリオ・墨シミュ | — |

- tools 更新は2通り：ビルドあり＝`python3 deploy_tools.py <name>`／ビルド不要の単一HTML＝`~/tsumiki-tools` を直接編集して push。
- 引っ越したら TOOLS からの撤去までワンセット（残すと本体を案内ページで上書きする事故）。
- 有料で渡すアプリは**プロダクトキーゲートを注入**（`inject_license.py <HTML> <app名>` または TOOLS エントリに `license:`）。
  キー発行は Supabase の `license_issue()`。
- 振り分けの正本 → `~/ObsidianVault/Decisions/2026-07-27-server-operation-model.md`

## 2. 戻るボタンとアイコンの注入
- **自分専用（ここ）に置く新規アプリには `~/制作物/inject_backbtn.py` を実行**。apple-touch-icon も毎回注入。
- **HTMLにベタ書きしない**（常時表示の `<a href="index.html">`・フッターリンクは禁止）。
  正しい仕様＝左端エッジスワイプのみ。見える「‹ つみき」ボタンは置かない。
- **外部配布（tools）には注入しない。**

## 2.5 見た目（配色・角丸・影）を決めるとき

### 正本は `DESIGN.md`（このリポジトリの直下）
つみきの配色・書体・余白・角丸・影・動き・禁止事項は **`~/制作物/DESIGN.md` に1本化**した。
[Google Labs の DESIGN.md 規格](https://github.com/google-labs-code/design.md)（Apache-2.0・`alpha`）準拠。
**新しいアプリを作る前・既存の色を変える前に、まずこれを読む。**

実測で決めた要点（迷ったらここ）:
- 塗りつぶしボタンは **ライト＝`--accent-2` の地に `--paper` の文字（5.35:1）／ダーク＝`--accent` の地に `--ink`（墨）の文字（7.07:1）**。
  **`--accent`（黄土 `#b06f26`）に白文字は 4.08:1 で不合格。** `color:#fff` の直書きをしない。
- 洗い色の帯の文字は `--good-ink` / `--warn-ink`（濃い側）。`--good` をそのまま `--good-wash` に置くと 3.98:1。
- 顔料6色は**塗りの地にしない**（文字色が色ごとに変わる）。`pigment-N-wash` に敷いて文字は墨。

### 検査（色を触ったら必ず通す）

    python3 design_check.py <HTML>     # そのHTMLだけ
    python3 design_check.py            # DESIGN.md ＋ 全HTML
    python3 design_check.py --spec-only

コントラスト（大きい文字の例外込み）・純白純黒・ブレイクポイント・入力欄16px を一度に見る。
HTMLは書き換えない。指摘して返すだけ。

2026-09-09 時点の既往指摘は **345件／70本**（初回スキャンは444件／77本）。
深刻なところ（コントラスト3.0未満・純白のカード）は片付けた。残っているのは
コントラスト 3.0〜4.5 が277件、区切りが42件、入力欄16px未満が6件、
そして「意図が絡むので手で見る」ものが少し（`--ghost` / `:active` / 地が純白のアプリ）。
**新しく足した分を増やさないための関門**として使う。

もう1本、**役の違う検査**がある。`design_check.py` は「正本のルールを守れているか」、
`color_leak.py` は「**決めた色板から漏れていないか**」を見る。重ならないので両方通す。

    python3 color_leak.py <HTML>          # ✗色漏れ / △直書き / ・無彩色 に分けて出す
    python3 color_leak.py --all <HTML>    # 無彩色もぜんぶ並べる

`:root` と dark の上書きで宣言した変数を色板とみなし、`var()` を通さずに直に書かれた色を拾う。
グラデーションの途中・SVGの `fill`・JSの中の色文字列も見る（目では見落とすところ）。
**✗ が1件でもあると終了コード1。** 出どころは lieflat-charts の validate.mjs の考え方
（コードは写していない）→ `design_refs/lieflat.chart.md`。

### refero styles から写すとき
- `refero-styles` スキルを起動する → 提案の義務は A層 §5 P2、手順の正本は
  `~/.claude/skills/refero-styles/SKILL.md`。道具は `refero_tokens.py`、見本は `design_refs/`。
- 見本は **`design_refs/<名前>.design.md`（DESIGN.md 規格準拠）**。`npx @google/design.md lint` が通る形。
- スキル本体は git 管理外なので、直したら `python3 sync_skills.py --write` で `skills/` に控えを取る。

## 2.6 JSを書かずに済ませる部品（tn.css）と、動きの下ごしらえ（tn.js）
- 選択カード・チェック・つまみ・アコーディオン・ダイアログ・明細・メーター・進捗・チップ・タブ・表・押せる行は
  **`tn.css` に用意してある**。クラスは全部 `tn-` 始まりで、既存アプリのCSSとぶつからない。
  色は `--card/--ink/--sub/--line/--accent/--radius` をそのまま使う（無いアプリでも既定値で動く）。
- 注入は `python3 inject_tn.py <HTML>`（何度でも実行可・古い版は自動で最新に置換）。
  **`tn.css` と `tn.js` を1つのマーカーで一緒に入れる。** 確認 `--check`／取り外し `--remove`。
  見本は `_tn_見本.html`（このページ自体が注入の動作確認）。
- **`tn.js` は CSS で書けない2つだけを持つ**（ぶら下がる名前は `window.TN` の1つ）。
  - `TN.rnd(i,k)` … **決定論の擬似乱数。デモ・架空データで `Math.random()` を使わない**
    （`~/制作物` の HTML 48本がまだ使っている・2026-09-09 実測）。
    リロードのたびに形が変わると、お返事カードもIG投稿も毎回ちがう絵になり、
    「前と同じか」の見比べもできない。`rndIn/pick/shuffle` も同じ理屈で決定論。
  - `TN.reveal(id, fn)` … 見えたら再生・押したらもう一度。**再生前にタイマーを全部消す**
    ので、連打しても積み上がらない（5回押しても走っているのは1本・実測）。
    **画面に寸法が無いところ（Claude のブラウザペインは 0×0・スクショ用ヘッドレス・
    PDF書き出し・`display:none` の iframe）では IntersectionObserver が永久に発火しない。**
    そのまま焼くと図が白いままになるので、寸法が無いときだけ 1.2 秒後に描く保険が入っている。
- 出どころは lieflat-charts の**考え方だけ**（あちらは非商用ライセンスなのでコードは写していない）。
  `rnd` の式は本家をそのまま使うと k=0 で等差の直線になるため、別のかき混ぜに替えてある。
  調査 → `~/つみき出力/道具としらべ/lieflat-charts_調査と採用可否_2026-09-08.md`
- **戻るボタンと違い、外部配布(`~/tsumiki-tools`)に入れてもよい**（見た目だけで屋号も戻る導線も含まない）。
- 「どれか1つ選ぶ」を作るとき `classList.toggle('on')` を手書きしない → `.tn-choice` + `:has(:checked)`。
- 出どころは sashimi UI(MIT)の手法を書き直したもの。調査の記録は
  `~/つみき出力/道具としらべ/sashimi-ui調査_2026-09-08.html`。
- 必要ブラウザ: `:has()` Safari 15.4+ / `color-mix()` Safari 16.2+（未裏取り）。実機iPhoneでは未検証。

## 3. このリポジトリ固有の禁止
- `~/制作物` は PUBLIC。受託ソースは `.gitignore`（`Kouban/` `Teppari/`）、成果物HTMLだけ `~/tsumiki-tools` へ。サンプルは架空名。
  （commit前の実名grepと `--force` で消えない件は A層の核にある）
- 墨の流体シミュ（`~/tsumiki-portfolio/ink-fluid.js`・`.ink-fluid`）に触らない → A層の核にある。
- つみきロゴの公式SVG座標の在り処＝`~/制作物/index.html` ヘッダーの `<svg class="mark" viewBox="0 0 100 100">`（使い方は A層の核）。

## 4. お客様への「お返事カード」（1枚画像）
- ご質問・改善のご相談への返信に添える1枚画像は `python3 ~/制作物/make_reply_card.py <カード.json>`。
  型・数値・禁止事項の正本 → `~/ObsidianVault/Playbooks/reply-card-format.md`
- 画面は**架空データの複製**から撮る（せんや＝`senya-shots-src/`）。本番の画面を撮らない。

## 5. やり取りの出力の置き場 — **プロジェクトごとのフォルダに入れる**
- 出力（レポート・図・調査結果・単発HTML）は **`~/つみき出力/<プロジェクト>/`** に**日本語ファイル名**で置く。
  実体は iCloud の `Kodai/00_Tsumiki/11_やりとり出力`。つみきリモートの「⋯ → 制作物を見る」がここを映す。
- **置き場は自分で組み立てず、必ずこの道具に聞く**：

      python3 ~/制作物/tsumiki_out.py --list                いまあるプロジェクトを見る
      python3 ~/制作物/tsumiki_out.py <プロジェクト> <ファイル名>  置き先を1行で受け取る

  既にあるプロジェクトなら**そこに寄る**（大小・全半角・カタカナ/ひらがな・空白のゆれを吸う）。
  **初めてのプロジェクトならフォルダを自動で作る**（許可を求めない）。
- プロジェクト名は「お客様名・アプリ名・案件名」。日付はファイル名の末尾に付ける
  （`せんや/せんや_ご返信文_2026-09-04.txt`）。フォルダ名に日付を入れて増やさない。
- ⚠️ **直下に置かない。** 2026-09-04 に、直下が155個の横一列になって探せなくなり、
  20個のプロジェクトに仕分け直した（元に戻す台本＝`~/.tsumiki-remote/undo-やりとり出力-20260904.sh`）。

## 6. Codex連携 — 現場ガード
- **Codex は `~/制作物` 専用**で使う（別dirから使うと team config に登録が増殖するバグ）。
- agmsg は**必ず scripts 経由**：受信 `~/.agents/skills/agmsg/scripts/inbox.sh`、送信 `.../send.sh`。db/ や teams/ を直接読み書きしない。
- **`/codex:review` 等のCLIを回すときだけ Codexデスクトップアプリを閉じる**（トークン共有で認証衝突）。agmsg会話だけなら開いたままでOK。
- レビュー依頼は4点セット：①目的 ②変更ファイル＋各意図 ③テスト/動作確認の結果 ④未解決の懸念。
- → 詳細 `~/ObsidianVault/Knowledge/claude-codex-integration.md`
