# 制作物（つみき）— AI作業ルール

ここは Kodai の「つみき」アプリ群（単一HTMLアプリ＋一部 Supabase 同期）の作業ディレクトリ。
**ルールの正本は Obsidian Vault**（`/Users/ko_dai/ObsidianVault/`）。このファイルは、
作業の現場で**事故が大きいルールだけ**を手元に置く要約。詳細・最新は必ず Vault を見る。

## セッション開始時に読む（正本）
- `~/ObsidianVault/Home.md` — 目次（全ノートへのリンク）
- `~/ObsidianVault/Knowledge/mistakes.md` — **行動ルールの唯一の正本**
- `~/ObsidianVault/Preferences/` — 人物像・好み・制作プロセス
- `~/ObsidianVault/Daily/` 直近 — 中断からの復帰（現在地・次の一手）

## ⚠️ 危険ルール（破ると被害が大きい・要約）

1. **動作確認で実データに書き込まない**（過去2回やらかし）。
   localStorage / Supabase 同期のあるアプリ（credit / recap / 各 *-app）で、
   実画面のボタン押下・入力イベント発火・フォーム送信は `save()`→クラウド push を
   トリガーし**本物のデータを上書きする**。検証は純粋関数の再現か複製データで。
   実画面は**読み取りのみ**。→ 詳細 `mistakes.md`(2026-06-09/06-10), `Preferences/app-verification.md`

2. **公開 = GitHub Pages を一気通貫**。「公開しますか？」と**許可を求めない**。
   動作確認 → 戻るボタン/アイコン注入 → `index.html` 追加 → commit & push まで完結し、
   **最後にまとめて報告＋公開URLを必ず貼る**。例外はユーザーが「まだ公開しないで」と明示した時のみ。
   **push は `git push` ではなく `~/制作物/push_pages.sh` を使う**（＝公開完了まで見届ける）。
   GitHub Pages は同時に1つしか公開できず、続けて push すると後発の deploy が 400 で落ちる。
   それが最後の push だと**サイトが古いまま止まる**（2026-08-11 実発生）。スクリプトが自動で再実行する。
   → 詳細 `Preferences/deploy-workflow.md`
   **⚠️ 置き場は「外部に使わせるか？」で決める（4系統）**：
   - **仕事（Apple）で同僚に使わせる → 別アカウント `teamkit-tools`＝teamkit-tools.github.io**
     （2026-08-04追加。仕事用URLに屋号「つみき」を出さないため。`gh auth switch --user teamkit-tools`
     で切り替え、**終わったら tsumiki-apps に戻す**。第1号＝Mentor Check）
   - **外部向け（無料公開も有料も全部）→ `~/tsumiki-tools`＝tools.tsumiki-apps.com**（戻るボタン非注入）。
   - **自分専用 → ここ（apps）＝tsumiki-apps.github.io/apps/**（戻るボタン注入）。
   - **root tsumiki-apps.com は会社の顔＝ポートフォリオ**（`~/tsumiki-portfolio`・墨シミュ・今回は現状維持）。
   迷ったら：少しでも外部に見せる/渡す/使わせる＝tools。
   tools 更新は2通り：ビルドあり＝`python3 deploy_tools.py <name>`／**ビルド不要の単一HTML＝
   `~/tsumiki-tools` を直接編集して push**（制作物側に開発ソースを持たない）。
   引っ越したら TOOLS からの撤去までワンセット（残すと本体を案内ページで上書きする事故）。
   有料で渡すアプリは**プロダクトキーゲートを注入**（`inject_license.py <HTML> <app名>` または
   TOOLS エントリに `license:`）。キー発行は Supabase の `license_issue()`（Claudeに頼めばよい）。
   → 詳細 `Decisions/2026-07-27-server-operation-model.md`（振り分けの正本）,
   `Decisions/2026-07-23-tools-distribution-repo.md`, `Decisions/2026-07-23-license-key-system.md`

3. **新規アプリには `~/制作物/inject_backbtn.py` を実行**して戻るボタンを注入する。
   **HTMLにベタ書きしない**（常時表示の `<a href="index.html">`・フッターリンク等は禁止）。
   正しい仕様＝左端エッジスワイプのみで戻る。見える「‹ つみき」ボタンは置かない。
   apple-touch-icon も毎回注入。→ 詳細 `mistakes.md`(2026-06-03/06-07)

4. **モバイル幅375pxで動作確認**（ユーザーは主にiPhone）。横はみ出し・ラベル縦折れ・
   タップ領域、数値入力は font-size 16px 以上（iOS自動ズーム防止）、新要素のサイズ/余白/
   角丸が既存と統一されているか。→ 詳細 `Preferences/app-verification.md`

5. **tsumiki-apps.com の墨の流体シミュレーションには、指示がない限り触らない**。
   対象＝`~/tsumiki-portfolio/ink-fluid.js` と `style.css` の `.ink-fluid` 周り。
   他の改修のついでに数値・挙動を変えない。必要と思っても**まず提案して指示を仰ぐ**。
   理由＝体感頼りで詰めた領域なうえ、**ブラウザペインはrAFが止まり検証できない**（壊しても気づけない）。
   → 詳細 `Knowledge/mistakes.md`（P0・2026-07-21）

## Codex連携（agmsg / レビュー）— 現場ガード
- **Codex は `~/制作物` 専用**で使う（別dirから使うと team config に登録が増殖するバグ）。
- agmsg は**必ず scripts 経由**：受信 `~/.agents/skills/agmsg/scripts/inbox.sh`、送信 `.../send.sh`。
  **db/ や teams/ を直接読み書きしない**。
- **`/codex:review` 等のCLIを回すときだけ Codexデスクトップアプリを閉じる**（ChatGPTトークン共有で認証衝突）。agmsg会話だけならアプリは開いたままでOK。
- **レビュー依頼は4点セット**で渡すと精度が上がる：①目的 ②変更ファイル＋各意図 ③テスト/動作確認の結果 ④未解決の懸念。
  → 詳細・最新は `~/ObsidianVault/Knowledge/claude-codex-integration.md`、運用方針は `Decisions/2026-06-17-claude-codex-env-operation.md`。

## 説明・報告のしかた
- **選ばせたいときは選択UI（AskUserQuestion）を使わない。本文に番号つきで選択肢を出し、チャット欄に数字で返してもらう**
  （Kodai は外出先から**つみきリモート**で見ており、あのパネルはタップも確定もできない）。
  原則1問ずつ・選択肢3〜4個・最後の番号に「ほかの案」。→ 詳細 `Preferences/ask-question-format.md`
- 専門用語は「用語（＝かんたんに言うと◯◯）」の形でやさしい解説をセットで。
- 完了報告は ①何を変更 ②どう変更 ③どう動作したか を簡潔な箇条書きで。失敗・スキップは正直に。

6. **ここは PUBLIC リポジトリ**（`tsumiki-apps/apps`）。**受託案件のソースとお客様の実データを置かない**。
   2026-08-03、受託ソースごと実在キャスト24名の氏名・NG日が公開されていた。実名は `App.tsx` や
   `initial-data.json`・CHANGELOG・テストにまで散るので、後からデータファイルだけ消しても足りない。
   受託ソースは `.gitignore`（`Kouban/` `Teppari/`）、成果物HTMLだけ `~/tsumiki-tools` へ。サンプルは架空名。
   **⚠️ `git push --force` では GitHub から消えない**（40桁SHAを直打ちすれば読める。短縮SHAは404を返すので誤判定する）。
   完全消去＝「リポジトリ削除→同名で作り直し」か「Support に gc 依頼」の2択。
   → 詳細 `Decisions/2026-08-03-public-repo-hygiene.md`

7. **やり取りの中で出力したものは `~/つみき出力/` に置く**（実体は iCloud Drive の
   `Kodai/00_Tsumiki/11_やりとり出力`。2026-08-14 に iCloud 直下の `つみきリモート` から移設。
   つみきリモートの一覧は親の `00_Tsumiki` 全体を映す）。レポート・図・調査結果・単発のHTMLなど、
   **リポジトリに入れるものではないが後で見返したい成果物**が対象。
   理由＝Kodai は外出先のスマホから作業を見ている。つみきリモートの「⋯ → 制作物を見る」が
   このフォルダを映しているので、置いておけば**その場でプレビューできる**。
   iCloud 経由でファイルアプリからも開ける。ファイル名は日本語で内容がわかるものにする。
   ⚠️ このフォルダを**プログラムから同期的に読まない**（`readdirSync` 等）。
   iCloud は数分返らないことがあり、常駐サーバーが丸ごと止まる。→ 2026-08-11 実際に止めた

> このファイルは**要約**。ルールが変わったら正本（`mistakes.md`）を直し、ここは追従させる。
> 二重管理を避けるため、ここには詳細を書かず Vault へリンクする。
