/* clinIA · service worker — gerado pelo build */
var CACHE = 'clinia-2026.10.21-023-candidata-202610211555';
self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(['./']); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (ks) {
    return Promise.all(ks.filter(function (k) { return k.indexOf('clinia-') === 0 && k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});
self.addEventListener('fetch', function (e) {
  var r = e.request;
  if (r.method !== 'GET') return;
  var u = new URL(r.url);
  if (u.origin !== self.location.origin) return;
  if (r.mode !== 'navigate' && !/\/(index\.html)?$/.test(u.pathname)) return;
  e.respondWith(fetch(r).then(function (res) {
    if (res.ok) { var copia = res.clone(); caches.open(CACHE).then(function (c) { c.put('./', copia); }); }
    return res;
  }).catch(function () { return caches.match('./'); }));
});
