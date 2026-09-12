"use strict";
const CACHE = "djonehub-push-v1";
const SHELL = ["./", "./index.html", "./style.css", "./app.js", "./icon.svg", "./manifest.webmanifest"];
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith("djonehub-push-") && key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", event => {
  if (event.request.method !== "GET" || new URL(event.request.url).origin !== self.location.origin) return;
  event.respondWith(fetch(event.request).catch(async () => (await caches.match(event.request, {ignoreSearch: true})) || Response.error()));
});
self.addEventListener("push", event => {
  // Every push produces a visible notification, including expired calls.
  let data = {};
  try { data = event.data?.json() || {}; } catch { /* show a generic reminder */ }
  const expiredCall = data.kind === "call" && Number.isFinite(data.expires) && data.expires <= Date.now();
  const title = expiredCall ? "DJOneHub 来电记录" : typeof data.title === "string" ? data.title.slice(0, 100) : "DJOneHub 提醒";
  const body = expiredCall ? "模块此前有电话呼入，请打开 DJOneHub 查看当前状态。" : typeof data.body === "string" ? data.body.slice(0, 500) : "模块有新消息，请打开 DJOneHub 查看。";
  event.waitUntil(self.registration.showNotification(title, {body, icon: "./icon.svg", tag: typeof data.tag === "string" ? data.tag.slice(0, 128) : "djonehub", data: {url: new URL("./", self.location.href).href}}));
});
self.addEventListener("notificationclick", event => {
  event.notification.close();
  event.waitUntil((async () => {
    const target = new URL("./", self.location.href).href;
    const clients = await self.clients.matchAll({type: "window", includeUncontrolled: true});
    for (const client of clients) { if (client.url.startsWith(target) && "focus" in client) return client.focus(); }
    return self.clients.openWindow(target);
  })());
});
