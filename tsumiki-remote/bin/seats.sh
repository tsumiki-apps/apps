#!/bin/bash
# つみきリモートの札と同じ「番号・題名」で、いまの席を並べる。
# 他の席の話をするとき（ListAgents の claude-c9 などを本人に見せるとき）に、
# 本人がスマホの札で見分けられる呼び名に直すために使う。
#   出力: 1・見積の見直し	work2	（この席）
# 並び・題名の決め方は server.js の newestFirst / titleOf / seatState と同じ
# （作った時刻の新しい順・同じ秒なら番号の大きいほう／手で付けた名札が勝つ）。
set -u
me=""
[ -n "${TMUX:-}" ] && me=$(tmux display-message -p '#{session_name}' 2>/dev/null)
host=$(hostname)
tmux list-sessions -F '#{session_created}|::|#{session_name}|::|#{@tsumiki_title}' 2>/dev/null |
while IFS= read -r line; do
  created=${line%%|::|*}; rest=${line#*|::|}
  name=${rest%%|::|*}; label=${rest#*|::|}
  ptitle=$(tmux display-message -p -t "=$name:" '#{pane_title}' 2>/dev/null)
  cwd=$(tmux display-message -p -t "=$name:" '#{pane_current_path}' 2>/dev/null)
  num=$(printf '%s' "$name" | sed 's/^[^0-9]*//'); num=${num:-0}
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$created" "$num" "$name" "$label" "$ptitle" "$cwd"
done | sort -t$'\t' -k1,1nr -k2,2nr |
python3 -c '
import sys, re, os
me, host = sys.argv[1], sys.argv[2]
SPIN = re.compile(r"^[⠀-⣿✻✽✶✳✢◐◑◒◓*·•\s]+")
i = 0
for row in sys.stdin:
    c = row.rstrip("\n").split("\t")
    if len(c) < 6: continue
    _, _, name, label, pt, cwd = c
    label = re.sub(r"\s+", " ", label).strip()[:40]
    t = SPIN.sub("", pt).strip()
    if t in (host, host.removesuffix(".local")) or re.fullmatch(r"\S+@\S+", t): t = ""
    if t[:1] in ("~", "/"): t = os.path.basename(t)
    if t in ("~", "/", "."): t = ""
    if not t and cwd: t = os.path.basename(cwd)
    title = label or (t or name)[:60]
    i += 1
    print(f"{i}・{title}\t{name}" + ("\t（この席）" if name == me else ""))
' "$me" "$host"
