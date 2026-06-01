export function render(container, context) {
  container.innerHTML = `
    <main class="shell">
      <div class="card">
        <h1>栖语</h1>
        <p class="subtitle">一个深夜懂你的 AI 伴侣</p>
        <div class="actions">
          <button data-path="/chat" class="btn primary">开始对话</button>
          <button data-path="/onboarding" class="btn">新手引导</button>
          <button data-path="/settings" class="btn">设置</button>
          <button data-path="/memory" class="btn">记忆中心</button>
          <button data-path="/privacy" class="btn">隐私与安全</button>
        </div>
      </div>
    </main>
  `;
  container.querySelectorAll('[data-path]').forEach(btn => {
    btn.addEventListener('click', () => {
      context.router.navigate(btn.dataset.path);
    });
  });
}
