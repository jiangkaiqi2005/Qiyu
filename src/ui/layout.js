const SIDEBAR_HOVER_INTENT_DELAY_MS = 760;
const SIDEBAR_CLOSE_GRACE_MS = 140;

export function renderAppShell(contentHtml, currentPath) {
  const routes = [
    { path: '/chat', label: '夜话', icon: '话' },
    { path: '/history', label: '记录', icon: '录' },
    { path: '/settings', label: '默契', icon: '默' },
    { path: '/privacy', label: '封存', icon: '封' }
  ];

  const devMode = window.localStorage.getItem('qiyu_dev_mode') === 'true';
  if (devMode) {
    routes.push({ path: '/lab', label: '幻镜', icon: '镜' });
  }

  const navItems = routes
    .map(
      (r, index) => `
    <button data-nav-path="${r.path}" class="nav-item ${currentPath === r.path ? 'active' : ''}" aria-current="${currentPath === r.path ? 'page' : 'false'}">
      <span class="nav-index" aria-hidden="true">${String(index + 1).padStart(2, '0')}</span>
      <span class="nav-icon" aria-hidden="true">${r.icon}</span>
      <span class="nav-label">${r.label}</span>
    </button>
  `
    )
    .join('');

  return `
    <a href="#main-content" class="skip-link">跳过导航</a>
    <div class="app-shell-container">
      <nav class="app-sidebar" aria-label="主导航">
        <span class="sidebar-sheen" aria-hidden="true"></span>
        <span class="sidebar-orbit" aria-hidden="true"></span>
        <div class="sidebar-brand">
          <span class="mark" aria-hidden="true">栖</span>
          <span class="brand-name">栖语</span>
        </div>
        <div class="sidebar-nav" role="tablist">
          ${navItems}
        </div>
        <div class="sidebar-context" aria-hidden="true">
          <span class="context-kicker">关系中枢</span>
          <strong>今晚低声模式</strong>
          <p>夜话、记录、默契与边界都在这里。需要时展开，不需要时安静退到边上。</p>
        </div>
      </nav>
      <div class="app-content-wrapper">
        <div class="app-canvas" aria-hidden="true"></div>
        <header class="app-header-bar">
          <div class="header-brand-mobile">
            <span class="mark" aria-hidden="true">栖</span>
            <span class="brand-name">栖语</span>
          </div>
          <div class="header-status">
            <span class="status-indicator online"></span>
            <span class="status-text">深夜在线</span>
          </div>
        </header>
        <main id="main-content" class="app-main-content" tabindex="-1">
          ${contentHtml}
        </main>
      </div>
      <nav class="app-bottom-nav" aria-label="移动端导航">
        ${navItems}
      </nav>
    </div>
  `;
}

export function bindSidebarHoverIntent(container, timers = globalThis) {
  const sidebar = typeof container.querySelector === 'function'
    ? container.querySelector('.app-sidebar')
    : null;
  if (!sidebar || sidebar.__qiyuSidebarHoverIntentBound) return;

  let openTimer = null;
  let closeTimer = null;
  let pointerInside = false;

  const clearTimer = (timer) => {
    if (timer !== null && typeof timers.clearTimeout === 'function') {
      timers.clearTimeout(timer);
    }
  };

  const setExpanded = (expanded) => {
    if (expanded) {
      sidebar.dataset.expanded = 'true';
    } else {
      delete sidebar.dataset.expanded;
    }
  };

  const scheduleOpen = (event) => {
    if (event.pointerType === 'touch') return;
    pointerInside = true;
    clearTimer(closeTimer);
    clearTimer(openTimer);
    closeTimer = null;
    openTimer = timers.setTimeout(() => {
      openTimer = null;
      if (pointerInside) {
        setExpanded(true);
      }
    }, SIDEBAR_HOVER_INTENT_DELAY_MS);
  };

  const scheduleClose = () => {
    pointerInside = false;
    clearTimer(openTimer);
    clearTimer(closeTimer);
    openTimer = null;
    closeTimer = timers.setTimeout(() => {
      closeTimer = null;
      const hasFocus = typeof sidebar.matches === 'function'
        ? sidebar.matches(':focus-within')
        : false;
      if (!hasFocus) {
        setExpanded(false);
      }
    }, SIDEBAR_CLOSE_GRACE_MS);
  };

  sidebar.addEventListener('pointerenter', scheduleOpen);
  sidebar.addEventListener('pointerleave', scheduleClose);
  sidebar.addEventListener('focusin', () => {
    clearTimer(openTimer);
    clearTimer(closeTimer);
    openTimer = null;
    closeTimer = null;
    setExpanded(true);
  });
  sidebar.addEventListener('focusout', scheduleClose);
  sidebar.__qiyuSidebarHoverIntentBound = true;
}

export function bindNavigation(container, router) {
  bindSidebarHoverIntent(container);

  if (typeof container.addEventListener === 'function' && !container.__qiyuNoticeDismissBound) {
    container.addEventListener('click', (event) => {
      const closeBtn = typeof event.target?.closest === 'function'
        ? event.target.closest('.btn-close-notice')
        : null;
      if (!closeBtn) return;

      event.preventDefault();
      const notice = typeof closeBtn.closest === 'function'
        ? closeBtn.closest('.notice')
        : closeBtn.parentElement;
      const dismissTarget = notice?.parentElement?.dataset?.noticeDismissScope === 'wrapper'
        ? notice.parentElement
        : notice;
      if (typeof dismissTarget?.remove === 'function') {
        dismissTarget.remove();
      }
    });
    container.__qiyuNoticeDismissBound = true;
  }

  container.querySelectorAll('[data-nav-path]').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      router.navigate(btn.dataset.navPath);
    });
  });
}
