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

### 3. Tailscale（外から繋ぐ）

```bash
sudo brew services start tailscale
tailscale up
```

`tailscale up` が出す URL でログイン（アカウント作成もここ）。そのあと:

```bash
tailscale serve --bg 8787
tailscale serve status
```

`https://<マシン名>.<テイルネット名>.ts.net/` が出る。これが外から届くURL。

サーバーは `127.0.0.1` にしか口を開けていないので、Tailscale を通した以外の経路では
一切届かない（ルーターのポート開放も不要）。

### 4. iPhone 側

1. App Store で **Tailscale** を入れて同じアカウントでログイン、VPN を常時ONにする
2. Safari で `https://<マシン名>.<テイルネット名>.ts.net/?t=<トークン>` を開く
   - トークン: `cat ~/.tsumiki-remote/token`
   - 一度開けば端末に保存され、URLからは消える
3. 共有 → **ホーム画面に追加**。以後アイコンから全画面で起動する

### 5. 通知（ntfy）

1. App Store で **ntfy** を入れる
2. トピックを購読: `cat ~/.tsumiki-remote/ntfy-topic`
3. Claude Code が許可を求めた／作業を終えたときに通知が来る

送っているのは **イベント名と tmux のセッション名だけ**。
会話の中身・ファイル名・コマンドは外に出さない。

## 注意

- ntfy.sh は外部サーバー。トピック名を知っている人は誰でも購読できるので、
  トピック名は共有しない（`~/.tsumiki-remote/ntfy-topic` は 600）。
- 蓋を開けたままの連続運用は、閉じた状態（クラムシェル）より排熱で有利。
  それでも長時間まわすときは電源接続で。
- このアプリは GitHub Pages では動かない（Mac 上のサーバーが要る）ので、
  `apps/index.html` には載せていない。
