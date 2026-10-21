# 動画同期（個人用）

人を撮った動画（A）と iPhone の画面録画（B）を、音で自動同期して 1080×1920 の縦動画にする。
Mac で処理し、iPhone から操作する。全部無料（ffmpeg・mlx-whisper・BudouX・fugashi・Tailscale）。

- 開く：iPhone で `https://<Macのtailnet名>:8443`（つみきリモートと同じ名前の :8443）（tailnet 限定）
- 常駐：`~/Library/LaunchAgents/com.tsumiki.douga-sync.plist`（127.0.0.1:8790）
- 作業の置き場：`~/Movies/動画同期/<番号>/`（元の動画・確認用・完成.mp4）
- 学習：`~/Movies/動画同期/学習/修正ログ.jsonl` と `覚えた言葉.json`
  - 書き出すとき、AI の字幕と直した字幕の違いを自動で記録
  - 次の文字起こしで、直した言葉を Whisper に先に渡し（initial_prompt）、同じ聞き間違いは置き換える
  - 画面の「覚えた言葉」から忘れさせられる

## 手順
1. タイトル → 2. 動画2本 → 3. 自動同期（±で手直し）→ 4. 文字起こし → 5. 字幕の確認・修正・早送り → 6. 書き出し → ダウンロード

- 早送り：確認の動画で「ここから」「ここまで」を押した区間を 2×/4×/8× で流す。区間は音なし・字幕なし（半分以上が区間に入る字幕は出さない）
- 撮り始めの撮影者の声（「よーい」「はい、ではお願いします」など）：job.json の `head_cut`（本編の頭から落とす秒数）。完成（冒頭つき）を作るときだけ切り、`本編.mp4` は切らずに残す。A を差し替えると消える。頭を切った作業は音の立ち上げを0.12秒に（第一声を弱めない）
- 字幕の改行：言葉の切れ目（BudouX の文節＋fugashi の形態素）だけで折る。検査は `.venv/bin/python test_wrap.py [job.json]`
- サムネイル：書き出しと一緒に作る（画面録画の1コマ）。横長（16:9）と縦長（9:16＝1080×1920）の2枚。縦長は完成動画の冒頭に3.5秒出し、0.6秒かけて本編へ切り替える（本編だけの動画は `本編.mp4`。色を変えると冒頭も入れ直す）。公式の写真などに替えるときは作業フォルダに画像を置き、job.json の `thumb_image`（`file`・`focus`・`box`・`island`・`card`・`upper`＝写真が画面の上だけのとき、端末は本物の縦横比で描き、写真が終わる所より上で縁が切る。写真が画面の半分より短いと、端末の半分を見せる下限で足した単色が見える）に書く。書き出し直しや「色を変える」でもその画像のまま。試すだけなら `thumbnail.py` の `--image` `--box` `--no-island` `--card` `--upper`

## 入れ直し
```
python3 -m venv .venv && .venv/bin/pip install mlx-whisper numpy scipy pillow budoux 'fugashi[unidic-lite]'
brew install ffmpeg
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tsumiki.douga-sync.plist
tailscale --socket ~/.tsumiki-remote/tailscaled.sock serve --bg --https=8443 http://127.0.0.1:8790
```
テスト用は `DSYNC_ROOT=<別の場所> DSYNC_PORT=8791 .venv/bin/python server.py`。
