# 動画同期（個人用）

人を撮った動画（A）と iPhone の画面録画（B）を、音で自動同期して 1080×1920 の縦動画にする。
Mac で処理し、iPhone から操作する。全部無料（ffmpeg・mlx-whisper・Tailscale）。

- 開く：iPhone で `https://<Macのtailnet名>:8443`（つみきリモートと同じ名前の :8443）（tailnet 限定）
- 常駐：`~/Library/LaunchAgents/com.tsumiki.douga-sync.plist`（127.0.0.1:8790）
- 作業の置き場：`~/Movies/動画同期/<番号>/`（元の動画・確認用・完成.mp4）
- 学習：`~/Movies/動画同期/学習/修正ログ.jsonl` と `覚えた言葉.json`
  - 書き出すとき、AI の字幕と直した字幕の違いを自動で記録
  - 次の文字起こしで、直した言葉を Whisper に先に渡し（initial_prompt）、同じ聞き間違いは置き換える
  - 画面の「覚えた言葉」から忘れさせられる

## 手順
1. タイトル → 2. 動画2本 → 3. 自動同期（±で手直し）→ 4. 文字起こし → 5. 字幕の確認・修正 → 6. 書き出し → 写真に保存

## 入れ直し
```
python3 -m venv .venv && .venv/bin/pip install mlx-whisper numpy scipy pillow
brew install ffmpeg
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tsumiki.douga-sync.plist
tailscale --socket ~/.tsumiki-remote/tailscaled.sock serve --bg --https=8443 http://127.0.0.1:8790
```
テスト用は `DSYNC_ROOT=<別の場所> DSYNC_PORT=8791 .venv/bin/python server.py`。
