/* ふたりカード — 通知用 Service Worker（Web Push）
   登録は futaricard.html から scope を './futaricard.html' に絞って行う。
   同じフォルダの cooking-sw.js / tsugi-sw.js と scope がぶつかると、相手の登録（と通知の購読）を上書きしてしまうため。 */
self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

/* サーバーからのプッシュ（アプリを閉じていても届く） */
self.addEventListener('push', e => {
  let title = 'ふたりカード', body = '', tag = 'futaricard';
  try {
    const d = e.data ? e.data.json() : {};
    title = d.title || title; body = d.body || ''; tag = d.tag || tag;
  } catch (_) { body = e.data ? e.data.text() : ''; }
  e.waitUntil(
    self.registration.showNotification(title, {
      body,
      icon: 'icons/icon-futaricard.png',
      badge: 'icons/icon-futaricard.png',
      tag,
      renotify: true
    })
  );
});

/* 通知をタップしたらアプリを前面に */
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      for (const c of list) {
        if (c.url.includes('futaricard.html') && 'focus' in c) return c.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow('./futaricard.html');
    })
  );
});
