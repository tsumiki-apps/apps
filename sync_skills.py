#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sync_skills.py — 手で書いたスキルを、公開リポジトリ側に控えとして残す

なぜ必要か:
    スキルの本体は `~/.claude/skills/` にある。ここは **git 管理でも Time Machine でもない**
    （2026-09-04 に確認: tmutil の保存先は未設定、~/.claude は ただのディレクトリ）。
    Mac が飛べば作り直しになる。だから `~/制作物/skills/` に控えを置いて push する。

つかいかた:
    python3 sync_skills.py            # 差分を見るだけ（何も書き換えない）
    python3 sync_skills.py --write    # 本体 → 控え に写す

いつ動かすか:
    スキルを作ったとき・直したとき。commit の前。
"""

import argparse
import filecmp
import os
import shutil
import sys

SRC = os.path.expanduser("~/.claude/skills")
DST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "skills")

# 控えを取らないもの（大きすぎる・外に出せない）。理由を必ず添える。
SKIP = {
    "consulting-pptx-skill": "32MB。素材PPTXを含み、公開リポジトリに置く判断がまだ済んでいない",
}


def walk(root):
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__", ".DS_Store")]
        for f in filenames:
            if f == ".DS_Store":
                continue
            p = os.path.join(dirpath, f)
            out[os.path.relpath(p, root)] = p
    return out


def main():
    ap = argparse.ArgumentParser(description="スキル本体をリポジトリ側の控えに写す")
    ap.add_argument("--write", action="store_true", help="実際に写す（既定は差分を見るだけ）")
    a = ap.parse_args()

    if not os.path.isdir(SRC):
        sys.exit("エラー: %s が見つかりません" % SRC)

    names = sorted(n for n in os.listdir(SRC)
                   if os.path.isdir(os.path.join(SRC, n)) and not n.startswith("."))
    changed = 0

    for name in names:
        if name in SKIP:
            print("－ %s ： 控えを取っていない（%s）" % (name, SKIP[name]))
            continue

        s = os.path.join(SRC, name)
        d = os.path.join(DST, name)
        sf, df = walk(s), walk(d) if os.path.isdir(d) else {}

        add = sorted(set(sf) - set(df))
        gone = sorted(set(df) - set(sf))
        diff = sorted(k for k in set(sf) & set(df)
                      if not filecmp.cmp(sf[k], df[k], shallow=False))

        if not (add or gone or diff):
            print("✓ %s ： 一致" % name)
            continue

        changed += 1
        print("! %s ： ズレている" % name)
        for k in add:
            print("    控えに無い: %s" % k)
        for k in diff:
            print("    中身が違う: %s" % k)
        for k in gone:
            print("    本体に無い（消された？）: %s" % k)

        if a.write:
            if os.path.isdir(d):
                shutil.rmtree(d)
            shutil.copytree(s, d, ignore=shutil.ignore_patterns(".DS_Store", "__pycache__"))
            print("    → 写しました: %s" % d)

    if changed and not a.write:
        print("\n差分があります。写すなら: python3 sync_skills.py --write")
        sys.exit(1)
    if not changed:
        print("\nすべて一致しています。")


if __name__ == "__main__":
    main()
