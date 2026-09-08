# -*- coding: utf-8 -*-
"""単一HTMLアプリに「つみき用ネイティブ部品CSS」(tn.css) を注入する。

何をするか:
  tn.css の中身を <style> ごと </head> の直前に差し込む。マーカーで囲むので、
  もう一度走らせると**古いブロックを最新の tn.css で置き換える**（何度やっても同じ結果）。
  クラス名はすべて tn- 始まりなので、アプリが元から持っているCSSとぶつからない。

使い方:
  python3 inject_tn.py <HTML> [<HTML> ...]   注入する／最新版に更新する
  python3 inject_tn.py --check [<HTML> ...]  入っているか・版が古くないかを見るだけ（既定は*.html全部）
  python3 inject_tn.py --remove <HTML> ...   取り外す

置き場の注意:
  戻るボタン(inject_backbtn.py)と違い、これは**外部配布(~/tsumiki-tools)に入れてもよい**。
  見た目の部品だけで、つみきへ戻る導線や屋号は含まれていない。
"""
import glob
import hashlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CSS_PATH = HERE / "tn.css"

OPEN_RE = re.compile(r"<!-- tsumiki-native-parts(?: [^>]*)? -->")
BLOCK_RE = re.compile(
    r"[ \t]*<!-- tsumiki-native-parts(?: [^>]*)? -->.*?<!-- /tsumiki-native-parts -->\n?",
    re.DOTALL,
)
HEAD_RE = re.compile(r"</head>", re.IGNORECASE)
BODY_RE = re.compile(r"</body>", re.IGNORECASE)


def load_css():
    if not CSS_PATH.exists():
        sys.exit(f"! {CSS_PATH} が見つかりません。tn.css と同じ場所に置いてください。")
    css = CSS_PATH.read_text(encoding="utf-8").strip()
    stamp = hashlib.sha256(css.encode("utf-8")).hexdigest()[:8]
    return css, stamp


def make_block(css, stamp):
    return (
        f"<!-- tsumiki-native-parts sha={stamp} -->\n"
        "<style>\n" + css + "\n</style>\n"
        "<!-- /tsumiki-native-parts -->\n"
    )


def current_stamp(html):
    """入っていれば版の8桁、入っていなければ None。"""
    m = OPEN_RE.search(html)
    if not m:
        return None
    got = re.search(r"sha=([0-9a-f]{8})", m.group(0))
    return got.group(1) if got else "unknown"


def inject(path, css, stamp):
    html = Path(path).read_text(encoding="utf-8")
    block = make_block(css, stamp)
    now = current_stamp(html)

    if now is not None:
        if now == stamp:
            print(f"- {path}: すでに最新（sha={stamp}）")
            return
        new = BLOCK_RE.sub(lambda _: block, html, count=1)
        Path(path).write_text(new, encoding="utf-8")
        print(f"✓ {path}: {now} → {stamp} に更新")
        return

    if HEAD_RE.search(html):
        new = HEAD_RE.sub(block + "</head>", html, count=1)
        where = "</head> の直前"
    elif BODY_RE.search(html):
        new = BODY_RE.sub(block + "</body>", html, count=1)
        where = "</body> の直前（<head> が無いので）"
    else:
        print(f"! {path}: </head> も </body> も見つからず、注入できませんでした")
        return

    Path(path).write_text(new, encoding="utf-8")
    print(f"✓ {path}: 注入しました（{where}・sha={stamp}）")


def remove(path):
    html = Path(path).read_text(encoding="utf-8")
    if current_stamp(html) is None:
        print(f"- {path}: 入っていません")
        return
    Path(path).write_text(BLOCK_RE.sub("", html, count=1), encoding="utf-8")
    print(f"✓ {path}: 取り外しました")


def check(paths, stamp):
    found = 0
    for path in paths:
        try:
            html = Path(path).read_text(encoding="utf-8")
        except OSError as e:
            print(f"! {path}: 読めません（{e}）")
            continue
        got = current_stamp(html)
        if got is None:
            continue
        found += 1
        if got == stamp:
            print(f"✓ {path}: 最新（sha={stamp}）")
        else:
            print(f"△ {path}: 古い版（{got}）→ python3 inject_tn.py {path} で更新")
    if found == 0:
        print("- どのファイルにも入っていません")
    print(f"\n手元の tn.css は sha={stamp}")


def main():
    css, stamp = load_css()
    args = sys.argv[1:]

    if not args:
        print(__doc__)
        sys.exit(0)

    if args[0] == "--check":
        targets = args[1:] or sorted(glob.glob("*.html"))
        check(targets, stamp)
        return

    if args[0] == "--remove":
        targets = args[1:]
        if not targets:
            sys.exit("! --remove には外すファイルを指定してください")
        for path in targets:
            remove(path)
        return

    for path in args:
        if not Path(path).exists():
            print(f"! {path}: ファイルがありません")
            continue
        inject(path, css, stamp)


if __name__ == "__main__":
    main()
