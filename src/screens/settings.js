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
import { confirmAction } from '../ui/confirm-dialog.js';
import {
  applyProviderPreset,
  detectProviderPreset,
  renderProviderPresetOptions
} from '../ui/provider-presets.js';

const MASKED_API_KEY = '••••••••';

function isMaskedApiKeyValue(value) {
  return String(value || '').trim() === MASKED_API_KEY;
}

export function render(container, context) {
  const storage = window.localStorage;
  let prefs = loadPreferences(storage);
  let state = loadBrowserState(storage);

  const innerHtml = `
    <div class="settings-workbench">
      <section class="settings-hero" aria-labelledby="settings-title">
        <div>
          <span class="settings-kicker">只在需要时调整</span>
          <h1 id="settings-title">默契中心</h1>
          <p>把接口、语气和边界调到合适的位置。设置完成后，回到夜话就能直接说。</p>
        </div>
        <div class="settings-hero-state" aria-hidden="true">
          <div>
            <span>当前路径</span>
            <strong>API 与偏好</strong>
          </div>
          <div>
            <span>保存位置</span>
            <strong>本机与服务端</strong>
          </div>
        </div>
      </section>

      ${prefs.onboardingState !== 'completed' ? `
        <div class="onboarding-warning-banner" data-notice-dismiss-scope="wrapper">
          ${renderNotice({
            type: 'warning',
            message: '你尚未完成首次设置。建议先完成初遇引导，开启我们之间的默契。 <button data-nav-path="/onboarding" class="btn primary notice-inline-action">去完成初遇引导</button>'
          })}
        </div>
      ` : ''}

      <div class="settings-notice-area"></div>
      <div class="settings-panel">

      <!-- Part 1: Normal Preferences -->
      <section class="settings-section" aria-labelledby="sec-normal-title">
        <div class="settings-section-head">
          <span class="settings-section-eyebrow">相处方式</span>
          <h2 id="sec-normal-title">相处温度</h2>
        </div>
        
        <div class="settings-form-stack">
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
            label: '本地上下文边界',
            description: '允许栖语在浏览器本地保存少量偏好与事实，用于之后的夜话连续性。',
            controlHtml: renderToggle({
              name: 'memoryConsent',
              checked: prefs.memoryConsent
            })
          })}
        </div>

        <div class="settings-actions">
          ${renderButton({ label: '保存温度配置', variant: 'primary', className: 'save-pref-btn settings-action-btn' })}
        </div>
      </section>

      <!-- Part 2: AI Soul Engine Settings -->
      <section class="settings-section" aria-labelledby="sec-ai-title">
        <div class="settings-section-head settings-section-head-split">
          <div>
            <span class="settings-section-eyebrow">模型接入</span>
            <h2 id="sec-ai-title">API 配置</h2>
          </div>
          ${renderButton({ label: '展开或收起配置', variant: 'normal', className: 'toggle-ai-btn settings-small-btn' })}
        </div>

        <div class="ai-config-panel">
          <div class="ai-status-card">
            <div class="status-row">
              <strong>连接状态</strong>
              <span class="status-badge">载入中...</span>
            </div>
            <div class="env-config-notice notice notice-warning">
              <span class="notice-icon" aria-hidden="true">注意</span>
              <span>当前由环境变量控制，页面保存的修改不会覆盖服务端已生效环境变量值。</span>
            </div>
            <div class="diagnostic-summary">
              <div><strong>实际接口地址:</strong> <span class="diag-url">-</span></div>
              <div><strong>最终运行模型:</strong> <span class="diag-model">-</span></div>
              <div><strong>配置生效来源:</strong> <span class="diag-source">-</span></div>
              <div><strong>最后诊断详情:</strong> <span class="diag-detail">-</span></div>
            </div>
          </div>

          <div class="notice notice-info">
            <span class="notice-icon" aria-hidden="true">提示</span>
            <span>填写你的 OpenAI 兼容或 Anthropic 原生大模型接口。如果未配置或配置出错，栖语将退回本地规则引擎。</span>
          </div>

          ${renderFieldRow({
            name: 'providerPreset',
            label: '服务商预设 (Provider Preset)',
            description: '快速载入常见大模型服务商的接口配置。',
            controlHtml: `
              <select id="input-providerPreset" name="providerPreset" class="form-select">
                ${renderProviderPresetOptions()}
              </select>
            `
          })}

          ${renderFieldRow({
            name: 'apiUrl',
            label: '接口地址 (API URL)',
            description: 'OpenAI 兼容终结点，或 Anthropic 原生 Messages 终结点。',
            controlHtml: renderInput({ name: 'apiUrl', placeholder: '比如：https://api.example.com/v1/chat/completions' })
          })}

          ${renderFieldRow({
            name: 'apiKey',
            label: '访问密钥 (API Key)',
            description: '你的私有 API 访问令牌。绝不上传给任何中心服务器。',
            controlHtml: `
              <div class="api-key-stack">
                <div class="api-key-control">
                  <input id="input-apiKey" name="apiKey" type="password" class="form-input" placeholder="输入 API Key">
                  <button type="button" class="btn toggle-pw-btn secret-toggle-btn" aria-label="显示 API 密钥">查看</button>
                </div>
                <div class="api-key-inline-notice"></div>
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

          <div class="settings-actions settings-actions-wrap">
            ${renderButton({ label: '测试 Provider 连接', variant: 'normal', className: 'test-connection-btn settings-action-btn' })}
            ${renderButton({ label: '测试栖语回复', variant: 'normal', className: 'test-chat-btn settings-action-btn' })}
            ${renderButton({ label: '保存 API 配置', variant: 'primary', className: 'save-ai-btn settings-action-btn' })}
          </div>
        </div>
      </section>

      <!-- Part 3: Data Actions & Privacy -->
      <section class="settings-section" aria-labelledby="sec-data-title">
        <div class="settings-section-head">
          <span class="settings-section-eyebrow">本地边界</span>
          <h2 id="sec-data-title">本地数据边界</h2>
        </div>
        
        <p class="settings-section-copy">
          管理你和栖语的本地上下文。你可以安全地导出，或在需要时彻底清空。
        </p>

        <div class="data-action-grid">
          ${renderButton({ label: '导出昨夜私语 (JSON)', variant: 'normal', className: 'export-data-btn settings-action-btn' })}
          ${renderButton({ label: '清空本地上下文', variant: 'danger', className: 'clear-memories-btn settings-action-btn' })}
          ${renderButton({ label: '抹去深夜相遇痕迹', variant: 'danger', className: 'clear-history-btn settings-action-btn' })}
        </div>
      </section>

      <!-- Part 4: Developer & Mirage Mode -->
      <section class="settings-section" aria-labelledby="sec-dev-title">
        <div class="settings-section-head">
          <span class="settings-section-eyebrow">开发调试</span>
          <h2 id="sec-dev-title">调试选项</h2>
        </div>
        
        ${renderFieldRow({
          name: 'devMode',
          label: '激活「幻境」实验室',
          description: '唤醒系统回归质量实验室，展示 System Prompt 预览与 live context 拼接。',
          controlHtml: renderToggle({
            name: 'devMode',
            checked: window.localStorage.getItem('qiyu_dev_mode') === 'true'
          })
        })}

        <div class="dev-preview-panel">
          <div class="dev-preview-block">
            <label class="field-label">当前 System Prompt 预览</label>
            <textarea readonly class="form-textarea dev-preview-textarea">加载中...</textarea>
          </div>
          <div class="dev-preview-block">
            <label class="field-label">最近拼接的 Live Context 预览</label>
            <textarea readonly class="form-textarea dev-preview-textarea">加载中...</textarea>
          </div>
        </div>
      </section>
      </div>
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
  const apiKeyInlineNotice = container.querySelector('.api-key-inline-notice');

  const saveAiBtn = container.querySelector('.save-ai-btn');
  const testConnectionBtn = container.querySelector('.test-connection-btn');
  const testChatBtn = container.querySelector('.test-chat-btn');
  const providerPreset = container.querySelector('[name="providerPreset"]');

  const exportDataBtn = container.querySelector('.export-data-btn');
  const clearMemoriesBtn = container.querySelector('.clear-memories-btn');
  const clearHistoryBtn = container.querySelector('.clear-history-btn');

  const devToggle = container.querySelector('[name="devMode"]');
  const devPanel = container.querySelector('.dev-preview-panel');

  const statusBadge = container.querySelector('.status-badge');
  const diagSummary = container.querySelector('.diagnostic-summary');
  const diagUrl = container.querySelector('.diag-url');
  const diagModel = container.querySelector('.diag-model');
  const diagSource = container.querySelector('.diag-source');
  const diagDetail = container.querySelector('.diag-detail');
  const envNotice = container.querySelector('.env-config-notice');

  function setApiKeyVisibility(type) {
    pwInput.type = type;
    togglePwBtn.innerText = type === 'password' ? '查看' : '隐藏';
    togglePwBtn.setAttribute('aria-label', type === 'password' ? '显示 API 密钥' : '隐藏 API 密钥');
  }

  function showNotification(type, message) {
    if (noticeArea) {
      noticeArea.innerHTML = renderNotice({ type, message });
    }
  }

  function updateHealthAndDiagnostics(config) {
    if (!statusBadge) return;

    let status = storage.getItem('qiyu_api_health_status');
    
    if (!config.hasLlm) {
      status = 'not_configured';
      storage.setItem('qiyu_api_health_status', status);
    } else if (!status || status === 'not_configured') {
      status = 'configured_untested';
      storage.setItem('qiyu_api_health_status', status);
    }

    let statusText = '未配置';
    let badgeColor = '#94a3b8'; // gray
    let badgeBg = 'rgba(148, 163, 184, 0.1)';

    if (status === 'configured_untested') {
      statusText = '已配置但未测试';
      badgeColor = '#eab308'; // yellow
      badgeBg = 'rgba(234, 179, 8, 0.1)';
    } else if (status === 'provider_connected') {
      statusText = 'Provider 已连接';
      badgeColor = '#3b82f6'; // blue
      badgeBg = 'rgba(59, 130, 246, 0.1)';
    } else if (status === 'chat_connected') {
      statusText = '栖语回复测试通过';
      badgeColor = '#22c55e'; // green
      badgeBg = 'rgba(34, 197, 94, 0.1)';
    } else if (status === 'chat_fallback') {
      statusText = '最近一次聊天回退本地';
      badgeColor = '#ef4444'; // red
      badgeBg = 'rgba(239, 68, 68, 0.1)';
    }

    statusBadge.innerText = statusText;
    statusBadge.style.color = badgeColor;
    statusBadge.style.backgroundColor = badgeBg;
    statusBadge.style.border = `1px solid ${badgeColor}33`;

    if (config.hasLlm || config.apiUrl) {
      if (diagSummary) diagSummary.style.display = 'flex';
      
      const displayUrl = config.apiUrl || '未配置';
      if (diagUrl) diagUrl.innerText = displayUrl;
      if (diagModel) diagModel.innerText = config.model || '未配置';
      
      let sourceText = '本地配置文件';
      if (config.source === 'env') {
        sourceText = '系统环境变量 (优先)';
      } else if (config.source === 'empty') {
        sourceText = '未检测到配置';
      }
      if (diagSource) diagSource.innerText = sourceText;
      if (envNotice) envNotice.style.display = config.source === 'env' ? 'block' : 'none';
    } else {
      if (diagSummary) diagSummary.style.display = 'none';
      if (envNotice) envNotice.style.display = 'none';
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
    showNotification('success', '深夜相处温度已保存并生效。');
  });

  // 2. Toggle Advanced AI Settings visibility
  toggleAiBtn.addEventListener('click', () => {
    const isHidden = aiPanel.style.display === 'none';
    aiPanel.style.display = isHidden ? 'flex' : 'none';
  });

  // 3. Password Visibility Toggle (WCAG AAA accessible update)
  pwInput.addEventListener('input', () => {
    if (pwInput.dataset) {
      pwInput.dataset.masked = 'false';
    }
    if (apiKeyInlineNotice) {
      apiKeyInlineNotice.style.display = 'none';
      apiKeyInlineNotice.innerText = '';
    }
  });

  togglePwBtn.addEventListener('click', () => {
    const maskedPlaceholderVisible = pwInput.dataset?.masked === 'true' || isMaskedApiKeyValue(pwInput.value);
    if (maskedPlaceholderVisible && pwInput.type === 'password') {
      showNotification('info', '当前显示的是脱敏后的 API Key 占位符，无法直接还原原始密钥。如需查看或修改，请重新输入。');
      if (apiKeyInlineNotice) {
        apiKeyInlineNotice.innerText = '当前显示的是脱敏占位符，无法直接还原原始 API Key。需要查看或修改时，请重新输入。';
        apiKeyInlineNotice.style.display = 'block';
      }
      if (typeof pwInput.focus === 'function') {
        pwInput.focus();
      }
      return;
    }

    setApiKeyVisibility(pwInput.type === 'password' ? 'text' : 'password');
  });

  // 4. Load Saved AI Settings from server
  async function fetchServerSettings() {
    try {
      const res = await fetch('/api/settings');
      if (res.ok) {
        const data = await res.json();
        container.querySelector('[name="apiUrl"]').value = data.apiUrl || '';
        container.querySelector('[name="apiKey"]').value = data.apiKey || '';
        container.querySelector('[name="apiKey"]').dataset.masked = data.apiKey === MASKED_API_KEY ? 'true' : 'false';
        setApiKeyVisibility('password');
        container.querySelector('[name="model"]').value = data.model || '';
        container.querySelector('[name="temperature"]').value = typeof data.temperature !== 'undefined' ? data.temperature : 0.8;
        container.querySelector('[name="timeoutMs"]').value = data.timeoutMs || 30000;
        if (providerPreset) {
          providerPreset.value = detectProviderPreset({ apiUrl: data.apiUrl, model: data.model });
        }
        
        if (data.csrfToken) {
          window.qiyuCsrfToken = data.csrfToken;
          updateDevUI();
        }

        updateHealthAndDiagnostics(data);
      }
    } catch (err) {
      showNotification('error', `未能同步云端引擎配置：${err.message}`);
    }
  }

  fetchServerSettings();

  // 5. Preset Selection
  if (providerPreset) {
    providerPreset.addEventListener('change', () => {
      const apiUrlInput = container.querySelector('[name="apiUrl"]');
      const modelInput = container.querySelector('[name="model"]');
      const preset = applyProviderPreset(providerPreset.value, { apiUrlInput, modelInput });
      showNotification('info', preset.notice);
    });
  }

  // 6. Test AI Connection
  testConnectionBtn.addEventListener('click', async () => {
    const apiUrl = container.querySelector('[name="apiUrl"]').value.trim();
    const apiKey = container.querySelector('[name="apiKey"]').value.trim();
    const model = container.querySelector('[name="model"]').value.trim();
    const timeoutMs = Number(container.querySelector('[name="timeoutMs"]').value);

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
        body: JSON.stringify({ apiUrl, apiKey, model, timeoutMs })
      });

      if (res.ok) {
        const data = await res.json();
        if (data.success) {
          storage.setItem('qiyu_api_health_status', 'provider_connected');
          if (diagDetail) {
            diagDetail.innerText = `[${new Date().toLocaleTimeString()}] Provider 通道测试成功 (延迟 ${data.latencyMs}ms)，已收到模型响应。`;
          }
          showNotification('success', '灵魂引擎握手成功，连接一切正常。');
          fetchServerSettings();
        } else {
          if (diagDetail) {
            diagDetail.innerText = `[${new Date().toLocaleTimeString()}] Provider 连接失败: ${data.error}`;
          }
          showNotification('error', `连接失败：${data.error || '未知模型错误'}`);
        }
      } else {
        showNotification('error', `请求被拒绝：HTTP ${res.status}`);
      }
    } catch (err) {
      showNotification('error', `网络握手超时：${err.message}`);
    } finally {
      testConnectionBtn.disabled = false;
      testConnectionBtn.innerHTML = originalText;
    }
  });

  // 6.2 Test Qiyu Reply Connection
  if (testChatBtn) {
    testChatBtn.addEventListener('click', async () => {
      const apiUrl = container.querySelector('[name="apiUrl"]').value.trim();
      const apiKey = container.querySelector('[name="apiKey"]').value.trim();
      const model = container.querySelector('[name="model"]').value.trim();
      const timeoutMs = Number(container.querySelector('[name="timeoutMs"]').value);

      if (!apiUrl || !model) {
        showNotification('warning', '请填入完整的接口地址 (API URL) 和模型名称以供测试。');
        return;
      }

      const originalText = testChatBtn.innerHTML;
      testChatBtn.disabled = true;
      testChatBtn.innerHTML = '<span class="loading-dots">发送中</span>';
      showNotification('warning', '正在向灵魂引擎发起测试夜聊会话，请稍候...');

      try {
        const res = await fetch('/api/settings/test-chat', {
          method: 'POST',
          headers: { 
            'Content-Type': 'application/json',
            'X-CSRF-Token': window.qiyuCsrfToken || ''
          },
          body: JSON.stringify({ apiUrl, apiKey, model, timeoutMs })
        });

        if (res.ok) {
          const data = await res.json();
          if (data.success) {
            storage.setItem('qiyu_api_health_status', 'chat_connected');
            if (diagDetail) {
              diagDetail.innerText = `[${new Date().toLocaleTimeString()}] 栖语回复测试成功 (延迟 ${data.latencyMs}ms)，栖语说: "${data.reply}"`;
            }
            showNotification('success', `栖语回复测试成功。栖语说：${data.reply}`);
            fetchServerSettings();
          } else {
            if (diagDetail) {
              diagDetail.innerText = `[${new Date().toLocaleTimeString()}] 栖语回复测试失败: ${data.error}`;
            }
            showNotification('error', `栖语回复测试失败：${data.error}`);
          }
        } else {
          showNotification('error', `请求被拒绝：HTTP ${res.status}`);
        }
      } catch (err) {
        showNotification('error', `握手通信故障：${err.message}`);
      } finally {
        testChatBtn.disabled = false;
        testChatBtn.innerHTML = originalText;
      }
    });
  }

  // 7. Save AI Settings to server
  saveAiBtn.addEventListener('click', async () => {
    const apiUrl = container.querySelector('[name="apiUrl"]').value.trim();
    const apiKey = container.querySelector('[name="apiKey"]').value.trim();
    const model = container.querySelector('[name="model"]').value.trim();
    const temperature = Number(container.querySelector('[name="temperature"]').value);
    const timeoutMs = Number(container.querySelector('[name="timeoutMs"]').value);

    const originalText = saveAiBtn.innerHTML;
    saveAiBtn.disabled = true;
    saveAiBtn.innerHTML = '<span class="loading-dots">保存中</span>';
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
        const data = await res.json();
        if (data.success) {
          const healthStatus = storage.getItem('qiyu_api_health_status');
          if (healthStatus !== 'chat_connected' && healthStatus !== 'provider_connected') {
            storage.setItem('qiyu_api_health_status', 'configured_untested');
          }
          showNotification('success', 'API 配置保存成功，下一次消息会使用新配置。');
          updateHealthAndDiagnostics(data);
        } else {
          showNotification('error', '保存失败。');
        }
      } else {
        showNotification('error', `保存失败：HTTP ${res.status}`);
      }
    } catch (err) {
      showNotification('error', `保存网络异常：${err.message}`);
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
    a.download = `qiyu-local-context-${Date.now()}.json`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    showNotification('success', '本地上下文已成功导出为备份 JSON。');
  });

  clearMemoriesBtn.addEventListener('click', async () => {
    const confirmed = await confirmAction({
      title: '清空本地上下文',
      message: '这会清空所有本地上下文事实，操作完成后无法找回。',
      confirmLabel: '清空'
    });
    if (confirmed) {
      state.memories = [];
      saveBrowserState(storage, state);
      showNotification('success', '本地上下文已清空。');
    }
  });

  clearHistoryBtn.addEventListener('click', async () => {
    const confirmed = await confirmAction({
      title: '重置全部相遇',
      message: '这会抹去所有对话痕迹、关系进度和历史归档。所有内容都会归零。',
      confirmLabel: '重置'
    });
    if (confirmed) {
      state = createInitialState(state.userId);
      saveBrowserState(storage, state);
      storage.removeItem('qiyu_trial_state');
      showNotification('success', '所有的痕迹均已归于夜空。再见，初见。');
    }
  });

  // 9. Developer & Mirage Mode Toggle
  function updateDevUI() {
    const devToggle = container.querySelector('[name="devMode"]');
    const devPanel = container.querySelector('.dev-preview-panel');
    if (!devToggle || !devPanel) return;

    const isDev = devToggle.checked;
    window.localStorage.setItem('qiyu_dev_mode', isDev ? 'true' : 'false');
    devPanel.style.display = isDev ? 'flex' : 'none';

    if (isDev) {
      const sysBox = devPanel.querySelectorAll('textarea')[0];
      const liveBox = devPanel.querySelectorAll('textarea')[1];
      if (sysBox && liveBox) {
        sysBox.value = '加载中...\n';
        liveBox.value = '加载中...\n';

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
  }

  if (devToggle) {
    devToggle.addEventListener('change', updateDevUI);
  }
  updateDevUI();
}
