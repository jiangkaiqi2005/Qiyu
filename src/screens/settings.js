import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadPreferences, savePreferences } from '../qiyu/preferences.js';
import { loadBrowserState, saveBrowserState, createInitialState } from '../qiyu/state.js';
import {
  renderButton,
  renderInput,
  renderToggle,
  renderFieldRow,
  renderNotice
} from '../ui/components.js';

export function render(container, context) {
  const storage = window.localStorage;
  let prefs = loadPreferences(storage);
  let state = loadBrowserState(storage);

  const innerHtml = `
    <div class="card" style="max-width: 720px;">
      <h1>默契中心</h1>
      <p class="subtitle">在这里，微调我们的相处温度，或是探索栖语的灵魂深处。</p>

      <div class="settings-notice-area"></div>

      <!-- Part 1: Normal Preferences -->
      <section class="settings-section" aria-labelledby="sec-normal-title" style="margin-bottom: 32px;">
        <h2 id="sec-normal-title" style="font-size: 18px; color: var(--accent); margin-bottom: 16px; border-left: 3px solid var(--accent); padding-left: 8px;">相处温度（基本设置）</h2>
        
        <div style="display: flex; flex-direction: column; gap: 8px;">
          ${renderFieldRow({
            name: 'userName',
            label: '深夜昵称',
            description: '我该如何在耳畔轻轻唤你？',
            controlHtml: renderInput({
              name: 'userName',
              value: prefs.userName || '',
              placeholder: '比如：林深、小雨...'
            })
          })}

          ${renderFieldRow({
            name: 'sleepTime',
            label: '安眠时刻',
            description: '你预计入睡的时间。届时我会主动收拢话题。',
            controlHtml: renderInput({
              name: 'sleepTime',
              type: 'time',
              value: prefs.sleepTime || '23:00'
            })
          })}

          ${renderFieldRow({
            name: 'companionshipStyle',
            label: '陪伴风格',
            description: '微调我在深夜里的相处温度与脾气。',
            controlHtml: `
              <select id="input-companionshipStyle" name="companionshipStyle" class="form-select">
                <option value="gentle" ${prefs.companionshipStyle === 'gentle' ? 'selected' : ''}>温柔倾听</option>
                <option value="playful" ${prefs.companionshipStyle === 'playful' ? 'selected' : ''}>轻松调侃</option>
                <option value="quiet" ${prefs.companionshipStyle === 'quiet' ? 'selected' : ''}>安静聆听</option>
              </select>
            `
          })}

          ${renderFieldRow({
            name: 'memoryConsent',
            label: '私语记忆功能',
            description: '允许我在浏览器本地悄悄记下你的喜好与碎念。',
            controlHtml: renderToggle({
              name: 'memoryConsent',
              checked: prefs.memoryConsent
            })
          })}
        </div>

        <div style="display: flex; justify-content: flex-end; margin-top: 16px;">
          ${renderButton({ label: '保存温度配置', variant: 'primary', className: 'save-pref-btn', attrs: 'style="min-height:44px;"' })}
        </div>
      </section>

      <!-- Part 2: AI Soul Engine Settings -->
      <section class="settings-section" aria-labelledby="sec-ai-title" style="margin-bottom: 32px; border-top: 1px dashed rgba(223,179,85,0.15); padding-top: 24px;">
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; flex-wrap: wrap; gap: 12px;">
          <h2 id="sec-ai-title" style="font-size: 18px; color: var(--accent); margin: 0; border-left: 3px solid var(--accent); padding-left: 8px;">灵魂引擎 (AI 接入设置)</h2>
          ${renderButton({ label: '显示/隐藏高级配置', variant: 'normal', className: 'toggle-ai-btn', attrs: 'style="font-size: 13px; padding: 6px 12px;"' })}
        </div>

        <div class="ai-config-panel" style="display: none; flex-direction: column; gap: 8px;">
          <div class="notice notice-info" style="font-size:13px; line-height:1.6; margin-bottom:16px;">
            <span class="notice-icon" aria-hidden="true">ℹ</span>
            <span>填写你的 OpenAI 兼容大模型接口。如果未配置或配置出错，栖语将退回本地规则引擎。</span>
          </div>

          ${renderFieldRow({
            name: 'apiUrl',
            label: '接口地址 (API URL)',
            description: 'OpenAI 兼容终结点。如：https://api.openai.com/v1/chat/completions',
            controlHtml: renderInput({ name: 'apiUrl', placeholder: '比如：https://api.example.com/v1/chat/completions' })
          })}

          ${renderFieldRow({
            name: 'apiKey',
            label: '访问密钥 (API Key)',
            description: '你的私有 API 访问令牌。绝不上传给任何中心服务器。',
            controlHtml: `
              <div style="display: flex; gap: 8px; width: 100%;">
                <input id="input-apiKey" name="apiKey" type="password" class="form-input" style="flex: 1;" placeholder="输入 API Key">
                <button type="button" class="btn toggle-pw-btn" aria-label="显示 API 密钥" style="padding: 6px 12px; min-width:44px; min-height:44px;">👁️</button>
              </div>
            `
          })}

          ${renderFieldRow({
            name: 'model',
            label: '模型名称 (Model)',
            description: '选用的模型名称。如：gpt-4o, claude-3-5-sonnet',
            controlHtml: renderInput({ name: 'model', placeholder: '比如：gpt-4o' })
          })}

          ${renderFieldRow({
            name: 'temperature',
            label: '随机温度 (Temperature)',
            description: '数值越高发言越随性，越低发言越严谨克制。推荐 0.8。',
            controlHtml: renderInput({ name: 'temperature', type: 'number', placeholder: '0.8', attrs: 'min="0" max="2" step="0.1"' })
          })}

          ${renderFieldRow({
            name: 'timeoutMs',
            label: '网络超时 (Timeout)',
            description: '请求的最大等待时间（毫秒）。默认 30000（30秒）。',
            controlHtml: renderInput({ name: 'timeoutMs', type: 'number', placeholder: '30000', attrs: 'min="1000"' })
          })}

          <div style="display: flex; justify-content: flex-end; gap: 12px; margin-top: 16px; flex-wrap: wrap;">
            ${renderButton({ label: '推荐默认配置', variant: 'normal', className: 'fill-defaults-btn', attrs: 'style="min-height:44px;"' })}
            ${renderButton({ label: '灵魂连接测试', variant: 'normal', className: 'test-connection-btn', attrs: 'style="min-height:44px;"' })}
            ${renderButton({ label: '注入灵魂引擎', variant: 'primary', className: 'save-ai-btn', attrs: 'style="min-height:44px;"' })}
          </div>
        </div>
      </section>

      <!-- Part 3: Data Actions & Privacy -->
      <section class="settings-section" aria-labelledby="sec-data-title" style="margin-bottom: 32px; border-top: 1px dashed rgba(223,179,85,0.15); padding-top: 24px;">
        <h2 id="sec-data-title" style="font-size: 18px; color: var(--accent); margin-bottom: 16px; border-left: 3px solid var(--accent); padding-left: 8px;">记忆封存与遗忘 (数据保护)</h2>
        
        <p style="font-size: 13px; line-height: 1.6; color: var(--muted); margin-bottom: 16px;">
          管理你和栖语的本地私密印记。你可以安全地导出或将其彻底归于虚无。
        </p>

        <div style="display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 16px;">
          ${renderButton({ label: '导出昨夜私语 (JSON)', variant: 'normal', className: 'export-data-btn', attrs: 'style="min-height:44px;"' })}
          ${renderButton({ label: '遗忘所有提取的印记', variant: 'danger', className: 'clear-memories-btn', attrs: 'style="min-height:44px;"' })}
          ${renderButton({ label: '抹去深夜相遇痕迹', variant: 'danger', className: 'clear-history-btn', attrs: 'style="min-height:44px;"' })}
        </div>
      </section>

      <!-- Part 4: Developer & Mirage Mode -->
      <section class="settings-section" aria-labelledby="sec-dev-title" style="border-top: 1px dashed rgba(223,179,85,0.15); padding-top: 24px;">
        <h2 id="sec-dev-title" style="font-size: 18px; color: var(--accent); margin-bottom: 16px; border-left: 3px solid var(--accent); padding-left: 8px;">开发者探幽 (调试选项)</h2>
        
        ${renderFieldRow({
          name: 'devMode',
          label: '激活「幻境」实验室',
          description: '唤醒系统回归质量实验室，展示 System Prompt 预览与 live context 拼接。',
          controlHtml: renderToggle({
            name: 'devMode',
            checked: window.localStorage.getItem('qiyu_dev_mode') === 'true'
          })
        })}

        <div class="dev-preview-panel" style="display: none; flex-direction: column; gap: 16px; margin-top: 16px;">
          <div style="display: flex; flex-direction: column; gap: 8px;">
            <label class="field-label">当前 System Prompt 预览</label>
            <textarea readonly class="form-textarea" style="font-family: monospace; font-size: 12px; background: rgba(0,0,0,0.3); opacity: 0.8; height: 180px;">加载中...</textarea>
          </div>
          <div style="display: flex; flex-direction: column; gap: 8px;">
            <label class="field-label">最近拼接的 Live Context 预览</label>
            <textarea readonly class="form-textarea" style="font-family: monospace; font-size: 12px; background: rgba(0,0,0,0.3); opacity: 0.8; height: 180px;">加载中...</textarea>
          </div>
        </div>
      </section>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/settings');
  bindNavigation(container, context.router);

  const noticeArea = container.querySelector('.settings-notice-area');
  const normalSaveBtn = container.querySelector('.save-pref-btn');
  const toggleAiBtn = container.querySelector('.toggle-ai-btn');
  const aiPanel = container.querySelector('.ai-config-panel');
  const togglePwBtn = container.querySelector('.toggle-pw-btn');
  const pwInput = container.querySelector('[name="apiKey"]');

  const saveAiBtn = container.querySelector('.save-ai-btn');
  const fillDefaultsBtn = container.querySelector('.fill-defaults-btn');
  const testConnectionBtn = container.querySelector('.test-connection-btn');

  const exportDataBtn = container.querySelector('.export-data-btn');
  const clearMemoriesBtn = container.querySelector('.clear-memories-btn');
  const clearHistoryBtn = container.querySelector('.clear-history-btn');

  const devToggle = container.querySelector('[name="devMode"]');
  const devPanel = container.querySelector('.dev-preview-panel');

  function showNotification(type, message) {
    if (noticeArea) {
      noticeArea.innerHTML = renderNotice({ type, message });
    }
  }

  // 1. Handle normal preferences saving
  normalSaveBtn.addEventListener('click', () => {
    const userName = container.querySelector('[name="userName"]').value.trim();
    const sleepTime = container.querySelector('[name="sleepTime"]').value;
    const style = container.querySelector('[name="companionshipStyle"]').value;
    const consent = container.querySelector('[name="memoryConsent"]').checked;

    prefs.userName = userName || '你';
    prefs.sleepTime = sleepTime || '23:00';
    prefs.companionshipStyle = style;
    prefs.memoryConsent = consent;

    savePreferences(storage, prefs);
    showNotification('success', '✓ 深夜相处温度已保存并生效。');
  });

  // 2. Toggle Advanced AI Settings visibility
  toggleAiBtn.addEventListener('click', () => {
    const isHidden = aiPanel.style.display === 'none';
    aiPanel.style.display = isHidden ? 'flex' : 'none';
  });

  // 3. Password Visibility Toggle (WCAG AAA accessible update)
  togglePwBtn.addEventListener('click', () => {
    const type = pwInput.type === 'password' ? 'text' : 'password';
    pwInput.type = type;
    togglePwBtn.innerText = type === 'password' ? '👁️' : '🔒';
    togglePwBtn.setAttribute('aria-label', type === 'password' ? '显示 API 密钥' : '隐藏 API 密钥');
  });

  // 4. Load Saved AI Settings from server
  async function fetchServerSettings() {
    try {
      const res = await fetch('/api/settings');
      if (res.ok) {
        const data = await res.json();
        container.querySelector('[name="apiUrl"]').value = data.apiUrl || '';
        container.querySelector('[name="apiKey"]').value = data.apiKey || '';
        container.querySelector('[name="model"]').value = data.model || '';
        container.querySelector('[name="temperature"]').value = typeof data.temperature !== 'undefined' ? data.temperature : 0.8;
        container.querySelector('[name="timeoutMs"]').value = data.timeoutMs || 30000;
        
        if (data.csrfToken) {
          window.qiyuCsrfToken = data.csrfToken;
          updateDevUI();
        }
      }
    } catch (err) {
      showNotification('error', `未能同步云端引擎配置：${err.message}`);
    }
  }

  fetchServerSettings();

  // 5. Fill Recommended Defaults SOTA values
  fillDefaultsBtn.addEventListener('click', () => {
    container.querySelector('[name="apiUrl"]').value = 'https://api.openai.com/v1/chat/completions';
    container.querySelector('[name="apiKey"]').value = '';
    container.querySelector('[name="model"]').value = 'gpt-4o';
    container.querySelector('[name="temperature"]').value = 0.8;
    container.querySelector('[name="timeoutMs"]').value = 30000;
    showNotification('success', '已载入推荐 SOTA AI 引擎模板。请填入你的 API Key 后连接。');
  });

  // 6. Test AI Connection
  testConnectionBtn.addEventListener('click', async () => {
    const apiUrl = container.querySelector('[name="apiUrl"]').value.trim();
    const apiKey = container.querySelector('[name="apiKey"]').value.trim();
    const model = container.querySelector('[name="model"]').value.trim();

    if (!apiUrl || !model) {
      showNotification('warning', '请填入完整的接口地址 (API URL) 和模型名称以供测试。');
      return;
    }

    const originalText = testConnectionBtn.innerHTML;
    testConnectionBtn.disabled = true;
    testConnectionBtn.innerHTML = '<span class="loading-dots">连接中</span>';
    showNotification('warning', '正在尝试建立灵魂引擎握手连接，请稍候...');

    try {
      const res = await fetch('/api/settings/test', {
        method: 'POST',
        headers: { 
          'Content-Type': 'application/json',
          'X-CSRF-Token': window.qiyuCsrfToken || ''
        },
        body: JSON.stringify({ apiUrl, apiKey, model })
      });

      if (res.ok) {
        const data = await res.json();
        if (data.success) {
          showNotification('success', '✓ 灵魂引擎握手成功！连接一切正常。');
        } else {
          showNotification('error', `✕ 连接失败：${data.error || '未知模型错误'}`);
        }
      } else {
        showNotification('error', `✕ 请求被拒绝：HTTP ${res.status}`);
      }
    } catch (err) {
      showNotification('error', `✕ 网络握手超时：${err.message}`);
    } finally {
      testConnectionBtn.disabled = false;
      testConnectionBtn.innerHTML = originalText;
    }
  });

  // 7. Save AI Settings to server
  saveAiBtn.addEventListener('click', async () => {
    const apiUrl = container.querySelector('[name="apiUrl"]').value.trim();
    const apiKey = container.querySelector('[name="apiKey"]').value.trim();
    const model = container.querySelector('[name="model"]').value.trim();
    const temperature = Number(container.querySelector('[name="temperature"]').value);
    const timeoutMs = Number(container.querySelector('[name="timeoutMs"]').value);

    const originalText = saveAiBtn.innerHTML;
    saveAiBtn.disabled = true;
    saveAiBtn.innerHTML = '<span class="loading-dots">注入中</span>';
    try {
      const res = await fetch('/api/settings', {
        method: 'POST',
        headers: { 
          'Content-Type': 'application/json',
          'X-CSRF-Token': window.qiyuCsrfToken || ''
        },
        body: JSON.stringify({ apiUrl, apiKey, model, temperature, timeoutMs })
      });

      if (res.ok) {
        showNotification('success', '✓ 灵魂引擎配置成功注入服务端配置，重启生效。');
      } else {
        showNotification('error', `✕ 注入失败：HTTP ${res.status}`);
      }
    } catch (err) {
      showNotification('error', `✕ 注入网络异常：${err.message}`);
    } finally {
      saveAiBtn.disabled = false;
      saveAiBtn.innerHTML = originalText;
    }
  });

  // 8. Data Export and Cleanup Actions
  exportDataBtn.addEventListener('click', () => {
    const backup = {
      preferences: prefs,
      state: state
    };
    const blob = new Blob([JSON.stringify(backup, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `qiyu-whispers-imprints-${Date.now()}.json`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    showNotification('success', '✓ 昨夜私语印记数据已成功导出为备份 JSON。');
  });

  clearMemoriesBtn.addEventListener('click', () => {
    if (confirm('确认遗忘我们所有的默契印记事实吗？这将无法找回。')) {
      state.memories = [];
      saveState();
      showNotification('success', '✓ 碎念事实已彻底消散。');
    }
  });

  clearHistoryBtn.addEventListener('click', () => {
    if (confirm('确定彻底抹去深夜里我们所有的相遇和对话痕迹吗？所有好感度和历史将被彻底重置为零。')) {
      state = createInitialState(state.userId);
      saveState();
      storage.removeItem('qiyu_trial_state');
      showNotification('success', '✓ 所有的痕迹均已归于夜空。再见，初见。');
    }
  });

  // 9. Developer & Mirage Mode Toggle
  function updateDevUI() {
    const isDev = devToggle.checked;
    window.localStorage.setItem('qiyu_dev_mode', isDev ? 'true' : 'false');
    devPanel.style.display = isDev ? 'flex' : 'none';

    if (isDev) {
      const sysBox = devPanel.querySelectorAll('textarea')[0];
      const liveBox = devPanel.querySelectorAll('textarea')[1];
      sysBox.value = '加载中...\n';
      liveBox.value = '加载中...\n';

      // Load System Prompt and live context from single source of truth
      fetch('/api/dev/context', {
        method: 'POST',
        headers: { 
          'Content-Type': 'application/json',
          'X-CSRF-Token': window.qiyuCsrfToken || ''
        },
        body: JSON.stringify({ text: 'ping', state: state })
      }).then(async (res) => {
        if (res.ok) {
          const data = await res.json();
          sysBox.value = data.systemPrompt || '加载失败';
          liveBox.value = data.liveContext || '加载失败';
        } else {
          sysBox.value = '加载出了点小状况。';
          liveBox.value = '加载出了点小状况。';
        }
      }).catch(() => {
        sysBox.value = '加载出了点小状况。';
        liveBox.value = '加载出了点小状况。';
      });
    }
  }

  devToggle.addEventListener('change', updateDevUI);
  updateDevUI();
}
