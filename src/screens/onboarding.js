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
        <h2 id="step-title-1" style="font-size: 18px; margin-top: 12px; color: var(--ink);">「 深夜里，我该怎么唤你？」</h2>
        <p class="subtitle">告诉我一个你最习惯的名字，让我在风吹动树梢的时刻，能轻轻唤你一声。</p>
        <div style="margin-top: 24px; margin-bottom: 24px;">
          ${renderInput({
            name: 'userName',
            placeholder: '比如：林深、小雨...',
            value: prefs.userName || '',
            attrs: 'aria-labelledby="step-title-1"'
          })}
        </div>
      `;
    }
    if (currentStep === 2) {
      return `
        <h2 id="step-title-2" style="font-size: 18px; margin-top: 12px; color: var(--ink);">「 你通常，何时坠入梦乡？」</h2>
        <p class="subtitle">告诉我你预计入睡的时间，我会在此前静静收拢话头，不再惊扰你的倦意。</p>
        <div style="margin-top: 24px; margin-bottom: 24px;">
          ${renderInput({
            name: 'sleepTime',
            type: 'time',
            value: prefs.sleepTime || '23:00',
            attrs: 'aria-labelledby="step-title-2"'
          })}
        </div>
      `;
    }
    if (currentStep === 3) {
      return `
        <fieldset style="border: 0; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 12px;">
          <legend id="step-title-3" style="font-size: 18px; margin-top: 12px; color: var(--ink); font-weight: bold; margin-bottom: 8px;">「 深夜相伴，你希望我是怎样的脾气？」</legend>
          <p class="subtitle" style="margin-top: 0; margin-bottom: 16px;">选择一种你最感到安心的相处温度。</p>
          
          <label style="display: flex; align-items: center; gap: 12px; cursor: pointer; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: rgba(16,15,13,0.4); transition: border-color 0.2s;">
            <input type="radio" name="style" value="gentle" ${prefs.companionshipStyle === 'gentle' ? 'checked' : ''} style="accent-color: var(--accent);">
            <div>
              <strong>温柔倾听</strong>
              <div style="font-size: 12px; color: var(--muted); margin-top: 4px;">细致共情，听你倾诉每一天的疲惫</div>
            </div>
          </label>
          <label style="display: flex; align-items: center; gap: 12px; cursor: pointer; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: rgba(16,15,13,0.4); transition: border-color 0.2s;">
            <input type="radio" name="style" value="playful" ${prefs.companionshipStyle === 'playful' ? 'checked' : ''} style="accent-color: var(--accent);">
            <div>
              <strong>轻松调侃</strong>
              <div style="font-size: 12px; color: var(--muted); margin-top: 4px;">带着善意的幽默，化解深夜的无聊</div>
            </div>
          </label>
          <label style="display: flex; align-items: center; gap: 12px; cursor: pointer; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: rgba(16,15,13,0.4); transition: border-color 0.2s;">
            <input type="radio" name="style" value="quiet" ${prefs.companionshipStyle === 'quiet' ? 'checked' : ''} style="accent-color: var(--accent);">
            <div>
              <strong>安静聆听</strong>
              <div style="font-size: 12px; color: var(--muted); margin-top: 4px;">少言寡语，只是在旁边默默守候</div>
            </div>
          </label>
        </fieldset>
      `;
    }
    if (currentStep === 4) {
      return `
        <h2 id="step-title-4" style="font-size: 18px; margin-top: 12px; color: var(--ink);">「 昨夜私语，你愿意让我记下吗？」</h2>
        <p class="subtitle">为了我们在未来的陪伴里更加默契，我可以用心记住你的一些日常喜好。</p>
        <p style="font-size: 13px; line-height: 1.6; margin-bottom: 24px; color: var(--muted);">
          这些悄悄提取的事实（如你爱吃的甜点、繁忙的项目）将<strong>完全只封存在你这台设备的浏览器本地 (localStorage)</strong>。
          绝不会上传给任何中心化的云端数据库。你可以在“印记中心”里对它们进行修剪、藏入箱底，或者彻底清空。
        </p>
        <div style="margin-bottom: 24px;">
          ${renderToggle({
            name: 'memoryConsent',
            checked: prefs.memoryConsent,
            label: '同意启用本地私语记忆功能',
            attrs: 'aria-labelledby="step-title-4"'
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
    if (prevBtn) {
      prevBtn.style.visibility = currentStep === 1 ? 'hidden' : 'visible';
    }
    if (nextBtn) {
      nextBtn.innerText = currentStep === totalSteps ? '完成设置' : '下一步';
    }
  }

  const innerHtml = `
    <div class="card onboarding-card" style="max-width: 600px; padding: 36px 32px;">
      <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(223, 179, 85, 0.15); padding-bottom: 12px; margin-bottom: 20px;">
        <h1 style="border: 0; padding: 0; margin: 0; font-size: 20px; color: var(--accent);">首次相遇设置</h1>
        <span class="step-progress-text" style="font-size: 13px; color: var(--muted);"></span>
      </div>

      <div class="onboarding-content" style="min-height: 240px;"></div>

      <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 32px; border-top: 1px solid rgba(223, 179, 85, 0.1); padding-top: 20px;">
        <button class="btn prev-btn">上一步</button>
        <button class="btn skip-all-btn" style="border-color: transparent; color: var(--muted);">跳过全部</button>
        <button class="btn primary next-btn">下一步</button>
      </div>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/onboarding');
  bindNavigation(container, context.router);

  updateUI();

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
