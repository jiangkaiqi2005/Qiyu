import { renderAppShell, bindNavigation } from '../ui/layout.js';

export function render(container, context) {
  const innerHtml = `
    <div class="card">
      <h1>栖语</h1>
      <p class="subtitle">一个深夜懂你的 AI 伴侣</p>
      <p style="line-height: 1.8; margin-bottom: 24px;">
        夜深了。无论今天过得如何，这里都有人愿意倾听你的声音。
        栖语会记住你分享的点滴，随着时间的推移，你们的默契会悄然增长。
      </p>
      <div class="actions" style="display: flex; gap: 12px; flex-wrap: wrap;">
        <button data-nav-path="/chat" class="btn primary">开始对话</button>
        <button data-nav-path="/onboarding" class="btn">新手引导</button>
      </div>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/');
  bindNavigation(container, context.router);
}
