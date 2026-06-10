import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadPreferences, savePreferences } from '../qiyu/preferences.js';
import { renderButton, renderInput, renderToggle, renderNotice } from '../ui/components.js';
import { applyProviderPreset, renderProviderPresetOptions } from '../ui/provider-presets.js';

export function render(container, context) {
  const storage = window.localStorage;
  let prefs = loadPreferences(storage);

  let currentStep = 1;
  const totalSteps = 5;
  let csrfToken = '';

  const settingsTokenPromise = fetch('/api/settings')
    .then(res => res.ok ? res.json() : null)
    .then(data => {
      if (data && data.csrfToken) {
        csrfToken = data.csrfToken;
        window.qiyuCsrfToken = data.csrfToken;
      }
      return csrfToken;
    })
    .catch(() => '');

  function getStepHtml() {
    if (currentStep === 1) {
      return `
        <div class="setup-step">
          <span class="setup-kicker">API first</span>
          <h2 id="step-title-1">先把引擎接上</h2>
          <p class="setup-copy">栖语可以先用本地规则陪你说话。但如果要让对话质感稳定，第一次进入时建议先配置 OpenAI 兼容或 Anthropic 原生 API。</p>
        </div>
        <div class="setup-fields">
          <select name="providerPreset" class="form-select setup-control" aria-labelledby="step-title-1">
            ${renderProviderPresetOptions()}
          </select>
          ${renderInput({
            name: 'apiUrl',
            placeholder: 'API 地址，比如：https://api.openai.com/v1',
            attrs: 'aria-labelledby="step-title-1" autocomplete="off"'
          })}
          ${renderInput({
            name: 'apiKey',
            type: 'password',
            placeholder: 'API Key',
            attrs: 'aria-labelledby="step-title-1" autocomplete="off"'
          })}
          ${renderInput({
            name: 'model',
            placeholder: '模型名称，比如：gpt-4o',
            attrs: 'aria-labelledby="step-title-1" autocomplete="off"'
          })}
          ${renderInput({
            name: 'temperature',
            type: 'number',
            value: '0.8',
            attrs: 'aria-labelledby="step-title-1" min="0" max="2" step="0.1"'
          })}
        </div>
        <p class="setup-note">暂时不填也可以继续，之后可在“默契中心”补上。</p>
      `;
    }
    if (currentStep === 2) {
      return `
        <div class="setup-step">
          <span class="setup-kicker">name</span>
          <h2 id="step-title-2">深夜里，我该怎么唤你</h2>
          <p class="setup-copy">告诉我一个你习惯的名字。以后开口时，我会少一点生硬。</p>
        </div>
        <div class="setup-fields setup-fields-compact">
          ${renderInput({
            name: 'userName',
            placeholder: '比如：林深、小雨...',
            value: prefs.userName || '',
            attrs: 'aria-labelledby="step-title-2"'
          })}
        </div>
      `;
    }
    if (currentStep === 3) {
      return `
        <div class="setup-step">
          <span class="setup-kicker">sleep</span>
          <h2 id="step-title-3">你通常何时睡下</h2>
          <p class="setup-copy">告诉我预计入睡的时间。临近这个时刻，我会主动把话题收轻一点。</p>
        </div>
        <div class="setup-fields setup-fields-time">
          ${renderInput({
            name: 'sleepTime',
            type: 'time',
            value: prefs.sleepTime || '23:00',
            attrs: 'aria-labelledby="step-title-3"'
          })}
        </div>
      `;
    }
    if (currentStep === 4) {
      return `
        <fieldset class="choice-stack">
          <legend id="step-title-4">深夜相伴，你希望我是怎样的脾气</legend>
          <p class="setup-copy">选择一种你更安心的相处温度。</p>

          <label class="choice-card">
            <input type="radio" name="style" value="gentle" ${prefs.companionshipStyle === 'gentle' ? 'checked' : ''}>
            <div class="choice-copy">
              <strong>温柔倾听</strong>
              <span>细致共情，听你倾诉每一天的疲惫</span>
            </div>
          </label>
          <label class="choice-card">
            <input type="radio" name="style" value="playful" ${prefs.companionshipStyle === 'playful' ? 'checked' : ''}>
            <div class="choice-copy">
              <strong>轻松调侃</strong>
              <span>带着善意的幽默，化解深夜的无聊</span>
            </div>
          </label>
          <label class="choice-card">
            <input type="radio" name="style" value="quiet" ${prefs.companionshipStyle === 'quiet' ? 'checked' : ''}>
            <div class="choice-copy">
              <strong>安静聆听</strong>
              <span>少言寡语，只是在旁边默默守候</span>
            </div>
          </label>
        </fieldset>
      `;
    }
    if (currentStep === 5) {
      return `
        <div class="setup-step">
          <span class="setup-kicker">local only</span>
          <h2 id="step-title-5">是否记住少量本地偏好</h2>
          <p class="setup-copy">如果你愿意，栖语会在本机浏览器里记住一些偏好和事实，让之后的夜话少一点重复确认。</p>
        </div>
        <p class="setup-privacy-note">
          这些内容只保存在这台设备的浏览器本地，不上传到中心化数据库。你可以随时在“印记”里查看、隐藏或清空。
        </p>
        <div class="setup-toggle-row">
          ${renderToggle({
            name: 'memoryConsent',
            checked: prefs.memoryConsent,
            label: '允许本地记住少量偏好',
            attrs: 'aria-labelledby="step-title-5"'
          })}
        </div>
      `;
    }
    return '';
  }

  function updateUI() {
    const stepsProgress = `初遇相识 ${currentStep} / ${totalSteps}`;
    const mainSection = container.querySelector('.onboarding-content');
    const stepText = container.querySelector('.step-progress-text');
    const prevBtn = container.querySelector('.prev-btn');
    const nextBtn = container.querySelector('.next-btn');

    if (mainSection) {
      mainSection.innerHTML = getStepHtml();
    }
    if (stepText) {
      stepText.innerText = stepsProgress;
    }
    container.querySelectorAll('.step-dot').forEach((dot, index) => {
      dot.classList.toggle('active', index + 1 === currentStep);
      dot.classList.toggle('completed', index + 1 < currentStep);
    });
    if (prevBtn) {
      prevBtn.style.visibility = currentStep === 1 ? 'hidden' : 'visible';
    }
    if (nextBtn) {
      nextBtn.innerText = currentStep === totalSteps ? '完成设置' : '下一步';
    }
    bindCurrentStepInteractions();
  }

  function bindCurrentStepInteractions() {
    if (currentStep !== 1) return;

    const providerPreset = container.querySelector('[name="providerPreset"]');
    if (!providerPreset) return;

    providerPreset.addEventListener('change', () => {
      const apiUrlInput = container.querySelector('[name="apiUrl"]');
      const modelInput = container.querySelector('[name="model"]');
      const preset = applyProviderPreset(providerPreset.value, { apiUrlInput, modelInput });
      showNotification('info', preset.notice);
    });
  }

  const innerHtml = `
    <section class="onboarding-layout">
      <aside class="step-rail" aria-label="首次设置步骤">
        <div class="rail-brand">
          <span class="mark" aria-hidden="true">栖</span>
          <div>
            <strong>初遇</strong>
            <span>第一次进入时完成。先接上引擎，再建立默契。</span>
          </div>
        </div>
        <ol>
          <li class="step-dot active"><span>01</span><strong>引擎</strong></li>
          <li class="step-dot"><span>02</span><strong>称呼</strong></li>
          <li class="step-dot"><span>03</span><strong>作息</strong></li>
          <li class="step-dot"><span>04</span><strong>脾气</strong></li>
          <li class="step-dot"><span>05</span><strong>记忆</strong></li>
        </ol>
      </aside>

      <div class="card onboarding-card">
        <div class="onboarding-head">
          <div>
            <h1>首次相遇设置</h1>
            <span>让我们在入夜前建立最初的默契</span>
          </div>
          <span class="step-progress-text"></span>
        </div>

        <div class="onboarding-content">${getStepHtml()}</div>
        <div class="onboarding-notice-area"></div>

        <div class="onboarding-footer">
          <button class="btn prev-btn">上一步</button>
          <button class="btn skip-all-btn">跳过全部</button>
          <button class="btn primary next-btn">下一步</button>
        </div>
      </div>
    </section>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/onboarding');
  bindNavigation(container, context.router);

  updateUI();

  const prevBtn = container.querySelector('.prev-btn');
  const nextBtn = container.querySelector('.next-btn');
  const skipBtn = container.querySelector('.skip-all-btn');
  const noticeArea = container.querySelector('.onboarding-notice-area');

  function showNotification(type, message) {
    if (noticeArea) {
      noticeArea.innerHTML = renderNotice({ type, message });
    }
  }

  async function ensureCsrfToken() {
    if (csrfToken || window.qiyuCsrfToken) {
      return csrfToken || window.qiyuCsrfToken;
    }
    return settingsTokenPromise;
  }

  async function saveApiSettingsIfProvided() {
    const apiUrlInput = container.querySelector('[name="apiUrl"]');
    const apiKeyInput = container.querySelector('[name="apiKey"]');
    const modelInput = container.querySelector('[name="model"]');
    const temperatureInput = container.querySelector('[name="temperature"]');
    const apiUrl = apiUrlInput ? apiUrlInput.value.trim() : '';
    const apiKey = apiKeyInput ? apiKeyInput.value.trim() : '';
    const model = modelInput ? modelInput.value.trim() : '';
    const temperature = temperatureInput ? Number(temperatureInput.value) : 0.8;

    if (!apiUrl && !apiKey && !model) return;

    const token = await ensureCsrfToken();
    if (!token) {
      throw new Error('未能获取安全令牌，请稍后重试');
    }

    const response = await fetch('/api/settings', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': token
      },
      body: JSON.stringify({
        apiUrl,
        apiKey,
        model,
        temperature: Number.isFinite(temperature) ? temperature : 0.8,
        timeoutMs: 30000
      })
    });

    if (!response.ok) {
      throw new Error(`API 配置保存失败：HTTP ${response.status}`);
    }

    const data = await response.json();
    if (!data.success) {
      throw new Error(data.error || 'API 配置保存失败');
    }
  }

  async function saveCurrentStepData() {
    try {
      if (currentStep === 1) {
        await saveApiSettingsIfProvided();
      } else if (currentStep === 2) {
        const nameInput = container.querySelector('[name="userName"]');
        if (nameInput) prefs.userName = nameInput.value.trim() || '你';
      } else if (currentStep === 3) {
        const sleepInput = container.querySelector('[name="sleepTime"]');
        if (sleepInput) prefs.sleepTime = sleepInput.value || '23:00';
      } else if (currentStep === 4) {
        const checkedStyle = container.querySelector('[name="style"]:checked');
        if (checkedStyle) prefs.companionshipStyle = checkedStyle.value;
      } else if (currentStep === 5) {
        const consentInput = container.querySelector('[name="memoryConsent"]');
        if (consentInput) prefs.memoryConsent = consentInput.checked;
      }
      savePreferences(storage, prefs);
      if (noticeArea) noticeArea.innerHTML = '';
      return true;
    } catch (error) {
      showNotification('error', error.message || '保存失败，请稍后重试');
      return false;
    }
  }

  if (prevBtn) {
    prevBtn.addEventListener('click', async () => {
      const saved = await saveCurrentStepData();
      if (!saved) return;
      if (currentStep > 1) {
        currentStep--;
        updateUI();
      }
    });
  }

  if (nextBtn) {
    nextBtn.addEventListener('click', async () => {
      const saved = await saveCurrentStepData();
      if (!saved) return;
      if (currentStep < totalSteps) {
        currentStep++;
        updateUI();
      } else {
        prefs.onboardingState = 'completed';
        savePreferences(storage, prefs);
        context.router.navigate('/chat');
      }
    });
  }

  if (skipBtn) {
    skipBtn.addEventListener('click', () => {
      prefs.onboardingState = 'skipped';
      savePreferences(storage, prefs);
      context.router.navigate('/chat');
    });
  }
}
