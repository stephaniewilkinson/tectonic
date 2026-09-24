// The session screen, kept for a reload with no signal. #543.
//
// What this does, and nothing else: when a session screen loads, a copy of it is kept on the
// phone, and if that same screen is opened again with no signal the copy is shown instead of the
// browser's offline page. The stylesheet and htmx are kept the same way, so the copy renders.
// Every other request passes straight through untouched -- this is not an offline app, it is one
// screen that survives a closed tab in a basement.
//
// **Network first, always.** A copy is only ever shown when the network could not be reached at
// all. With signal the phone gets the live page exactly as it would without this file, so a
// deploy is never hidden behind a stale copy -- which is the failure #543 was most wary of, since
// an installed app is the one a lifter never thinks to hard-refresh. An error page from the
// server is shown as an error page; a copy stands in for a missing network, never for a broken
// server, because a stale page that looks fine is worse than an error that says so.
//
// **One session, and gone at sign-out.** Only the last session screen loaded is kept -- a copy
// of yesterday's session is not a thing anybody needs offline -- and the whole cache is dropped
// when the lifter signs out or reaches the sign-in page, so the next person to use the phone
// never gets somebody else's training out of it. Only a page that actually loaded is kept: a
// redirect to sign in is not a session screen.
//
// A tap on the copy is held and sent when signal returns, by the queue #542 built -- that is
// what makes the copy useful rather than a picture. The doorbell and the poll fail quietly
// offline and pick up again when they can, as they already do on a page that lost signal.

const VERSION = 'tectonic-session-v1';
const SESSION = /^\/workouts\/\d+\/session\/?$/;
const SHELL = ['/assets/css/styles.css', '/js/htmx.min.js'];

self.addEventListener('install', () => self.skipWaiting());

// Caches from any earlier version go, so a changed rule never serves a copy kept under the old one.
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(names.filter((name) => name !== VERSION).map((name) => caches.delete(name))))
      .then(() => self.clients.claim())
  );
});

function forget() {
  return caches.delete(VERSION);
}

// The page itself, fetched live; kept if it loaded, and the copy handed back only if the
// network could not be reached at all.
function session(request) {
  return fetch(request).then((response) => {
    if (response.ok && !response.redirected) {
      const copy = response.clone();
      caches.open(VERSION).then((cache) => keepOnly(cache, request, copy));
    }
    return response;
  }).catch(() => caches.open(VERSION)
    .then((cache) => cache.match(request))
    .then((kept) => kept || Promise.reject(new Error('offline, and this session was never kept'))));
}

// The last session screen and the shell, and nothing older.
function keepOnly(cache, request, response) {
  return cache.keys()
    .then((keys) => Promise.all(keys
      .filter((key) => SESSION.test(new URL(key.url).pathname) && key.url !== request.url)
      .map((key) => cache.delete(key))))
    .then(() => cache.put(request, response));
}

function shell(request) {
  return fetch(request).then((response) => {
    if (response.ok) {
      const copy = response.clone();
      caches.open(VERSION).then((cache) => cache.put(request, copy));
    }
    return response;
  }).catch(() => caches.match(request).then((kept) => kept || Promise.reject(new Error('offline'))));
}

// The page that registered this asks for itself to be kept. The first time a session screen is
// opened this worker is not yet in charge of it -- it was installed by that very page -- so the
// fetch above never saw it, and without this the screen a lifter is standing in front of would be
// the one screen not kept.
self.addEventListener('message', (event) => {
  const address = event.data && event.data.keep;
  if (!address) { return; }
  const url = new URL(address);
  if (url.origin !== self.location.origin || !SESSION.test(url.pathname)) { return; }
  // The stylesheet and htmx were fetched before this worker was in charge too, and a copy
  // without them is a page with no styling and no queue behind its Done buttons.
  const kept = [session(new Request(url.href, { credentials: 'same-origin' }))]
    .concat(SHELL.map((path) => shell(new Request(path))));
  event.waitUntil(Promise.all(kept.map((keeping) => keeping.catch(() => null))));
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) { return; }

  if (url.pathname === '/logout' || url.pathname === '/login') {
    event.waitUntil(forget());
    return;
  }
  if (request.method !== 'GET') { return; }

  if (request.mode === 'navigate' && SESSION.test(url.pathname)) {
    event.respondWith(session(request));
  } else if (SHELL.includes(url.pathname)) {
    event.respondWith(shell(request));
  }
});
