#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""やり取りの出力を置く場所を決める（プロジェクト → 成果物 → 版 → 種類）。

    python3 ~/制作物/tsumiki_out.py --list                       いまあるプロジェクトを並べる
    python3 ~/制作物/tsumiki_out.py みほん                        プロジェクトの置き場（無ければ作る）
    python3 ~/制作物/tsumiki_out.py みほん ご返信カード 返信.png    いまの版に置く
    python3 ~/制作物/tsumiki_out.py みほん ご返信カード 返信.png --new
                                                                 新しい版（V2, V3…）を作ってそこに置く
    python3 ~/制作物/tsumiki_out.py みほん ご返信カード --versions  版の一覧（新しい順）

出るのは**絶対パス1行だけ**（--list / --versions を除く）。そのまま > や Write の宛先に使える。

置き方（2026-09-15 本人の依頼で決めた）：

    11_やりとり出力/<プロジェクト>/<成果物>/V<番号>/<種類>/<ファイル>

  ・成果物 … 「ストーリー_募集」「ご返信カード」のように、作り直していく1つのもの
  ・V<番号> … 作り直したら番号を上げる。いちばん大きい番号が最新
    - 同じ作業の中でファイルを足す・直すだけなら、いまの版に置く（--new を付けない）
    - 本人に見せたあとで作り直すとき、見た目や中身を大きく変えるときは --new
  ・種類 … 拡張子で決まる（下の KINDS）。フォルダとファイルを同じ階層に混ぜない
    （2026-09-06 に iCloud 全体で通した整理の方針）
  ・ファイル名に日付や v2 を付けなくてよい（版はフォルダが持つ）

なぜ道具にするか：
  置き場を毎回 AI の判断に任せると、同じプロジェクトが「みほん」「みほん様」
  「ミホン」に散る。ここで既にあるフォルダに寄せる（大小・全半角・NFC/NFD の
  ゆれを吸って、部分一致も見る）。成果物の名前も同じように寄せる。
  それでも見つからなければ初めてなので、黙って作る（許可を求めない＝2026-09-04 の決めごと）。

⚠️ 置き場の実体は iCloud。同期の読み出しが返らないことがあるので、
   一覧の読み取りには必ず制限時間を付ける（返らないときは黙って固まらず、
   理由を言って終わる）。
⚠️ 試すときは TSUMIKI_OUT_ROOT に作業用のフォルダを渡す（本物の iCloud にフォルダを作らない）。
"""
import os, re, sys, unicodedata, threading

ROOT = os.environ.get('TSUMIKI_OUT_ROOT') or os.path.expanduser(
    '~/Library/Mobile Documents/com~apple~CloudDocs/Kodai/00_Tsumiki/11_やりとり出力')
READ_TIMEOUT = 5.0

# 種類のフォルダ名。名前は 2026-09-06 の iCloud 整理と同じにそろえる
KINDS = [
    ('画像', {'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'svg', 'icns'}),
    ('書類', {'pdf', 'html', 'htm', 'docx', 'xlsx', 'pptx', 'key', 'pages', 'numbers'}),
    ('動画・音声', {'mp4', 'mov', 'm4v', 'mp3', 'm4a', 'wav', 'aiff'}),
    ('メモ', {'md', 'txt'}),
]
OTHER_KIND = 'データ'      # json・csv・台本（py/sh）など、上に当てはまらないもの
VER_RE = re.compile(r'^[Vv](\d+)$')


def kind_of(filename):
    ext = os.path.splitext(filename)[1].lower().lstrip('.')
    for name, exts in KINDS:
        if ext in exts:
            return name
    return OTHER_KIND


def norm(s):
    """比べるための形にそろえる。

    ・NFKC … macOS の名前は NFD で来る（NFC と別物）。全角英数・半角カナもここで揃う
    ・カタカナ→ひらがな … 「ミホン」と「みほん」を同じものとして扱う
      （2026-09-04 実測：これが無くてカタカナの名前で新しいフォルダを作ってしまった）
    ・小文字化・空白落とし
    """
    s = unicodedata.normalize('NFKC', s).strip().lower()
    s = ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in s)
    return s.replace(' ', '').replace('　', '').replace('_', '').replace('・', '')


def listdir_within(path, timeout):
    """制限時間つきの一覧（フォルダだけ）。返らなければ None（固まったまま待たない）。
    まだ無いフォルダは空の一覧"""
    if not os.path.isdir(path):
        return []
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
    if 'e' in box or 'v' not in box:
        return None
    return box['v']


def resolve(name, candidates):
    """既にあるフォルダに寄せる。無ければ None（＝新しく作る）"""
    n = norm(name)
    by = {norm(p): p for p in candidates}
    if n in by:
        return by[n]
    # 部分一致。長いほうを優先する（「みほん」で「みほん」も「つみきandみほん」も
    # 当たるとき、短く言われたほうの名前を採る）
    hits = [p for p in candidates if n in norm(p) or norm(p) in n]
    if len(hits) == 1:
        return hits[0]
    if hits:
        return sorted(hits, key=lambda p: abs(len(norm(p)) - len(n)))[0]
    return None


def clean(name, what):
    s = unicodedata.normalize('NFC', name).strip()
    if not s or '/' in s or s in ('.', '..'):
        raise ValueError('%sとして使えません: %r' % (what, name))
    return s


def versions(folder):
    """その成果物の版の番号（小さい順）"""
    names = listdir_within(folder, READ_TIMEOUT)
    if names is None:
        return None
    return sorted(int(m.group(1)) for m in (VER_RE.match(n) for n in names) if m)


def fail(msg):
    sys.stderr.write(msg + '\n')
    return 2


def main(argv):
    flags = {a for a in argv if a.startswith('--')}
    args = [a for a in argv if not a.startswith('--')]

    projects = listdir_within(ROOT, READ_TIMEOUT)
    if projects is None:
        return fail('つみき出力の一覧が読めません（iCloud が返らないか、Mac 側の許可が切れています）。\n'
                    'システム設定 → プライバシーとセキュリティ → フルディスクアクセス を見てください。')
    projects.sort()

    if not args or '--list' in flags or '-l' in argv:
        for p in projects:
            print(p)
        return 0

    notes = []
    try:
        pname = resolve(args[0], projects) or clean(args[0], 'プロジェクト名')
    except ValueError as e:
        return fail(str(e))
    if pname not in projects:
        notes.append('初めてのプロジェクトなので「%s」を作りました' % pname)
    pdir = os.path.join(ROOT, pname)

    if len(args) == 1:
        os.makedirs(pdir, exist_ok=True)
        print(pdir)
        for n in notes:
            sys.stderr.write('（%s）\n' % n)
        return 0

    # 前の書き方（<プロジェクト> <ファイル名>）で呼ばれたときの受け皿（2026-09-15）。
    # ほかのセッションはまだこの形で呼ぶので、2つ目がファイル名に見えたら、そこから
    # 成果物名を作る（末尾の日付・v2 を落とす）。ファイル名の形のフォルダを作らないため
    if len(args) == 2 and re.search(r'\.[A-Za-z0-9]{1,5}$', args[1]):
        stem = os.path.splitext(args[1])[0]
        stem = re.sub(r'[_\-\s]*(\d{4}-\d{2}-\d{2}|\d{8}|[Vv]\d+)$', '', stem)
        stem = re.sub(r'[_\-\s]*(\d{4}-\d{2}-\d{2}|\d{8}|[Vv]\d+)$', '', stem)
        # 頭にプロジェクト名が付いていたら落とす（みほん/みほん_ご返信文 → ご返信文）。
        # 比べるのはゆれを吸った形（「ミホン_カード」の頭も「みほん」として落とす）
        for k in range(1, len(stem) + 1):
            if norm(stem[:k]) == norm(pname):
                stem = re.sub(r'^[_\-\s　・]*', '', stem[k:])
                break
        # 名前がプロジェクト名だけ・日付だけだったとき、プロジェクト名のフォルダを作らない
        if not norm(stem) or norm(stem) == norm(pname):
            stem = 'そのほか'
        args = [args[0], stem, args[1]]
        notes.append('成果物名が無かったので「%s」としました。次からは '
                     'tsumiki_out.py <プロジェクト> <成果物> <ファイル名> [--new] の形で呼んでください' % stem)

    works = listdir_within(pdir, READ_TIMEOUT)
    if works is None:
        return fail('「%s」の中が読めません（iCloud が返りません）' % pname)
    try:
        # 成果物は**ゆれを吸った完全一致だけ**で寄せる。部分一致にすると、短い名前
        # （「みほん」）が別の成果物（「ミホン_カード」）をつかんで混ざる（2026-09-15 試しで発覚）
        wname = ({norm(x): x for x in works}.get(norm(args[1]))
                 or clean(args[1], '成果物の名前'))
    except ValueError as e:
        return fail(str(e))
    if VER_RE.match(wname) or wname in [k for k, _ in KINDS] + [OTHER_KIND]:
        return fail('成果物の名前に「%s」は使えません（版や種類のフォルダ名と紛れる）' % wname)
    if wname not in works:
        notes.append('初めての成果物なので「%s」を作りました' % wname)
    wdir = os.path.join(pdir, wname)

    vs = versions(wdir)
    if vs is None:
        return fail('「%s/%s」の中が読めません（iCloud が返りません）' % (pname, wname))

    if '--versions' in flags:
        for v in reversed(vs):
            print('V%d%s' % (v, '（最新）' if v == vs[-1] else ''))
        return 0

    if '--new' in flags or not vs:
        ver = (vs[-1] + 1) if vs else 1
        if vs:
            notes.append('新しい版 V%d を作りました（前は V%d）' % (ver, vs[-1]))
    else:
        ver = vs[-1]
    vdir = os.path.join(wdir, 'V%d' % ver)

    if len(args) > 2:
        try:
            fname = clean(args[2], 'ファイル名')
        except ValueError as e:
            return fail(str(e))
        out = os.path.join(vdir, kind_of(fname))
        os.makedirs(out, exist_ok=True)
        out = os.path.join(out, fname)
    else:
        os.makedirs(vdir, exist_ok=True)
        out = vdir

    print(out)
    for n in notes:
        sys.stderr.write('（%s）\n' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
