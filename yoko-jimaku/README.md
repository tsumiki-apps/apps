# 横動画字幕（個人用）

16:9 の横動画1本に、タイトルと自動字幕（日本語＋英語）を入れて 1920×1080 で書き出す。
動画同期（`../douga-sync`）と同じ作り。Mac で処理し、iPhone から操作する。全部無料（ffmpeg・mlx-whisper・BudouX・fugashi・Tailscale）。

- 開く：iPhone で `https://<Macのtailnet名>:8444`（tailnet 限定）
- 常駐：`~/Library/LaunchAgents/com.tsumiki.yoko-jimaku.plist`（127.0.0.1:8792）
- Python：動画同期の `.venv` をそのまま使う（`../douga-sync/.venv/bin/python`）
- 作業の置き場：`~/Movies/横動画字幕/<番号>/`（元の動画・確認用・完成.mp4）
- 学習：動画同期と同じ `~/Movies/動画同期/学習/`（どちらで直した言葉も両方に効く）

## 手順
1. タイトル → 2. 動画（選ぶと自動で文字起こし・見直し・英訳まで進む）→ 4. 字幕の確認・修正・早送り → 5. 書き出し → ダウンロード

- 形：動画を画面いっぱいに敷き、上にタイトル、下に日英の字幕を白い札で重ねる
- 16:9 でない動画（縦・4:3）は縮めて真ん中に置き、余りは黒い帯（切らない）
- 字幕の1行は約20字（横に長く伸ばさない）。1枚は2行まで。折る所は動画同期と同じ（言葉の切れ目だけ）
- 早送り・音量そろえ（-16 LUFS）・見直し（Claude）・英訳・覚えた言葉は動画同期と同じ
- 検査：`../douga-sync/.venv/bin/python test_wrap.py [job.json]`

## 入れ直し
```
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tsumiki.yoko-jimaku.plist
tailscale --socket ~/.tsumiki-remote/tailscaled.sock serve --bg --https=8444 http://127.0.0.1:8792
```
テスト用は `YJ_ROOT=<別の場所> YJ_LEARN=<別の場所> YJ_PORT=8793 ../douga-sync/.venv/bin/python server.py`。
