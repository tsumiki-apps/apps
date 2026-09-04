#!/usr/bin/env python3
"""ディスプレイ配置のプリセットを保存／復元する。

displayplacer をエンジンに、現在の全ディスプレイの解像度・配置座標・回転を
名前つきプリセットとして保存し、ワンコマンドで元に戻す。

再接続でディスプレイIDが変わる環境（Sidecar / BetterDisplay の仮想ディスプレイ）
のため、各画面の永続IDとシリアルIDを両方保存し、復元時に実在するIDへ読み替える。

  dispreset.py save <名前>            いまの配置を保存
  dispreset.py apply <名前>           保存した配置に戻す
  dispreset.py list                   プリセット一覧
  dispreset.py rename <旧名> <新名>   プリセットの名前を変更
  dispreset.py rm <名前>              プリセット削除

  dispreset.py watch-on               iPad接続時の自動復元をオン
  dispreset.py watch-off              自動復元をオフ
  dispreset.py watch-status           on / off を表示
  dispreset.py last                   最後に使ったプリセット名
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime

# 保存先。DISPRESET_DIR を指定すると別の場所を使う（実データを汚さずテストするため）。
PRESET_DIR = os.environ.get("DISPRESET_DIR") or os.path.expanduser("~/.config/dispreset")
DISPLAYPLACER = "/opt/homebrew/bin/displayplacer"


def displayplacer_path():
    if os.path.exists(DISPLAYPLACER):
        return DISPLAYPLACER
    from shutil import which
    found = which("displayplacer")
    if not found:
        die("displayplacer が見つかりません。`brew install displayplacer` を実行してください。")
    return found


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def read_screens():
    """displayplacer list を解析して、現在の各画面の情報を返す。"""
    out = subprocess.run(
        [displayplacer_path(), "list"], capture_output=True, text=True
    ).stdout

    # 末尾に「現在の配置を再現するコマンド」が出力される。各画面の引数はここから取る。
    cmd_line = None
    for line in out.splitlines():
        if line.startswith("displayplacer ") and "origin:" in line:
            cmd_line = line
    if not cmd_line:
        die("displayplacer から現在の配置を読み取れませんでした。")

    args_by_id = {}
    for chunk in re.findall(r'"([^"]+)"', cmd_line):
        m = re.match(r"id:(\S+)\s+(.*)", chunk)
        if m:
            args_by_id[m.group(1)] = m.group(2)

    # 各画面のブロックから 永続ID / シリアルID / 種別 を拾う
    screens = []
    current = {}
    for line in out.splitlines():
        m = re.match(r"Persistent screen id: (\S+)", line)
        if m:
            current = {"persistent": m.group(1)}
            screens.append(current)
            continue
        m = re.match(r"Serial screen id: (\S+)", line)
        if m and current:
            current["serial"] = m.group(1)
            continue
        m = re.match(r"Type: (.+)", line)
        if m and current:
            current["type"] = m.group(1).strip()

    result = []
    for s in screens:
        args = args_by_id.get(s.get("persistent"))
        if args:
            s["args"] = args
            result.append(s)
    return result


def preset_path(name):
    if "/" in name or name.startswith("."):
        die("プリセット名に / は使えません。")
    return os.path.join(PRESET_DIR, name + ".json")


def last_path():
    return os.path.join(PRESET_DIR, ".last")


def read_last_raw():
    """.last に書かれている名前をそのまま返す（実在は確かめない）。"""
    try:
        with open(last_path()) as f:
            return f.read().strip() or None
    except OSError:
        return None


def read_last():
    """最後に適用したプリセット名。無ければ None。"""
    name = read_last_raw()
    # 消されたあとの迷子を掴まないよう、実在を確かめる
    if name and os.path.exists(os.path.join(PRESET_DIR, name + ".json")):
        return name
    return None


def write_last(name):
    os.makedirs(PRESET_DIR, exist_ok=True)
    with open(last_path(), "w") as f:
        f.write(name)


def cmd_save(name):
    screens = read_screens()
    os.makedirs(PRESET_DIR, exist_ok=True)
    data = {
        "name": name,
        "saved_at": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "screens": screens,
    }
    with open(preset_path(name), "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"「{name}」に現在の配置を保存しました（画面 {len(screens)} 枚）")
    for s in screens:
        origin = re.search(r"origin:\(([^)]*)\)", s["args"])
        res = re.search(r"res:(\S+)", s["args"])
        print(f"  - {s['type']}: {res.group(1) if res else '?'} @ ({origin.group(1) if origin else '?'})")


def cmd_apply(name):
    path = preset_path(name)
    if not os.path.exists(path):
        die(f"プリセット「{name}」がありません。`dispreset.py list` で確認してください。")
    with open(path) as f:
        data = json.load(f)

    # いま実在するIDの集合を作る（永続ID・シリアルIDの両方で引けるように）
    live = read_screens()
    live_persistent = {s["persistent"] for s in live}
    live_serial = {s.get("serial") for s in live if s.get("serial")}

    args_list = []
    missing = []
    for s in data["screens"]:
        # 保存時のIDが今も生きていればそれを使う。ダメならシリアルIDで読み替える。
        if s["persistent"] in live_persistent:
            screen_id = s["persistent"]
        elif s.get("serial") in live_serial:
            screen_id = s["serial"]
        else:
            missing.append(s.get("type", "不明な画面"))
            continue
        args_list.append(f'id:{screen_id} {s["args"]}')

    if not args_list:
        die(f"「{name}」に保存された画面が1枚も繋がっていません。iPad の接続を確認してください。")

    subprocess.run([displayplacer_path()] + args_list, check=False)
    write_last(name)

    print(f"「{name}」の配置に戻しました（画面 {len(args_list)} 枚）")
    if missing:
        print("繋がっていないため飛ばした画面: " + "、".join(missing))


def cmd_list():
    if not os.path.isdir(PRESET_DIR):
        print("プリセットはまだありません。")
        return
    names = sorted(f[:-5] for f in os.listdir(PRESET_DIR) if f.endswith(".json"))
    if not names:
        print("プリセットはまだありません。")
        return
    for n in names:
        with open(preset_path(n)) as f:
            data = json.load(f)
        print(f"{n}\t{len(data['screens'])}枚\t{data['saved_at']} 保存")


def cmd_names():
    """.app のピッカー用に、プリセット名だけを1行ずつ出す。"""
    if not os.path.isdir(PRESET_DIR):
        return
    for n in sorted(f[:-5] for f in os.listdir(PRESET_DIR) if f.endswith(".json")):
        print(n)


def cmd_rm(name):
    path = preset_path(name)
    if not os.path.exists(path):
        die(f"プリセット「{name}」がありません。")
    os.remove(path)
    print(f"「{name}」を削除しました。")


WATCH_LABEL = "com.kodai.dispreset.watch"


def watch_plist_path():
    return os.path.expanduser(f"~/Library/LaunchAgents/{WATCH_LABEL}.plist")


def watch_is_on():
    r = subprocess.run(
        ["/bin/launchctl", "print", f"gui/{os.getuid()}/{WATCH_LABEL}"],
        capture_output=True,
    )
    return r.returncode == 0


def cmd_watch_status():
    print("on" if watch_is_on() else "off")


def cmd_watch_on():
    import plistlib

    # 「最後に使った配置」が無いと、オンにしても何も起きない
    if not read_last():
        die("先に一度どれかの配置を適用してください（例: dispreset.py apply 家）。\n"
            "自動復元は「最後に使った配置」に戻す仕組みなので、その記録が要ります。")

    here = os.path.dirname(os.path.abspath(__file__))

    # 「ログイン項目と機能拡張」の一覧は、launchd が起動する実行ファイルの名前を
    # そのまま表示する（AssociatedBundleIdentifiers は ad-hoc 署名だと効かなかった）。
    # そこで、python3 をそのまま起動せず「ディスプレイ配置」という名前の
    # 薄いランチャースクリプト経由で起動する。素のスクリプトなので署名は要らない。
    launcher = os.path.join(here, "ディスプレイ配置")
    watcher = os.path.join(here, "dispreset_watch.py")
    with open(launcher, "w") as f:
        f.write("#!/bin/sh\n")
        f.write(f'exec /usr/bin/python3 "{watcher}"\n')
    os.chmod(launcher, 0o755)

    logfile = os.path.expanduser("~/Library/Logs/dispreset-watch.log")
    plist = {
        "Label": WATCH_LABEL,
        "ProgramArguments": [launcher],
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": logfile,
        "StandardErrorPath": logfile,
    }
    os.makedirs(os.path.dirname(watch_plist_path()), exist_ok=True)
    with open(watch_plist_path(), "wb") as f:
        plistlib.dump(plist, f)

    # 既に動いていれば入れ替える
    subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{WATCH_LABEL}"],
                   capture_output=True)
    r = subprocess.run(
        ["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", watch_plist_path()],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        die(f"自動復元を有効にできませんでした: {r.stderr.strip()}")
    print("自動復元をオンにしました。iPad を繋ぐと、最後に使った配置に戻ります。")


def cmd_watch_off():
    subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{WATCH_LABEL}"],
                   capture_output=True)
    if os.path.exists(watch_plist_path()):
        os.remove(watch_plist_path())
    print("自動復元をオフにしました。")


def cmd_rename(old, new):
    if not os.path.exists(preset_path(old)):
        die(f"プリセット「{old}」がありません。")
    if new == old:
        die("いまと同じ名前です。")
    if os.path.exists(preset_path(new)):
        die(f"「{new}」はすでにあります。別の名前にしてください。")

    with open(preset_path(old)) as f:
        data = json.load(f)
    data["name"] = new
    with open(preset_path(new), "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.remove(preset_path(old))
    # 「最後に使った」が旧名を指したままだと自動復元が迷子になる
    if read_last_raw() == old:
        write_last(new)
    print(f"「{old}」を「{new}」に変更しました。")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    action = sys.argv[1]
    arg = sys.argv[2] if len(sys.argv) > 2 else None
    arg2 = sys.argv[3] if len(sys.argv) > 3 else None

    if action == "save":
        if not arg:
            die("保存する名前を指定してください（例: dispreset.py save 家）")
        cmd_save(arg)
    elif action == "apply":
        if not arg:
            die("戻すプリセット名を指定してください（例: dispreset.py apply 家）")
        cmd_apply(arg)
    elif action == "list":
        cmd_list()
    elif action == "names":
        cmd_names()
    elif action == "rm":
        if not arg:
            die("削除する名前を指定してください。")
        cmd_rm(arg)
    elif action == "rename":
        if not arg or not arg2:
            die("変更前と変更後の名前を指定してください（例: dispreset.py rename 家 リビング）")
        cmd_rename(arg, arg2)
    elif action == "last":
        print(read_last() or "")
    elif action == "watch-status":
        cmd_watch_status()
    elif action == "watch-on":
        cmd_watch_on()
    elif action == "watch-off":
        cmd_watch_off()
    else:
        die(f"知らないコマンドです: {action}")


if __name__ == "__main__":
    main()
