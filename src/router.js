import { render as renderHome } from './screens/home.js';
import { render as renderChat } from './screens/chat.js';
import { render as renderOnboarding } from './screens/onboarding.js';
import { render as renderSettings } from './screens/settings.js';
import { render as renderMemory } from './screens/memory.js';
import { render as renderLab } from './screens/lab.js';
import { render as renderPrivacy } from './screens/privacy.js';

const routes = {
  '/': renderHome,
  '/chat': renderChat,
  '/onboarding': renderOnboarding,
  '/settings': renderSettings,
  '/memory': renderMemory,
  '/lab': renderLab,
  '/privacy': renderPrivacy
};

export class Router {
  constructor(container, getContext) {
    this.container = container;
    this.getContext = getContext;
    window.addEventListener('popstate', () => this.resolve());
  }

  navigate(path) {
    window.history.pushState(null, '', path);
    this.resolve();
  }

  resolve() {
    const path = window.location.pathname;
    const renderFn = routes[path];

    this.container.innerHTML = '';

    if (renderFn) {
      const context = this.getContext ? this.getContext(this) : { router: this };
      renderFn(this.container, context);
    } else {
      this.renderNotFound();
    }
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
