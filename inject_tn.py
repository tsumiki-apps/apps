# -*- coding: utf-8 -*-
"""単一HTMLアプリに「つみき用ネイティブ部品」(tn.css + tn.js) を注入する。

何をするか:
  tn.css を <style>、tn.js を <script> にして、ひとつのマーカーで囲み
  </head> の直前に差し込む。もう一度走らせると**古いブロックを最新版で置き換える**
  （何度やっても同じ結果）。
  クラス名はすべて tn- 始まり、JSは window.TN の1つだけなので、
  アプリが元から持っているCSS・JSとぶつからない。

  tn.js が入るもの:
    TN.rnd(i,k)      決定論の擬似乱数（Math.random() の置き換え）
    TN.reveal(id,fn) 見えたら再生・押したらもう一度（タイマーの掃除つき）
  <script> は関数を定義するだけで、読み込み時にDOMを触らない。だから <head> でよい。

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
JS_PATH = HERE / "tn.js"

OPEN_RE = re.compile(r"<!-- tsumiki-native-parts(?: [^>]*)? -->")
BLOCK_RE = re.compile(
    r"[ \t]*<!-- tsumiki-native-parts(?: [^>]*)? -->.*?<!-- /tsumiki-native-parts -->\n?",
    re.DOTALL,
)
HEAD_RE = re.compile(r"</head>", re.IGNORECASE)
BODY_RE = re.compile(r"</body>", re.IGNORECASE)


def load_parts():
    """tn.css と tn.js を読む。版の8桁は2つを合わせた内容から作る。"""
    if not CSS_PATH.exists():
        sys.exit(f"! {CSS_PATH} が見つかりません。inject_tn.py と同じ場所に置いてください。")
    css = CSS_PATH.read_text(encoding="utf-8").strip()
    # tn.js は無くても動く（CSSだけ注入する）。あれば一緒に入れる。
    js = JS_PATH.read_text(encoding="utf-8").strip() if JS_PATH.exists() else ""
    stamp = hashlib.sha256((css + "\n\x00\n" + js).encode("utf-8")).hexdigest()[:8]
    return css, js, stamp


def make_block(css, js, stamp):
    out = (
        f"<!-- tsumiki-native-parts sha={stamp} -->\n"
        "<style>\n" + css + "\n</style>\n"
    )
    if js:
        out += "<script>\n" + js + "\n</script>\n"
    out += "<!-- /tsumiki-native-parts -->\n"
    return out


def current_stamp(html):
    """入っていれば版の8桁、入っていなければ None。"""
    m = OPEN_RE.search(html)
    if not m:
        return None
    got = re.search(r"sha=([0-9a-f]{8})", m.group(0))
    return got.group(1) if got else "unknown"


def inject(path, css, js, stamp):
    html = Path(path).read_text(encoding="utf-8")
    block = make_block(css, js, stamp)
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
    print(f"\n手元の tn.css + tn.js は sha={stamp}")


def main():
    css, js, stamp = load_parts()
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
        inject(path, css, js, stamp)


if __name__ == "__main__":
    main()
