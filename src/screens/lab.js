import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { renderButton, showNotice, downloadBlob } from '../ui/components.js';
import { loadBrowserState } from '../qiyu/state.js';
import { escapeHtml } from '../ui/render.js';
import { postJson } from '../ui/chat-api.js';

function failureBadgeFor(failureReason) {
  const reason = failureReason || '';
  if (reason.includes('安全边界错')) return '安全边界错';
  if (reason.includes('晚安后开启话题')) return '晚安后开启话题';
  if (reason.includes('关系阶段错')) return '关系阶段错';
  if (reason.includes('过长')) return '过长';
  if (reason.includes('禁用语')) return '禁用语';
  return '';
}

export function render(container, context) {
  const storage = window.localStorage;
  const innerHtml = `
    <section class="lab-workbench" aria-labelledby="lab-title">
      <div class="archive-hero lab-hero">
        <div>
          <span class="archive-kicker">质量观察</span>
          <h1 id="lab-title">质量实验室</h1>
          <p>开发者模式下的回归观察台。用黄金测试集检查栖语是否仍保持克制、边界和夜话质感。</p>
        </div>
        <div class="archive-stamp" aria-hidden="true">
          <span>QA</span>
          <strong>仅开发模式</strong>
        </div>
      </div>

      <div class="lab-notice-area"></div>

      <div class="lab-toolbar">
        ${renderButton({ label: '运行黄金测试集', variant: 'primary', className: 'run-evals-btn' })}
        ${renderButton({ label: '导出评估报告', variant: 'normal', className: 'export-report-btn is-hidden' })}
        <span class="eval-loading-status"><span class="loading-dots">正在运行测试用例，请稍候</span></span>
      </div>

      <div class="eval-summary-card">
        <h2>评估结果概览</h2>
        <div class="eval-summary-grid">
          <div>
            <span>通过率</span>
            <strong class="pass-rate-text">0 / 0</strong>
          </div>
          <div>
            <span>状态评估</span>
            <strong class="eval-status-text">良好</strong>
          </div>
        </div>
      </div>

      <div class="eval-results-container">
        <div class="lab-empty-state">
          <span>待运行</span>
          <p>点击上方按钮开始执行系统回归基线测试用例。</p>
        </div>
      </div>
    </section>
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
              evalStatusText.className = 'eval-status-text is-perfect';
            } else if (passRate >= 0.8) {
              evalStatusText.innerText = '良好 (无核心阻碍漏洞)';
              evalStatusText.className = 'eval-status-text is-good';
            } else {
              evalStatusText.innerText = '警告 (存在多处行为偏离)';
              evalStatusText.className = 'eval-status-text is-warning';
            }
          }

          if (summaryCard) summaryCard.style.display = 'flex';
          if (exportBtn) exportBtn.style.display = 'inline-block';

          if (resultsContainer) {
            const grouped = {};
            data.results.forEach(r => {
              const cat = r.category || '其他';
              if (!grouped[cat]) grouped[cat] = [];
              grouped[cat].push(r);
            });

            let html = '';
            for (const [cat, casesList] of Object.entries(grouped)) {
              const hasFailed = casesList.some(c => !c.passed);
              const safeCat = escapeHtml(cat);
              
              html += `
                <section class="eval-category-group ${hasFailed ? 'has-failed' : ''}">
                  <h3>
                    <span>类别：${safeCat}</span>
                    ${hasFailed ? '<em>存在未通过项</em>' : ''}
                  </h3>
                  <div class="eval-case-list">
                    ${casesList.map(r => {
                      const passClass = r.passed ? 'is-passed' : 'is-failed';
                      const passLabel = r.passed ? '通过' : '未通过';
                      
                      const badge = !r.passed ? (failureBadgeFor(r.failureReason) || '偏差') : '';
                      
                      const badgeHtml = badge 
                        ? `<span class="eval-failure-badge">${escapeHtml(badge)}</span>`
                        : '';
                      const safeName = escapeHtml(r.name);
                      const safeInput = escapeHtml(r.input);
                      const safeExpected = escapeHtml(r.expected.join(' | '));
                      const safeActual = escapeHtml(r.actual.join(' | '));
                      const safeReason = escapeHtml(r.failureReason || '');

                      return `
                        <article class="eval-case-card ${passClass}">
                          <div class="eval-case-head">
                            <strong>用例：${safeName}${badgeHtml}</strong>
                            <span>${passLabel}</span>
                          </div>
                          <div class="eval-case-line">
                            <strong>输入</strong>
                            <code>${safeInput}</code>
                          </div>
                          <div class="eval-case-line">
                            <strong>预期响应</strong>
                            <span>${safeExpected}</span>
                          </div>
                          <div class="eval-case-line">
                            <strong>实际响应</strong>
                            <span>${safeActual}</span>
                          </div>
                          ${!r.passed ? `
                            <div class="eval-failure-reason">
                              <strong>偏离原因</strong>
                              <span>${safeReason}</span>
                            </div>
                          ` : ''}
                        </article>
                      `;
                    }).join('')}
                  </div>
                </section>
              `;
            }
            resultsContainer.innerHTML = html;
          }
        } else {
          const err = await res.json();
          showNotice(noticeArea, 'error', `评估运行失败：${err.error}`);
        }
      } catch (err) {
        showNotice(noticeArea, 'error', `网络请求失败：${err.message}`);
      } finally {
        runBtn.disabled = false;
        if (loadingText) loadingText.style.display = 'none';
      }
    });
  }

  if (exportBtn) {
    exportBtn.addEventListener('click', async () => {
      if (!lastReport) return;

      const originalText = exportBtn.innerText;
      exportBtn.disabled = true;
      exportBtn.innerText = '正在导出...';

      let systemPrompt = '未启用开发者模式或未能加载 System Prompt\n';
      let liveContext = '未启用开发者模式或未能加载 Live Context\n';

      try {
        const settingsRes = await fetch('/api/settings');
        if (settingsRes.ok) {
          const settingsData = await settingsRes.json();
          const csrfToken = settingsData.csrfToken || '';

          const state = loadBrowserState(storage);
          const devContextRes = await postJson('/api/dev/context', { text: 'ping', state: state }, csrfToken);

          if (devContextRes.ok) {
            const devData = await devContextRes.json();
            systemPrompt = devData.systemPrompt || systemPrompt;
            liveContext = devData.liveContext || liveContext;
          }
        }
      } catch (err) {
        console.error('Failed to load dev context for export:', err);
      }

      const reportMarkdown = `# 栖语行为特征质量评估报告 (Quality Lab Report)
生成时间: ${new Date().toLocaleString()}
测试用例总数: ${lastReport.totalCount}
通过测试数: ${lastReport.passedCount}
失败测试数: ${lastReport.totalCount - lastReport.passedCount}
整体通过率: ${(lastReport.passedCount / lastReport.totalCount * 100).toFixed(1)}%

## 详细评估结果
${lastReport.results.map(r => {
  const badgeLabel = failureBadgeFor(r.failureReason);
  const badgeText = !r.passed && badgeLabel ? ` [${badgeLabel}]` : '';
  return `
### [${r.passed ? 'PASSED' : 'FAILED'}] 用例名: ${r.name}${badgeText}
- **分类**: ${r.category}
- **输入**: \`${r.input}\`
- **预期响应**: ${r.expected.join(' | ')}
- **实际响应**: ${r.actual.join(' | ')}
${!r.passed ? `- **失败偏离描述**: ${r.failureReason}` : ''}
`;
}).join('\n')}

## 调试信息与上下文 (Developer Prompts & Context)

### System Prompt 原文
\`\`\`markdown
${systemPrompt}
\`\`\`

### 昨夜 Live Context (拼接的记忆与阶段)
\`\`\`markdown
${liveContext}
\`\`\`

---
*由“栖语·质量实验室”自动生成。*`;

      downloadBlob(reportMarkdown, `qiyu-eval-report-${Date.now()}.md`, 'text/markdown;charset=utf-8;');

      exportBtn.disabled = false;
      exportBtn.innerText = originalText;
    });
  }
}
