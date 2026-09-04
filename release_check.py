#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""release_check.py — 公開・お渡しの前に、身元がばれるものが混ざっていないか一括で見る。

なぜ要るか:
  実名の流出は3回起きている。
    2026-08-03  受託ソースごと、実在キャストの氏名・NG日が公開リポジトリに入っていた
    2026-08-30  配布ビルドの initial-data.json にお客様の本番データが同梱されていた
    2026-08-31  公開ずみ説明書の見本画像14枚に、実在のお客様の店名が写っていた

見るもの:
  1. 実名grep     渡した全ファイルから、探す語を行番号つきで出す
                  （タグまたぎ `山<span>田</span>`・空白またぎ・英字の大小も当てる）
  2. 画像の文字   shots_ocr.swift を呼ぶ。HTML/SVG に base64 で埋め込んだ画像も取り出して読む
  3. <style>      入れ子・閉じ忘れ／同じセレクタが後ろで丸ごと打ち消されていないか
  4. CSS変数      var(--x) で参照しているのに定義が無いもの／定義したのに未使用のもの
  5. QRの中身     qr_read.swift を呼んで実際に読み取り、URLをそのまま出す

■ この道具がいちばん気をつけていること＝「調べていないのに緑」を出さない
  - 画像以外は全部テキストとして開く（App.tsx・CHANGELOG・拡張子なしも対象）。
  - --names が空／--no-ocr で画像を渡した／OCRが失敗した ときは「クリーン」と言わない。
  - **画像が途中で切れていないかを確かめる**（PNGは IEND、JPEGは EOI）。
    ⚠️ `sips` は切れたPNGでもヘッダから幅を返すので「読めた」に見える。
    そして `shots_ocr.swift` は読めた枚数と関係なく「✓ N枚を読みました」と言って終了コード0を返す。
    この2つを重ねると、**中身が読めていないのに「入っていません」**になる（2026-09-04 実測）。
  - 中を読めない形式は、書類（PDF/Office/zip）は NG、フォント・動画は「見ていない」と明記する。
  - 行番号は必ず「そのファイルの行」を出す。

使い方:
  python3 release_check.py --names "山田,やまだ商店" app.html shot1.png qr.png
  python3 release_check.py --names-file names.txt *.html *.png *.css
  python3 release_check.py --names "…" --expect-url "tsumiki-license-gate" qr.png

終了コード: 0=クリーン / 1=1件でも見つかった・確かめられなかった / 2=引数や環境の問題

※ この道具はファイルを1つも書き換えない。読むだけ。
"""
import argparse
import base64
import binascii
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OCR = HERE / "shots_ocr.swift"
QRR = HERE / "qr_read.swift"          # 2026-08-31 から在る既存の道具。二重に持たない

IMG_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".tiff", ".heic", ".bmp"}
# 中を素のテキストとして読めない形式。NUL の有無で判定すると、本文を8進エスケープで持つ
# 全ASCIIのPDFが素通りする（実測）ので、拡張子で決め打ちする。
DOC_EXT = {".pdf", ".docx", ".xlsx", ".pptx", ".doc", ".xls", ".ppt",
           ".key", ".pages", ".numbers", ".zip", ".gz", ".tar", ".7z", ".bz2", ".xz", ".rar"}
MEDIA_EXT = {".ttf", ".otf", ".woff", ".woff2", ".eot", ".icns", ".ico",
             ".mp4", ".mov", ".mp3", ".wav", ".m4a", ".psd", ".ai", ".wasm", ".sqlite"}

TAG_RE = re.compile(r"<[^>]*>")
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
DATA_IMG_RE = re.compile(r"data:image/(png|jpe?g|gif|webp);base64,([A-Za-z0-9+/=\s]{64,})", re.I)


# ---------------------------------------------------------------- 読み取り

def read_lines(p: Path):
    """画像以外は全部テキストとして開く。読まなかったら (None, 理由)。"""
    ext = p.suffix.lower()
    if ext in DOC_EXT:
        return None, f"拡張子が {ext} なので中を読んでいません（書類・書庫）"
    if ext in MEDIA_EXT:
        return None, f"拡張子が {ext} なので中を読んでいません（フォント・音や動画）"
    try:
        raw = p.read_bytes()
    except Exception as e:
        return None, f"開けません（{e}）"
    if b"\x00" in raw[:8192]:
        return None, "中身がバイナリです"
    for enc in ("utf-8", "cp932"):
        try:
            return raw.decode(enc).splitlines(), None
        except UnicodeDecodeError:
            continue
    return None, "文字コードを判別できません"


def blank(pattern, text):
    """位置がずれないように、同じ長さの空白へ置き換える。"""
    return pattern.sub(lambda m: " " * len(m.group(0)), text)


# ---------------------------------------------------------------- 1. 実名grep

def check_names(text_files, names):
    """3通りで当てる＝①原文 ②タグを空白にした写し ③空白も除いた写し。
    タグまたぎ（`山<span>田</span>`）と空白またぎ（`山 田`）を拾うため。
    このリポジトリは「日本語＋タグ＋日本語」が35ファイル95箇所ある日常的な書き方（2026-09-04 実測）。"""
    hits, unread = [], []
    ascii_names = {n: n.casefold() for n in names if n.isascii()}
    for p in text_files:
        lines, why = read_lines(p)
        if lines is None:
            unread.append((p, why))
            continue
        for i, ln in enumerate(lines, 1):
            notag = blank(TAG_RE, ln)
            squashed = re.sub(r"\s+", "", notag)
            low = ln.casefold()
            for n in names:
                how = None
                if n in ln:
                    how = ""
                elif n in notag:
                    how = "（タグをまたいでいます）"
                elif n in squashed:
                    how = "（タグ・空白をまたいでいます）"
                elif n in ascii_names and ascii_names[n] in low:
                    how = "（大文字小文字が違います）"
                if how is not None:
                    j = max(ln.find(n), 0)
                    hits.append((p, i, n, ln[max(0, j - 30):j + len(n) + 40].strip(), how))
    return hits, unread


# ---------------------------------------------------------------- 2. 画像

def image_readable(p: Path):
    """sips が幅の数字を返すか。⚠️ 壊れたファイルでも終了コード0で `pixelWidth: <nil>` を返す。"""
    if not shutil.which("sips"):
        return None
    try:
        r = subprocess.run(["sips", "-g", "pixelWidth", str(p)],
                           capture_output=True, text=True, timeout=60)
        m = re.search(r"pixelWidth:\s*(\d+)", r.stdout)
        return bool(m) and int(m.group(1)) > 0
    except Exception:
        return False


def image_complete(p: Path):
    """最後まで届いているか。sips はヘッダだけで幅を返すので、切れた画像を見抜けない。
    切れたPNGは NSImage が上半分だけ描き、Vision は文字を1つも読まないのに
    shots_ocr.swift は「✓ 読みました・入っていません」と言う（2026-09-04 実測）。"""
    try:
        raw = p.read_bytes()
    except Exception:
        return False
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return raw.rstrip().endswith(b"IEND\xaeB`\x82")
    if raw[:2] == b"\xff\xd8":
        return raw.rstrip().endswith(b"\xff\xd9")
    return None            # 判定できない形式（gif/webp/heic など）


def extract_embedded(text_files, outdir: Path):
    """HTML・SVG に base64 で埋め込まれた画像を取り出す。
    拡張子だけで画像を決めると、単一HTMLに焼き込んだ見本画像を丸ごと見落とす。"""
    got = []
    for p in text_files:
        lines, _ = read_lines(p)
        if lines is None:
            continue
        src = "\n".join(lines)
        for k, m in enumerate(DATA_IMG_RE.finditer(src), 1):
            kind = m.group(1).lower().replace("jpeg", "jpg")
            try:
                data = base64.b64decode(re.sub(r"\s", "", m.group(2)), validate=False)
            except (binascii.Error, ValueError):
                continue
            if len(data) < 64:
                continue
            q = outdir / f"{p.stem}_埋め込み{k}.{kind}"
            q.write_bytes(data)
            got.append((q, p, src.count("\n", 0, m.start()) + 1))
    return got


def check_ocr(images, names):
    """戻り値: (状態, 出力行, 読めなかったもの[(path,理由)])"""
    if not OCR.exists():
        return "missing", [], []
    if not shutil.which("swift"):
        return "noswift", [], []
    bad_imgs = []
    ok_imgs = []
    for p in images:
        if image_readable(p) is False:
            bad_imgs.append((p, "画像として開けません"))
        elif image_complete(p) is False:
            bad_imgs.append((p, "途中で切れています（最後まで届いていない）"))
        else:
            ok_imgs.append(p)
    if not ok_imgs:
        return "none-readable", [], bad_imgs
    cmd = ["swift", str(OCR), ",".join(names)] + [str(p) for p in ok_imgs]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return "timeout", [], bad_imgs
    except FileNotFoundError:
        return "noswift", [], bad_imgs
    # shots_ocr.swift は開けなかった画像を stderr に書くだけで、終了コード0のまま
    # 「✓ N枚を読みました」と言う。stderr を必ず読む。
    for ln in (r.stderr or "").splitlines():
        if ln.startswith("読めません: "):
            bad_imgs.append((Path(ln[len("読めません: "):].strip()), "OCRが画像を開けませんでした"))
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    if r.returncode not in (0, 1):
        return "error", lines + [(r.stderr or "").strip()[:200]], bad_imgs
    return ("hit" if r.returncode == 1 else "clean"), lines, bad_imgs


# ---------------------------------------------------------------- CSS の下ごしらえ

STYLE_RE = re.compile(r"<style\b[^>]*>(.*?)</style>", re.S | re.I)
COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
LINK_CSS_RE = re.compile(r"<link[^>]+?href\s*=\s*[\"']([^\"']+\.css[^\"']*)[\"'][^>]*>", re.I)
URL_RE = re.compile(r"url\((?:[^()]|\([^()]*\))*\)", re.I)
GROUP_AT = {"@media", "@supports", "@container", "@layer", "@scope", "@document"}
VAR_DEF = re.compile(r"(--[A-Za-z0-9_-]+)\s*:")
VAR_USE = re.compile(r"var\(\s*(--[A-Za-z0-9_-]+)")
WHITE = re.compile(r"(?:^|[;{\s])color\s*:\s*(#fff\b|#ffffff\b|white\b)", re.I)
TEXTVAR_HINT = ("--on-", "--ink", "--fg", "--text", "--font-color", "--foreground")


def style_blocks(src):
    return [(m.start(1), m.group(1)) for m in STYLE_RE.finditer(src)]


def linked_css(p: Path, src: str):
    """<link rel=stylesheet> の先の .css を、同じフォルダから読む。
    読めれば ③④ に食わせる（外部CSSのページを毎回NGにしないため）。"""
    got, miss = [], []
    for m in LINK_CSS_RE.finditer(src):
        href = m.group(1).split("?")[0].split("#")[0]
        if re.match(r"^(https?:)?//", href):
            miss.append(href)
            continue
        q = (p.parent / href).resolve()
        if q.exists():
            try:
                got.append((q, q.read_text(encoding="utf-8", errors="replace")))
                continue
            except Exception:
                pass
        miss.append(href)
    return got, miss


def _skip_block(css, i):
    depth, n = 0, len(css)
    while i < n:
        if css[i] == "{":
            depth += 1
        elif css[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def norm_at(prelude):
    s = " ".join(prelude.split())
    return re.sub(r"\s*([:,()])\s*", r"\1", s).lower()


def iter_rules(css):
    """(文脈, セレクタ1つ, 宣言, セレクタの開始位置)。@media の中と外は別の文脈。"""
    out, stack = [], []
    i, n, start = 0, len(css), 0
    while i < n:
        c = css[i]
        if c == "{":
            raw = css[start:i]
            prelude = " ".join(raw.split())
            lead = len(raw) - len(raw.lstrip())
            if prelude.startswith("@"):
                if prelude.split()[0].lower() in GROUP_AT:
                    stack.append(norm_at(prelude))
                    i += 1
                    start = i
                    continue
                i = _skip_block(css, i)
                start = i
                continue
            j = _skip_block(css, i)
            for one in re.split(r",(?![^()]*\))", prelude):
                one = " ".join(one.split())
                if one:
                    out.append((tuple(stack), one, css[i + 1:j - 1], start + lead))
            i = j
            start = i
            continue
        if c == "}":
            if stack:
                stack.pop()
            i += 1
            start = i
            continue
        i += 1
    return out


def parse_decls(text):
    """{名前: !important か}。url(data:image/png;base64,…) の中の ; と : で割らないよう先に潰す。"""
    text = blank(URL_RE, text)
    out = {}
    for q in text.split(";"):
        if ":" not in q:
            continue
        name, val = q.split(":", 1)
        name = name.strip().lower()
        if name and not name.startswith(("/", "<")):
            out[name] = "!important" in val.lower()
    return out


# ---------------------------------------------------------------- 3. <style>

def css_sources(p: Path, src: str):
    """(表示名, ファイル内オフセット or None, CSS本文) の並び。外部CSSも含める。"""
    out = [(p, base, css) for base, css in style_blocks(src)]
    ext, miss = linked_css(p, src)
    for q, css in ext:
        out.append((q, 0, css))
    return out, miss


def check_style_dup(html_files):
    findings, examined = [], {}
    for p in html_files:
        src = p.read_text(encoding="utf-8", errors="replace")
        opens = len(re.findall(r"<style\b", src, re.I))
        closes = len(re.findall(r"</style\s*>", src, re.I))
        blocks = style_blocks(src)
        srcs, miss = css_sources(p, src)
        examined[p] = (opens, len(blocks), len(srcs), miss)

        nested = [b for _, b in blocks if re.search(r"<style\b", b, re.I)]
        if opens != closes or nested:
            findings.append((p, 0,
                             f"<style> の開き{opens}個 / 閉じ{closes}個"
                             + ("・入れ子あり" if nested else ""),
                             "入れ子や閉じ忘れがあると、直後の :root{} が丸ごと捨てられます"))
        if opens and not blocks:
            findings.append((p, 0, "⚠️ この道具が <style> の中身を1本も取り出せませんでした",
                             f"ソースには <style> が {opens}個あります。道具を直してください"))
        if not srcs:
            findings.append((p, 0, "CSSを1文字も見ていません",
                             f"<style> 0本・読めた外部CSS 0本"
                             + (f"（辿れなかった href: {', '.join(miss[:3])}）" if miss else "")
                             + "。③④はこのファイルについて何も確かめていません"))

        seen = {}
        for owner, base, b in srcs:
            css = blank(COMMENT_RE, b)
            body = owner.read_text(encoding="utf-8", errors="replace") if owner != p else src
            for ctx, sel, decls, off in iter_rules(css):
                d = parse_decls(decls)
                if not d:
                    continue
                line = (body.count("\n", 0, base + off) + 1) if owner == p \
                    else (css.count("\n", 0, off) + 1)
                key = (ctx, sel)
                if key in seen:
                    pd, pline, powner = seen[key]
                    dead = pd and all(k in d and (not imp or d[k]) for k, imp in pd.items())
                    if dead:
                        where = f"（{' '.join(ctx)} の中）" if ctx else ""
                        findings.append(
                            (powner, pline,
                             f"`{sel}`{where} の宣言が、あとの {line}行目"
                             + (f"（{owner.name}）" if owner != powner else "")
                             + "に丸ごと上書きされています",
                             f"先の {sorted(pd)} は1つも効いていません"))
                    seen[key] = ({**pd, **d}, line, owner)
                else:
                    seen[key] = (d, line, owner)
    return findings, examined


# ---------------------------------------------------------------- 4. CSS変数

def var_used_elsewhere(clean_src, name, css_pieces):
    """CSS の var() 以外で使われていないか。安全側に倒すが、**倒した理由を返す**。
    ⚠️ 語幹一致は「変数参照の形」でだけ見る。ただの語幹一致にすると
    `--c1`〜`--c9` が `'var(--c'` ひとつで全部永久に黙る（2026-09-04 実測）。
    ⚠️ コメントは呼ぶ側で空白化してから渡すこと。
    「--dead-a はもう使っていない」というメモで黙るのは安全側ではない。"""
    def outside(needle):
        return clean_src.count(needle) > sum(css.count(needle) for _, css in css_pieces)
    if outside(name):
        return "名前がCSS以外の場所にあります"
    stem = re.sub(r"\d+$", "", name)
    if stem != name and len(stem) >= 3:
        for form in (f"var({stem}", f"'{stem}", f'"{stem}'):
            if outside(form):
                return f"JSで名前を組み立てている形（{form}…）が見つかりました"
    return None


def check_css_vars(html_files):
    undef, unused, hidden, whites, nocss = [], [], [], [], []
    for p in html_files:
        src = p.read_text(encoding="utf-8", errors="replace")
        srcs, _ = css_sources(p, src)
        pieces = [(base, blank(COMMENT_RE, css)) for _, base, css in srcs]
        for m in re.finditer(r'style\s*=\s*"([^"]*)"', src):
            pieces.append((m.start(1), m.group(1)))
        if not pieces:
            nocss.append(p)
            continue
        # 「使っている」を数えるときは、CSSコメント・HTMLコメントを両方消した写しで見る
        clean_src = blank(HTML_COMMENT_RE, blank(COMMENT_RE, src))
        defs, uses = {}, {}
        for base, css in pieces:
            for m in VAR_DEF.finditer(css):
                defs.setdefault(m.group(1), src.count("\n", 0, base + m.start()) + 1)
            for m in VAR_USE.finditer(css):
                uses.setdefault(m.group(1), src.count("\n", 0, base + m.start()) + 1)
        for v, ln in uses.items():
            if v not in defs:
                undef.append((p, ln, v))
        for v, ln in defs.items():
            if v in uses:
                continue
            why = var_used_elsewhere(clean_src, v, pieces)
            (hidden if why else unused).append((p, ln, v, why) if why else (p, ln, v))
        if any(any(h in k for h in TEXTVAR_HINT) for k in defs):
            for base, css in pieces:
                for ctx, sel, decls, off in iter_rules(blank(COMMENT_RE, css)):
                    m = WHITE.search(blank(URL_RE, decls))
                    if not m:
                        continue
                    if re.search(r"background(-color)?\s*:[^;]*var\(", decls):
                        continue
                    whites.append((p, src.count("\n", 0, base + off) + 1,
                                   m.group(0).strip() + f"（{sel}）"))
    return undef, unused, hidden, whites, nocss


# ---------------------------------------------------------------- 5. QR

def check_qr(images, already_bad):
    if not QRR.exists():
        return "missing", [], []
    if not shutil.which("swift"):
        return "noswift", [], []
    skip = {p for p, _ in already_bad}
    out, errs = [], []
    for img in images:
        if img in skip:
            continue                    # ②で数えたものを二重に数えない
        try:
            r = subprocess.run(["swift", str(QRR), str(img)],
                               capture_output=True, text=True, timeout=300)
        except subprocess.TimeoutExpired:
            errs.append((img.name, "時間切れ"))
            continue
        got = [ln[len("QRの中身: "):] for ln in r.stdout.splitlines()
               if ln.startswith("QRの中身: ")]
        if got:
            out += [(img.name, g) for g in got]
        elif r.returncode not in (0, 2):
            errs.append((img.name, (r.stderr or r.stdout).strip()[:200] or f"終了コード{r.returncode}"))
    return ("found" if out else "none"), out, errs


# ---------------------------------------------------------------- 本体

def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--names", default="", help="探す語（カンマ区切り）")
    ap.add_argument("--names-file", default="")
    ap.add_argument("--expect-url", default="", help="QRのURLに必ず入っているべき語")
    ap.add_argument("--no-ocr", action="store_true")
    a = ap.parse_args()

    names = [x.strip() for x in a.names.split(",") if x.strip()]
    if a.names_file:
        f = Path(a.names_file).expanduser()
        if not f.exists():
            print(f"✗ ありません: {f}", file=sys.stderr)
            return 2
        names += [l.strip() for l in f.read_text(encoding="utf-8").splitlines() if l.strip()]

    paths, missing = [], []
    for f in a.files:
        p = Path(f).expanduser()
        (paths if p.exists() else missing).append(p)
    if missing:
        for p in missing:
            print(f"✗ ファイルがありません: {p}", file=sys.stderr)
        return 2

    images = [p for p in paths if p.suffix.lower() in IMG_EXT]
    text_files = [p for p in paths if p not in images]
    html_files = [p for p in paths if p.suffix.lower() in (".html", ".htm", ".svg")]

    with tempfile.TemporaryDirectory() as td:
        embedded = extract_embedded(text_files, Path(td))
        all_images = images + [q for q, _, _ in embedded]
        rc = run(a, names, paths, images, all_images, embedded, text_files,
                 [p for p in html_files if p.suffix.lower() in (".html", ".htm")])
    return rc


def run(a, names, paths, images, all_images, embedded, text_files, html_files):
    print(f"■ 公開前チェック  テキスト{len(text_files)}本 / 画像{len(images)}枚"
          + (f" ＋ 埋め込み画像{len(embedded)}枚" if embedded else ""))
    bad = 0
    if names:
        print(f"  探す語: {' / '.join(names)}")
    else:
        print("  🔴 --names が空です。**実名を1語も探していません。**")
        bad += 1
    if embedded:
        for q, owner, ln in embedded[:6]:
            print(f"  ・{owner.name}:{ln} に埋め込まれた画像を取り出しました → {q.name}")
    print()

    # ① ----------------------------------------------------------------
    print("① 実名grep（テキストの中）")
    unchecked_media = []
    if not names:
        print("   🔴 飛ばしました（--names が空）＝検査していません")
    elif not text_files:
        print("   ・テキストファイルが渡されていません")
    else:
        hits, unread = check_names(text_files, names)
        if hits:
            bad += len(hits)
            print(f"   🔴 {len(hits)}件")
            for p, ln, n, snip, how in hits[:40]:
                print(f"      {p}:{ln}  「{n}」{how}  … {snip}")
            if len(hits) > 40:
                print(f"      … ほか {len(hits) - 40}件")
        docs = [(p, w) for p, w in unread if p.suffix.lower() in DOC_EXT or "バイナリ" in (w or "")
                or "文字コード" in (w or "") or "開けません" in (w or "")]
        media = [(p, w) for p, w in unread if (p, w) not in docs]
        if docs:
            bad += len(docs)
            print(f"   🔴 中を読めなかったファイル {len(docs)}本＝**検査できていません**")
            for p, w in docs:
                print(f"      {p}  … {w}")
            print("      PDF・Office等は、別途テキストを抜き出して渡してください。")
        if media:
            unchecked_media = media
            print(f"   ⚠️ 中を見ていないファイル {len(media)}本（フォント・音や動画）")
            for p, w in media:
                print(f"      {p}  … {w}")
        if not hits and not docs:
            print(f"   ✓ {len(text_files) - len(unread)}本を見て0件"
                  "（タグまたぎ・空白またぎ・英字の大小も当てています）")
    print()

    # ② ----------------------------------------------------------------
    print("② 画像の中の文字（OCR）")
    ocr_bad = []
    if not all_images:
        print("   ・画像が渡されていません（埋め込みも0枚）")
    elif a.no_ocr:
        bad += 1
        print(f"   🔴 飛ばしました（--no-ocr）＝画像 {len(all_images)}枚を検査していません")
        print("      画像に焼かれた文字は grep で見つかりません"
              "（2026-08-31・公開ずみ説明書の見本14枚に実在の店名）。")
    elif not names:
        print("   🔴 飛ばしました（--names が空）＝検査していません")
    else:
        st, lines, ocr_bad = check_ocr(all_images, names)
        if ocr_bad:
            bad += len(ocr_bad)
            print(f"   🔴 読めなかった画像 {len(ocr_bad)}枚＝**検査できていません**")
            for p, why in ocr_bad:
                print(f"      {p.name}  … {why}")
        if st in ("missing", "noswift", "timeout", "error", "none-readable"):
            bad += 1
            msg = {"missing": f"{OCR} がありません", "noswift": "swift がありません",
                   "timeout": "時間切れ", "error": "OCRが異常終了しました",
                   "none-readable": "読める画像が1枚もありませんでした"}[st]
            print(f"   🔴 {msg}＝画像は検査できていません")
            for l in lines:
                print(f"      {l}")
        else:
            for l in lines:
                print("   " + l)
            print(f"   （最後まで届いていて読めた画像 {len(all_images) - len(ocr_bad)}枚 / "
                  f"渡された {len(all_images)}枚）")
            if st == "hit":
                bad += 1
    print()

    # ③ ----------------------------------------------------------------
    print("③ <style> の二重・打ち消し")
    if not html_files:
        print("   ・HTMLが渡されていません")
    else:
        f3, examined = check_style_dup(html_files)
        if f3:
            bad += len(f3)
            print(f"   🔴 {len(f3)}件")
            for p, ln, what, why in f3[:20]:
                print(f"      {p}{':' + str(ln) if ln else ''}  {what}")
                print(f"        → {why}")
        else:
            tot = sum(v[2] for v in examined.values())
            print(f"   ✓ HTML {len(html_files)}本・CSS {tot}本（<style>＋読めた外部CSS）を見て0件")
        for p, (opens, blocks, srcs, miss) in examined.items():
            if srcs and (opens == 0 or miss):
                print(f"   ・{p.name}: <style> {opens}本＋外部CSS {srcs - blocks}本を読みました"
                      + (f"（辿れなかった href {len(miss)}本: {', '.join(miss[:2])}）" if miss else ""))
    print()

    # ④ ----------------------------------------------------------------
    print("④ CSS変数の生死")
    if not html_files:
        print("   ・HTMLが渡されていません")
    else:
        undef, unused, hidden, whites, nocss = check_css_vars(html_files)
        if undef:
            bad += len(undef)
            print(f"   🔴 参照しているのに定義が無い変数 {len(undef)}件（その指定は無効）")
            for p, ln, v in undef[:20]:
                print(f"      {p}:{ln}  var({v})")
        elif len(nocss) < len(html_files):
            print("   ✓ 参照しているのに定義が無い変数 0件")
        if whites:
            print(f"   ⚠️ color の白の直書き {len(whites)}件（変数を作ったのに置き換え漏れ）")
            for p, ln, t in whites[:10]:
                print(f"      {p}:{ln}  {t}")
        if unused:
            print(f"   ・使われていない変数 {len(unused)}件（参考。消してよいとは限らない）")
            print("      " + ", ".join(v for _, _, v in unused[:12])
                  + (" …" if len(unused) > 12 else ""))
        if hidden:
            print(f"   ・伏せた変数 {len(hidden)}件（CSSからは未使用だが、他で使われている形跡あり）")
            for p, ln, v, why in hidden[:8]:
                print(f"      {v} … {why}")
    print()

    # ⑤ ----------------------------------------------------------------
    print("⑤ QRの中身")
    if not all_images:
        print("   ・画像が渡されていません")
        if a.expect_url:
            bad += 1
            print(f"   🔴 --expect-url「{a.expect_url}」を確かめられていません（画像が0枚）")
    else:
        st, qrs, errs = check_qr(all_images, ocr_bad)
        if errs:
            bad += len(errs)
            print(f"   🔴 読めなかった画像 {len(errs)}枚＝確かめられていません")
            for k, v in errs:
                print(f"      {k}: {v}")
        if st in ("missing", "noswift"):
            bad += 1
            print(f"   🔴 {QRR if st == 'missing' else 'swift'} がありません＝QRを読んでいません")
        elif st == "none":
            looked = len(all_images) - len(ocr_bad) - len(errs)
            print(f"   ・読めた {looked}枚にQRは見つかりませんでした（渡された {len(all_images)}枚）")
            if a.expect_url:
                bad += 1
                print(f"   🔴 --expect-url「{a.expect_url}」を渡されたのに、QRが1枚も見つかりません")
        else:
            for name, payload in qrs:
                print(f"   {name}\n      → {payload}")
                if a.expect_url:
                    if a.expect_url in payload:
                        print(f"      ✓ 「{a.expect_url}」が入っています")
                    else:
                        print(f"      🔴 「{a.expect_url}」が入っていません")
                        bad += 1
            print("   ※ 読み取った実物です。組み立てた推測ではありません。")
            print("   ※ そのURLが本当に開けるかは確かめていません（外へ通信しないため）。")
    print()

    if bad:
        print(f"判定: 🔴 NG（{bad}件）。出す前に直してください。")
        print("     ※ 「検査できていない」も NG に数えています（黙って緑にしないため）＝①〜⑤すべて。")
        return 1
    tail = f"・中を見ていないファイル {len(unchecked_media)}本あり" if unchecked_media else ""
    print(f"判定: ✓ クリーン（見た範囲では0件{tail}）")
    print("※ 見たのは渡されたファイルだけです。渡し忘れたファイルは検査されていません。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
