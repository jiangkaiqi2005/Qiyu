export function render(container, context) {
  container.innerHTML = `
    <main class="shell">
      <div class="card">
        <h1>设置中心</h1>
        <p>配置你的聊天模型、个性偏好及相关安全参数。</p>
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
