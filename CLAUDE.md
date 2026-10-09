# 制作物（つみき）— AI作業ルール（B層・このリポジトリだけ）

つみきアプリ群の作業場。共通ルールはA層。長い説明は `docs/`（必要なときに開く）。

> **A層カナリア: A-20260831**
> この行の直前に「Kodai の共通ルール（A層）」の内容が見えていなければ、
> `~/.claude/CLAUDE.md` が読まれていない。**その場合は作業を止めて Kodai に伝える。**

## 1. 置き場は「外部に使わせるか？」で決める
- 外に少しでも見せる＝`~/tsumiki-tools`（tools.tsumiki-apps.com・戻るボタンなし）／自分専用＝ここ（apps・戻るボタンあり）／会社の顔＝`~/tsumiki-portfolio`。
- 仕事（Apple）の同僚向け＝`teamkit-tools.github.io`（屋号を出さない。`gh auth switch --user teamkit-tools`→**終わったら tsumiki-apps に戻す**）。
- tools 更新：ビルドあり＝`python3 deploy_tools.py <name>`／単一HTML＝`~/tsumiki-tools` を直接編集して push。引っ越したら TOOLS から撤去までワンセット。
- 有料アプリは**プロダクトキーゲートを注入**（`inject_license.py <HTML> <app名>`）。キー発行は Supabase の `license_issue()`。
- 正本 → `~/ObsidianVault/Decisions/2026-07-27-server-operation-model.md`

## 2. 注入
- 自分専用の新規アプリは `inject_backbtn.py`（戻るボタン＋apple-touch-icon）。**HTMLにベタ書きしない**（左端エッジスワイプのみ。見える「‹ つみき」は置かない）。外部配布には注入しない。
- UI部品（選択カード・つまみ・ダイアログ・タブ・表など）は `tn.css`、決定論の乱数 `TN.rnd` と見えたら再生 `TN.reveal` は `tn.js`。`python3 inject_tn.py <HTML>` で両方入る。デモで `Math.random()` を使わない。外部配布に入れてよい → 詳細 `docs/tn部品.md`

## 3. 見た目
- 正本は `DESIGN.md`（読むのはA層 §5 P1）。ダークの塗りボタンは `--accent` 地に `--ink` 文字、洗い色の帯は `--good-ink`/`--warn-ink`。
- 色を触ったら `python3 design_check.py <HTML>` と `python3 color_leak.py <HTML>` の両方を通す（✗1件で終了コード1）。
- refero から写すときは `refero-styles` スキル。スキルを直したら `python3 sync_skills.py --write`。→ 詳細 `docs/見た目の検査.md`

## 4. 固有の禁止・お返事カード
- 受託ソース `Kouban/` `Teppari/` は `.gitignore`。成果物のHTMLだけを `~/tsumiki-tools` へ。
- お返事カード（1枚画像）は `python3 make_reply_card.py <カード.json>`。正本 `~/ObsidianVault/Playbooks/reply-card-format.md`。画面は架空データの複製から撮る（せんや＝`senya-shots-src/`）。

## 5. 出力の置き場（正本＝`docs/置き場.md`）
- 出力は全部 `~/つみき出力/<セッションの名前>/<ファイル>`（実体は iCloud `Kodai/04_つみきリモート制作物`）。種類や版のフォルダを作らない。名前は日本語、日付や v2 を付けない。
- **置き場は自分で組み立てず `python3 tsumiki_out.py <ファイル名>` に聞く**（見せた後に作り直すなら `--new`）。`SendUserFile` はここに置いてから。
- 「保存版に移行して」と言われたら、行き先（種類で自動）・`<月>_<名前>` のフォルダ・`書類/画像/データ` に分けて移動 → 正本 `docs/置き場.md` の「保存版への移行」。言われない限り移さない。

## 6. Codex連携
**2026-10-10 から停止中**（本人の指示）。Codex には頼まず・agmsg も使わない。再開は `bash ~/.claude/backups/codex-off-20261010/restore.sh` のあとこの行を消す。
Codex は `~/制作物` 専用。agmsg は scripts の inbox.sh / send.sh 経由だけ。CLI を回すときだけデスクトップアプリを閉じる。→ `~/ObsidianVault/Knowledge/claude-codex-integration.md`

## 7. クラウドで開かれたら止まる
A層が見えない／`~/ObsidianVault` が無い＝claude.ai/code などのクラウド環境。代わりの手順を組まず「ここでは作業しない」と伝えて止まる。ブランチも push しない。→ `docs/クラウドセッション.md`
