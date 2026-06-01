export function render(container, context) {
  container.innerHTML = `
    <main class="shell">
      <div class="card">
        <h1>新手引导</h1>
        <p>欢迎来到栖语。在这里我们将完成首次设置，让你和栖语的相遇更加自然。</p>
        <button data-path="/chat" class="btn primary">进入聊天</button>
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
