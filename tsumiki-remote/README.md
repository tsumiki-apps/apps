# つみきリモート

Mac の tmux セッション（＝Claude Code などを走らせている画面）を、
iPhone から見て・指示を返せるようにする自作アプリ。

蓋は開けたまま、画面だけ消して Mac は動かし続ける。外出先からは Tailscale 経由で届く。

```
iPhone (PWA)  ──https──▶  Tailscale  ──▶  Mac:8787 (server.js)  ──▶  tmux  ──▶  Claude Code
```

## 中身

| ファイル | 役割 |
|---|---|
| `server.js` | 依存パッケージなしの小さなHTTPサーバー。tmux にコマンドを投げるだけ |
| `public/index.html` | スマホ用の画面（単一HTML・PWA）。1.5秒ごとに状態を取りに行く |
| `hooks/ntfy-notify.sh` | Claude Code の hook から ntfy.sh に「返答待ち／終わった」を通知 |
| `launchagents/*.plist` | ログイン時に ①サーバー ②caffeinate を自動起動 |

## 状態の見かた

| 表示 | 判定 |
|---|---|
| **作業中** | 画面に `esc to interrupt` やスピナーがある／直近5秒で画面が動いた |
| **返答待ち** | 画面に `Do you want` `❯ 1.` `(y/n)` などの選択肢が出ている |
| **待機** | 5秒以上なにも動いていない |

判定に使うのは「いま見えている画面」だけ。スクロールバックを混ぜると、
一度出た `Do you want…` が永遠に残って返答待ちに見えてしまう。

## セットアップ

### 1. 常駐（済）

```bash
launchctl list | grep tsumiki
```

`com.tsumiki.remote`（サーバー）と `com.tsumiki.awake`（caffeinate）が出れば動いている。

止めたいとき:

```bash
launchctl unload ~/Library/LaunchAgents/com.tsumiki.awake.plist
```

### 2. 画面だけ消す

- キーボード: **Control + Shift + 電源ボタン**（macOS標準）
- コマンド: `pmset displaysleepnow`

`caffeinate -ims` を常駐させてあるので、画面が消えても Mac は眠らない。
（`-d` を付けていないので「画面は消える」。付けると画面も点いたままになる）

### 3. Tailscale（外から繋ぐ）— sudo なしで動かす

公式の案内は `sudo brew services start tailscale` だが、それだと管理者権限が要る。
**userspace-networking モード**なら一般ユーザー権限のまま動く。

```bash
launchctl load ~/Library/LaunchAgents/com.tsumiki.tailscaled.plist
```

このモードでは OS のネットワーク層に入らない代わりに、
**外から入ってきた接続は localhost の同じポートへ転送される**。
今回欲しいのは「iPhone → Mac:8787」の向きだけなので、これで足りる。

CLI は毎回ソケットの指定が要る（普段の `tailscale` コマンドとは別物になる）:

```bash
alias ts='tailscale --socket=$HOME/.tsumiki-remote/tailscaled.sock'
ts status
ts ip -4
```

ログインは `ts up` が出す URL をブラウザで開いて認証する。

サーバーは `127.0.0.1` にしか口を開けていないので、Tailscale を通した以外の経路では
一切届かない（ルーターのポート開放も不要）。

`https://…ts.net/` の名前で開きたい場合だけ、管理画面で HTTPS を有効にしたうえで
`ts serve --bg 8787`。名前が要らなければ `http://<tailscale IP>:8787` で足りる。

### 4. iPhone 側

1. App Store で **Tailscale** を入れて同じアカウントでログイン、VPN を常時ONにする
2. `./bin/qr.sh` が出す QR を iPhone のカメラで読む（URL にトークンが入っている）
   - 一度開けば端末に保存され、URL からは自動的に消える
   - 手打ちするなら `http://<tailscale IP>:8787/?t=<トークン>`（`cat ~/.tsumiki-remote/token`）
   - **QRとURLはトークン入り。人に見せない・スクショを配らない**
3. 共有 → **ホーム画面に追加**。以後アイコンから全画面で起動する

### 5. 通知（ntfy）

1. App Store で **ntfy** を入れる
2. トピックを購読: `cat ~/.tsumiki-remote/ntfy-topic`
3. Claude Code が**こちらの返事で止まったとき**に通知が来る

鳴るのは `PermissionRequest`（許可待ち）と `Notification`（入力待ち）の2つだけ。
`Stop`（1ターンの応答完了）にも付けていたが、**返答のたびに鳴って実用にならない**ので外した。

送っているのは **イベント名と tmux のセッション名だけ**。
会話の中身・ファイル名・コマンドは外に出さない。

## セッションを閉じる

ヘッダーの **閉じる** ボタン。中で動いているものごと終了するので確認を挟む。
アプリを使わないなら次のどれでも同じ:

| 中身 | 閉じかた |
|---|---|
| Claude | `/exit` → シェルに戻る → `exit` |
| シェル | `exit` |
| Mac から | `tmux kill-session -t work2` |

閉じ忘れても害はない（待機中のセッションは何も消費しない）。Mac を再起動すれば全部消える。

## 注意

- ntfy.sh は外部サーバー。トピック名を知っている人は誰でも購読できるので、
  トピック名は共有しない（`~/.tsumiki-remote/ntfy-topic` は 600）。
- 蓋を開けたままの連続運用は、閉じた状態（クラムシェル）より排熱で有利。
  それでも長時間まわすときは電源接続で。
- このアプリは GitHub Pages では動かない（Mac 上のサーバーが要る）ので、
  `apps/index.html` には載せていない。
