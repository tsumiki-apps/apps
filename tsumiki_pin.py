#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""作ったものに印を付ける（つみきリモートの席の画面の帯に、確実に出すため）。

    python3 ~/制作物/tsumiki_pin.py <ファイル>...

## なぜ要るか

席の画面の帯（「さっき作ったもの」）は、置き場を新しい順に舐めて拾っている。
これは**作り方に左右されない**かわりに、2つの弱点がある。

  ・iCloud の探索は締め切り（3.5秒）で打ち切られる＝実データではほぼ毎回
    「途中まで」になる（2026-09-16 実測）。拾い漏れがありうる
  ・同じ時間に別の席が書き出したものも混ざる

印を付けたものは **stat 1回で必ず出る**（探索の結果に頼らない）ので、この2つを
受けない。帯では印のあるものが先に並ぶ。

## 使い方の決まり

  ・`tsumiki_out.py` が置き場を返すとき、**自動でここを通る**（呼ぶ側の手間はゼロ）
  ・その道具を通さずに作ったものは、このコマンドで後から印を付けられる
  ・**まだ無いファイルでもよい**。`tsumiki_out.py` は「これから置く場所」を返すので、
    印はその時点で付く。帯に出るのは実際にできたものだけ（サーバーが見に行った
    ときに無ければ出さない）＝置くのをやめても、幽霊の札は出ない
  ・置き場（00_Tsumiki）の外は受け付けない。プレビューがその中しか開けないため

## 置き場

`~/.tsumiki-remote/made.jsonl`（1行1件）。**追記しかしない**＝複数の席が同時に
書いても混ざらない（1行が 4KB 未満なら書き込みは原子的）。増えたら古いほうから刈る。
"""
import json, os, sys, time

PREVIEW_ROOT = os.environ.get('TSUMIKI_PREVIEW_ROOT') or os.path.expanduser(
    '~/Library/Mobile Documents/com~apple~CloudDocs/Kodai/00_Tsumiki')
MADE_FILE = os.path.join(os.path.expanduser('~'), '.tsumiki-remote', 'made.jsonl')
KEEP = 400          # これを超えたら、新しい 400 行だけ残す
LIMIT = 800         # 刈るかどうかを見る行数


def _rel(path):
    """置き場からの相対パスにする。外のもの・たどれないものは None。"""
    try:
        full = os.path.abspath(os.path.expanduser(path))
        root = os.path.abspath(PREVIEW_ROOT)
        rel = os.path.relpath(full, root)
    except Exception:
        return None
    # ⚠️ 「..」で外に出るものを弾く。印は帯に出す＝プレビューで開ける道なので、
    #    置き場の外を指させない（`/preview/` 側にも同じ関門があるが、ここでも止める）
    if rel.startswith('..') or os.path.isabs(rel):
        return None
    return rel.replace(os.sep, '/')


def _trim():
    """増えすぎたら古い行を落とす。失敗しても黙って諦める（印は無くても困らない）。"""
    try:
        with open(MADE_FILE, encoding='utf-8') as f:
            lines = f.readlines()
        if len(lines) <= LIMIT:
            return
        tmp = MADE_FILE + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.writelines(lines[-KEEP:])
        os.replace(tmp, MADE_FILE)
    except Exception:
        pass


def pin(paths, by='tsumiki_out'):
    """印を付ける。付けられた数を返す。**呼び出し側を絶対に落とさない。**

    ⚠️ ここで例外を上げると、置き場を聞いただけの道具が道連れで死ぬ。
       印が付かないのは「帯に出にくくなる」だけなので、黙って諦めるほうが軽い。
    """
    rows = []
    now = int(time.time() * 1000)
    for p in paths:
        rel = _rel(p)
        if not rel:
            continue
        rows.append(json.dumps({'rel': rel, 'at': now, 'by': by}, ensure_ascii=False))
    if not rows:
        return 0
    try:
        os.makedirs(os.path.dirname(MADE_FILE), exist_ok=True)
        # 1行ずつ、追記で開いて1回で書く（他の席と混ざらない）
        fd = os.open(MADE_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            for r in rows:
                os.write(fd, (r + '\n').encode('utf-8'))
        finally:
            os.close(fd)
        _trim()
        return len(rows)
    except Exception:
        return 0


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        sys.stderr.write(__doc__)
        return 2
    n = pin(argv, by='tsumiki_pin')
    if not n:
        sys.stderr.write('印を付けられませんでした（置き場の外か、書けませんでした）\n')
        return 1
    sys.stderr.write('（%d件に印を付けました）\n' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
