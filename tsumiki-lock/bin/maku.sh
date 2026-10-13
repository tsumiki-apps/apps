#!/bin/bash
# Claude が画面を使う作業のあいだだけ幕を外し、終わったら元に戻す（本人の許可 2026-10-13）。
#   maku.sh status   … 掛かっているか（locked / unlocked）
#   maku.sh off      … 掛かっていたら外し、「Claude が外した」印を残す。外れていれば何もしない
#   maku.sh restore  … 印があるときだけ掛け直して印を消す（本人が自分で外していた分は掛けない）
# ⚠️ off したら、作業の成否にかかわらず必ず restore まで行う。
set -euo pipefail
CONF="${TSUMIKI_LOCK_CONF:-$HOME/.tsumiki-remote}"
KEY="$(cat "$CONF/lock-key")"
MARK="$CONF/lock-paused-by-claude"
U="http://127.0.0.1:${TSUMIKI_LOCK_PORT:-8797}"
locked() { curl -s -m 3 -H "x-lock-key: $KEY" "$U/status" | python3 -c 'import sys,json;print("locked" if json.load(sys.stdin).get("locked") else "unlocked")'; }
case "${1:-status}" in
  status) locked ;;
  off)
    if [ "$(locked)" = locked ]; then
      date +%s > "$MARK"
      curl -s -m 3 -X POST -H "x-lock-key: $KEY" -d '{"by":"Claude（画面の作業）"}' "$U/unlock" >/dev/null
      echo "外した（あとで restore）"
    else
      echo "もともと外れている（restore しても掛けない）"
    fi ;;
  restore)
    if [ -f "$MARK" ]; then
      curl -s -m 3 -X POST -H "x-lock-key: $KEY" -d '{"by":"Claude（作業が終わった）"}' "$U/lock" >/dev/null
      rm -f "$MARK"
      echo "掛け直した：$(locked)"
    else
      echo "印なし＝Claude は外していない（何もしない）"
    fi ;;
  *) echo "usage: maku.sh status|off|restore" >&2; exit 2 ;;
esac
