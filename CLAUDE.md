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

## 3. このリポジトリ固有の禁止
- `~/制作物` は PUBLIC。受託ソースは `.gitignore`（`Kouban/` `Teppari/`）、成果物HTMLだけ `~/tsumiki-tools` へ。サンプルは架空名。
  （commit前の実名grepと `--force` で消えない件は A層の核にある）
- 墨の流体シミュ（`~/tsumiki-portfolio/ink-fluid.js`・`.ink-fluid`）に触らない → A層の核にある。
- つみきロゴの公式SVG座標の在り処＝`~/制作物/index.html` ヘッダーの `<svg class="mark" viewBox="0 0 100 100">`（使い方は A層の核）。

## 4. やり取りの出力の置き場
- 出力したもの（レポート・図・調査結果・単発HTML）は `~/つみき出力/` に**日本語ファイル名**で置く。
  実体は iCloud Drive の `Kodai/00_Tsumiki/11_やりとり出力`。つみきリモートの「⋯ → 制作物を見る」がここを映すので、
  外出先のスマホからその場でプレビューできる。
  （**同期的に読むと固まる**件は A層の核にある）

## 5. Codex連携 — 現場ガード
- **Codex は `~/制作物` 専用**で使う（別dirから使うと team config に登録が増殖するバグ）。
- agmsg は**必ず scripts 経由**：受信 `~/.agents/skills/agmsg/scripts/inbox.sh`、送信 `.../send.sh`。db/ や teams/ を直接読み書きしない。
- **`/codex:review` 等のCLIを回すときだけ Codexデスクトップアプリを閉じる**（トークン共有で認証衝突）。agmsg会話だけなら開いたままでOK。
- レビュー依頼は4点セット：①目的 ②変更ファイル＋各意図 ③テスト/動作確認の結果 ④未解決の懸念。
- → 詳細 `~/ObsidianVault/Knowledge/claude-codex-integration.md`
