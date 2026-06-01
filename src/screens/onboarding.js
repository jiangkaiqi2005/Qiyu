import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadPreferences, savePreferences } from '../qiyu/preferences.js';
import { renderButton, renderInput, renderToggle } from '../ui/components.js';

export function render(container, context) {
  const storage = window.localStorage;
  let prefs = loadPreferences(storage);

  let currentStep = 1;
  const totalSteps = 4;

  function getStepHtml() {
    if (currentStep === 1) {
      return `
        <h2 style="font-size: 18px; margin-top: 12px; color: var(--ink);">第 1 步：如何称呼你？</h2>
        <p class="subtitle">让栖语在深夜里能唤出你的名字。</p>
        <div style="margin-top: 24px; margin-bottom: 24px;">
          ${renderInput({
            name: 'userName',
            placeholder: '比如：林深、小雨...',
            value: prefs.userName || ''
          })}
        </div>
      `;
    }
    if (currentStep === 2) {
      return `
        <h2 style="font-size: 18px; margin-top: 12px; color: var(--ink);">第 2 步：你通常几点休息？</h2>
        <p class="subtitle">栖语会据此调整陪伴节奏，在你休息前收束话题。</p>
        <div style="margin-top: 24px; margin-bottom: 24px;">
          ${renderInput({
            name: 'sleepTime',
            type: 'time',
            value: prefs.sleepTime || '23:00'
          })}
        </div>
      `;
    }
    if (currentStep === 3) {
      return `
        <h2 style="font-size: 18px; margin-top: 12px; color: var(--ink);">第 3 步：陪伴风格</h2>
        <p class="subtitle">你希望栖语在深夜以何种面貌与你相伴？</p>
        <div style="margin-top: 24px; margin-bottom: 24px; display: flex; flex-direction: column; gap: 12px;">
          <label style="display: flex; align-items: center; gap: 12px; cursor: pointer; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: rgba(16,15,13,0.4);">
            <input type="radio" name="style" value="gentle" ${prefs.companionshipStyle === 'gentle' ? 'checked' : ''}>
            <div>
              <strong>温柔倾听</strong>
              <div style="font-size: 12px; color: var(--muted); margin-top: 4px;">细致共情，听你倾诉每一天的疲惫</div>
            </div>
          </label>
          <label style="display: flex; align-items: center; gap: 12px; cursor: pointer; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: rgba(16,15,13,0.4);">
            <input type="radio" name="style" value="playful" ${prefs.companionshipStyle === 'playful' ? 'checked' : ''}>
            <div>
              <strong>轻松调侃</strong>
              <div style="font-size: 12px; color: var(--muted); margin-top: 4px;">带着善意的幽默，化解深夜的无聊</div>
            </div>
          </label>
          <label style="display: flex; align-items: center; gap: 12px; cursor: pointer; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: rgba(16,15,13,0.4);">
            <input type="radio" name="style" value="quiet" ${prefs.companionshipStyle === 'quiet' ? 'checked' : ''}>
            <div>
              <strong>安静聆听</strong>
              <div style="font-size: 12px; color: var(--muted); margin-top: 4px;">少言寡语，只是在旁边默默守候</div>
            </div>
          </label>
        </div>
      `;
    }
    if (currentStep === 4) {
      return `
        <h2 style="font-size: 18px; margin-top: 12px; color: var(--ink);">第 4 步：记忆机制</h2>
        <p class="subtitle">让栖语能够回想起你们聊过的内容。</p>
        <p style="font-size: 13px; line-height: 1.6; margin-bottom: 24px; color: var(--muted);">
          为了实现持续的陪伴默契，栖语可以把对话中的核心事实（如你喜欢的食物、作息、工作）提取并保存在<strong>本地浏览器中</strong>。
          这不需要上传任何个人隐私到云端数据库。你可以随时在记忆中心进行管理或彻底清空。
        </p>
        <div style="margin-bottom: 24px;">
          ${renderToggle({
            name: 'memoryConsent',
            checked: prefs.memoryConsent,
            label: '同意启用本地对话记忆功能'
          })}
        </div>
      `;
    }
    return '';
  }

  function updateUI() {
    const stepsProgress = `步骤 ${currentStep} / ${totalSteps}`;
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
    if (prevBtn) {
      prevBtn.style.visibility = currentStep === 1 ? 'hidden' : 'visible';
    }
    if (nextBtn) {
      nextBtn.innerText = currentStep === totalSteps ? '完成设置' : '下一步';
    }
  }

  const innerHtml = `
    <div class="card onboarding-card" style="max-width: 600px; padding: 36px 32px;">
      <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(216, 169, 75, 0.15); padding-bottom: 12px; margin-bottom: 20px;">
        <h1 style="border: 0; padding: 0; margin: 0; font-size: 20px; color: var(--accent);">首次相遇设置</h1>
        <span class="step-progress-text" style="font-size: 13px; color: var(--muted);"></span>
      </div>

      <div class="onboarding-content" style="min-height: 240px;"></div>

      <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 32px; border-top: 1px solid rgba(216, 169, 75, 0.1); padding-top: 20px;">
        <button class="btn prev-btn">上一步</button>
        <button class="btn skip-all-btn" style="border-color: transparent; color: var(--muted);">跳过全部</button>
        <button class="btn primary next-btn">下一步</button>
      </div>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/onboarding');
  bindNavigation(container, context.router);

  updateUI();

  const card = container.querySelector('.onboarding-card');
  const prevBtn = container.querySelector('.prev-btn');
  const nextBtn = container.querySelector('.next-btn');
  const skipBtn = container.querySelector('.skip-all-btn');

  function saveCurrentStepData() {
    if (currentStep === 1) {
      const nameInput = container.querySelector('[name="userName"]');
      if (nameInput) prefs.userName = nameInput.value.trim() || '你';
    } else if (currentStep === 2) {
      const sleepInput = container.querySelector('[name="sleepTime"]');
      if (sleepInput) prefs.sleepTime = sleepInput.value || '23:00';
    } else if (currentStep === 3) {
      const checkedStyle = container.querySelector('[name="style"]:checked');
      if (checkedStyle) prefs.companionshipStyle = checkedStyle.value;
    } else if (currentStep === 4) {
      const consentInput = container.querySelector('[name="memoryConsent"]');
      if (consentInput) prefs.memoryConsent = consentInput.checked;
    }
    savePreferences(storage, prefs);
  }

  if (prevBtn) {
    prevBtn.addEventListener('click', () => {
      saveCurrentStepData();
      if (currentStep > 1) {
        currentStep--;
        updateUI();
      }
    });
  }

  if (nextBtn) {
    nextBtn.addEventListener('click', () => {
      saveCurrentStepData();
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
