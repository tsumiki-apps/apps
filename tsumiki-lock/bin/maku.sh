#!/bin/bash
# Claude が画面を使う作業のあいだだけ幕を外し、終わったら元に戻す（本人の許可 2026-10-13）。
#   maku.sh status          … locked / unlocked / error（error は終了コード1）
#   maku.sh run <コマンド…> … 掛かっていれば外してコマンドを動かし、終わったら（失敗しても）戻す。これを使う
#   maku.sh off / restore   … 手で分けて使うとき。off したら必ず restore まで行う
#   maku.sh pass <秒>       … 幕は掛けたまま、その秒数だけメモ（純正）を幕の下で前に出してよくする（0 で終える・最長300）
#                             純正メモにチェックリストを作るとき（~/memo-checklist）用。画面は見えないまま
#
# 戻すのは次の全部がそろったときだけ（本人の上に幕を落とさない・反証役）：
#   ① 自分が外した印がある ② 今も外れている ③ 最後の掛け外しが自分の「外した」のまま
#      （そのあと本人が掛けた・外したなら触らない） ④ 印が2時間より新しい
# 重なったとき（別のセッションも off していた）は、最後の1人が restore したときに掛ける。
set -uo pipefail
CONF="${TSUMIKI_LOCK_CONF:-$HOME/.tsumiki-remote}"
KEYF="$CONF/lock-key"
LOG="${TSUMIKI_LOCK_LOG:-$CONF/lock.log}"
MARK="$CONF/lock-paused-by-claude"
U="http://127.0.0.1:${TSUMIKI_LOCK_PORT:-8797}"
BY_OFF="Claude（画面の作業）"
MAX_AGE=7200

# 鍵は引数に載せない（ps で見えるため）。ヘッダーをファイルから読ませる
hdr() { printf 'x-lock-key: %s\n' "$(cat "$KEYF")"; }
call() {  # call METHOD PATH [BODY] → 本文を出し、HTTP の番号を $CODE に
  local out
  out=$(curl -s -m 5 -w '\n%{http_code}' -X "$1" -H @<(hdr) ${3:+-d "$3"} "$U$2" 2>/dev/null) || out=$'\n000'
  CODE="${out##*$'\n'}"; BODY="${out%$'\n'*}"
}
state() {
  [ -r "$KEYF" ] || { echo error; return; }
  call GET /status
  [ "$CODE" = 200 ] || { echo error; return; }
  printf '%s' "$BODY" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print("locked" if d["locked"] is True else "unlocked" if d["locked"] is False else "error")
except Exception: print("error")'
}
# 最後の「ロック（…）」か「解除（…）」の行
last_event() { grep -E ' (ロック|解除)（' "$LOG" 2>/dev/null | tail -1 | sed -E 's/^[^ ]+ //'; }

off() {
  local s; s=$(state)
  case "$s" in
    error) echo "幕の状態が読めません（外していない）" >&2; return 1 ;;
    unlocked)
      # 印が残っていて、最後の出来事が自分の「外した」なら＝別のセッションが外している最中。相乗りする
      if [ -f "$MARK" ] && [ "$(last_event)" = "解除（${BY_OFF}）" ]; then
        echo "$$" >> "$MARK"; echo "ほかの作業が外している最中（相乗り・あとで restore）"; return 0
      fi
      rm -f "$MARK"   # 古い印は捨てる（本人が外していた分を、あとで掛けないため）
      echo "もともと外れている（restore しても掛けない）"; return 0 ;;
    locked)
      call POST /unlock "{\"by\":\"$BY_OFF\"}"
      if [ "$CODE" != 200 ] || [ "$(state)" != unlocked ]; then
        echo "外せませんでした（${CODE}）" >&2; return 1
      fi
      { date +%s; echo "$$"; } > "$MARK"
      echo "外した（あとで restore）" ;;
  esac
}

restore() {
  [ -f "$MARK" ] || { echo "印なし＝Claude は外していない（何もしない）"; return 0; }
  # 重なっていたら自分の分だけ降りる（最後の1人が掛ける）
  local holders; holders=$(($(wc -l < "$MARK") - 1))
  if [ "$holders" -gt 1 ]; then
    sed -i '' '$d' "$MARK"; echo "ほかの作業がまだ外している（掛けない）"; return 0
  fi
  local born; born=$(head -1 "$MARK")
  local s; s=$(state)
  if [ "$s" = error ]; then echo "幕の状態が読めません（印は残す）" >&2; return 1; fi
  if [ "$s" = locked ]; then rm -f "$MARK"; echo "もう掛かっている（何もしない）"; return 0; fi
  if [ "$(last_event)" != "解除（${BY_OFF}）" ]; then
    rm -f "$MARK"; echo "外したあとに本人が掛け外しした（掛けない）"; return 0
  fi
  if [ $(( $(date +%s) - born )) -gt $MAX_AGE ]; then
    rm -f "$MARK"; echo "印が古すぎる（2時間超・掛けない）"; return 0
  fi
  call POST /lock '{"by":"Claude（作業が終わった）"}'
  if [ "$CODE" = 200 ] && [ "$(state)" = locked ]; then
    rm -f "$MARK"; echo "掛け直した"
  else
    echo "掛け直せませんでした（${CODE}・印は残す）" >&2; return 1
  fi
}

case "${1:-status}" in
  status) s=$(state); echo "$s"; [ "$s" != error ] ;;
  off) off ;;
  restore) restore ;;
  run)
    shift
    [ $# -gt 0 ] || { echo "usage: maku.sh run <コマンド…>" >&2; exit 2; }
    off || exit 1
    trap 'restore' EXIT   # 失敗しても・止められても戻す
    "$@" ;;
  pass)
    sec="${2:-}"
    [[ "$sec" =~ ^[0-9]{1,3}$ ]] && [ "$sec" -le 300 ] || { echo "usage: maku.sh pass <0〜300>" >&2; exit 2; }
    sec=$((10#$sec))   # 00・010 を JSON に出せる形に（そのままだと 400 で閉じられない・反証役）
    [ -r "$KEYF" ] || { echo "鍵が読めません" >&2; exit 1; }
    call POST /pass "{\"bundle\":\"com.apple.Notes\",\"seconds\":$sec,\"by\":\"メモのチェックリスト\"}"
    [ "$CODE" = 200 ] || { echo "通り道を開けませんでした（${CODE}）" >&2; exit 1; }
    echo "ok" ;;
  *) echo "usage: maku.sh status|run <コマンド…>|off|restore|pass <秒>" >&2; exit 2 ;;
esac
