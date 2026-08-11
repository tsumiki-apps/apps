#!/bin/sh
# Claude Code の hook から呼ばれて、iPhone に「返答待ち／終わった」だけを通知する。
#
# 送るのは「イベント名」と「そのセッションの題名」だけ。
# 題名＝Claude Code がターミナルの題名に出している「いま何をしているか」の一行
# （例: つみきリモートの画像通知機能の変更）。work5 では何の用事か分からないため。
# ⚠️ ntfy.sh は外部サーバーなので、題名はそこに残る。会話の中身・ファイル名・
# コマンドは今までどおり一切送らない。題名も出したくない時は USE_TITLE=0 にする。
#
# 使い方: ntfy-notify.sh <event>
#   event = permission | notification | stop

set -u

USE_TITLE=1

# 日本語の題名を切り貼りするので、文字の扱いを UTF-8 に固定する
# （LC_ALL=C のままだと sed が濁点まみれの文字化けを返す）
LC_ALL=
LC_CTYPE=UTF-8
export LC_ALL LC_CTYPE

TOPIC_FILE="$HOME/.tsumiki-remote/ntfy-topic"
[ -r "$TOPIC_FILE" ] || exit 0
TOPIC=$(tr -d ' \n' < "$TOPIC_FILE")
[ -n "$TOPIC" ] || exit 0

TMUX_BIN=/opt/homebrew/bin/tmux
SESSION="-"
WHO="-"
if [ -n "${TMUX:-}" ] && [ -x "$TMUX_BIN" ]; then
  FMT='#S|#{pane_title}|#{pane_current_path}'
  # 自分がいるペインを指名して聞く（指名しないと別のペインの題名を拾いうる）
  PANE="${TMUX_PANE:-}"
  INFO=''
  [ -n "$PANE" ] && INFO=$("$TMUX_BIN" display-message -p -t "$PANE" "$FMT" 2>/dev/null || echo '')
  # ペインIDが渡っていない環境では、従来どおり指名なしで聞く
  [ -n "$INFO" ] || INFO=$("$TMUX_BIN" display-message -p "$FMT" 2>/dev/null || echo '')
  SESSION=$(printf '%s' "$INFO" | cut -d'|' -f1)
  [ -n "$SESSION" ] || SESSION="-"
  WHO="$SESSION"

  # 題名（一覧アプリ側の titleOf と同じ考え方）。
  # 先頭のスピナー（⠐ や ✳）を落とし、ホスト名・user@host・パスだけのものは
  # 題名とみなさずフォルダ名に、それも無ければセッション名に戻す。
  if [ "$USE_TITLE" = "1" ]; then
    T=$(printf '%s' "$INFO" | cut -d'|' -f2 \
        | sed 's/^[⠀-⣿✻✽✶✳✢*·•[:space:]]*//; s/[[:space:]]*$//')
    HOST=$(hostname 2>/dev/null || echo '')
    [ -n "$HOST" ] && [ "$T" = "$HOST" ] && T=''
    [ -n "$HOST" ] && [ "$T" = "${HOST%.local}" ] && T=''
    # user@host だけ（空白なし＆@あり）はシェルの既定表示なので題名にしない
    case "$T" in
      *\ *) : ;;
      *@*)  T='' ;;
    esac
    case "$T" in
      '~'|'/'|'.') T='' ;;
      '~'*|'/'*)   T=$(basename "$T") ;;
    esac
    if [ -z "$T" ]; then
      CWD=$(printf '%s' "$INFO" | cut -d'|' -f3)
      [ -n "$CWD" ] && T=$(basename "$CWD")
    fi
    [ -n "$T" ] && WHO="$T"
  fi
fi

# 同じセッションの連発を抑える。
# 許可待ちのとき Claude Code は PermissionRequest と Notification の両方を撃つので、
# そのままだと「返答待ち」の 6 秒後に「入力待ち」が来て 1 件の用事で 2 回鳴る。
# 先に来た方（＝より具体的な「返答待ち」）だけ通し、直後の追い討ちは捨てる。
COOLDOWN=20
STATE_DIR="$HOME/.tsumiki-remote/notify-state"
KEY=$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9_.-' '_')
NOW=$(date +%s)
LAST=0
if [ -r "$STATE_DIR/$KEY" ]; then
  LAST=$(cat "$STATE_DIR/$KEY" 2>/dev/null)
  case "$LAST" in (''|*[!0-9]*) LAST=0 ;; esac
fi
[ "$((NOW - LAST))" -lt "$COOLDOWN" ] && exit 0
mkdir -p "$STATE_DIR" 2>/dev/null
printf '%s' "$NOW" > "$STATE_DIR/$KEY" 2>/dev/null

EVENT="${1:-notification}"
case "$EVENT" in
  permission)
    TITLE="返答待ち"
    BODY="$WHO が許可を待っています"
    TAGS="raised_hand"
    PRIORITY="high"
    ;;
  stop)
    TITLE="終わりました"
    BODY="$WHO の作業が終わりました"
    TAGS="white_check_mark"
    PRIORITY="default"
    ;;
  *)
    TITLE="入力待ち"
    BODY="$WHO があなたを待っています"
    TAGS="bell"
    PRIORITY="high"
    ;;
esac

curl -s -m 5 \
  -H "Title: $TITLE" \
  -H "Tags: $TAGS" \
  -H "Priority: $PRIORITY" \
  -d "$BODY" \
  "https://ntfy.sh/$TOPIC" > /dev/null 2>&1

exit 0
