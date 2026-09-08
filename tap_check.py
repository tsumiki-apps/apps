# -*- coding: utf-8 -*-
"""指で押すところが44pxあるかを、**実際に描かせて**測る道具。

なぜ静的に読まないか:
  CSSを目で追っても、実際の高さは padding・line-height・flex・継承の合わせ技で決まる。
  当てずっぽうになるので、ブラウザに描かせて getBoundingClientRect() で測る。

安全のしくみ（A層 P0「動作確認で実データに書き込まない」）:
  本番のHTMLは開かない。`_tap_検査/` に**複製**を作り、その先頭に目隠しを差し込む。
    - localStorage / sessionStorage をメモリ上の偽物に差し替える（本番のキーに触れない）
    - fetch / XMLHttpRequest / WebSocket / sendBeacon を黙らせる（外に出さない）
  そのうえで iframe に並べて読むだけ。クリックもinput発火もしない。

使い方:
  python3 tap_check.py            # *.html すべての複製を作る
  python3 tap_check.py a.html b.html
  → できた `_tap_検査/harness.html` をブラウザで開き、`?from=0&n=12` で少しずつ測る。
     結果は window.TAPRESULT に入る。
  python3 tap_check.py --clean    # 複製を消す
"""
import glob
import html
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "_tap_検査"

SHIM = """<script>
/* 検査用の目隠し。保存も通信も外に出さない（本番データに触れないため） */
(function(){
  var mem = {};
  var fake = {
    getItem: function(k){ return Object.prototype.hasOwnProperty.call(mem,k) ? mem[k] : null; },
    setItem: function(k,v){ mem[k] = String(v); },
    removeItem: function(k){ delete mem[k]; },
    clear: function(){ mem = {}; },
    key: function(i){ return Object.keys(mem)[i] || null; }
  };
  Object.defineProperty(fake, "length", { get: function(){ return Object.keys(mem).length; } });
  try { Object.defineProperty(window, "localStorage",   { value: fake, configurable: true }); } catch(e){}
  try { Object.defineProperty(window, "sessionStorage", { value: fake, configurable: true }); } catch(e){}
  window.fetch = function(){ return new Promise(function(){}); };
  window.XMLHttpRequest = function(){
    this.open=function(){}; this.send=function(){}; this.setRequestHeader=function(){};
    this.addEventListener=function(){}; this.abort=function(){};
  };
  window.WebSocket = function(){ this.close=function(){}; this.send=function(){}; };
  if (navigator.sendBeacon) { try { navigator.sendBeacon = function(){ return false; }; } catch(e){} }
  window.alert = window.confirm = window.prompt = function(){ return false; };
})();
</script>
"""

HARNESS = """<!doctype html><meta charset="utf-8">
<title>タップ44px 検査</title>
<style>
 body{font:14px/1.6 -apple-system,sans-serif;margin:0;padding:12px}
 #frames{position:absolute;left:-99999px;top:0}
 iframe{width:375px;height:900px;border:0}
 pre{white-space:pre-wrap;word-break:break-all}
</style>
<h1>タップ44px 検査</h1>
<p id="status">読み込み中…</p>
<div id="frames"></div>
<pre id="out"></pre>
<script>
/* 押せるものを拾う。見えていないもの・大きさ0のものは数えない。 */
var SEL = 'button, a[href], input, select, textarea, summary, label[for], [role="button"], [onclick], [tabindex]:not([tabindex="-1"])';
var SKIP_TYPES = { hidden:1, file:1 };   /* file は端末のUIなので測らない */

function measure(doc){
  var bad = [], seen = 0;
  var list = doc.querySelectorAll(SEL);
  for (var i = 0; i < list.length; i++) {
    var el = list[i];
    if (el.type && SKIP_TYPES[el.type]) continue;
    var cs = doc.defaultView.getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || cs.pointerEvents === 'none') continue;
    if (cs.opacity === '0') continue;                    /* 目に見えない替え玉（本命はラベル側） */
    if (el.type === 'range') continue;                   /* つまみを引くものは44pxの対象外 */
    /* 文章の中のリンクは対象外（WCAG 2.5.8 も inline の例外を置いている）。
       ボタンの見た目をしたリンク＝block / inline-flex などは対象に残す。 */
    if (el.tagName === 'A' && cs.display === 'inline') continue;
    var r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;          /* 描かれていない画面の中身 */
    if (el.closest('[hidden]')) continue;
    seen++;
    var w = Math.round(r.width), h = Math.round(r.height);
    if (w >= 44 && h >= 44) continue;
    /* 親か自分が当たり判定を広げていれば見逃す */
    if (el.className && String(el.className).indexOf('tn-hit') >= 0) continue;
    var lab = el.tagName.toLowerCase() + (el.className ? '.' + String(el.className).trim().split(/\\s+/).join('.') : '')
            + (el.id ? '#' + el.id : '');
    bad.push({ el: lab.slice(0,70), w: w, h: h, text: (el.textContent||'').trim().slice(0,14) });
  }
  return { seen: seen, bad: bad };
}

var q = new URLSearchParams(location.search);
var from = parseInt(q.get('from') || '0', 10), n = parseInt(q.get('n') || '10', 10);

fetch('list.json').then(function(r){ return r.json(); }).then(function(files){
  var slice = files.slice(from, from + n);
  var box = document.getElementById('frames');
  var done = 0, result = {};
  document.getElementById('status').textContent =
    files.length + '本中 ' + (from+1) + '〜' + (from+slice.length) + '本目を測っています…';
  slice.forEach(function(f){
    var fr = document.createElement('iframe');
    fr.src = f;
    fr.onload = function(){
      try { result[f] = measure(fr.contentDocument); }
      catch (e) { result[f] = { error: String(e) }; }
      if (++done === slice.length) finish(files, result);
    };
    fr.onerror = function(){ result[f] = { error: 'よみこめない' }; if (++done === slice.length) finish(files, result); };
    box.appendChild(fr);
  });
  if (!slice.length) finish(files, result);
});

function finish(files, result){
  window.TAPRESULT = { total: files.length, from: from, n: n, result: result };
  var lines = [];
  Object.keys(result).forEach(function(f){
    var r = result[f];
    if (r.error) { lines.push('! ' + f + ' — ' + r.error); return; }
    if (!r.bad.length) { lines.push('ok ' + f + '（' + r.seen + '個）'); return; }
    lines.push('● ' + f + '（' + r.seen + '個中 ' + r.bad.length + '個が44px未満）');
    r.bad.slice(0,6).forEach(function(b){ lines.push('    ' + b.w + 'x' + b.h + '  ' + b.el + '  ' + b.text); });
  });
  document.getElementById('out').textContent = lines.join('\\n');
  document.getElementById('status').textContent = '測りおわりました（' + (from+1) + '〜' + (from+Object.keys(result).length) + ' / ' + files.length + '本）';
}
</script>
"""


def main():
    args = sys.argv[1:]
    if args and args[0] == "--clean":
        if OUT.exists():
            shutil.rmtree(OUT)
            print("消しました:", OUT)
        else:
            print("もうありません")
        return

    targets = args or sorted(
        f for f in glob.glob("*.html")
        if not Path(f).name.startswith("_")
    )
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir()

    made = []
    for path in targets:
        src = Path(path)
        try:
            s = src.read_text(encoding="utf-8")
        except OSError as e:
            print(f"! {path}: 読めません（{e}）")
            continue
        low = s.lower()
        i = low.find("<body")
        if i < 0:
            print(f"- {path}: <body> が無いので飛ばします")
            continue
        j = s.find(">", i)
        out = s[: j + 1] + "\n" + SHIM + s[j + 1 :]
        (OUT / src.name).write_text(out, encoding="utf-8")
        made.append(src.name)

    (OUT / "list.json").write_text(json.dumps(made, ensure_ascii=False), encoding="utf-8")
    (OUT / "harness.html").write_text(HARNESS, encoding="utf-8")
    print(f"✓ {len(made)}本の複製を {OUT.name}/ に作りました")
    print(f"  開く: {OUT.name}/harness.html?from=0&n=12")
    print("  ※ 複製は保存も通信も殺してある（本番データに触れない）")


if __name__ == "__main__":
    main()
