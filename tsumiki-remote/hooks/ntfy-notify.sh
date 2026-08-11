#!/bin/sh
# Claude Code の hook から呼ばれて、iPhone に「返答待ち／終わった」だけを通知する。
#
# 送るのは「イベント名」と「tmux のセッション名」だけ。
# 会話の中身・ファイル名・コマンドは一切送らない（ntfy.sh は外部サーバーなので）。
#
# 使い方: ntfy-notify.sh <event>
#   event = permission | notification | stop

set -u

TOPIC_FILE="$HOME/.tsumiki-remote/ntfy-topic"
[ -r "$TOPIC_FILE" ] || exit 0
TOPIC=$(tr -d ' \n' < "$TOPIC_FILE")
[ -n "$TOPIC" ] || exit 0

TMUX_BIN=/opt/homebrew/bin/tmux
SESSION="-"
if [ -n "${TMUX:-}" ] && [ -x "$TMUX_BIN" ]; then
  SESSION=$("$TMUX_BIN" display-message -p '#S' 2>/dev/null || echo "-")
fi

EVENT="${1:-notification}"
case "$EVENT" in
  permission)
    TITLE="返答待ち"
    BODY="$SESSION が許可を待っています"
    TAGS="raised_hand"
    PRIORITY="high"
    ;;
  stop)
    TITLE="終わりました"
    BODY="$SESSION の作業が終わりました"
    TAGS="white_check_mark"
    PRIORITY="default"
    ;;
  *)
    TITLE="入力待ち"
    BODY="$SESSION があなたを待っています"
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
