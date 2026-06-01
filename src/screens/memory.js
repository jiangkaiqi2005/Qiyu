export function render(container, context) {
  container.innerHTML = `
    <main class="shell">
      <div class="card">
        <h1>记忆中心</h1>
        <p>在这里可以查看并管理栖语为你记录下的生活点滴及性格事实。</p>
        <button data-path="/" class="btn">返回首页</button>
      </div>
    </main>
  `;
  container.querySelectorAll('[data-path]').forEach(btn => {
    btn.addEventListener('click', () => {
      context.router.navigate(btn.dataset.path);
    });
  });
}
