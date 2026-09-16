#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""作ったものに印を付ける（つみきリモートで、履歴の中のファイル名を押して開くための索引）。

    python3 ~/制作物/tsumiki_pin.py <ファイル>...

## なぜ要るか

つみきリモートは、履歴に出ている `使い方.png` のような**名前**を押すと、その中身を開く。
名前から場所を引く索引は2つあって、1つは置き場を新しい順に舐めた「最近」の写し。
これには穴が2つある。

  ・iCloud の探索は締め切り（3.5秒）で打ち切られる＝実データではほぼ毎回
    「途中まで」になる（2026-09-16 実測）。拾い漏れがありうる
  ・写しは遅れる（集め直すのは10分に1回まで）。作った直後の名前は光らないことがある

印を付けたものは stat 1回で見つかるので、この2つを受けない。さらに、`index.html` や
`メモ.md` のような**ありふれた名前は、印のあるものだけが光る**（画面の字がこの置き場の
ものを指している保証が無いため）。

## 使い方の決まり

  ・`tsumiki_out.py` が置き場を返すとき、**自動でここを通る**（呼ぶ側の手間はゼロ）
  ・その道具を通さずに作ったものは、このコマンドで後から印を付けられる
    （`~/つみき出力/…` の短いパスでも通る）
  ・**まだ無いファイルでもよい**。`tsumiki_out.py` は「これから置く場所」を返すので、
    印はその時点で付く。光るのは実際にできたものだけ（サーバーが見に行ったときに
    無ければ候補にしない）＝置くのをやめても、幽霊は光らない
  ・置き場（00_Tsumiki）の外は受け付けない。プレビューがその中しか開けないため

## 置き場

`~/.tsumiki-remote/made.jsonl`（1行1件）。追記と刈り込みは**同じ錠**（`made.jsonl.lock`）を
取ってから行う。錠が無いと、刈り込み（全部読む→書き直す）のあいだに別の席が足した行が
消える（2026-09-16 反証役が再現：801行から40本同時に足して1件消えた）。
増えたら古いほうから刈る（800行を超えたら新しい400行だけ残す）。

⚠️ iCloud の上のパスをたどる（realpath）ので、**締め切りを付けて**呼ぶ。返ってこなければ
   たどらずに比べる（短いパスだと印が付かないだけで、道具は止まらない）。
"""
import fcntl, json, os, sys, threading, time

PREVIEW_ROOT = os.environ.get('TSUMIKI_PREVIEW_ROOT') or os.path.expanduser(
    '~/Library/Mobile Documents/com~apple~CloudDocs/Kodai/00_Tsumiki')
MADE_FILE = os.path.join(os.path.expanduser('~'), '.tsumiki-remote', 'made.jsonl')
LOCK_FILE = MADE_FILE + '.lock'
KEEP = 400          # 刈るときに残す行数
LIMIT = 800         # これを超えたら刈る
REAL_TIMEOUT = 1.0  # realpath を待つ上限（秒）
LOCK_TIMEOUT = 1.0  # 錠を待つ上限（秒）


def _real(path):
    """シンボリックリンクをたどった実体のパス。返ってこなければ、たどらない形を返す。"""
    box = {}

    def run():
        try:
            box['p'] = os.path.realpath(path)
        except Exception:
            pass
    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(REAL_TIMEOUT)
    return box.get('p') or os.path.abspath(path)


def _rel(path):
    """置き場からの相対パスにする。外のもの・たどれないものは None。"""
    try:
        full = _real(os.path.expanduser(path))
        root = _real(PREVIEW_ROOT)
        rel = os.path.relpath(full, root)
    except Exception:
        return None
    # ⚠️ 外に出るものを弾く。**区切りごとに** `..` を見る（`..foo.png` のような
    #    正当な名前まで弾かないため）。印はプレビューで開ける道なので、外を指させない
    parts = rel.split(os.sep)
    if os.path.isabs(rel) or '..' in parts:
        return None
    return '/'.join(parts)


class _Lock:
    """made.jsonl を触るあいだの錠。取れなければ ok=False（待ちすぎない）。"""

    def __enter__(self):
        self.fd = None
        self.ok = False
        try:
            os.makedirs(os.path.dirname(LOCK_FILE), exist_ok=True)
            self.fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o600)
            end = time.time() + LOCK_TIMEOUT
            while True:
                try:
                    fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.ok = True
                    break
                except BlockingIOError:
                    if time.time() > end:
                        break
                    time.sleep(0.02)
        except Exception:
            pass
        return self

    def __exit__(self, *a):
        if self.fd is not None:
            try:
                if self.ok:
                    fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
        return False


def _trim_locked():
    """錠を持っている前提で、増えすぎた古い行を落とす。"""
    try:
        with open(MADE_FILE, encoding='utf-8') as f:
            lines = f.readlines()
        if len(lines) <= LIMIT:
            return
        tmp = '%s.%d.tmp' % (MADE_FILE, os.getpid())   # 一時ファイルは席ごとに別の名前
        with open(tmp, 'w', encoding='utf-8') as f:
            f.writelines(lines[-KEEP:])
        os.replace(tmp, MADE_FILE)
    except Exception:
        pass


def pin(paths, by='tsumiki_out'):
    """印を付ける。付けられた数を返す。**呼び出し側を絶対に落とさない。**

    ⚠️ ここで例外を上げると、置き場を聞いただけの道具が道連れで死ぬ。
       印が付かないのは「光りにくくなる」だけなので、黙って諦めるほうが軽い。
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
        with _Lock() as lk:
            if not lk.ok:
                return 0            # 錠が取れない＝別の席が刈っている最中。今回は諦める
            os.makedirs(os.path.dirname(MADE_FILE), exist_ok=True)
            fd = os.open(MADE_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                for r in rows:
                    os.write(fd, (r + '\n').encode('utf-8'))
            finally:
                os.close(fd)
            _trim_locked()
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
