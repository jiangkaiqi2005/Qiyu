export function renderAppShell(contentHtml, currentPath) {
  const routes = [
    { path: '/', label: '栖所', icon: '🏠' },
    { path: '/chat', label: '夜话', icon: '💬' },
    { path: '/onboarding', label: '初遇', icon: '✨' },
    { path: '/settings', label: '默契', icon: '⚙️' },
    { path: '/memory', label: '印记', icon: '🧠' },
    { path: '/privacy', label: '封存', icon: '🛡️' }
  ];

  const devMode = window.localStorage.getItem('qiyu_dev_mode') === 'true';
  if (devMode) {
    routes.push({ path: '/lab', label: '幻镜', icon: '🧪' });
  }

  const navItems = routes
    .map(
      (r) => `
    <button data-nav-path="${r.path}" class="nav-item ${currentPath === r.path ? 'active' : ''}" aria-current="${currentPath === r.path ? 'page' : 'false'}">
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
        <div class="sidebar-brand">
          <span class="mark" aria-hidden="true">栖</span>
          <span class="brand-name">栖语</span>
        </div>
        <div class="sidebar-nav" role="tablist">
          ${navItems}
        </div>
      </nav>
      <div class="app-content-wrapper">
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
        <main id="main-content" class="app-main-content" tabindex="-1" style="outline: none;">
          ${contentHtml}
        </main>
      </div>
      <nav class="app-bottom-nav" aria-label="移动端导航">
        ${navItems}
      </nav>
    </div>
  `;
}

export function bindNavigation(container, router) {
  container.querySelectorAll('[data-nav-path]').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      router.navigate(btn.dataset.navPath);
    });
  });
}
