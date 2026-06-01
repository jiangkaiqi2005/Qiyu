export function render(container, context) {
  container.innerHTML = `
    <main class="shell">
      <div class="card">
        <h1>隐私与安全边界</h1>
        <p>详细了解栖语的数据本地保存机制及与云端大模型的安全合规边界。</p>
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
