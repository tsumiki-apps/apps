/* ================================================================
   つみき用「動きの下ごしらえ」JS  v1  (2026-09-09)

   tn.css の相棒。CSS では書けない2つだけを持つ。
     1. rnd()    …… 決定論の擬似乱数（Math.random() の置き換え）
     2. reveal() …… 見えたら再生・押したらもう一度

   考え方の出どころ: lieflat-charts（PolyForm Noncommercial）。
   ライセンスが非商用なので**コードは写していない**。借りたのは
   「デモの乱数は決定論にする」「再生前に必ずタイマーを掃除する」
   という2つの考え方だけで、中身はつみき用に書き直したもの。
   調査 → ~/つみき出力/道具としらべ/lieflat-charts_調査と採用可否_2026-09-08.md

   使い方: 単一HTMLの <script> にこのまま貼る（or python3 inject_tn.py <HTML>）。
   ぶら下がる名前は window.TN の1つだけ。既存コードとぶつからない。
   ================================================================ */
(function (global) {
  'use strict';

  /* ── 1 · 決定論の擬似乱数 ────────────────────────────────
     Math.random() を使わない。リロードのたびに形が変わると、
     スクショも録画も「前と同じか」の見比べも全部あてにならなくなる。
     つみきは「架空データの複製から画面を撮る」運用（お返事カード・IG投稿）
     をしているので、ここが変わると成果物が毎回ちがう絵になる。

     同じ (i, k) を渡せば、いつ・どの端末で呼んでも同じ 0〜1 が返る。
     i = 何番目か、k = 用途の区別（x座標なら 0、y座標なら 1、など）。

     ※ 参考にした式（`((i*73856093)^(k*19349663))%1000/1000`）は
       **k=0 のとき 0.000 / 0.093 / 0.186 … と等差の直線になる**（実測）。
       既定の k=0 でいちばん使うのに散らばらないので、ここは採らずに
       32bit のかき混ぜ（xor と乗算を交互に）に置き換えてある。     */
  function rnd(i, k) {
    var h = Math.imul((i | 0) + 0x9e3779b9, 0x85ebca6b);
    h ^= Math.imul(((k === undefined ? 0 : k) | 0) + 0xc2b2ae35, 0x27d4eb2f);
    h ^= h >>> 15; h = Math.imul(h, 0x2545f491);
    h ^= h >>> 13; h = Math.imul(h, 0x3d73373b);
    h ^= h >>> 16;
    return (h >>> 0) / 4294967296;
  }

  /* lo〜hi に散らす（rnd の範囲つき版） */
  function rndIn(i, k, lo, hi) {
    return lo + rnd(i, k) * (hi - lo);
  }

  /* 配列から決定論的に1つ選ぶ（アイコン・色・名前のダミー割り当て用） */
  function pick(list, i, k) {
    if (!list || !list.length) return undefined;
    return list[Math.floor(rnd(i, k) * list.length) % list.length];
  }

  /* 配列を決定論的に並べ替える（シャッフルしたいが毎回同じ順がいいとき） */
  function shuffle(list, k) {
    return list
      .map(function (v, i) { return [rnd(i, k), v]; })
      .sort(function (a, b) { return a[0] - b[0]; })
      .map(function (p) { return p[1]; });
  }

  /* ── 2 · 見えたら再生・押したらもう一度 ──────────────────
     画面に入ってから描く。入場アニメが「スクロールする前に終わっていた」
     を防ぐ。押すともう一度。

     肝は**再生前にタイマーを全部消すこと**。消さないと、連打したぶん
     setInterval が積み上がって、だんだん速くなる／二重に描かれる。

       TN.reveal('chart', function (el, ctx) {
         el.innerHTML = '';
         ctx.keep(setInterval(tick, 16));   // ← 自分で作ったタイマーは keep に預ける
         if (ctx.reduced) { drawInstantly(el); return; }   // 動きを減らす設定のとき
         drawWithAnimation(el);
       });

     opt: { threshold: 0.3, replay: true, once: true }
       threshold … どれだけ見えたら再生するか（0〜1）
       replay    … クリックで再生し直すか（既定 true）
       once      … 一度再生したら監視をやめるか（既定 true）             */

  var kept = new Map();   // 要素 → そこで動いているタイマーの控え

  function clearKept(el) {
    var list = kept.get(el) || [];
    for (var i = 0; i < list.length; i++) {
      clearTimeout(list[i]);
      clearInterval(list[i]);
    }
    kept.set(el, []);
  }

  function reduced() {
    return !!(global.matchMedia &&
      global.matchMedia('(prefers-reduced-motion: reduce)').matches);
  }

  function reveal(target, draw, opt) {
    var el = typeof target === 'string' ? document.getElementById(target) : target;
    if (!el || typeof draw !== 'function') return null;

    var o = opt || {};
    var threshold = o.threshold === undefined ? 0.3 : o.threshold;
    var replay = o.replay === undefined ? true : o.replay;
    var once = o.once === undefined ? true : o.once;
    var fallback = o.fallback === undefined ? 1200 : o.fallback;
    var drawn = false;

    function go() {
      drawn = true;
      clearKept(el);   // ← ここで kept.get(el) は必ず空配列になる
      draw(el, {
        rnd: rnd,
        reduced: reduced(),
        keep: function (id) { kept.get(el).push(id); return id; }
      });
    }

    // 動きを減らす設定なら、監視もアニメもせずその場で1回だけ描く
    if (reduced() || !global.IntersectionObserver) {
      go();
    } else {
      var io = new IntersectionObserver(function (entries) {
        if (!entries[0].isIntersecting) return;
        go();
        if (once) io.disconnect();
      }, { threshold: threshold });
      io.observe(el);

      /* 保険。**画面に寸法が無いところでは IntersectionObserver は永久に発火しない**
         （Claude のブラウザペインは innerWidth/innerHeight とも 0・2026-09-09 実測。
          スクショ用のヘッドレス、PDF書き出し、display:none の iframe も同じ）。
         そのまま放っておくと図が白いまま焼き付く。だから寸法が無いときだけ、
         少し待ってから描く。ふつうのブラウザの「下のほうにある要素」は
         寸法があるので、ここは通らない＝スクロールするまで待つ挙動のまま。 */
      if (fallback) {
        setTimeout(function () {
          if (drawn) return;
          if (!global.innerWidth || !global.innerHeight) go();
        }, fallback);
      }
    }

    if (replay) {
      el.style.cursor = 'pointer';
      el.addEventListener('click', go);
    }
    return go;   // 呼び出し側から手で再生したいとき用
  }

  /* 止める（要素を消す前に呼ぶ。タイマーの置き去りを防ぐ） */
  reveal.stop = function (target) {
    var el = typeof target === 'string' ? document.getElementById(target) : target;
    if (el) clearKept(el);
  };

  global.TN = global.TN || {};
  global.TN.rnd = rnd;
  global.TN.rndIn = rndIn;
  global.TN.pick = pick;
  global.TN.shuffle = shuffle;
  global.TN.reveal = reveal;
  global.TN.reduced = reduced;
})(typeof window !== 'undefined' ? window : globalThis);
