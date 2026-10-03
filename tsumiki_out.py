#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""やり取りで作った物を置く場所を決める（セッションごとに1つのフォルダ）。

    python3 ~/制作物/tsumiki_out.py 返信.png            このセッションのフォルダに置く場所
    python3 ~/制作物/tsumiki_out.py 返信.png --new      前の物を残して「返信(2).png」に置く
    python3 ~/制作物/tsumiki_out.py --dir               このセッションのフォルダ（無ければ作る）
    python3 ~/制作物/tsumiki_out.py --name              フォルダ名だけ
    python3 ~/制作物/tsumiki_out.py --session 名前 …    フォルダ名を自分で決める（最初の1回だけ効く）
    python3 ~/制作物/tsumiki_out.py --list              受け取り口の中のフォルダを並べる

出るのは**絶対パス1行だけ**（--name / --list を除く）。そのまま > や Write の宛先に使える。

置き方（2026-09-27 本人が決めた。決まりの正本は ~/制作物/docs/置き場.md）：

    Kodai/04_つみきリモート制作物/<セッションの名前>/<ファイル>

  ・セッションの名前 … つみきリモートの席の札に出る題名。名札（@tsumiki_title）があればそれ、
    無ければ Claude Code の題名（/rename の題名 → 自動の題名）。
  ・**名前は最初に置いた時点で固定する**（控え＝~/.cache/tsumiki/out_sessions.json、キーはセッションID）。
    自動の題名は途中で変わることがあり、変わるたびにフォルダが増えないようにするため。
  ・同じ名前のフォルダが別のセッションのもの（または本人が作ったもの）なら「名前(2)」にする。
  ・種類のフォルダは作らない（2026-09-27 本人）。フォルダの中はファイルだけ。
  ・同じセッションで同じ名前を聞けば同じ場所（直して上書き）。前の物を残したいときは --new。
  ・2026-09-27 より前の物は、つみきは Kodai/00_Tsumiki の番号フォルダ、Apple は Kodai/02_Apple/2026、
    私用は Kodai/05_Personal/2026 へ仕分けた（対応表＝~/.tsumiki-remote/moved.json）。

前の書き方（<プロジェクト> <成果物> <ファイル名>）で呼ばれても止めない。最後のファイル名だけを使い、
書き方を注意する（ほかのスキルや手順書がまだ前の形で呼ぶことがあるため）。

⚠️ 置き場の実体は iCloud。同期の読み出しが返らないことがあるので、必ず制限時間を付ける。
⚠️ 試すときは TSUMIKI_OUT_ROOT に作業用のフォルダ、TSUMIKI_OUT_MAP に控えの置き場を渡す
   （本物の iCloud にフォルダを作らない・本物の控えを汚さない）。
"""
import fcntl, json, os, re, subprocess, sys, threading, time, unicodedata

# 置いたものに印を付ける（つみきリモートで、履歴の中の名前を押して開くための索引）。
# 同じフォルダに無い・壊れている場合でも、この道具は動き続ける
try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from tsumiki_pin import pin as pin_made
except Exception:
    def pin_made(paths):
        return 0

TESTING = bool(os.environ.get('TSUMIKI_OUT_ROOT'))
ROOT = os.environ.get('TSUMIKI_OUT_ROOT') or os.path.expanduser(
    '~/Library/Mobile Documents/com~apple~CloudDocs/Kodai/04_つみきリモート制作物')
MAP_FILE = os.environ.get('TSUMIKI_OUT_MAP') or os.path.expanduser('~/.cache/tsumiki/out_sessions.json')
ARCHIVE = '_これまでの制作物'   # 2026-09-27 に廃止した保管庫の名前。新しいセッションに使わせない
READ_TIMEOUT = 5.0
# 空白は「_」にする（2026-10-03）。iPad のファイルアプリは、パスのフォルダ名に空白があると
# shareddocuments:// で中まで進めず「最近使った項目」で止まる（本人の iPad で、空白ありのフォルダは
# 止まり、空白なしのフォルダは作ったばかりのファイルでも開けた）。iPhone は空白があっても開ける
SPACE_RE = re.compile(r'[\s_]*\s[\s_]*')   # 空白（全角・NBSP・タブも）と、その前後の _ をまとめて1つの _ に
# 札の頭に Claude Code が付ける動きの印（✳ ✻ など）と点字の回転
SPIN_RE = re.compile(r'^[\s⠀-⣿✳✻✽✶✢·•*⏺◐◓◑◒]+')


def within(fn, timeout=READ_TIMEOUT):
    """制限時間つきで呼ぶ。返らなければ ('timeout', None)"""
    box = {}

    def run():
        try:
            box['v'] = fn()
        except Exception as e:
            box['e'] = e
    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(timeout)
    if 'v' in box:
        return 'ok', box['v']
    return ('error', box['e']) if 'e' in box else ('timeout', None)


def clean_name(s):
    """フォルダ名に使える形。/ : は「・」に、頭の点や動きの印は落とす。長すぎれば切る"""
    s = unicodedata.normalize('NFC', str(s or ''))
    s = SPIN_RE.sub('', s).strip()
    s = re.sub(r'[/:\\\n\r\t]+', '・', s)
    s = s.lstrip('.').strip()
    s = SPACE_RE.sub('_', s)
    return s[:60].rstrip('_ ')     # 頭の _ は落とさない（ARCHIVE の守りが効くように）


def tmux(*args):
    if not os.environ.get('TMUX'):
        return ''
    try:
        r = subprocess.run(['tmux'] + list(args), capture_output=True, text=True, timeout=3)
        return r.stdout.strip() if r.returncode == 0 else ''
    except Exception:
        return ''


def transcript_titles(sid):
    """Claude Code の会話記録から題名を拾う。(/rename の題名, 自動の題名)。新しいほうを採る"""
    custom = ai = ''
    base = os.path.expanduser('~/.claude/projects')
    try:
        dirs = os.listdir(base)
    except Exception:
        return custom, ai
    for d in dirs:
        f = os.path.join(base, d, sid + '.jsonl')
        if not os.path.isfile(f):
            continue
        try:
            with open(f, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    if 'itle"' not in line:
                        continue
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    if o.get('type') == 'custom-title' and o.get('customTitle'):
                        custom = o['customTitle']
                    elif o.get('type') == 'ai-title' and o.get('aiTitle'):
                        ai = o['aiTitle']
        except Exception:
            pass
        break
    return custom, ai


def session_title(sid):
    """つみきリモートの札と同じ順で題名を決める。取れなければ ''"""
    pane = os.environ.get('TMUX_PANE', '')
    if pane:
        seat = tmux('display', '-p', '-t', pane, '#{session_name}')
        label = tmux('show-options', '-t', seat, '-qv', '@tsumiki_title') if seat else ''
        if clean_name(label):
            return clean_name(label)
    if sid:
        custom, ai = transcript_titles(sid)
        for t in (custom, ai):
            if clean_name(t):
                return clean_name(t)
    if pane:
        t = clean_name(tmux('display', '-p', '-t', pane, '#{pane_title}'))
        # 題名が付く前の札は機械の名前（ホスト名）なので使わない
        if t and t != clean_name(os.uname().nodename.split('.')[0]) and not t.startswith('Claude Code'):
            return t
    return ''


class Locked:
    """控え（out_sessions.json）を触るあいだの錠"""

    def __enter__(self):
        os.makedirs(os.path.dirname(MAP_FILE), exist_ok=True)
        self.fd = os.open(MAP_FILE + '.lock', os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def load_map():
    try:
        with open(MAP_FILE, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def save_map(m):
    tmp = MAP_FILE + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(m, f, ensure_ascii=False, indent=0)
    os.replace(tmp, MAP_FILE)


def exists(path):
    st, v = within(lambda: os.path.exists(path))
    if st != 'ok':
        raise TimeoutError('iCloud が返りません: ' + path)
    return v


def session_dir(forced, notes):
    """このセッションのフォルダ（作る）。名前は控えで固定する"""
    sid = os.environ.get('CLAUDE_CODE_SESSION_ID', '')
    # Claude の外（手で打った・ほかの道具）から呼ばれたときは、tmux の席ごと＋日付で1つ
    key = sid or ('seat:' + (tmux('display', '-p', '#{session_name}') or 'none') + ':' + time.strftime('%Y-%m-%d'))
    with Locked():
        m = load_map()
        got = m.get(key)
        if got and not forced:
            name = got['name']
        else:
            want = clean_name(forced) if forced else session_title(sid)
            if not want:
                want = 'セッション_' + time.strftime('%Y-%m-%d_%H%M')
                notes.append('題名が取れなかったので「%s」にしました（--session 名前 で決められます）' % want)
            if want == ARCHIVE:
                want += '_'
            taken = {v['name'] for k, v in m.items() if k != key}
            name, n = want, 2
            while name in taken or (not got or got['name'] != name) and exists(os.path.join(ROOT, name)):
                name = '%s(%d)' % (want, n)     # 空白を入れない（→ SPACE_RE）
                n += 1
            if got and got['name'] != name:
                notes.append('フォルダ名を「%s」→「%s」に決め直しました（前のフォルダはそのまま）' % (got['name'], name))
            m[key] = {'name': name, 'at': time.time()}
            save_map(m)
    d = os.path.join(ROOT, name)
    st, _ = within(lambda: os.makedirs(d, exist_ok=True))
    if st != 'ok':
        raise TimeoutError('フォルダを作れません（iCloud が返りません）: ' + d)
    return d


def free_name(d, fname):
    """前の物を残す名前：返信.png → 返信(2).png → 返信(3).png（空白を入れない → SPACE_RE）"""
    stem, ext = os.path.splitext(fname)
    n = 2
    cand = fname
    while exists(os.path.join(d, cand)):
        cand = '%s(%d)%s' % (stem, n, ext)
        n += 1
    return cand


def fail(msg):
    sys.stderr.write(msg + '\n')
    return 2


def main(argv):
    notes = []
    forced = None
    if '--session' in argv:
        i = argv.index('--session')
        if i + 1 >= len(argv):
            return fail('--session のあとに名前を書いてください')
        forced = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    flags = {a for a in argv if a.startswith('--')}
    args = [a for a in argv if not a.startswith('--')]

    if '--list' in flags or '-l' in argv:
        st, names = within(lambda: sorted(n for n in os.listdir(ROOT) if not n.startswith('.')))
        if st != 'ok':
            return fail('受け取り口の一覧が読めません（iCloud が返らないか、Mac 側の許可が切れています）')
        print('\n'.join(names))
        return 0
    if '--versions' in flags:
        return fail('版（V）はやめました（2026-09-27）。前の物を残すときは <ファイル名> --new で「名前(2)」になります')

    # 前の書き方：<プロジェクト> [<成果物>] <ファイル名>。ファイル名らしい最後の1つだけを使う
    if len(args) > 1:
        notes.append('置き方が変わりました（2026-09-27）。次からは tsumiki_out.py <ファイル名> [--new] で呼んでください。'
                     'プロジェクト名・成果物名（%s）は使いません' % ' / '.join(args[:-1]))
        args = args[-1:]
    if args and not re.search(r'\.[A-Za-z0-9]{1,6}$', args[0]):
        # プロジェクト名だけで呼ばれた（前の書き方）＝このセッションのフォルダを返す
        notes.append('「%s」はファイル名に見えないので、このセッションのフォルダを返します' % args[0])
        args = []

    try:
        d = session_dir(forced, notes)
    except TimeoutError as e:
        return fail(str(e))

    if '--name' in flags:
        print(os.path.basename(d))
    elif not args:
        print(d)
    else:
        fname = unicodedata.normalize('NFC', args[0]).strip()
        if SPACE_RE.search(fname):
            old = fname
            fname = SPACE_RE.sub('_', fname)
            notes.append('名前の空白は「_」にしました（iPad のファイルアプリで開けないため）：%s → %s' % (old, fname))
        if not fname or '/' in fname or fname in ('.', '..'):
            return fail('ファイル名として使えません: %r' % args[0])
        try:
            if '--new' in flags:
                old = fname
                fname = free_name(d, fname)
                if fname != old:
                    notes.append('前の「%s」を残して「%s」にしました' % (old, fname))
        except TimeoutError as e:
            return fail(str(e))
        out = os.path.join(d, fname)
        # つみきリモートで、履歴の中のこの名前を押したら開けるようにする印。
        # ⚠️ まだファイルは無い（ここで返すのは「これから置く場所」）。光るのは実際にできたものだけ。
        # ⚠️ 試しの置き場のときは付けない（印の控えは1つしかなく、本物の画面で光ってしまう）
        if not TESTING:
            pin_made([out])
        print(out)
    for n in notes:
        sys.stderr.write('（%s）\n' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
