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
- `refero-styles` スキルを起動する → 提案の義務は A層 §5 P2、手順の正本は
  `~/.claude/skills/refero-styles/SKILL.md`。道具は `refero_tokens.py`、見本は `design_refs/`。
- スキル本体は git 管理外なので、直したら `python3 sync_skills.py --write` で `skills/` に控えを取る。

## 3. このリポジトリ固有の禁止
- `~/制作物` は PUBLIC。受託ソースは `.gitignore`（`Kouban/` `Teppari/`）、成果物HTMLだけ `~/tsumiki-tools` へ。サンプルは架空名。
  （commit前の実名grepと `--force` で消えない件は A層の核にある）
- 墨の流体シミュ（`~/tsumiki-portfolio/ink-fluid.js`・`.ink-fluid`）に触らない → A層の核にある。
- つみきロゴの公式SVG座標の在り処＝`~/制作物/index.html` ヘッダーの `<svg class="mark" viewBox="0 0 100 100">`（使い方は A層の核）。

### 3.1 headcount プラグイン（project スコープ・ここだけ）
- 入れているのは `product@headcount` の1部署だけ（毎セッション約1,445トークン）。撤収は `claude plugin uninstall product@headcount --scope project`。
- **`product:ux-product-auditor` は「本番を監査しろ・ステージングを監査するな」と書いてある**
  （`SKILL.md` の Never 節「Audit a staging build ... that real users never touch」）。
  **A層 P0 と反する。従わない。** ソースを読むのは可。ただし**動かして確かめる対象は必ず `_テスト` の複製＋架空データ**で、
  本番アプリをブラウザで開いて操作・撮影しない（ボタン押下・input発火は save()→クラウド push を呼ぶ）。
- 配色・角丸・影を決めるのは `refero-styles`。`product:design-styles` は使わない（2.5節のとおり）。
- スライドは `consulting-pptx-skill`。`product:presentation-design` は使わない。
- 不具合の原因を詰めるのは `~/制作物/.claude/skills/genin-shoumei`（日本語で発動する自前スキル）。

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
