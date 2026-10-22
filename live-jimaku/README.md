# ライブ字幕（個人用）

YouTube の生配信（配信者が字幕を出していないものでも）の声を、Mac で文字にして大きな文字で流す。
横動画字幕（`../yoko-jimaku`）と同じ作り。全部この Mac の中で動く（無料：yt-dlp・ffmpeg・mlx-whisper・Tailscale）。

- 開く：Mac は `http://127.0.0.1:8798`／iPhone は `https://<Macのtailnet名>:8445`（tailnet 限定）
- 常駐：`~/Library/LaunchAgents/com.tsumiki.live-jimaku.plist`（127.0.0.1:8798）
- Python：動画同期の `.venv` をそのまま使う（`../douga-sync/.venv/bin/python`）・モデルは whisper-large-v3-turbo
- 記録：`~/Movies/ライブ字幕/<日付 時刻> <題名>.txt`（画面の保存ボタンでも取れる）
- 覚えた言葉：動画同期・横動画字幕と同じ `~/Movies/動画同期/学習/` の置き換えが効く

## 使いかた
1. 「Chrome」で今見ているタブの URL を入れる（または貼る）→「始める」
2. 数秒〜十数秒遅れて字幕が出る。薄い字は「仮」（話している途中）、確定すると濃くなる
3. A− / A+ で文字の大きさ（覚えておく）。上に戻って読むと自動で追わなくなり、「最新」で戻る

## しくみ
yt-dlp（音）→ ffmpeg（16kHz・1ch）→ 静かな所（0.6秒）か最長12秒で区切って Whisper。
区切る前も1.5秒ごとに仮の字幕を出す。Whisper のくり返し（同じ言葉が何十回も出る癖）は1回にまとめ、
音の長さに対して字が多すぎる分は切る。無音の決まり文句（「ご視聴ありがとうございました」など）は捨てる。

## 入れ直し
```
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tsumiki.live-jimaku.plist
tailscale --socket ~/.tsumiki-remote/tailscaled.sock serve --bg --https=8445 http://127.0.0.1:8798
```
plist の `LJ_HOSTS` に tailnet の名前を入れる（リポジトリには書かない）。
テスト用は `LJ_ROOT=<別の場所> LJ_PORT=8799 ../douga-sync/.venv/bin/python "$PWD/server.py"`。
