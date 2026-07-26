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
   → 詳細 `Preferences/deploy-workflow.md`
   **⚠️ 置き場は「外部に使わせるか？」で決める（3系統）**：
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
- 専門用語は「用語（＝かんたんに言うと◯◯）」の形でやさしい解説をセットで。
- 完了報告は ①何を変更 ②どう変更 ③どう動作したか を簡潔な箇条書きで。失敗・スキップは正直に。

> このファイルは**要約**。ルールが変わったら正本（`mistakes.md`）を直し、ここは追従させる。
> 二重管理を避けるため、ここには詳細を書かず Vault へリンクする。
