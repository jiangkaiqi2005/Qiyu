import { Router } from './router.js';

const app = document.querySelector('#app');
if (app) {
  const router = new Router(app);
  router.resolve();
}
