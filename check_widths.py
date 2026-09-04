#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_widths.py — 8幅の検品を、その場の即興ではなく「走る道具」にする。

なぜ要るか（やさしく言うと）:
  つみきのアプリは毎回 8つの幅すべてで崩れないことを確かめる決まりになっている
  （~/.claude/CLAUDE.md の「8幅」）。ところが確かめ方は文章でしか書かれていないので、
  毎回その場で JS を書き直していた。書き直すたびに、過去にハマった罠を思い出さないと
  検査そのものが嘘になる。この道具は、その罠をコードに固定したもの。

測るもの（幅ごと）:
  1. 横はみ出し      documentElement.clientWidth をはみ出している要素
  2. タップ44px未満   押せるもの（タグ・role・onclick・tabindex・cursor:pointer）
  3. 入力欄16px未満   input / textarea / select の font-size
  4. 縦の切れ         overflow が hidden/clip の入れ物の中で、文字が切れている要素
  5. 表のスクロール枠  はみ出している <table> が overflow-x:auto の中に入っているか
  加えて 1回だけ: CSS に 100vh があって 100dvh が無いか

■ この道具がいちばん気をつけていること＝「調べていないのに緑」を出さない
  - 指定した幅で本当に見ているか（documentElement.clientWidth）を毎回確かめる。
    window.innerWidth は中身がはみ出すと一緒に広がるので物差しに使えない
    （実測: 375指定で innerWidth=1200 / clientWidth=375）。
  - 開いたページが本当に渡されたファイルか（location.href）を毎回確かめる。
  - 見えている要素が0／押せるものが0なら、OKではなく NG（読み込めていない疑い）。
  - CSSを1文字も読めなかったときは、そう言う。
  - 途中で例外が出たら終了コード2（＝「崩れあり」の1と混ぜない）。

安全のために守っていること:
  - ローカル専用。file:// と localhost / 127.0.0.1 だけを受け付け、
    本番の http(s):// URL は「読み取りだけのつもり」でも実行せずに拒否する。
  - 外への通信を止める。http(s) は CDP の Fetch で遮断し、ws/wss は Network.setBlockedURLs で
    遮断する（Fetch ドメインは WebSocket のハンドシェイクを止められないため。
    Supabase Realtime は WebSocket なので、ここを抜くと本番へつながる）。
    遮断した相手は最後にホスト名で報告する。
  - ページに書き込まない。クリックしない。input を発火させない。style も差し込まない。
  - Chrome は毎回、空きポート＋そのプロセス専用のプロファイルで起動し、
    自分で作ったタブだけを見る。終わったらプロファイルごと捨てる。
    （固定ポートだと、別の検品が開いていたタブを乗っ取って
      「別のアプリの画面を、このファイルの結果として」報告する事故が起きる）

分かっている限界（報告にも出る）:
  - 閉じているシート・ダイアログの中身は測れない（開くにはクリックが要り、それは禁止のため）。
    そのぶんは「DOMにN個・見えているのはM個」として毎回報告する。
  - 渡されたファイルが持っている状態しか見ていない。
    「偽データは、実データにある状態を隠す」（mistakes.md）。

使い方:
  python3 check_widths.py <HTMLのパス | file:// | http://localhost:...>
  python3 check_widths.py app.html --widths 375,768
  python3 check_widths.py report.html --allow-no-controls   # 押せるものが無い静的ページ
  python3 check_widths.py app.html --json

終了コード: 0=全幅OK / 1=1つでもNG / 2=引数・環境・実行時の問題（拒否と例外を含む）
"""
import argparse
import contextlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from urllib.parse import unquote, urlparse

try:
    import websocket  # websocket-client
except ImportError:
    print("✗ websocket-client が要ります: pip3 install websocket-client", file=sys.stderr)
    sys.exit(2)

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

WIDTHS = [
    (320, 812), (375, 812), (390, 844), (430, 932),
    (768, 1024), (1024, 768), (1440, 900), (1920, 1080),
]
MOBILE_UNDER = 768
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}


def free_port():
    with contextlib.closing(socket.socket()) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def resolve_target(arg: str):
    """ローカルだけを通す。本番URLは拒否する（読み取りのつもりでも拒否側に倒す）。"""
    if re.match(r"^https?://", arg, re.I):
        host = (urlparse(arg).hostname or "").lower()
        if host in LOCAL_HOSTS or host.endswith(".localhost"):
            return arg, f"localhost（{host}）"
        return None, (
            f"本番URLは受け付けません: {arg}\n"
            "  この道具はローカル専用です（file:// か localhost だけ）。\n"
            "  理由: 本番のページを開くと、読み取りのつもりでも、ページ自身が起動時に走らせる\n"
            "        書き込み（migrate・一度きりの取り込み・クラウド同期）を巻き込みます。\n"
            "  する: 複製を手元に置いて、そのファイルを渡してください。"
        )
    if arg.startswith("file://"):
        p = Path(unquote(urlparse(arg).path))
        if not p.exists():
            return None, f"ファイルがありません: {p}"
        return p.as_uri(), str(p)   # 日本語パスの表記ゆれを正規化（比較で誤爆させない）
    p = Path(arg).expanduser().resolve()
    if not p.exists():
        return None, f"ファイルがありません: {p}"
    return p.as_uri(), str(p)


MEASURE_JS = r"""
(() => {
  const vp = document.querySelector('meta[name="viewport" i]');
  // 物差しは documentElement.clientWidth。window.innerWidth は中身がはみ出すと
  // それにつられて広がるので（実測: 375指定で innerWidth=1200 / clientWidth=375）、
  // これを物差しにすると「はみ出していない」という嘘の結果になる。
  const out = {href: location.href,
               w: window.innerWidth, cw: document.documentElement.clientWidth,
               h: window.innerHeight,
               overflow: [], tap: [], font: [], clip: [], table: [],
               vp: vp ? (vp.getAttribute('content') || '') : null,
               seen: {el: 0, tap: 0, input: 0, table: 0},
               dom: {tap: 0, input: 0, table: 0},
               inlink: 0,
               docScrollWidth: document.documentElement.scrollWidth};

  const cs = (e) => getComputedStyle(e);

  const vis = (el) => {
    const s = cs(el);
    if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
    // 親が透明なら、中身も見えていない（opacity は継承しないので自分で辿る）
    for (let p = el.parentElement; p && p !== document.documentElement; p = p.parentElement) {
      const ps = cs(p);
      if (ps.display === 'none' || ps.visibility === 'hidden' || ps.opacity === '0') return false;
    }
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    if (r.bottom < -2000 || r.top > document.documentElement.scrollHeight + 2000) return false;
    return true;
  };

  const sel = (el) => {
    if (!el || el === document.documentElement) return 'html';
    let s = el.tagName.toLowerCase();
    if (el.id) return s + '#' + el.id;
    const c = (el.getAttribute('class') || '').trim().split(/\s+/).filter(Boolean).slice(0, 2);
    if (c.length) s += '.' + c.join('.');
    const p = el.parentElement;
    if (p) {
      const same = [...p.children].filter(x => x.tagName === el.tagName);
      if (same.length > 1) s += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
      if (!el.id && !c.length && p !== document.body) s = sel(p) + ' > ' + s;
    }
    return s;
  };

  const W = out.cw;

  // 1. 横はみ出し
  //    ページ自体が横に伸びていない（scrollWidth <= clientWidth）なら、右にはみ出して見える要素は
  //    `transform:translateX(100%)` で画面外へ待避したUI。崩れではないので数えない。
  const reallyWide = document.documentElement.scrollWidth > out.cw + 1;
  for (const el of document.querySelectorAll('body *')) {
    if (!vis(el)) continue;
    out.seen.el++;
    const r = el.getBoundingClientRect();
    if (reallyWide && r.right > W + 1) {
      out.overflow.push({sel: sel(el), right: Math.round(r.right),
                         w: Math.round(r.width), pos: cs(el).position});
    }
  }

  // 2. タップ44px未満
  //    タグ・role・onclick だけだと、addEventListener で押せるようにした div を落とす。
  //    つみきのアプリは押せるものに cursor:pointer が付くので、それも数える。
  //    入れ子のときは外側だけ数える（押せる範囲は外側なので）。
  //    ※ 実測（2026-09-04・mitsumori/hiyou/genka）では cursor:pointer で増えた候補は
  //      3本とも0件だった。効くのは自作の div ボタンを持つアプリだけで、
  //      「hiyou が押せるもの1件だった」原因はこれではなく、下のインラインリンク除外67件。
  const TAPQ = 'a[href], button, input, select, textarea, label[for], summary,' +
               '[role=button], [role=tab], [role=link], [role=checkbox], [role=switch],' +
               '[role=menuitem], [onclick], [tabindex]';
  const cand = new Set();
  for (const el of document.querySelectorAll(TAPQ)) cand.add(el);
  const isPtr = (e) => cs(e).cursor === 'pointer';
  for (const el of document.querySelectorAll('body *')) {
    if (!isPtr(el)) continue;
    const p = el.parentElement;
    if (p && p !== document.body && p !== document.documentElement && isPtr(p)) continue;
    cand.add(el);
  }
  for (const el of cand) {
    out.dom.tap++;
    if (!vis(el)) continue;
    const t = (el.getAttribute('type') || '').toLowerCase();
    if (el.tagName === 'INPUT' && t === 'hidden') continue;
    // 本文の中に埋まったリンク（文章の一部）は44pxの対象にしない。行の中の語を押すものなので。
    if (el.tagName === 'A') {
      const par = el.parentElement;
      if (cs(el).display === 'inline' && par) {
        // 親の文字から、その中のリンクの文字を全部引いた「地の文」の長さで決める。
        // 「親のほうが3文字多い」で判断すると、リンクが2つ並んだだけで全部“本文中”に
        // なってしまう（実測: nav の3件が全部除外され、44px検査が0件になった）。
        let prose = (par.textContent || '').trim().length;
        for (const a2 of par.querySelectorAll('a')) prose -= (a2.textContent || '').trim().length;
        if (prose >= 8) { out.inlink++; continue; }
      }
    }
    out.seen.tap++;
    const r = el.getBoundingClientRect();
    if (r.width < 44 || r.height < 44) {
      out.tap.push({sel: sel(el), w: +r.width.toFixed(1), h: +r.height.toFixed(1),
                    text: (el.textContent || el.value || '').trim().slice(0, 16)});
    }
  }

  // 3. 入力欄の font-size 16px未満（iOS が勝手に拡大する境目）
  for (const el of document.querySelectorAll('input, textarea, select')) {
    out.dom.input++;
    if (!vis(el)) continue;
    out.seen.input++;
    const fs = parseFloat(cs(el).fontSize);
    if (fs < 16) out.font.push({sel: sel(el), size: +fs.toFixed(1)});
  }

  // 4. 縦・横の切れ（スクロールできない入れ物の中で、文字が切れている）
  //    ※ 横だけ測ると見逃す＝2026-08-31 の実例（札が2pxだけはみ出して切れていた）
  //    ※ 中身が飾り（バー・図形）の overflow:hidden はわざとなので数えない
  //    ※ text-overflow:ellipsis の「…」もわざとなので数えない
  for (const el of document.querySelectorAll('body *')) {
    if (!vis(el)) continue;
    if ((el.innerText || '').trim().length === 0) continue;
    const s = cs(el);
    if (el.scrollHeight > el.clientHeight + 1 && (s.overflowY === 'hidden' || s.overflowY === 'clip')) {
      out.clip.push({sel: sel(el), need: el.scrollHeight, have: el.clientHeight, axis: 'Y'});
    }
    if (el.scrollWidth > el.clientWidth + 1 && (s.overflowX === 'hidden' || s.overflowX === 'clip')
        && s.textOverflow !== 'ellipsis') {
      out.clip.push({sel: sel(el), need: el.scrollWidth, have: el.clientWidth, axis: 'X'});
    }
  }

  // 5. はみ出している表が、スクロールできる枠に入っているか
  for (const tb of document.querySelectorAll('table')) {
    out.dom.table++;
    if (!vis(tb)) continue;
    out.seen.table++;
    const r = tb.getBoundingClientRect();
    if (!((tb.scrollWidth > tb.clientWidth + 1) || (r.right > W + 1) || (r.width > W + 1))) continue;
    let scroller = null;
    for (let p = tb.parentElement; p && p !== document.documentElement; p = p.parentElement) {
      const ox = cs(p).overflowX;
      if (ox === 'auto' || ox === 'scroll') { scroller = p; break; }
    }
    if (!scroller) out.table.push({sel: sel(tb), w: Math.round(r.width)});
  }

  return out;
})()
"""

CSSTEXT_JS = r"""
(() => {
  let txt = '', blocked = 0, rules = 0, sheets = 0;
  for (const s of document.styleSheets) {
    sheets++;
    try { for (const r of s.cssRules) { txt += r.cssText + '\n'; rules++; } }
    catch (e) { blocked++; }
  }
  let inline = 0;
  for (const el of document.querySelectorAll('[style]')) { txt += el.getAttribute('style') + '\n'; inline++; }
  return {vh: (txt.match(/100vh/g) || []).length,
          dvh: (txt.match(/100dvh/g) || []).length,
          blocked, rules, sheets, inline, chars: txt.length};
})()
"""


class Chrome:
    """空きポート＋専用プロファイルで起動し、自分で作ったタブだけを見る。"""

    def __init__(self):
        self.port = free_port()
        # ⚠️ CDP の Fetch も Network.setBlockedURLs も WebSocket を止められない。
        #    実測（2026-09-04）: ws:// の HTTP Upgrade がそのまま相手に届いていた。
        #    誰も待ち受けていないポートをプロキシに指定して、外向きの接続そのものを断つ。
        #    loopback は Chrome が既定でプロキシを迂回するので、localhost の検証は通る。
        self.proxy_port = free_port()
        self.prof = Path(os.environ.get("TMPDIR", "/tmp")) / f"cw-chromeprof-{os.getpid()}"
        self.blocked = {}
        self.blocked_kind = {}   # ホスト -> {resourceType}
        self.ws_seen = {}        # requestId -> ホスト
        self.ws_leaked = set()   # 握手の返事が返ってきた＝止められていないホスト
        self.evn = 1_000_000
        self.n = 0
        self.p = subprocess.Popen(
            [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
             "--no-first-run", "--no-default-browser-check",
             f"--proxy-server=127.0.0.1:{self.proxy_port}",
             f"--remote-debugging-port={self.port}", f"--user-data-dir={self.prof}",
             "--remote-allow-origins=*", "about:blank"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        ws_url = None
        for _ in range(80):
            try:
                # 自分専用のタブを作る（他人のタブにぶら下がらない）
                req = urllib.request.Request(
                    f"http://127.0.0.1:{self.port}/json/new?url=about:blank", method="PUT")
                tab = json.load(urllib.request.urlopen(req, timeout=3))
                ws_url = tab.get("webSocketDebuggerUrl")
                if ws_url:
                    break
            except Exception:
                pass
            time.sleep(0.25)
        if not ws_url:
            self.close()
            raise RuntimeError("Chrome が自分用のタブを出しませんでした")

        self.ws = websocket.create_connection(ws_url, timeout=40)
        self.cmd("Page.enable")
        self.cmd("Runtime.enable")
        # http(s) は Fetch で止める
        self.cmd("Fetch.enable", {"patterns": [{"urlPattern": "*"}]})
        # WebSocket は Fetch では止まらないので、こちらで止める（Supabase Realtime 対策）
        self.cmd("Network.enable")
        self.cmd("Network.setBlockedURLs", {"urls": ["ws://*", "wss://*"]})

    # ---- 通信の遮断 -------------------------------------------------
    @staticmethod
    def _is_local(url: str) -> bool:
        if url.startswith(("file:", "data:", "blob:", "about:", "chrome:")):
            return True
        if re.match(r"^(https?|wss?)://", url, re.I):
            host = (urlparse(url).hostname or "").lower()
            return host in LOCAL_HOSTS or host.endswith(".localhost")
        return False

    def _send_raw(self, method, params):
        self.evn += 1
        self.ws.send(json.dumps({"id": self.evn, "method": method, "params": params}))

    def _event(self, m):
        if m.get("method") == "Fetch.requestPaused":
            prm = m["params"]
            rid, url = prm["requestId"], prm.get("request", {}).get("url", "")
            if self._is_local(url):
                self._send_raw("Fetch.continueRequest", {"requestId": rid})
            else:
                host = (urlparse(url).hostname or url[:40]) or "?"
                self.blocked[host] = self.blocked.get(host, 0) + 1
                self.blocked_kind.setdefault(host, set()).add(prm.get("resourceType", "?"))
                self._send_raw("Fetch.failRequest",
                               {"requestId": rid, "errorReason": "BlockedByClient"})
        elif m.get("method") == "Network.webSocketCreated":
            url = m["params"].get("url", "")
            if not self._is_local(url):
                host = (urlparse(url).hostname or url[:40]) or "?"
                self.ws_seen[m["params"].get("requestId", "?")] = host
                self.blocked[f"{host}（WebSocket）"] = self.blocked.get(f"{host}（WebSocket）", 0) + 1
        elif m.get("method") == "Network.webSocketHandshakeResponseReceived":
            # 返事が来た＝**遮断できていない**。止めたつもりで通っていた事故（2026-09-04）の再発検知。
            host = self.ws_seen.get(m["params"].get("requestId", "?"))
            if host:
                self.ws_leaked.add(host)

    # ---- CDP --------------------------------------------------------
    def cmd(self, method, params=None):
        self.n += 1
        mine = self.n
        self.ws.send(json.dumps({"id": mine, "method": method, "params": params or {}}))
        while True:
            m = json.loads(self.ws.recv())
            if "method" in m:
                self._event(m)
                continue
            if m.get("id") == mine:
                if "error" in m:
                    raise RuntimeError(f"{method}: {m['error']}")
                return m.get("result", {})

    def eval(self, expr):
        r = self.cmd("Runtime.evaluate",
                     {"expression": expr, "returnByValue": True, "awaitPromise": True})
        if r.get("exceptionDetails"):
            raise RuntimeError(f"ページ内のJSが落ちました: {r['exceptionDetails'].get('text')}")
        return r["result"].get("value")

    def pump(self, seconds):
        """待っているあいだも CDP を回す。
        止めると、あとから読むCSS/フォントの要求が保留のままになり、
        同じファイル・同じ幅なのに判定が割れる（実測）。"""
        end = time.time() + seconds
        self.ws.settimeout(0.1)
        try:
            while time.time() < end:
                try:
                    m = json.loads(self.ws.recv())
                except (websocket.WebSocketTimeoutException, socket.timeout):
                    continue
                except Exception:
                    break
                if "method" in m:
                    self._event(m)
        finally:
            self.ws.settimeout(40)

    def close(self):
        for f in (lambda: self.ws.close(), lambda: self.p.terminate()):
            try:
                f()
            except Exception:
                pass
        try:
            self.p.wait(timeout=5)
        except Exception:
            pass
        shutil.rmtree(self.prof, ignore_errors=True)   # プロファイルは本当に使い捨てにする


def measure(ch, url, w, h, wait=1.2):
    ch.cmd("Emulation.setDeviceMetricsOverride",
           {"width": w, "height": h, "deviceScaleFactor": 1,
            "mobile": w < MOBILE_UNDER, "screenWidth": w, "screenHeight": h})
    ch.cmd("Emulation.setTouchEmulationEnabled", {"enabled": w < MOBILE_UNDER})
    ch.cmd("Page.navigate", {"url": url})     # 幅を変えたら読み込み直す
    ready_timeout = True
    for _ in range(100):
        if ch.eval("document.readyState") == "complete":
            ready_timeout = False
            break
        ch.pump(0.1)
    ch.pump(wait)                             # 遅れて動く描画・あとから読むCSSを待つ
    r = ch.eval(MEASURE_JS)
    # 開いているのが本当に渡したファイルか、毎回確かめる
    raw_got = r.get("href") or ""
    strip = lambda u: unquote(u.split("#")[0].split("?")[0])
    got, want = strip(raw_got), strip(url)
    if got != want:
        raise RuntimeError(
            "測っているページが渡したファイルと違います\n"
            f"  渡した : {want}\n  開いた : {got}")
    if raw_got.split("#")[0] != url.split("#")[0]:
        r["_urlchanged"] = raw_got          # ?クエリが変わった（アプリが状態をURLに書いた）
    r["_readytimeout"] = ready_timeout
    return r


def width_ok(r):
    return abs(r["cw"] - r["_w"]) <= 1


def content_ok(r, allow_no_controls):
    """「調べていないのに緑」を止める。見えている要素が0＝読み込めていない。"""
    if r["seen"]["el"] == 0:
        return False
    if r["seen"]["tap"] == 0 and not allow_no_controls:
        return False
    return True


# 遮断すると測定そのものが無意味になるもの。
HARD = {"Script", "Document", "XHR", "Fetch"}
# 遮断しても、ページ内に別のCSSが残っていれば測定は成り立つもの
# （webフォントを止めただけで NG にすると、mitsumori.html のような正常なアプリが毎回赤くなる）。
SOFT = {"Stylesheet", "Font"}


def scripts_blocked(blocked_kind, css_rules=None):
    """遮断のせいで「殻だけを測って OK と言う」状態になっていないか。
    実例: genka.html は supabase-js を cdn.jsdelivr.net から読む。遮断すると sb=null で
    済むが、CDNのライブラリで画面を組むアプリでは、殻だけを測って「OK」と言ってしまう。
    Stylesheet は、そのページのCSSを1本も読めていないときだけ致命傷とみなす。"""
    out = {}
    for h, k in blocked_kind.items():
        if k & HARD:
            out[h] = sorted(k)
        elif (k & SOFT) and css_rules == 0:
            out[h] = sorted(k)
    return out


def ng_of(r, allow_no_controls=False):
    if not width_ok(r):
        return True
    if not content_ok(r, allow_no_controls):
        return True
    return bool(r["overflow"]) or bool(r["tap"]) or bool(r["font"]) \
        or bool(r["clip"]) or bool(r["table"])


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("target", help="HTMLのパス / file:// / http://localhost:...")
    ap.add_argument("--widths", default="", help="例 375,768（既定は8幅すべて）")
    ap.add_argument("--limit", type=int, default=4, help="明細の表示件数（既定4）")
    ap.add_argument("--allow-no-controls", action="store_true",
                    help="押せるものが無い静的ページを OK として扱う")
    ap.add_argument("--allow-blocked-scripts", action="store_true",
                    help="外部スクリプトを遮断したままでも OK として扱う（中身が描かれない恐れあり）")
    ap.add_argument("--wait", type=float, default=1.2,
                    help="読み込み後に待つ秒数（既定1.2）。遅れて描くページは伸ばす")
    ap.add_argument("--json", action="store_true", help="機械向けにJSONで出す")
    a = ap.parse_args()

    url, note = resolve_target(a.target)
    if url is None:
        print(f"✗ {note}", file=sys.stderr)
        return 2

    widths = WIDTHS
    if a.widths:
        try:
            want = {int(x) for x in a.widths.split(",") if x.strip()}
        except ValueError:
            print(f"✗ --widths は数字をカンマ区切りで指定してください: {a.widths}", file=sys.stderr)
            return 2
        widths = [(w, h) for (w, h) in WIDTHS if w in want]
        extra = sorted(want - {x[0] for x in WIDTHS})
        if extra:
            print(f"  ⚠️ 決まった8幅に無い値が指定されました: {', '.join(map(str, extra))}"
                  "（高さ812で走ります。打ち間違いではありませんか）")
        widths += [(w, 812) for w in extra]
        widths.sort()
    if not widths:
        print("✗ 幅の指定が空です", file=sys.stderr)
        return 2
    if not Path(CHROME).exists():
        print(f"✗ Chrome が見つかりません: {CHROME}", file=sys.stderr)
        return 2

    ch = None
    try:
        ch = Chrome()
        results, csstext = [], None
        for w, h in widths:
            r = measure(ch, url, w, h, a.wait)
            r["_w"], r["_h"], r["_wait"] = w, h, a.wait
            results.append(r)
            if csstext is None:
                csstext = ch.eval(CSSTEXT_JS)
        blocked = dict(ch.blocked)
        blocked_kind = {k: set(v) for k, v in ch.blocked_kind.items()}
        ws_leaked = set(ch.ws_leaked)
    except Exception as e:
        print(f"✗ 検査を最後まで走らせられませんでした（＝崩れの有無は分かっていません）\n  {e}",
              file=sys.stderr)
        return 2
    finally:
        if ch:
            ch.close()

    sb = scripts_blocked(blocked_kind, (csstext or {}).get("rules"))
    invalid = []
    if sb and not a.allow_blocked_scripts:
        invalid.append("外部スクリプト等を遮断したまま測っています（"
                       + ", ".join(list(sb)[:3]) + "）")
    if ws_leaked:
        invalid.append("WebSocket を止められていません（" + ", ".join(sorted(ws_leaked)) + "）")
    if csstext and csstext.get("blocked") and csstext.get("rules", 0) == 0:
        invalid.append("CSSを1本も読めていません")

    if a.json:
        print(json.dumps({"target": note, "css": csstext, "blocked": blocked,
                          "blocked_kind": {k: sorted(v) for k, v in blocked_kind.items()},
                          "ws_leaked": sorted(ws_leaked),
                          "measurement_invalid": invalid,
                          "widths": results}, ensure_ascii=False, indent=2))
        return 1 if (invalid or any(ng_of(r, a.allow_no_controls) for r in results)) else 0
    return report(note, results, csstext, a.limit, blocked, a.allow_no_controls,
                  blocked_kind, invalid, ws_leaked)


def report(note, results, css, limit, blocked, anc, blocked_kind, invalid, ws_leaked):
    full = len(results) == len(WIDTHS)
    label = "8幅検品" if full else f"幅の検品（{len(results)}幅だけ）"
    print(f"■ {label}  {note}")
    if not full:
        print("  ⚠️ 8幅すべては走らせていません。この結果を「8幅で確かめた」と書かないでください。")
    print()
    print("  指定幅  実測幅  はみ出し  44px未満  16px未満  縦切れ  表  判定")
    print("  " + "-" * 62)
    for r in results:
        if not width_ok(r):
            print("  {:>5}  {:>5}  ← この幅で見ていません（測れず）           NG".format(
                r["_w"], r["cw"]))
            continue
        if not content_ok(r, anc):
            print("  {:>5}  {:>5}  ← 中身を測れていません（読み込めていない疑い）  NG".format(
                r["_w"], r["cw"]))
            continue
        print("  {:>5}  {:>5}  {:>8}  {:>8}  {:>8}  {:>6}  {:>2}  {}".format(
            r["_w"], r["cw"], len(r["overflow"]), len(r["tap"]), len(r["font"]),
            len(r["clip"]), len(r["table"]), "NG" if ng_of(r, anc) else "OK"))
    print()

    shown = {}
    for r in results:
        if not ng_of(r, anc):
            continue
        if not width_ok(r):
            print(f"  --- {r['_w']}px の中身 ---")
            print(f"    ⚠️ 指定は {r['_w']}px なのに、実際のレイアウト幅"
                  f"（documentElement.clientWidth）は {r['cw']}px でした。")
            if r["vp"] is None:
                print('       原因: <meta name="viewport"> がありません。')
                print("       これが無いと、スマホの表示は幅980px相当で組まれてから縮小表示になり、")
                print("       いくら幅を指定しても『その幅で見た』ことになりません。")
                print('       する: <head> に <meta name="viewport" '
                      'content="width=device-width, initial-scale=1"> を置く。')
            else:
                print(f"       viewport の指定: {r['vp']}")
                print("       width=device-width になっているか確かめてください。")
            print("       ※ この幅の他の数字は測っていません（あてにならないため）。")
            print()
            continue
        if not content_ok(r, anc):
            s = r["seen"]
            print(f"  --- {r['_w']}px の中身 ---")
            if s["el"] == 0:
                print("    ⚠️ 見えている要素が0件でした＝ページが1つも描かれていません。")
                print("       読み込めていないか、中身が後から作られる作りの可能性があります。")
                print(f"       あとから描くページなら --wait を伸ばしてください（いまは {r.get('_wait', 1.2)}秒）。")
                print("       ※ --allow-no-controls では通りません（0件は「崩れ0件」ではないため）。")
            else:
                print(f"    ⚠️ 見えている要素は {s['el']}件ありますが、押せるものが0件でした。")
                print(f"       （本文中のインラインリンク {r.get('inlink', 0)}件は 44px の対象から外しています）")
                print("       押せるものが本当に無い静的なページなら --allow-no-controls を付けてください。")
            print()
            continue

        print(f"  --- {r['_w']}px の中身 ---")
        # 鍵はセレクタの並びだけ。寸法まで入れると幅ごとに必ず違うので、
        # いちばん多い型（同じ要素が全幅で出る）で省略が一度も効かなくなる。
        sig = json.dumps([sorted(str(x.get("sel")) for x in r[k])
                          for k in ("overflow", "tap", "font", "clip", "table")],
                         ensure_ascii=False)
        if sig in shown:
            print(f"      {shown[sig]}px と同じ顔ぶれ（寸法は幅ごとに違います・省略）")
            print()
            continue
        shown[sig] = r["_w"]

        if r["overflow"]:
            print(f"    横はみ出し {len(r['overflow'])}件"
                  f"（documentElement.scrollWidth={r['docScrollWidth']} > {r['cw']}）")
            if r["w"] != r["cw"]:
                print(f"      ※ はみ出しのせいで window.innerWidth が {r['w']} に広がっています"
                      "（innerWidth を物差しにすると見逃す）")
            for x in r["overflow"][:limit]:
                print(f"      ・{x['sel']}  幅{x['w']} 右端{x['right']}  position:{x['pos']}")
            if len(r["overflow"]) > limit:
                print(f"      … ほか {len(r['overflow']) - limit}件")
        if r["tap"]:
            print(f"    タップ44px未満 {len(r['tap'])}件")
            for x in r["tap"][:limit]:
                t = f"「{x['text']}」" if x["text"] else ""
                print(f"      ・{x['sel']}  {x['w']}×{x['h']}px  {t}")
            if len(r["tap"]) > limit:
                print(f"      … ほか {len(r['tap']) - limit}件")
        if r["font"]:
            print(f"    入力欄16px未満 {len(r['font'])}件（iOSが勝手に拡大する）")
            for x in r["font"][:limit]:
                print(f"      ・{x['sel']}  {x['size']}px")
            if len(r["font"]) > limit:
                print(f"      … ほか {len(r['font']) - limit}件")
        if r["clip"]:
            print(f"    文字の切れ {len(r['clip'])}件（スクロールできない入れ物の中で切れている）")
            for x in r["clip"][:limit]:
                print(f"      ・{x['sel']}  {x['axis']}軸 中身{x['need']} > 枠{x['have']}")
            if len(r["clip"]) > limit:
                print(f"      … ほか {len(r['clip']) - limit}件")
        if r["table"]:
            print(f"    スクロール枠の無い表 {len(r['table'])}件（overflow-x:auto に入れる）")
            for x in r["table"][:limit]:
                print(f"      ・{x['sel']}  幅{x['w']}")
        print()

    # CSS は「読めた量」を必ず出す。0件と「1文字も読めていない」を見分けられるように。
    if css:
        print(f"  CSS: ルール {css['rules']}本 / スタイルシート {css['sheets']}枚 / "
              f"style属性 {css['inline']}個 / 文字数 {css['chars']}")
        if css["rules"] == 0 and css["inline"] == 0:
            print("    ⚠️ CSSを1文字も読めていません。100vh の検査は行われていません")
        elif css["vh"] and not css["dvh"]:
            print(f"    ⚠️ 100vh が {css['vh']}件、100dvh が 0件。"
                  "iPhone はアドレスバーぶん下が切れます（100dvh にする）")
        elif css["vh"]:
            print(f"    ・100vh {css['vh']}件 / 100dvh {css['dvh']}件（併記なら可）")
        elif css["blocked"]:
            print("    ・100vh は見つかりませんでしたが、"
                  f"読めなかったスタイルシートが {css['blocked']}枚あるので**判定できていません**")
        else:
            print("    ・100vh は使われていません")
        if css["blocked"]:
            print(f"    ・読めなかったスタイルシートが {css['blocked']}枚"
                  "（外部CSS）。その中の 100vh は数えられていません")
        print()

    for r in results:
        if r.get("_readytimeout"):
            print(f"  ⚠️ {r['_w']}px: 読み込み完了を10秒待っても complete になりませんでした"
                  "（そのまま測っています）")
        if r.get("_urlchanged"):
            print(f"  ・{r['_w']}px: ページがURLを書き換えました → {r['_urlchanged']}")
    ref = next((r for r in results if width_ok(r)), None)
    if ref:
        s, d = ref["seen"], ref["dom"]
        print(f"  調べた件数（{ref['_w']}px）: 見えている要素 {s['el']} / "
              f"押せるもの {s['tap']}（DOMには {d['tap']}） / "
              f"入力欄 {s['input']}（DOMには {d['input']}） / 表 {s['table']}（DOMには {d['table']}）")
        if d["tap"] > s["tap"] + ref.get("inlink", 0):
            print(f"    ※ 差の {d['tap'] - s['tap'] - ref.get('inlink', 0)}件は、いま画面に見えていません"
                  "（閉じているシート・ダイアログの中身は測れていません）")
        if ref.get("inlink"):
            print(f"    ※ 本文中のインラインリンク {ref['inlink']}件は 44px の対象から外しています"
                  "（親から、その中のリンクの字を引いた「地の文」が8文字以上あるもの）")
            if ref["inlink"] > max(3, s["tap"] * 3):
                print(f"    ⚠️ 押せるもの {s['tap']}件に対して除外が {ref['inlink']}件と多く、"
                      "44pxの検査はほとんど働いていません。緑を鵜呑みにしないでください")
        print()

    sb = scripts_blocked(blocked_kind, (css or {}).get("rules"))
    bad = sum(1 for r in results if ng_of(r, anc))
    if ws_leaked:
        print("  🔴🔴 **WebSocket を止められていません**（握手の返事が返ってきました）: "
              + ", ".join(sorted(ws_leaked)))
        print("     本番のクラウド（Supabase Realtime など）へ実際につながっている恐れがあります。")
        print("     この道具を使うのをやめて、先に遮断を直してください。")
        print()
    if sb and invalid:
        print("  🔴 外部のスクリプト等を遮断しました＝**この測定は当てになりません**")
        for h, kinds in list(sb.items())[:6]:
            print(f"      ・{h}（{'/'.join(kinds)}）")
        if len(sb) > 6:
            print(f"      … ほか {len(sb) - 6}ホスト")
        print("     そのライブラリやCSSで画面を組むアプリだと、殻だけを測って「崩れ0件」と言います。")
        print("     する: 外部依存を外した複製（sb=null・架空データ）を作って、それを渡す。")
        print("     どうしてもこのまま見たいときだけ --allow-blocked-scripts。")
        print()

    print(("  8幅それぞれ → " if full else "  走らせた幅 → ") + " ".join(
        f"{r['_w']}:{'NG' if ng_of(r, anc) else 'OK'}" for r in results))
    if bad:
        print(f"  幅の判定: NG（{bad}/{len(results)} 幅で崩れが残っている）")
    else:
        print(f"  幅の判定: OK（{len(results)}幅すべて・崩れ0件）")
    if invalid:
        for x in invalid:
            print(f"  測定の判定: 🔴 当てになりません — {x}")
    print(f"  総合: {'🔴 NG' if (bad or invalid) else '✓ OK'}")
    print()
    print("  ※ 渡されたファイルが持っている状態しか見ていません。"
          "偽データは、実データにある状態を隠します。")
    if blocked:
        tot = sum(blocked.values())
        # WebSocket は必ず先に出す（本番の Realtime へ繋ごうとした合図なので、
        # 件数順にすると、いちばん出てほしい場面で埋もれる）
        order = sorted(blocked.items(),
                       key=lambda x: (0 if "WebSocket" in x[0] else 1, -x[1]))
        head = order[:6]
        print(f"  ※ 外への通信を {tot}本 止めました（書き込み事故を防ぐため）: "
              + " / ".join(f"{h}×{c}" for h, c in head)
              + (f" / ほか {len(order) - 6}ホスト" if len(order) > 6 else ""))
        kinds = sorted({k for v in blocked_kind.values() for k in v})
        if any("WebSocket" in h for h, _ in order):
            kinds.append("WebSocket")
        print(f"     止めた種類: {', '.join(kinds) if kinds else '（種類を取れませんでした）'}")
        print(f"     ・{'/'.join(sorted(HARD))} が入っていたら、そのページの中身は描かれていません（測定は無効）")
        print(f"     ・{'/'.join(sorted(SOFT))} は、ほかにCSSが残っていれば測定は成り立ちます"
              "（外部フォントを止めたぶん、字幅は本番と少しずれます）")
    else:
        print("  ※ 外への通信は0本でした（このページは外を見にいっていません）。")
    return 1 if (bad or invalid) else 0


if __name__ == "__main__":
    sys.exit(main())
