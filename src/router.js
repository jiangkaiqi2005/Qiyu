const routes = {
  '/': () => import('./screens/home.js'),
  '/chat': () => import('./screens/chat.js'),
  '/history': () => import('./screens/history.js'),
  '/onboarding': () => import('./screens/onboarding.js'),
  '/settings': () => import('./screens/settings.js'),
  '/memory': () => import('./screens/memory.js'),
  '/lab': () => import('./screens/lab.js'),
  '/privacy': () => import('./screens/privacy.js')
};

const titles = {
  '/': '夜话 - 栖语',
  '/chat': '夜话 - 栖语',
  '/history': '记录 - 栖语',
  '/onboarding': '初遇 - 栖语',
  '/settings': '默契 - 栖语',
  '/memory': '本地上下文 - 栖语',
  '/lab': '幻境 - 栖语',
  '/privacy': '封存 - 栖语'
};

const APP_TITLE = '栖语';

// Screen paths shared with the dev server's SPA fallback (scripts/dev-server.mjs)
export const SPA_ROUTES = Object.keys(routes);

export class Router {
  constructor(container) {
    this.container = container;
    window.addEventListener('popstate', () => this.resolve());
  }

  navigate(path) {
    window.history.pushState(null, '', path);
    return this.resolve();
  }

  async resolve() {
    const path = window.location.pathname;
    const loadScreen = routes[path];

    if (loadScreen) {
      try {
        document.title = titles[path] || APP_TITLE;
        const hasCurrentView = this.container.firstChild !== null;
        if (!hasCurrentView) {
          this.renderLoading();
        }

        const module = await loadScreen();

        this.container.innerHTML = '';
        const context = { router: this };
        await module.render(this.container, context);
      } catch (err) {
        console.error('Failed to load dynamic screen bundle chunk:', err);
        this.renderError();
      }
    } else {
      this.container.innerHTML = '';
      document.title = '404 迷路了 - 栖语';
      this.renderNotFound();
    }
  }

  renderLoading() {
    this.container.innerHTML = `
      <main class="route-loading-shell" aria-live="polite" aria-busy="true">
        <div class="route-loading-panel">
          <span class="route-loading-mark" aria-hidden="true">栖</span>
          <span class="route-loading-line"></span>
          <span class="route-loading-text">正在把夜色铺开</span>
        </div>
      </main>
    `;
  }

  renderError() {
    this.container.innerHTML = `
      <main class="route-state route-state-error">
        <section class="route-state-panel" aria-labelledby="route-error-title">
          <span class="route-state-kicker">连接短暂停住</span>
          <h1 id="route-error-title">栖语加载出了点小状况</h1>
          <p>请检查本地服务或网络连接，然后重新试一次。</p>
          <button class="btn primary route-state-action" data-reload>重新加载</button>
        </section>
      </main>
    `;
    const btn = this.container.querySelector('[data-reload]');
    if (btn) {
      btn.addEventListener('click', () => {
        window.location.reload();
      });
    }
  }

  renderNotFound() {
    this.container.innerHTML = `
      <main class="route-state route-state-not-found">
        <section class="route-state-panel" aria-labelledby="route-not-found-title">
          <span class="route-state-kicker">路径没有回声</span>
          <h1 id="route-not-found-title">这里暂时没有夜话</h1>
          <p>这条路没有可打开的页面。回到夜话，直接开始说就好。</p>
          <button data-path="/chat" class="btn primary route-state-action">返回夜话</button>
        </section>
      </main>
    `;
    const btn = this.container.querySelector('[data-path]');
    if (btn) {
      btn.addEventListener('click', () => {
        this.navigate(btn.dataset.path);
      });
    }
  }
}
