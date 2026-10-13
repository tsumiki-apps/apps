# つみきロック（Mac の幕）

Mac の画面に全画面の幕をかけて、**中（Claude・tmux・つみきリモート）は動かしたまま**、
その場にいる人に画面を使わせないための常駐アプリ。

```
iPhone（つみきリモートの鍵ボタン）──▶ server.js（/api/lock/*）──▶ 127.0.0.1:8797 ──▶ 幕
                           Face ID（パスキー）で外す              掛ける／外す／状態／合言葉
Mac の前：Touch ID（指紋のボタンか Enter）か合言葉（数字4〜8桁）で外す
```

## 入っているもの
| もの | 場所 |
|---|---|
| アプリ | `~/Applications/TsumikiLock.app`（`./build.sh` で組み直し） |
| 常駐 | `~/Library/LaunchAgents/com.tsumiki.lock.plist`（KeepAlive・Aqua） |
| 掛け外しの鍵 | `~/.tsumiki-remote/lock-key`（0600・server.js と共有） |
| 幕の状態 | `~/.tsumiki-remote/lock-state.json`（落ちて起きたとき掛け直すため） |
| 合言葉 | 鍵束（キーチェーン）`com.tsumiki.lock` / `pin`。**値ではなく塩＋PBKDF2 だけ** |
| パスキー | `~/.tsumiki-remote/passkeys.json`（公開鍵だけ） |
| 記録 | `~/.tsumiki-remote/lock.log` |

組み直したら `launchctl kickstart -k gui/501/com.tsumiki.lock`。

## 守り
- 幕の高さはいちばん上（CGShieldingWindowLevel）。Touch ID の確認を出すあいだだけ 999 に下げ、確認の窓（coreautha・1000）を上に出す
- 掛かっているあいだは ⌘Tab・強制終了・Dock・メニュー・ログアウトを止める（presentationOptions）
- ほかのアプリが前に出たら（Touch ID の確認中でも）確認を打ち切って前に戻る。0.5秒ごとにも前に出し直す。
  Touch ID の確認は20秒で打ち切る
- 数字・⌫・Enter 以外のキーは捨てる。**Enter は「打っていれば決定、何も打っていなければ Touch ID」**
- 合言葉は最後まで打っても勝手には確かめない（丸は打った数だけ・最低4つ＝桁数を見せない）
- 合言葉を5回まちがえると 30秒→60秒→…（上限10分）待たせる。数えは状態ファイルに残る
- 鍵束は専用のキューでしか触らない（「許可しますか」で止まっても、幕と iPhone からの解除は動く）
- 幕には作業の題名を出さない（お客様の名前が入ることがある）。状態ごとの数だけ
- 127.0.0.1 の口は鍵（x-lock-key）を先に確かめ、本文は 0〜64KB だけ読む。5秒で切る
- 状態ファイルがあるのに読めないときは「掛かっている」として起きる
- 掛けるのは本人確認なし（すぐ閉められることを優先）。iPhone から外すのはパスキー必須
- 合言葉を決めないと掛けられない（Touch ID が通らないとき Mac の前で外せなくなるため）。
  つみきリモートの帯の鍵は、パスキーが未登録なら掛けずにシートを開く（↻ の押し間違いで外から外せなくなるのを防ぐ）
- 最初のパスキー登録と合言葉は Face ID なしで決められる（幕のアプリが動いていて、幕が外れているときだけ）。
  決め直しは登録済みのパスキーが要る。passkeys.json が壊れていたら何も通さない

## わかっている弱点
- **これは macOS のログインの鍵ではない。** 電源の長押しで再起動されれば幕は消える
  （再起動後は macOS のログイン画面が守る。そのあとログインすると幕が掛け直される）
- 強制終了などで幕のアプリを落とされると、launchd が起こし直すまで約2秒は素通しになる（未実測）
- ミッションコントロール・4本指・ホットコーナー・Siri・VoiceOver を全部は試していない。
  別のアプリが前に出れば戻す作りだが、前に出ない形で裏が見える道があれば防げない
- 前にいる人が合言葉をわざと間違えて待たせたり、Touch ID をわざと失敗させたりはできる（外から iPhone で外せる）
- 「パスキー必須」は正確には「パスキーと、その端末の本人確認（Face ID か端末のパスコード）」。
  iCloud キーチェーンで同期した自分の別の端末からも外せる
- つみきリモートの合言葉（?t=）を持っている人は席に何でも打てるので、パスキーは
  「その上にもう1枚」であって最後の砦ではない（認証器の証明は取っていない＝attestation:none）
- パスキーを iPhone から消したら、Mac で `~/.tsumiki-remote/passkeys.json` を消して登録し直す

## 試験のしかた（本番の状態・鍵束に触らない）
環境変数で置き場と口と鍵束の名前を変える。`TSUMIKI_LOCK_AUTOUNLOCK=秒` で勝手に外れる。
`/try`（キーを打たずにボタンと同じ道を通す）は鍵束の名前が本番以外のときだけ開く。
```
open -n --env TSUMIKI_LOCK_CONF=<別の置き場> --env TSUMIKI_LOCK_PORT=8798 \
  --env TSUMIKI_LOCK_KC=com.tsumiki.lock.test --env TSUMIKI_LOCK_AUTOUNLOCK=30 TsumikiLock.app
TsumikiLock --render out.png 1440 900    # 幕の見た目を画像に（架空の席）
```
⚠️ tmux の中から直接起動すると画面（WindowServer）の外になり、幕が出ない。`open` か launchd で起動する。
