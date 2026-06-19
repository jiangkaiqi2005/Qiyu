const CACHE_NAME = 'qiyu-app-shell-v36';
const DYNAMIC_CACHE_NAME = 'qiyu-dynamic-assets-v1';
const FONT_CACHE_NAME = 'qiyu-fonts-v1';

const ASSETS = [
  '/',
  '/index.html',
  '/src/main.js',
  '/src/router.js',
  '/src/styles.css',
  '/src/ui/layout.js',
  '/src/ui/components.js',
  '/src/ui/confirm-dialog.js',
  '/src/ui/render.js',
  '/src/ui/chat-api.js',
  '/src/screens/home.js',
  '/src/screens/chat.js',
  '/src/screens/onboarding.js',
  '/src/screens/settings.js',
  '/src/screens/memory.js',
  '/src/screens/lab.js',
  '/src/screens/privacy.js',
  '/src/screens/history.js',
  '/public/manifest.webmanifest',
  '/public/offline.html'
];

async function limitCacheSize(cacheName, maxItems) {
  const cache = await caches.open(cacheName);
  const keys = await cache.keys();
  if (keys.length > maxItems) {
    await cache.delete(keys[0]);
    await limitCacheSize(cacheName, maxItems);
  }
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(ASSETS);
    }).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys.map((key) => {
          if (key !== CACHE_NAME && key !== DYNAMIC_CACHE_NAME && key !== FONT_CACHE_NAME) {
            return caches.delete(key);
          }
        })
      );
    }).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Exclude API requests
  if (url.pathname.startsWith('/api/')) {
    return;
  }

  // Google Fonts caching with dynamic size limits
  if (url.hostname.includes('fonts.gstatic.com') || url.hostname.includes('fonts.googleapis.com')) {
    event.respondWith(
      caches.match(event.request).then((cachedResponse) => {
        if (cachedResponse) {
          return cachedResponse;
        }
        return fetch(event.request).then((networkResponse) => {
          if (networkResponse.status === 200) {
            const responseClone = networkResponse.clone();
            caches.open(FONT_CACHE_NAME).then((cache) => {
              cache.put(event.request, responseClone);
              limitCacheSize(FONT_CACHE_NAME, 15);
            });
          }
          return networkResponse;
        });
      })
    );
    return;
  }

  // Stale-While-Revalidate for App Shell Static Assets
  event.respondWith(
    caches.open(CACHE_NAME).then(async (cache) => {
      const cachedResponse = await cache.match(event.request);
      
      const fetchPromise = fetch(event.request).then((networkResponse) => {
        if (networkResponse.status === 200) {
          cache.put(event.request, networkResponse.clone());
        }
        return networkResponse;
      }).catch(() => {
        if (event.request.mode === 'navigate') {
          return caches.match('/public/offline.html');
        }
      });

      return cachedResponse || fetchPromise;
    })
  );
});
