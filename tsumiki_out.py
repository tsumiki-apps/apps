#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""やり取りの出力を置く場所を決める（プロジェクトごと・無ければ自動で作る）。

    python3 ~/制作物/tsumiki_out.py --list             いまあるプロジェクトを並べる
    python3 ~/制作物/tsumiki_out.py せんや              置き場を出す（無ければ作る）
    python3 ~/制作物/tsumiki_out.py せんや 返信文.txt    そのファイルの置き場まで出す

出るのは**絶対パス1行だけ**。そのまま > や Write の宛先に使える。

なぜ道具にするか：
  置き場を毎回 AI の判断に任せると、同じプロジェクトが「せんや」「せんや様」
  「センヤ」に散る。ここで既にあるフォルダに寄せる（大小・全半角・NFC/NFD の
  ゆれを吸って、部分一致も見る）。それでも見つからなければ初めてのプロジェクト
  なので、黙って作る（許可を求めない＝2026-09-04 の決めごと）。

⚠️ 置き場の実体は iCloud。同期の読み出しが返らないことがあるので、
   一覧の読み取りには必ず制限時間を付ける（返らないときは黙って固まらず、
   理由を言って終わる）。
"""
import os, sys, unicodedata, threading

ROOT = os.path.expanduser(
    '~/Library/Mobile Documents/com~apple~CloudDocs/Kodai/00_Tsumiki/11_やりとり出力')
READ_TIMEOUT = 5.0


def norm(s):
    """比べるための形にそろえる。

    ・NFKC … macOS の名前は NFD で来る（NFC と別物）。全角英数・半角カナもここで揃う
    ・カタカナ→ひらがな … 「センヤ」と「せんや」を同じものとして扱う
      （2026-09-04 実測：これが無くて「センヤ」で新しいフォルダを作ってしまった）
    ・小文字化・空白落とし
    """
    s = unicodedata.normalize('NFKC', s).strip().lower()
    s = ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in s)
    return s.replace(' ', '').replace('　', '').replace('_', '').replace('・', '')


def listdir_within(path, timeout):
    """制限時間つきの一覧。返らなければ None（固まったまま待たない）"""
    box = {}

    def run():
        try:
            box['v'] = [n for n in os.listdir(path)
                        if not n.startswith('.') and os.path.isdir(os.path.join(path, n))]
        except Exception as e:
            box['e'] = e

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(timeout)
    if 'e' in box:
        return None
    return box.get('v')


def resolve(name, projects):
    """既にあるプロジェクトに寄せる。無ければ None（＝新しく作る）"""
    n = norm(name)
    by = {norm(p): p for p in projects}
    if n in by:
        return by[n]
    # 部分一致。長いほうを優先する（「せんや」で「せんや」も「つみきandせんや」も
    # 当たるとき、短く言われたほうの名前を採る）
    hits = [p for p in projects if n in norm(p) or norm(p) in n]
    if len(hits) == 1:
        return hits[0]
    if hits:
        return sorted(hits, key=lambda p: abs(len(norm(p)) - len(n)))[0]
    return None


def main(argv):
    projects = listdir_within(ROOT, READ_TIMEOUT)
    if projects is None:
        sys.stderr.write(
            'つみき出力の一覧が読めません（iCloud が返らないか、Mac 側の許可が切れています）。\n'
            'システム設定 → プライバシーとセキュリティ → フルディスクアクセス を見てください。\n')
        return 2
    projects.sort()

    if not argv or argv[0] in ('--list', '-l'):
        for p in projects:
            print(p)
        return 0

    name = argv[0]
    hit = resolve(name, projects)
    made = False
    if hit is None:
        hit = unicodedata.normalize('NFC', name).strip()
        if not hit or '/' in hit:
            sys.stderr.write('プロジェクト名として使えません: %r\n' % name)
            return 2
        os.makedirs(os.path.join(ROOT, hit), exist_ok=True)
        made = True

    out = os.path.join(ROOT, hit)
    if len(argv) > 1:
        out = os.path.join(out, argv[1])
    print(out)
    if made:
        sys.stderr.write('（初めてのプロジェクトなので「%s」を作りました）\n' % hit)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
