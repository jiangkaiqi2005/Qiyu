import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadPreferences, savePreferences } from '../qiyu/preferences.js';
import { renderButton, renderInput, renderToggle, renderFieldRow, renderNotice } from '../ui/components.js';
import { loadBrowserState, saveBrowserState } from '../qiyu/state.js';

export function render(container, context) {
  const storage = window.localStorage;
  let prefs = loadPreferences(storage);

  const innerHtml = `
    <div class="card">
      <h1>设置中心</h1>
      <p class="subtitle">管理你的个人偏好与大语言模型 (AI) 连接配置。</p>

      <div class="settings-notice-area"></div>

      <section class="settings-section">
        <h3 style="color: var(--accent); margin-bottom: 16px; border-bottom: 1px solid rgba(216, 169, 75, 0.1); padding-bottom: 8px;">基本设置</h3>
        ${renderFieldRow({
          label: '如何称呼你',
          description: '栖语深夜里对你的昵称',
          controlHtml: renderInput({ name: 'userName', value: prefs.userName })
        })}
        ${renderFieldRow({
          label: '休息时间',
          description: '用于睡眠前对话收束的时间点',
          controlHtml: renderInput({ name: 'sleepTime', type: 'time', value: prefs.sleepTime })
        })}
        ${renderFieldRow({
          label: '陪伴风格',
          description: '温柔倾听、轻松调侃或安静聆听',
          controlHtml: `
            <select name="style" class="form-input" style="width: 180px;">
              <option value="gentle" ${prefs.companionshipStyle === 'gentle' ? 'selected' : ''}>温柔倾听</option>
              <option value="playful" ${prefs.companionshipStyle === 'playful' ? 'selected' : ''}>轻松调侃</option>
              <option value="quiet" ${prefs.companionshipStyle === 'quiet' ? 'selected' : ''}>安静聆听</option>
            </select>
          `
        })}
        ${renderFieldRow({
          label: '对话记忆功能',
          description: '是否同意栖语在浏览器本地存储对话事实以保持默契',
          controlHtml: renderToggle({ name: 'memoryConsent', checked: prefs.memoryConsent })
        })}
      </section>

      <section class="settings-section" style="margin-top: 32px; border-top: 1px solid rgba(216, 169, 75, 0.15); padding-top: 24px;">
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
          <h3 style="margin: 0; color: var(--accent);">大语言模型 (AI) 设置</h3>
          ${renderToggle({ name: 'showAdvanced', checked: false, label: '显示高级配置' })}
        </div>

        <div class="advanced-llm-fields" style="display: none; flex-direction: column; gap: 12px; margin-top: 16px;">
          ${renderFieldRow({
            label: 'API 地址 (API URL)',
            description: '例如：https://api.openai.com/v1',
            controlHtml: renderInput({ name: 'apiUrl', value: '' })
          })}
          ${renderFieldRow({
            label: 'API 密钥 (API Key)',
            description: '安全储存于本地服务，绝不在浏览器端暴露明文',
            controlHtml: `
              <div style="display: flex; gap: 8px; width: 100%;">
                <input name="apiKey" type="password" class="form-input" style="flex: 1;" placeholder="输入 API Key">
                <button type="button" class="btn toggle-pw-btn" style="padding: 6px 12px;">👁️</button>
              </div>
            `
          })}
          ${renderFieldRow({
            label: '模型名称 (Model)',
            description: '例如：gpt-4o-mini、deepseek-chat',
            controlHtml: renderInput({ name: 'model', value: '' })
          })}
          ${renderFieldRow({
            label: '温度控制 (Temperature)',
            description: '数值越低回答越理性稳定，默认 0.8',
            controlHtml: renderInput({ name: 'temperature', type: 'number', attrs: 'min="0" max="2" step="0.1"', value: '0.8' })
          })}
          ${renderFieldRow({
            label: '超时时间 (Timeout ms)',
            description: '请求接口等待的最大毫秒数，默认 30000',
            controlHtml: renderInput({ name: 'timeoutMs', type: 'number', value: '30000' })
          })}

          <div style="display: flex; gap: 12px; margin-top: 16px; flex-wrap: wrap;">
            ${renderButton({ label: '测试连接', attrs: 'class="btn test-connection-btn"' })}
            ${renderButton({ label: '加载推荐默认值', attrs: 'class="btn load-defaults-btn"' })}
            ${renderButton({ label: '保存 AI 配置', variant: 'primary', attrs: 'class="btn primary save-llm-btn"' })}
          </div>
        </div>
      </section>

      <section class="settings-section" style="margin-top: 32px; border-top: 1px solid rgba(216, 169, 75, 0.15); padding-top: 24px;">
        <h3 style="color: var(--accent); margin-bottom: 16px;">隐私与数据操作</h3>
        <p class="subtitle" style="margin-bottom: 16px;">对你浏览器本地的安全存储进行备份或清空操作。</p>
        <div style="display: flex; gap: 12px; flex-wrap: wrap;">
          ${renderButton({ label: '导出所有本地数据', attrs: 'class="btn export-data-btn"' })}
          ${renderButton({ label: '清空事实记忆', variant: 'danger', attrs: 'class="btn danger clear-mem-btn"' })}
          ${renderButton({ label: '重置并清空所有历史', variant: 'danger', attrs: 'class="btn danger reset-history-btn"' })}
        </div>
      </section>

      <section class="settings-section" style="margin-top: 32px; border-top: 1px solid rgba(216, 169, 75, 0.15); padding-top: 24px;">
        <h3 style="color: var(--accent); margin-bottom: 16px;">开发者选项 (Developer Options)</h3>
        ${renderFieldRow({
          label: '开发者模式 (Developer Mode)',
          description: '启用后将解锁左侧导航栏的回归测试实验室 (🧪 实验室)',
          controlHtml: renderToggle({ name: 'devMode', checked: storage.getItem('qiyu_dev_mode') === 'true' })
        })}
        
        <div class="dev-live-previews" style="display: none; flex-direction: column; gap: 16px; margin-top: 20px;">
          <div>
            <h4 style="margin: 0 0 8px; color: var(--accent); font-size: 14px;">系统 Prompt 框架预览</h4>
            <pre class="sys-prompt-preview" style="background: rgba(0,0,0,0.4); border: 1px solid var(--line); padding: 12px; border-radius: 8px; font-family: monospace; font-size: 12px; white-space: pre-wrap; margin: 0; max-height: 200px; overflow-y: auto;"></pre>
          </div>
          <div>
            <h4 style="margin: 0 0 8px; color: var(--accent); font-size: 14px;">当前 Prompt 实时上下文结构</h4>
            <pre class="context-prompt-preview" style="background: rgba(0,0,0,0.4); border: 1px solid var(--line); padding: 12px; border-radius: 8px; font-family: monospace; font-size: 12px; white-space: pre-wrap; margin: 0; max-height: 200px; overflow-y: auto;"></pre>
          </div>
        </div>
      </section>

      <div style="margin-top: 40px; border-top: 1px solid rgba(216, 169, 75, 0.1); padding-top: 20px; text-align: right;">
        ${renderButton({ label: '保存基本偏好设置', variant: 'primary', attrs: 'class="btn primary save-base-settings-btn"' })}
      </div>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/settings');
  bindNavigation(container, context.router);

  const noticeArea = container.querySelector('.settings-notice-area');
  const advancedFields = container.querySelector('.advanced-llm-fields');
  
  const showAdvancedToggle = container.querySelector('[name="showAdvanced"]');
  const devModeToggle = container.querySelector('[name="devMode"]');
  const togglePwBtn = container.querySelector('.toggle-pw-btn');
  const pwInput = container.querySelector('[name="apiKey"]');

  const saveBaseBtn = container.querySelector('.save-base-settings-btn');
  const saveLlmBtn = container.querySelector('.save-llm-btn');
  const testConnBtn = container.querySelector('.test-connection-btn');
  const loadDefaultsBtn = container.querySelector('.load-defaults-btn');
  
  const exportBtn = container.querySelector('.export-data-btn');
  const clearMemBtn = container.querySelector('.clear-mem-btn');
  const resetHistoryBtn = container.querySelector('.reset-history-btn');

  const devPreviews = container.querySelector('.dev-live-previews');
  const sysPromptPreview = container.querySelector('.sys-prompt-preview');
  const contextPromptPreview = container.querySelector('.context-prompt-preview');

  function showNotice(type, message) {
    if (noticeArea) {
      noticeArea.innerHTML = renderNotice({ type, message });
      container.querySelector('.app-main-content').scrollTop = 0;
      setTimeout(() => {
        noticeArea.innerHTML = '';
      }, 4000);
    }
  }

  // Password hide/reveal
  if (togglePwBtn && pwInput) {
    togglePwBtn.addEventListener('click', () => {
      const type = pwInput.getAttribute('type') === 'password' ? 'text' : 'password';
      pwInput.setAttribute('type', type);
      togglePwBtn.innerText = type === 'password' ? '👁️' : '🔒';
    });
  }

  // Toggle advanced LLM configuration
  if (showAdvancedToggle) {
    showAdvancedToggle.addEventListener('change', (e) => {
      advancedFields.style.display = e.target.checked ? 'flex' : 'none';
    });
  }

  // Toggle Dev Mode (requires shell re-rendering to update Quality Lab link)
  if (devModeToggle) {
    devModeToggle.addEventListener('change', (e) => {
      storage.setItem('qiyu_dev_mode', e.target.checked ? 'true' : 'false');
      render(container, context);
    });
  }

  // Load Developer Previews if active
  function loadDevPreviews() {
    const isDev = storage.getItem('qiyu_dev_mode') === 'true';
    if (isDev && devPreviews) {
      devPreviews.style.display = 'flex';
      
      sysPromptPreview.innerText = `[SYSTEM PROMPT OUTLINE]
------------------------------------
【栖语人设核心】:
- 深夜的陪伴者与倾听者，带着几分温暖的毒舌与调侃。
- 绝非死板客服。避免复述用户的话语，不讲官方套话。
- 习惯性有呼吸感、停顿、口癖（如“……”, “哈”, “嗯”）。

【危机干预策略 (Crisis Guardrail)】:
- 如果识别自残、自杀自虐，无条件切换到直白诚挚的防护回应，提供紧急援助渠道。
------------------------------------`;

      const chatState = loadBrowserState(storage);
      const memoriesText = (chatState.memories || []).map(m => `- ${m.key}: ${m.value} (${m.source})`).join('\n') || '无本地事实记忆';
      const recentDialogueText = (chatState.turns || []).slice(-4).map(t => `${t.speaker === 'user' ? '你' : '栖语'}: ${t.text}`).join('\n') || '尚无对话记录';

      contextPromptPreview.innerText = `[LIVE CONTEXT INJECTION]
------------------------------------
【昵称偏好】: ${prefs.userName}
【陪伴类型】: ${prefs.companionshipStyle}
【睡眠时间】: ${prefs.sleepTime}

【关联记忆事实】:
${memoriesText}

【近期轮次缓存】:
${recentDialogueText}
------------------------------------`;
    }
  }
  loadDevPreviews();

  // Load server-side advanced configs
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
      }
    } catch (err) {
      console.error('Failed to load server settings:', err);
    }
  }
  fetchServerSettings();

  // Save base settings
  if (saveBaseBtn) {
    saveBaseBtn.addEventListener('click', () => {
      prefs.userName = container.querySelector('[name="userName"]').value.trim() || '你';
      prefs.sleepTime = container.querySelector('[name="sleepTime"]').value || '23:00';
      prefs.companionshipStyle = container.querySelector('[name="style"]').value;
      prefs.memoryConsent = container.querySelector('[name="memoryConsent"]').checked;

      savePreferences(storage, prefs);
      showNotice('success', '基本偏好设置已成功保存！');
      loadDevPreviews();
    });
  }

  // Load defaults
  if (loadDefaultsBtn) {
    loadDefaultsBtn.addEventListener('click', () => {
      container.querySelector('[name="userName"]').value = '你';
      container.querySelector('[name="sleepTime"]').value = '23:00';
      container.querySelector('[name="style"]').value = 'gentle';
      container.querySelector('[name="memoryConsent"]').checked = true;

      container.querySelector('[name="apiUrl"]').value = 'https://api.openai.com/v1';
      container.querySelector('[name="apiKey"]').value = '';
      container.querySelector('[name="model"]').value = 'gpt-4o-mini';
      container.querySelector('[name="temperature"]').value = '0.7';
      container.querySelector('[name="timeoutMs"]').value = '30000';

      showNotice('info', '已填充 SOTA 推荐配置。请补充 API Key 密钥后保存。');
    });
  }

  // Save LLM Config
  if (saveLlmBtn) {
    saveLlmBtn.addEventListener('click', async () => {
      const config = {
        apiUrl: container.querySelector('[name="apiUrl"]').value.trim(),
        apiKey: container.querySelector('[name="apiKey"]').value,
        model: container.querySelector('[name="model"]').value.trim(),
        temperature: Number(container.querySelector('[name="temperature"]').value),
        timeoutMs: Number(container.querySelector('[name="timeoutMs"]').value)
      };

      try {
        const res = await fetch('/api/settings', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(config)
        });
        if (res.ok) {
          showNotice('success', 'AI (LLM) 服务端大模型配置已成功保存！');
        } else {
          const err = await res.json();
          showNotice('error', `保存失败：${err.error}`);
        }
      } catch (err) {
        showNotice('error', `请求失败：${err.message}`);
      }
    });
  }

  // Test connection
  if (testConnBtn) {
    testConnBtn.addEventListener('click', async () => {
      showNotice('info', '正在连接 AI 大模型节点进行握手，请耐心等待...');

      const config = {
        apiUrl: container.querySelector('[name="apiUrl"]').value.trim(),
        apiKey: container.querySelector('[name="apiKey"]').value,
        model: container.querySelector('[name="model"]').value.trim(),
        temperature: 0.1
      };

      try {
        const res = await fetch('/api/settings/test', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(config)
        });
        const data = await res.json();
        if (data.success) {
          showNotice('success', '✓ 连接测试成功！大模型节点响应正常。');
        } else {
          showNotice('error', `✕ 连接测试失败：${data.error}`);
        }
      } catch (err) {
        showNotice('error', `网络错误：${err.message}`);
      }
    });
  }

  // Export User Data
  if (exportBtn) {
    exportBtn.addEventListener('click', () => {
      const chatState = loadBrowserState(storage);
      const userPrefs = loadPreferences(storage);
      const exportPayload = {
        preferences: userPrefs,
        chatState: chatState,
        exportedAt: new Date().toISOString()
      };

      const blob = new Blob([JSON.stringify(exportPayload, null, 2)], { type: 'application/json;charset=utf-8;' });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.setAttribute('download', `qiyu-backup-data-${Date.now()}.json`);
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      showNotice('success', '所有本地历史和偏好数据已打包成功导出并下载。');
    });
  }

  // Clear Memories
  if (clearMemBtn) {
    clearMemBtn.addEventListener('click', () => {
      if (confirm('确定要清空栖语记录的所有事实记忆吗？这不会影响聊天记录。')) {
        const chatState = loadBrowserState(storage);
        chatState.memories = [];
        saveBrowserState(storage, chatState);
        showNotice('success', '本地事实记忆数据已彻底擦除！');
        loadDevPreviews();
      }
    });
  }

  // Reset dialog state
  if (resetHistoryBtn) {
    resetHistoryBtn.addEventListener('click', () => {
      if (confirm('确认彻底擦除与栖语的所有深夜约定与聊天历史吗？这不可撤回！')) {
        storage.removeItem('qiyu.state');
        showNotice('success', '对话历史已成功还原至初始状态。正在跳转首页...');
        setTimeout(() => {
          context.router.navigate('/');
        }, 1500);
      }
    });
  }
}
