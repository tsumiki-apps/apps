#!/usr/bin/env python3
"""ディスプレイが増えたら、最後に使ったプリセットの配置に自動で戻す常駐役。

launchd から起動される（com.kodai.dispreset.watch）。

やっていること:
  2秒ごとに CoreGraphics で「いま繋がっているディスプレイID」の集合を取り、
  前回より増えていたら、落ち着くのを待ってから最後に使ったプリセットを適用する。

暴発しないための条件:
  - 見るのは「配置」ではなく「IDの集合」。適用しても集合は変わらないので、
    自分の適用が次の検知を呼ぶ無限ループにならない。
  - 増えたときだけ動く。iPad を外したときは何もしない（外した拍子に
    他の画面を動かしても無意味なため）。
  - 起動直後は現状を覚えるだけで適用しない。
  - Sidecar と BetterDisplay の仮想ディスプレイは時間差で現れるので、
    増加を検知したら SETTLE 秒待ち、集合が安定してから一度だけ適用する。
"""

import os
import subprocess
import sys
import time
from ctypes import CDLL, byref, c_uint32

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dispreset

POLL = 2        # 何秒ごとに見るか
SETTLE = 4      # 増加を検知してから、落ち着くのを待つ秒数
COOLDOWN = 15   # 一度適用したら、次に動くまで最低これだけ空ける

CG = CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")


def online_displays():
    """いま繋がっているディスプレイIDの集合。"""
    ids = (c_uint32 * 16)()
    count = c_uint32()
    if CG.CGGetOnlineDisplayList(16, ids, byref(count)) != 0:
        return None
    return {ids[i] for i in range(count.value)}


def log(msg):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


def notify(title, text):
    subprocess.run(
        ["/usr/bin/osascript", "-e",
         f'display notification {json_str(text)} with title {json_str(title)}'],
        check=False, capture_output=True,
    )


def json_str(s):
    """AppleScript の文字列リテラルとして安全に埋め込む。"""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    known = online_displays()
    if known is None:
        log("ディスプレイ一覧を取得できませんでした。終了します。")
        return 1
    log(f"監視を開始しました（いま {len(known)} 枚）")
    last_applied_at = 0.0

    while True:
        time.sleep(POLL)
        now_set = online_displays()
        if now_set is None or now_set == known:
            continue

        added = now_set - known
        removed = known - now_set
        known = now_set

        if not added:
            log(f"ディスプレイが減りました（{len(removed)} 枚）。何もしません。")
            continue

        if time.time() - last_applied_at < COOLDOWN:
            log("直前に適用したばかりなので、今回は見送ります。")
            continue

        log(f"ディスプレイが増えました（{len(added)} 枚）。{SETTLE}秒待って落ち着かせます。")
        # Sidecar と仮想ディスプレイが出揃うのを待つ。待つ間に更に増えたら数え直す。
        deadline = time.time() + SETTLE
        while time.time() < deadline:
            time.sleep(1)
            s = online_displays()
            if s is not None and s != known:
                known = s
                deadline = time.time() + SETTLE

        target = dispreset.read_last()
        if not target:
            log("最後に使ったプリセットが無いので、何もしません。")
            continue

        try:
            dispreset.cmd_apply(target)
            last_applied_at = time.time()
            log(f"「{target}」を自動で適用しました。")
            notify("ディスプレイ配置を復元しました", target)
        except SystemExit as e:
            # cmd_apply は die() で SystemExit を投げる（例: 保存された画面が1枚も無い）
            log(f"適用を見送りました: {e}")
        except Exception as e:
            log(f"適用に失敗しました: {e}")


if __name__ == "__main__":
    sys.exit(main() or 0)
