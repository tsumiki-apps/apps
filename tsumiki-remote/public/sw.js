'use strict';

// つみきリモート — 画面一式を iPhone の中に置いておく係（Service Worker）。
//
// この画面（index.html）は MacBook が配っている。だから Mac に届かないと
// 「中身が古い」どころか画面そのものを受け取れず、開いても真っ白になる（2026-08-12）。
// ここで index.html とアイコンを端末の中に写しておき、取りに行けなかったときは
// その写しを出す。中身（セッション一覧・画面の文字）は index.html 側が
// localStorage に残していて、開いた瞬間にそれを描く。
//
// ⚠️ この仕組みは https でないと動かない（ブラウザの決まり）。
//    http で開いている間は登録自体が失敗するだけで、他は普通に動く。

var CACHE = 'tsumiki-remote-shell-v1';
var SHELL = ['./index.html', './icon-180.png', './icon-512.png'];

// 画面を取りに行くときの待ち時間。Mac がスリープしていると「つながらない」と
// 分かるまで数十秒かかることがあり、そのあいだ真っ白のままになる。
// これを過ぎたら写しを出して、取得はそのまま裏で続けさせる（次回は新しくなる）。
var NAV_TIMEOUT = 4000;

self.addEventListener('install', function (e) {
  e.waitUntil(
    caches.open(CACHE)
      .then(function (c) { return c.addAll(SHELL); })
      .then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys()
      .then(function (keys) {
        return Promise.all(keys.map(function (k) {
          return k === CACHE ? null : caches.delete(k);
        }));
      })
      .then(function () { return self.clients.claim(); })
  );
});

// 取りに行って、取れたら写しを更新する
function fresh(req, key) {
  return fetch(req).then(function (res) {
    if (res && res.ok) {
      var copy = res.clone();
      caches.open(CACHE).then(function (c) { c.put(key, copy); }).catch(function () {});
    }
    return res;
  });
}

var OFFLINE_HTML =
  '<!doctype html><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width,initial-scale=1">' +
  '<body style="margin:0;display:flex;align-items:center;justify-content:center;' +
  'height:100vh;background:#0e0f12;color:#8b93a1;' +
  'font:14px/1.6 -apple-system,BlinkMacSystemFont,\'Hiragino Sans\',sans-serif;text-align:center">' +
  '<p>MacBook に届きません。<br>電波が戻ったら開き直してください。</p></body>';

self.addEventListener('fetch', function (e) {
  var req = e.request;
  if (req.method !== 'GET') return;

  var url;
  try { url = new URL(req.url); } catch (err) { return; }
  if (url.origin !== self.location.origin) return;

  // 中身は必ず取りに行く。古い写しを「今の状態」として見せたら嘘になる
  if (url.pathname.indexOf('/api/') === 0 || url.pathname.indexOf('/preview/') === 0) return;

  // 画面そのもの（ホーム画面から起動したときもここを通る）
  if (req.mode === 'navigate') {
    e.respondWith(new Promise(function (resolve) {
      var done = false;
      var fallback = function () {
        if (done) return;
        done = true;
        caches.match('./index.html').then(function (hit) {
          resolve(hit || new Response(OFFLINE_HTML, {
            status: 200,
            headers: { 'content-type': 'text/html; charset=utf-8' },
          }));
        });
      };
      var timer = setTimeout(fallback, NAV_TIMEOUT);
      fresh(req, './index.html').then(function (res) {
        clearTimeout(timer);
        if (done) return;      // もう写しを出したあと。取得ぶんは写しの更新に使われる
        done = true;
        resolve(res);
      }, function () {
        clearTimeout(timer);
        fallback();
      });
    }));
    return;
  }

  // アイコンなど。写しがあれば即出しつつ、裏で新しくしておく
  e.respondWith(
    caches.match(req).then(function (hit) {
      var net = fresh(req, req).catch(function () { return hit; });
      return hit || net;
    })
  );
});
