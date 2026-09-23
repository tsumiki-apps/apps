#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tsumiki_inbox.py — 本人に送ったファイルを「受け取り」フォルダにも複製する。

なぜ要るか:
  iPhone のファイルアプリの「最近使った項目」には、その iPhone で開いたものしか並ばない。
  Mac で作って iCloud に置いただけのファイルは出てこず、深い階層（11_やりとり出力/<案件>/<成果物>/V1/…）を
  辿らないと開けなかった（2026-09-23 本人の指摘）。本人は「受け取り」を「よく使う項目」に登録してある。

置き場: iCloud Drive/Kodai/00_Tsumiki/受け取り（2026-09-23 本人が直下から移した。つみきリモートの範囲の中）
  **無ければ作らない**（本人が動かした可能性がある。勝手に元の場所へ作り直すと2か所に割れる）。警告だけ出す。

使い方:
  SendUserFile の PostToolUse フックから `python3 tsumiki_inbox.py --hook`（本文の JSON を標準入力で受ける）
  手で呼ぶとき: python3 tsumiki_inbox.py <ファイル> [...]

決まり（2026-09-23 反証役の指摘で作り直した）:
  ・**自分で置いた複製だけを覚えておき（控え＝~/.cache/tsumiki/inbox.json）、刈り込みはその中だけ。**
    本人が自分で置いたファイルは、名前が同じでも消さない・上書きしない。
  ・同じ成果物の同じファイル名は、版（V1→V2）が変わっても同じ名前で置き換える（古い版が元の名前で残って取り違えないように）。
  ・名前がぶつかったら（本人のファイル／別の案件の同じ名前）、「名前（成果物名）.拡張子」→「名前 (2)」の順に逃がす。
  ・新しい KEEP 件だけ残す。フォルダの一覧は取らない（iCloud の一覧は固まることがある。控えだけで決まる）。
  ・コピーは一時名に書いてから入れ替える（途中で打ち切っても、書きかけが正しい名前で残らない）。
  ・.wflow（署名前のショートカット・合い言葉が平文）と . 始まりは複製しない。
  ・「送る物は ~/つみき出力 に置いてから送る」の見張りも兼ねる（memory: send-user-file-must-be-in-tsumiki-out）。
    つみきリモートが開ける範囲（00_Tsumiki の中＝server.js の PREVIEW_ROOT と同じ）の外なら、
    **Claude にも本人にも届く形**（additionalContext と systemMessage）で知らせる。
  ・何が起きても終了コード0（フックの失敗で本来の作業を止めない）。
"""
import os, sys, json, subprocess, pathlib, time, re

CLOUD = pathlib.Path.home() / "Library/Mobile Documents/com~apple~CloudDocs"
# つみきリモート（tsumiki-remote/server.js の PREVIEW_ROOT・tsumiki_pin.py）と同じ根。ここの外はリモートで開けない
PREVIEW_ROOT = pathlib.Path(os.environ.get("TSUMIKI_PREVIEW_ROOT") or (CLOUD / "Kodai/00_Tsumiki"))
INBOX = pathlib.Path(os.environ.get("TSUMIKI_INBOX") or (PREVIEW_ROOT / "受け取り"))
OUT = PREVIEW_ROOT / "11_やりとり出力"
LEDGER = pathlib.Path(os.environ.get("TSUMIKI_INBOX_LEDGER") or (pathlib.Path.home() / ".cache/tsumiki/inbox.json"))
KEEP = 10
SKIP_EXT = {".wflow"}


def load():
    try:
        return json.loads(LEDGER.read_text(encoding="utf-8"))
    except Exception:
        return []


def save(items):
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    tmp = LEDGER.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False)
    os.replace(tmp, LEDGER)


def product_of(src):
    """11_やりとり出力/<案件>/<成果物>/V1/<種類>/<ファイル> の <成果物>"""
    try:
        parts = src.resolve().relative_to(OUT.resolve()).parts
        return parts[1] if len(parts) >= 3 else ""
    except Exception:
        return ""


def same_item(a, b):
    """同じ物か。版のフォルダ（/V1/ /V2/）だけが違うなら同じ物の新しい版＝同じ名前で置き換える"""
    norm = lambda x: re.sub(r"/V\d+/", "/V*/", str(x))
    return norm(a) == norm(b)


def pick_name(src, ledger):
    """ぶつからない名前。控えの中で同じ物（送り直し・新しい版）なら同じ名前を使い回す＝置き換え"""
    mine = {e["name"]: e["src"] for e in ledger}
    base = src.name
    cands = [base]
    prod = product_of(src)
    if prod:
        cands.append(f"{src.stem}（{prod}）{src.suffix}")
    cands += [f"{src.stem} ({i}){src.suffix}" for i in range(2, 50)]
    for n in cands:
        if n in mine:
            if same_item(mine[n], src):
                return n                      # 同じ物の送り直し・新しい版
            continue                          # 別の案件の同じ名前
        if not (INBOX / n).exists():
            return n                          # 空いている（本人のファイルでもない）
    return None


def copy_in(src, name):
    part = INBOX / f".{name}.part"
    try:
        r = subprocess.run(["/bin/cp", "-p", str(src), str(part)], capture_output=True, timeout=120)
        if r.returncode != 0:
            raise OSError(r.stderr.decode(errors="replace")[:120])
        os.replace(part, INBOX / name)
        os.utime(INBOX / name, None)
        return True
    except Exception:
        try:
            part.unlink()
        except Exception:
            pass
        return False


def main(paths, cwd=None):
    notes_user, notes_model, placed = [], [], []
    srcs = []
    for p in paths:
        q = pathlib.Path(p).expanduser()
        if not q.is_absolute() and cwd:
            q = pathlib.Path(cwd) / q
        srcs.append(q)

    for src in srcs:
        full = os.path.abspath(str(src)).replace(str(pathlib.Path.home() / "つみき出力"), str(OUT), 1)
        if not full.startswith(str(PREVIEW_ROOT) + os.sep):
            notes_model.append(f"送ったファイル「{src.name}」は ~/つみき出力 の外にあります。つみきリモートで押しても開けません。"
                               "tsumiki_out.py で置き場を聞いてそこへ置き直し、送り直してください。")
            notes_user.append(f"⚠️ {src.name} は置き場の外（リモートで開けません）")

    if not INBOX.is_dir():
        notes_user.append("⚠️ 受け取りフォルダが見つかりません（場所を変えましたか？）。複製していません")
        notes_model.append(f"受け取りフォルダ（{INBOX}）が見つかりません。本人が移した可能性があるので、"
                           "場所を聞いて tsumiki_inbox.py の INBOX を直してください。作り直さないこと。")
    else:
        ledger = load()
        for src in srcs:
            if src.suffix.lower() in SKIP_EXT or src.name.startswith(".") or not src.is_file():
                continue
            name = pick_name(src, ledger)
            if not name or not copy_in(src, name):
                notes_user.append(f"⚠️ 受け取りに置けませんでした（{src.name}）")
                continue
            ledger = [e for e in ledger if e["name"] != name]
            ledger.append({"name": name, "src": str(src), "at": time.time()})
            placed.append(name)
        # 刈り込み：控えにある（自分で置いた）ものだけ。新しい KEEP 件を残す
        ledger.sort(key=lambda e: e["at"], reverse=True)
        for e in ledger[KEEP:]:
            try:
                (INBOX / e["name"]).unlink()
            except FileNotFoundError:
                pass
            except Exception:
                continue
        save(ledger[:KEEP])

    return placed, notes_user, notes_model


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
    placed, nu, nm = main(files, d.get("cwd"))
    out = {}
    msg = []
    if placed:
        msg.append("受け取りにも置きました: " + " / ".join(placed))
    msg += nu
    if msg:
        out["systemMessage"] = "\n".join(msg)
    if nm:
        out["hookSpecificOutput"] = {"hookEventName": "PostToolUse", "additionalContext": "\n".join(nm)}
    if out:
        print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["--hook"]:
            hook()
        elif len(sys.argv) > 1:
            placed, nu, nm = main(sys.argv[1:], os.getcwd())
            for line in (["受け取りにも置きました: " + " / ".join(placed)] if placed else []) + nu:
                print(line)
        else:
            print(__doc__.strip().split("\n")[0])
    except Exception as e:                    # フックの失敗で本来の作業を止めない
        print(json.dumps({"systemMessage": f"⚠️ 受け取り：{str(e)[:100]}"}, ensure_ascii=False))
    sys.exit(0)
