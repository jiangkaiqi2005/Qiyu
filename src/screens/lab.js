import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { renderButton, renderNotice } from '../ui/components.js';
import { loadBrowserState } from '../qiyu/state.js';

export function render(container, context) {
  const storage = window.localStorage;
  const innerHtml = `
    <div class="card" style="max-width: 820px; padding: 40px 32px; text-align: left;">
      <h1 style="border-bottom: 1px solid rgba(223, 179, 85, 0.12); padding-bottom: 16px; margin-bottom: 24px;">质量实验室 (Quality Lab)</h1>
      <p class="subtitle" style="margin-top: -12px; margin-bottom: 28px;">深度陪伴回归分析与黄金测试集 (Golden Cases) 质量评估室。</p>

      <div class="lab-notice-area"></div>

      <div style="margin-bottom: 28px; display: flex; gap: 14px; align-items: center; flex-wrap: wrap;">
        ${renderButton({ label: '运行黄金测试集', variant: 'primary', className: 'run-evals-btn' })}
        ${renderButton({ label: '导出评估报告', variant: 'normal', className: 'export-report-btn', attrs: 'style="display:none;"' })}
        <span class="eval-loading-status" style="display: none; font-size: 14px; color: var(--muted);"><span class="loading-dots">正在运行测试用例，请稍候</span></span>
      </div>

      <div class="eval-summary-card notice notice-info" style="display: none; margin-bottom: 28px; flex-direction: column; gap: 10px; border-color: rgba(223,179,85,0.25); background: rgba(223,179,85,0.06); padding: 18px 24px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);">
        <h4 style="margin: 0; color: var(--accent); font-size: 16px; font-weight: bold; border: 0; padding: 0;">评估结果概览</h4>
        <div style="display: flex; gap: 32px; margin-top: 4px; align-items: center;">
          <div>通过率：<strong class="pass-rate-text" style="font-size: 22px; color: var(--success); font-family: monospace;">0/0</strong></div>
          <div style="border-left: 1px solid rgba(223, 179, 85, 0.15); height: 24px;"></div>
          <div>状态评估：<strong class="eval-status-text" style="font-size: 16px;">良好</strong></div>
        </div>
      </div>

      <div class="eval-results-container" style="display: flex; flex-direction: column; gap: 16px; width: 100%;">
        <p style="color: var(--muted); text-align: center; padding: 48px 0; font-size: 14.5px;">点击上方按钮开始执行系统回归基线测试用例。</p>
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
            const grouped = {};
            data.results.forEach(r => {
              const cat = r.category || '其他';
              if (!grouped[cat]) grouped[cat] = [];
              grouped[cat].push(r);
            });

            let html = '';
            for (const [cat, casesList] of Object.entries(grouped)) {
              const hasFailed = casesList.some(c => !c.passed);
              const catHeaderStyle = hasFailed 
                ? 'font-size: 15px; color: #ff9d9d; margin-top: 24px; border-bottom: 1px solid rgba(255, 157, 157, 0.25); padding-bottom: 6px; display: flex; align-items: center; gap: 8px;'
                : 'font-size: 15px; color: var(--accent); margin-top: 24px; border-bottom: 1px solid rgba(223, 179, 85, 0.15); padding-bottom: 6px; display: flex; align-items: center; gap: 8px;';
              
              html += `
                <div class="category-group" style="margin-bottom: 20px;">
                  <h3 style="${catHeaderStyle}">
                    <span>类别: ${cat}</span>
                    ${hasFailed ? '<span style="font-size: 11px; background: rgba(255,100,100,0.2); color: #ff9d9d; padding: 2px 6px; border-radius: 4px; font-weight: normal;">存在未通过项</span>' : ''}
                  </h3>
                  <div style="display: flex; flex-direction: column; gap: 12px; margin-top: 12px;">
                    ${casesList.map(r => {
                      const passClass = r.passed ? 'notice-success' : 'notice-error';
                      const passLabel = r.passed ? '✓ PASSED' : '✕ FAILED';
                      
                      let badge = '';
                      if (!r.passed) {
                        if (r.failureReason.includes('安全边界错')) badge = '安全边界错';
                        else if (r.failureReason.includes('晚安后开启话题')) badge = '晚安后开启话题';
                        else if (r.failureReason.includes('关系阶段错')) badge = '关系阶段错';
                        else if (r.failureReason.includes('过长')) badge = '过长';
                        else if (r.failureReason.includes('禁用语')) badge = '禁用语';
                        else badge = '偏差';
                      }
                      
                      const badgeHtml = badge 
                        ? `<span style="background: #ff5f5f; color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 11px; margin-left: 8px; font-weight: bold;">[${badge}]</span>`
                        : '';

                      return `
                        <div class="notice ${passClass}" style="flex-direction: column; align-items: stretch; padding: 16px; margin: 0; gap: 8px;">
                          <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 8px;">
                            <strong style="font-size: 14px;">用例：${r.name}${badgeHtml}</strong>
                            <span style="font-weight: bold; font-size: 12px;">${passLabel}</span>
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
                    }).join('')}
                  </div>
                </div>
              `;
            }
            resultsContainer.innerHTML = html;
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
          const devContextRes = await fetch('/api/dev/context', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'X-CSRF-Token': csrfToken
            },
            body: JSON.stringify({ text: 'ping', state: state })
          });

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
  let badgeText = '';
  if (!r.passed) {
    if (r.failureReason.includes('安全边界错')) badgeText = ' [安全边界错]';
    else if (r.failureReason.includes('晚安后开启话题')) badgeText = ' [晚安后开启话题]';
    else if (r.failureReason.includes('关系阶段错')) badgeText = ' [关系阶段错]';
    else if (r.failureReason.includes('过长')) badgeText = ' [过长]';
    else if (r.failureReason.includes('禁用语')) badgeText = ' [禁用语]';
  }
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

      const blob = new Blob([reportMarkdown], { type: 'text/markdown;charset=utf-8;' });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.setAttribute('download', `qiyu-eval-report-${Date.now()}.md`);
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);

      exportBtn.disabled = false;
      exportBtn.innerText = originalText;
    });
  }
}
