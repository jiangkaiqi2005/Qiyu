export function render(container, context) {
  container.innerHTML = `
    <main class="shell">
      <div class="card">
        <h1>质量实验室</h1>
        <p>开发者及高级用户的质量控制和黄金测试集评估室。</p>
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
