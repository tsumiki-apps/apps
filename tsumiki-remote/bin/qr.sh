#!/bin/sh
# iPhone で読み取るためのQRを出す。
# URL にトークンを含めるので、人に見せない・スクショを配らないこと。
#
#   ./bin/qr.sh            ターミナルにQRを表示
#   ./bin/qr.sh png        ~/.tsumiki-remote/qr.png に保存

set -eu

SOCK="$HOME/.tsumiki-remote/tailscaled.sock"
TOKEN=$(tr -d ' \n' < "$HOME/.tsumiki-remote/token")
PORT="${TSUMIKI_REMOTE_PORT:-8787}"

# tailscale serve を張っていればその URL、無ければ tailscale IP に直接。
# serve status の1行目は短縮名なので、FQDN（*.ts.net）の行を拾う。
BASE=$(/opt/homebrew/bin/tailscale --socket="$SOCK" serve status 2>/dev/null \
  | grep -oE '^https?://[A-Za-z0-9.-]+\.ts\.net' | head -1 || true)
IP_TS=$(/opt/homebrew/bin/tailscale --socket="$SOCK" ip -4 2>/dev/null | head -1 || true)

if [ -n "$BASE" ]; then
  URL="$BASE/?t=$TOKEN"
elif [ -n "$IP_TS" ]; then
  URL="http://$IP_TS:$PORT/?t=$TOKEN"
else
  echo "Tailscale にまだログインしていません" >&2
  exit 1
fi

echo "$URL"
if [ "${1:-}" = "png" ]; then
  /opt/homebrew/bin/qrencode -o "$HOME/.tsumiki-remote/qr.png" -s 8 -m 2 "$URL"
  echo "saved: $HOME/.tsumiki-remote/qr.png"
else
  /opt/homebrew/bin/qrencode -t ANSIUTF8 "$URL"
fi
