#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tsumiki_inbox.py — 本人に送ったファイルが、受け取り口（04_つみきリモート制作物）の中にあるかを見張る。

受け取り口は1つ（2026-09-27 本人が決めた）:
  iCloud Drive/Kodai/04_つみきリモート制作物（Mac からは ~/つみき出力 が近道）
  置き場の決まりの正本 → ~/制作物/docs/置き場.md

前は送ったファイルを 00_Tsumiki/受け取り に複製していたが、役目が本物の置き場と重なって
取り違えの元になったので、2026-09-27 に受け取りごと廃止した。
（深い置き場まで辿れない問題は、つみきリモートのピンクの名前がファイルアプリで直接開くことで解いた）

使い方:
  SendUserFile の PostToolUse フックから `python3 tsumiki_inbox.py --hook`（本文の JSON を標準入力で受ける）
  手で呼ぶとき: python3 tsumiki_inbox.py <ファイル> [...]

決まり:
  ・受け取り口の外のファイルを送ったら、**Claude にも本人にも届く形**（additionalContext と systemMessage）で知らせる。
    つみきリモートで押しても開けないため（memory: send-user-file-must-be-in-tsumiki-out）。
  ・iCloud には触らない（字の上で比べるだけ。iCloud の呼び出しは返ってこないことがある）。
  ・何が起きても終了コード0（フックの失敗で本来の作業を止めない）。
"""
import os, sys, json, pathlib

CLOUD = pathlib.Path.home() / "Library/Mobile Documents/com~apple~CloudDocs"
OUT = pathlib.Path(os.environ.get("TSUMIKI_OUT_ROOT") or (CLOUD / "Kodai/04_つみきリモート制作物"))
ALIAS = str(pathlib.Path.home() / "つみき出力")
# つみきリモートが開ける所（tsumiki-remote/server.js の PREVIEW_TOPS と同じ）。ロゴ等の 00_Tsumiki も開けるので警告しない
OPENABLE = [OUT, CLOUD / "Kodai/00_Tsumiki"]


def main(paths, cwd=None):
    notes_user, notes_model = [], []
    for p in paths:
        src = pathlib.Path(p).expanduser()
        if not src.is_absolute() and cwd:
            src = pathlib.Path(cwd) / src
        full = os.path.abspath(str(src))
        if full == ALIAS or full.startswith(ALIAS + os.sep):
            full = str(OUT) + full[len(ALIAS):]
        if not any(full.startswith(str(r) + os.sep) for r in OPENABLE):
            notes_model.append(f"送ったファイル「{src.name}」は受け取り口（~/つみき出力）の外にあります。つみきリモートで押しても開けません。"
                               "tsumiki_out.py で置き場を聞いてそこへ置き直し、送り直してください。")
            notes_user.append(f"⚠️ {src.name} は受け取り口の外（リモートで開けません）")
    return notes_user, notes_model


def hook():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    files = (d.get("tool_input") or {}).get("files") or []
    if isinstance(files, str):
        files = [files]
    if not files:
        return
    nu, nm = main(files, d.get("cwd"))
    out = {}
    if nu:
        out["systemMessage"] = "\n".join(nu)
    if nm:
        out["hookSpecificOutput"] = {"hookEventName": "PostToolUse", "additionalContext": "\n".join(nm)}
    if out:
        print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["--hook"]:
            hook()
        elif len(sys.argv) > 1:
            nu, nm = main(sys.argv[1:], os.getcwd())
            print("\n".join(nu) or "OK（受け取り口の中）")
        else:
            print(__doc__.strip().split("\n")[0])
    except Exception as e:                    # フックの失敗で本来の作業を止めない
        print(json.dumps({"systemMessage": f"⚠️ 置き場の見張り：{str(e)[:100]}"}, ensure_ascii=False))
    sys.exit(0)
