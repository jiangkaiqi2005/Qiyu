const CACHE_NAME = 'qiyu-app-shell-v1';
const ASSETS = [
  '/',
  '/index.html',
  '/src/main.js',
  '/src/router.js',
  '/src/styles.css',
  '/src/ui/layout.js',
  '/src/ui/components.js',
  '/src/ui/render.js',
  '/src/ui/chat-api.js',
  '/src/screens/home.js',
  '/src/screens/chat.js',
  '/src/screens/onboarding.js',
  '/src/screens/settings.js',
  '/src/screens/memory.js',
  '/src/screens/lab.js',
  '/src/screens/privacy.js',
  '/public/manifest.webmanifest',
  '/public/offline.html'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(ASSETS);
    })
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys.map((key) => {
          if (key !== CACHE_NAME) {
            return caches.delete(key);
          }
        })
      );
    })
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  if (url.pathname.startsWith('/api/')) {
    return;
  }

  event.respondWith(
    caches.match(event.request).then((cachedResponse) => {
      if (cachedResponse) {
        return cachedResponse;
      }
      return fetch(event.request).catch(() => {
        if (event.request.mode === 'navigate') {
          return caches.match('/public/offline.html');
        }
      });
    })
  );
});
