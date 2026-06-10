import { Router } from './router.js';

const app = document.querySelector('#app');
if (app) {
  const router = new Router(app);
  router.resolve();
}

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').then((reg) => {
      console.log('Qiyu service worker registered successfully:', reg.scope);
    }).catch((err) => {
      console.warn('Qiyu service worker registration failed:', err);
    });
  });
}
