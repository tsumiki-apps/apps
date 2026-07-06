# extract-shift（シフトのスクショ→セッション自動抽出）

recap.html の「Floor」タブで、シフト表のスクショから勤務セッションを自動抽出するための Edge Function。

## 概要
- 入力: `{ imageBase64 }`（データURL可）
- 出力: `{ room, shiftHours, items:[ {time,hours,zone,role,tag} | {break:true,time} ] }`
- LLM: Google Gemini Vision `gemini-2.5-flash`（無料枠）
- Secret: `GEMINI_API_KEY` を利用（`generate-recap-email` と共有。**新規登録は不要**）

## デプロイ済み
- プロジェクト: `okbjqtdirrathscctyvx`
- 関数名: `extract-shift`（verify_jwt: true。クライアントは anon キーを Bearer 送信）
- 更新するときは Supabase ダッシュボード → Edge Functions → `extract-shift` に `index.ts` を貼り替えて Deploy。

## 補足
- CORS は `*`。GitHub Pages から直接呼べる。
- 精度対策: 抽出結果は recap.html 側で**プレビュー編集**してから確定するため、多少の誤読はその場で直せる。
- モデル変更が必要なら `index.ts` の `model` を `gemini-flash-latest` などに変更して再デプロイ。
