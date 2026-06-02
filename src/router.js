const routes = {
  '/': () => import('./screens/home.js'),
  '/chat': () => import('./screens/chat.js'),
  '/onboarding': () => import('./screens/onboarding.js'),
  '/settings': () => import('./screens/settings.js'),
  '/memory': () => import('./screens/memory.js'),
  '/lab': () => import('./screens/lab.js'),
  '/privacy': () => import('./screens/privacy.js')
};

const titles = {
  '/': '栖所 - 栖语',
  '/chat': '夜话 - 栖语',
  '/onboarding': '初遇 - 栖语',
  '/settings': '默契 - 栖语',
  '/memory': '印记 - 栖语',
  '/lab': '幻境 - 栖语',
  '/privacy': '封存 - 栖语'
};

export class Router {
  constructor(container, getContext) {
    this.container = container;
    this.getContext = getContext;
    window.addEventListener('popstate', () => this.resolve());
  }

  navigate(path) {
    window.history.pushState(null, '', path);
    return this.resolve();
  }

  async resolve() {
    const path = window.location.pathname;
    const loadScreen = routes[path];

    this.container.innerHTML = '';

    if (loadScreen) {
      try {
        document.title = titles[path] || '栖语';
        
        // Dynamic loading fog placeholder to prevent visual layout shifts (CLS)
        this.container.innerHTML = `<div class="skeleton-container" style="min-height: 80vh; opacity: 0.2; filter: blur(4px);"></div>`;
        
        // Lazy-load the target screen bundle chunk on-demand
        const module = await loadScreen();
        
        this.container.innerHTML = '';
        const context = this.getContext ? this.getContext(this) : { router: this };
        module.render(this.container, context);
      } catch (err) {
        console.error('Failed to load dynamic screen bundle chunk:', err);
        this.renderError();
      }
    } else {
      document.title = '404 迷路了 - 栖语';
      this.renderNotFound();
    }
  }

  renderError() {
    this.container.innerHTML = `
      <main class="shell error-screen">
        <div class="card" style="text-align: center;">
          <h2>栖语：加载出了点小状况</h2>
          <p>夜色深了，网络好像也有点累了。请检查你的连接并刷新试试。</p>
          <button onclick="window.location.reload()" class="btn primary">刷新页面</button>
        </div>
      </main>
    `;
  }

  renderNotFound() {
    this.container.innerHTML = `
      <main class="shell error-screen">
        <div class="card">
          <h1>404 - 迷路了</h1>
          <p>好像走丢了呢。这里没有发现栖语的声音。</p>
          <button data-path="/" class="btn primary">返回首页</button>
        </div>
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
