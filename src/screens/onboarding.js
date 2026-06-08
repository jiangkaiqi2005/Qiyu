import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadPreferences, savePreferences } from '../qiyu/preferences.js';
import { renderButton, renderInput, renderToggle, renderNotice } from '../ui/components.js';

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
        <h2 id="step-title-1" style="font-size: 19px; margin-top: 12px; color: var(--ink); border: 0; padding: 0; font-weight: bold; margin-bottom: 8px;">「 先把灵魂引擎接上。」</h2>
        <p class="subtitle" style="margin-top: 0; margin-bottom: 24px;">栖语可以先用本地规则陪你说话，但如果要真正拥有稳定的人格、记忆和对话质感，建议先配置一个 OpenAI 兼容 API。</p>
        <div style="display: flex; flex-direction: column; gap: 14px; margin-top: 22px;">
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
        <p class="field-desc" style="margin-top: 14px;">暂时不填也可以继续，之后可在“默契中心”补上。</p>
      `;
    }
    if (currentStep === 2) {
      return `
        <h2 id="step-title-2" style="font-size: 19px; margin-top: 12px; color: var(--ink); border: 0; padding: 0; font-weight: bold; margin-bottom: 8px;">「 深夜里，我该怎么唤你？」</h2>
        <p class="subtitle" style="margin-top: 0; margin-bottom: 24px;">告诉我一个你最习惯的名字，让我在风吹动树梢的时刻，能轻轻唤你一声。</p>
        <div style="margin-top: 24px; margin-bottom: 24px;">
          ${renderInput({
            name: 'userName',
            placeholder: '比如：林深、小雨...',
            value: prefs.userName || '',
            attrs: 'aria-labelledby="step-title-2" style="padding: 14px 18px; font-size: 15px;"'
          })}
        </div>
      `;
    }
    if (currentStep === 3) {
      return `
        <h2 id="step-title-3" style="font-size: 19px; margin-top: 12px; color: var(--ink); border: 0; padding: 0; font-weight: bold; margin-bottom: 8px;">「 你通常，何时坠入梦乡？」</h2>
        <p class="subtitle" style="margin-top: 0; margin-bottom: 24px;">告诉我你预计入睡的时间，我会在此前静静收拢话头，不再惊扰你的倦意。</p>
        <div style="margin-top: 24px; margin-bottom: 24px;">
          ${renderInput({
            name: 'sleepTime',
            type: 'time',
            value: prefs.sleepTime || '23:00',
            attrs: 'aria-labelledby="step-title-3" style="padding: 14px 18px; font-size: 15px; width: 100%; max-width: 180px;"'
          })}
        </div>
      `;
    }
    if (currentStep === 4) {
      return `
        <fieldset style="border: 0; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 14px;">
          <legend id="step-title-4" style="font-size: 19px; margin-top: 12px; color: var(--ink); font-weight: bold; margin-bottom: 8px; border: 0; padding: 0; display: block;">「 深夜相伴，你希望我是怎样的脾气？」</legend>
          <p class="subtitle" style="margin-top: 0; margin-bottom: 18px;">选择一种你最感到安心的相处温度。</p>
          
          <label style="display: flex; align-items: flex-start; gap: 14px; cursor: pointer; padding: 16px; border: 1.5px solid rgba(223,179,85,0.15); border-radius: 12px; background: rgba(22, 20, 18, 0.4); transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1); box-shadow: 0 4px 12px rgba(0,0,0,0.25);">
            <input type="radio" name="style" value="gentle" ${prefs.companionshipStyle === 'gentle' ? 'checked' : ''} style="accent-color: var(--accent); margin-top: 4px; width: 16px; height: 16px;">
            <div style="text-align: left;">
              <strong style="color: var(--ink); font-size: 15px;">温柔倾听</strong>
              <div style="font-size: 12.5px; color: var(--muted); margin-top: 6px; line-height: 1.5;">细致共情，听你倾诉每一天的疲惫</div>
            </div>
          </label>
          <label style="display: flex; align-items: flex-start; gap: 14px; cursor: pointer; padding: 16px; border: 1.5px solid rgba(223,179,85,0.15); border-radius: 12px; background: rgba(22, 20, 18, 0.4); transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1); box-shadow: 0 4px 12px rgba(0,0,0,0.25);">
            <input type="radio" name="style" value="playful" ${prefs.companionshipStyle === 'playful' ? 'checked' : ''} style="accent-color: var(--accent); margin-top: 4px; width: 16px; height: 16px;">
            <div style="text-align: left;">
              <strong style="color: var(--ink); font-size: 15px;">轻松调侃</strong>
              <div style="font-size: 12.5px; color: var(--muted); margin-top: 6px; line-height: 1.5;">带着善意的幽默，化解深夜的无聊</div>
            </div>
          </label>
          <label style="display: flex; align-items: flex-start; gap: 14px; cursor: pointer; padding: 16px; border: 1.5px solid rgba(223,179,85,0.15); border-radius: 12px; background: rgba(22, 20, 18, 0.4); transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1); box-shadow: 0 4px 12px rgba(0,0,0,0.25);">
            <input type="radio" name="style" value="quiet" ${prefs.companionshipStyle === 'quiet' ? 'checked' : ''} style="accent-color: var(--accent); margin-top: 4px; width: 16px; height: 16px;">
            <div style="text-align: left;">
              <strong style="color: var(--ink); font-size: 15px;">安静聆听</strong>
              <div style="font-size: 12.5px; color: var(--muted); margin-top: 6px; line-height: 1.5;">少言寡语，只是在旁边默默守候</div>
            </div>
          </label>
        </fieldset>
      `;
    }
    if (currentStep === 5) {
      return `
        <h2 id="step-title-5" style="font-size: 19px; margin-top: 12px; color: var(--ink); border: 0; padding: 0; font-weight: bold; margin-bottom: 8px;">「 昨夜私语，你愿意让我记下吗？」</h2>
        <p class="subtitle" style="margin-top: 0; margin-bottom: 24px;">为了我们在未来的陪伴里更加默契，我可以用心记住你的一些日常喜好。</p>
        <p style="font-size: 13px; line-height: 1.6; margin-bottom: 24px; color: var(--muted); text-align: left;">
          这些悄悄提取的事项（如你爱吃的甜点、繁忙的项目）将<strong>完全只封存在你这台设备的浏览器本地 (localStorage)</strong>。
          绝不会上传给任何中心化的云端数据库。你可以在“印记中心”里对它们进行修剪、藏入箱底，或者彻底清空。
        </p>
        <div style="margin-bottom: 24px; text-align: left;">
          ${renderToggle({
            name: 'memoryConsent',
            checked: prefs.memoryConsent,
            label: '同意启用本地私语记忆功能',
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
  }

  const innerHtml = `
    <section class="onboarding-layout">
      <aside class="step-rail" aria-label="首次设置步骤">
        <div class="rail-brand">
          <span class="mark" aria-hidden="true">栖</span>
          <div>
            <strong>初遇</strong>
            <span>在你栖息的时刻，有人跟你说说话。先接上引擎，再建立默契。</span>
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
