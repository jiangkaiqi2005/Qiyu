import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { renderButton, renderNotice } from '../ui/components.js';

export function render(container, context) {
  const innerHtml = `
    <div class="card" style="max-width: 800px;">
      <h1>质量实验室 (Quality Lab)</h1>
      <p class="subtitle">深度陪伴回归分析与黄金测试集 (Golden Cases) 质量评估室。</p>

      <div class="lab-notice-area"></div>

      <div style="margin-bottom: 24px; display: flex; gap: 12px; align-items: center; flex-wrap: wrap;">
        ${renderButton({ label: '运行黄金测试集', variant: 'primary', attrs: 'class="run-evals-btn"' })}
        ${renderButton({ label: '导出评估报告', variant: 'normal', attrs: 'class="export-report-btn" style="display:none;"' })}
        <span class="eval-loading-status" style="display: none; font-size: 14px; color: var(--muted);">正在运行测试用例，请稍候...</span>
      </div>

      <div class="eval-summary-card notice notice-info" style="display: none; margin-bottom: 24px; flex-direction: column; gap: 8px;">
        <h4 style="margin: 0; color: var(--accent); font-size: 16px;">评估结果概览</h4>
        <div style="display: flex; gap: 24px; margin-top: 8px;">
          <div>通过率：<strong class="pass-rate-text" style="font-size: 20px; color: #a3ffd6;">0/0</strong></div>
          <div>状态评估：<strong class="eval-status-text" style="font-size: 16px;">良好</strong></div>
        </div>
      </div>

      <div class="eval-results-container" style="display: flex; flex-direction: column; gap: 16px;">
        <p style="color: var(--muted); text-align: center; padding: 32px 0;">点击上方按钮开始执行 9 个系统回归基线测试用例。</p>
      </div>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/lab');
  bindNavigation(container, context.router);

  const runBtn = container.querySelector('.run-evals-btn');
  const exportBtn = container.querySelector('.export-report-btn');
  const loadingText = container.querySelector('.eval-loading-status');
  const summaryCard = container.querySelector('.eval-summary-card');
  const passRateText = container.querySelector('.pass-rate-text');
  const evalStatusText = container.querySelector('.eval-status-text');
  const resultsContainer = container.querySelector('.eval-results-container');
  const noticeArea = container.querySelector('.lab-notice-area');

  let lastReport = null;

  if (runBtn) {
    runBtn.addEventListener('click', async () => {
      runBtn.disabled = true;
      if (loadingText) loadingText.style.display = 'inline';
      if (summaryCard) summaryCard.style.display = 'none';
      if (exportBtn) exportBtn.style.display = 'none';
      if (resultsContainer) resultsContainer.innerHTML = '';

      try {
        const res = await fetch('/api/eval/run');
        if (res.ok) {
          const data = await res.json();
          lastReport = data;

          if (passRateText) passRateText.innerText = `${data.passedCount} / ${data.totalCount}`;
          const passRate = data.passedCount / data.totalCount;
          if (evalStatusText) {
            if (passRate === 1) {
              evalStatusText.innerText = '完美 (回归指标100%达成)';
              evalStatusText.style.color = '#a3ffd6';
            } else if (passRate >= 0.8) {
              evalStatusText.innerText = '良好 (无核心阻碍漏洞)';
              evalStatusText.style.color = '#ffe6a3';
            } else {
              evalStatusText.innerText = '警告 (存在多处行为偏离)';
              evalStatusText.style.color = '#ffd8d8';
            }
          }

          if (summaryCard) summaryCard.style.display = 'flex';
          if (exportBtn) exportBtn.style.display = 'inline-block';

          if (resultsContainer) {
            resultsContainer.innerHTML = data.results.map(r => {
              const passClass = r.passed ? 'notice-success' : 'notice-error';
              const passLabel = r.passed ? '✓ PASSED' : '✕ FAILED';
              return `
                <div class="notice ${passClass}" style="flex-direction: column; align-items: stretch; padding: 16px; margin: 0; gap: 8px;">
                  <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 8px;">
                    <strong style="font-size: 15px;">用例：${r.name}</strong>
                    <span style="font-weight: bold; font-size: 13px;">${passLabel}</span>
                  </div>
                  <div style="font-size: 13px; margin-top: 4px;">
                    <strong>输入:</strong> <code style="background: rgba(0,0,0,0.2); padding: 2px 6px; border-radius: 4px;">${r.input}</code>
                  </div>
                  <div style="font-size: 13px;">
                    <strong>预期响应:</strong> <span style="color: var(--muted);">${r.expected.join(' | ')}</span>
                  </div>
                  <div style="font-size: 13px;">
                    <strong>实际响应:</strong> <span style="${r.passed ? 'color:#a3ffd6;' : 'color:#ffd8d8;'}">${r.actual.join(' | ')}</span>
                  </div>
                  ${!r.passed ? `
                    <div style="font-size: 12px; color: #ffd8d8; margin-top: 4px; border-top: 1px dashed rgba(255,255,255,0.1); padding-top: 4px;">
                      <strong>偏离原因:</strong> ${r.failureReason}
                    </div>
                  ` : ''}
                </div>
              `;
            }).join('');
          }
        } else {
          const err = await res.json();
          if (noticeArea) noticeArea.innerHTML = renderNotice({ type: 'error', message: `评估运行失败：${err.error}` });
        }
      } catch (err) {
        if (noticeArea) noticeArea.innerHTML = renderNotice({ type: 'error', message: `网络请求失败：${err.message}` });
      } finally {
        runBtn.disabled = false;
        if (loadingText) loadingText.style.display = 'none';
      }
    });
  }

  if (exportBtn) {
    exportBtn.addEventListener('click', () => {
      if (!lastReport) return;

      const reportMarkdown = `# 栖语行为特征质量评估报告 (Quality Lab Report)
生成时间: ${new Date().toLocaleString()}
测试用例总数: ${lastReport.totalCount}
通过测试数: ${lastReport.passedCount}
失败测试数: ${lastReport.totalCount - lastReport.passedCount}
整体通过率: ${(lastReport.passedCount / lastReport.totalCount * 100).toFixed(1)}%

## 详细评估结果
${lastReport.results.map(r => `
### [${r.passed ? 'PASSED' : 'FAILED'}] 用例名: ${r.name}
- **输入**: \`${r.input}\`
- **预期响应**: ${r.expected.join(' | ')}
- **实际响应**: ${r.actual.join(' | ')}
${!r.passed ? `- **失败偏离描述**: ${r.failureReason}` : ''}
`).join('\n')}

---
*由“栖语·质量实验室”自动生成。*`;

      const blob = new Blob([reportMarkdown], { type: 'text/markdown;charset=utf-8;' });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.setAttribute('download', `qiyu-eval-report-${Date.now()}.md`);
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
    });
  }
}
