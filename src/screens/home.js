import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { createQiyuReply } from '../qiyu/engine.js';
import {
  startSession,
  loadBrowserState,
  saveBrowserState,
  createInitialState
} from '../qiyu/state.js';
import { renderBubble } from '../ui/render.js';
import { sendChatMessage } from '../ui/chat-api.js';

export function render(container, context) {
  const storage = window.localStorage;
  const existingState = loadBrowserState(storage);
  const hasHistory = existingState && existingState.turns && existingState.turns.length > 0;

  let trialState = JSON.parse(storage.getItem('qiyu_trial_state') || 'null');
  if (!trialState) {
    trialState = createInitialState('trial-user');
    trialState.isTrial = true;
    trialState.trialTurnsCount = 0;
    storage.setItem('qiyu_trial_state', JSON.stringify(trialState));
  }

  const innerHtml = `
    <div class="card" style="max-width: 620px;">
      <h1>栖语</h1>
      <p class="subtitle">一个深夜懂你的 AI 伴侣</p>
      
      <div class="trial-chat-container">
        <section class="thread trial-thread" aria-label="深夜夜话试用" role="log" aria-live="polite" style="max-height: 280px; min-height: 120px; overflow-y: auto; margin-bottom: 16px;">
          <div class="message-container trial-message-container"></div>
        </section>
        
        <form class="composer trial-composer" aria-label="试用发送" style="display: grid; grid-template-columns: 1fr auto; gap: 8px;">
          <input name="message" autocomplete="off" placeholder="深夜了，写点什么吧..." aria-label="写下你想对栖语说的话" style="padding: 10px 12px; border-radius: 8px; border: 1px solid var(--line); background: rgba(16, 15, 13, 0.78); color: var(--ink);">
          <button type="submit" class="btn primary" style="padding: 10px 16px;">发送</button>
        </form>
        
        <div class="onboarding-invite notice notice-info" style="display: none; margin-top: 16px;">
          <span class="notice-icon" aria-hidden="true">✨</span>
          <span class="notice-message" style="flex: 1; display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;">
            <span>感觉还不错吗？完成简短的初遇相识设置，让我能够长久记住你。</span>
            <button data-nav-path="/onboarding" class="btn primary" style="padding: 6px 12px; font-size: 13px;">开启正式对话</button>
          </span>
        </div>
      </div>

      ${hasHistory ? `
        <div class="returning-path" style="margin-top: 24px; text-align: center; border-top: 1px dashed rgba(223, 179, 85, 0.1); padding-top: 16px;">
          <button data-nav-path="/chat" class="btn primary">继续今晚的对话</button>
        </div>
      ` : ''}
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/');
  bindNavigation(container, context.router);

  const thread = container.querySelector('.trial-thread');
  const msgContainer = container.querySelector('.trial-message-container');
  const form = container.querySelector('.trial-composer');
  const input = form.elements.message;
  const inviteBox = container.querySelector('.onboarding-invite');

  function scrollToBottom(options = {}) {
    const isReduced = typeof window.matchMedia === 'function' ? window.matchMedia('(prefers-reduced-motion: reduce)').matches : false;
    const defaultBehavior = isReduced ? 'auto' : 'smooth';
    
    thread.scrollTo({
      top: thread.scrollHeight,
      behavior: options.behavior || defaultBehavior
    });
  }

  function appendMessage(speaker, text) {
    const html = renderBubble({ speaker, text });
    const tempDiv = document.createElement('div');
    tempDiv.innerHTML = html.trim();
    const bubble = tempDiv.firstChild;
    bubble.classList.add('bubble-fadeIn');
    msgContainer.appendChild(bubble);
    scrollToBottom();
  }

  function appendTypingIndicator() {
    const indicator = document.createElement('p');
    indicator.className = 'qiyu typing-indicator bubble-fadeIn';
    indicator.setAttribute('role', 'status');
    indicator.setAttribute('aria-label', '栖语正在想...');
    indicator.innerHTML = '<span>.</span><span>.</span><span>.</span>';
    msgContainer.appendChild(indicator);
    scrollToBottom();
    return indicator;
  }

  // SOTA DocumentFragment batching for trial history
  if (trialState.turns && trialState.turns.length) {
    const fragment = document.createDocumentFragment();
    trialState.turns.forEach(turn => {
      const html = renderBubble({ speaker: turn.speaker === 'user' ? 'user' : 'qiyu', text: turn.text });
      const tempDiv = document.createElement('div');
      tempDiv.innerHTML = html.trim();
      const bubble = tempDiv.firstChild;
      bubble.classList.add('bubble-fadeIn');
      fragment.appendChild(bubble);
    });
    msgContainer.appendChild(fragment);
    scrollToBottom({ behavior: 'auto' });

    if (trialState.trialTurnsCount >= 3) {
      inviteBox.style.display = 'flex';
      input.disabled = true;
      form.querySelector('button').disabled = true;
      input.placeholder = '试用额度已满，请开启正式对话';
    }
  } else {
    appendMessage('qiyu', '你来了。今晚，外面安静下来了吗？');
  }

  let isTyping = false;

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (isTyping) return;

    const text = input.value.trim();
    if (!text) return;

    input.value = '';
    appendMessage('user', text);

    isTyping = true;
    input.disabled = true;
    form.querySelector('button').disabled = true;

    let result;
    try {
      result = await sendChatMessage({ text, state: trialState });
    } catch {
      result = createQiyuReply(text, trialState);
    }

    trialState = result.nextState;
    trialState.trialTurnsCount = (trialState.trialTurnsCount || 0) + 1;
    storage.setItem('qiyu_trial_state', JSON.stringify(trialState));

    const replyMessages = result.messages;

    for (let i = 0; i < replyMessages.length; i++) {
      const replyText = replyMessages[i];
      const indicator = appendTypingIndicator();
      const delay = Math.min(Math.max(replyText.length * 40 + 200, 300), 1000);
      await new Promise(resolve => setTimeout(resolve, delay));
      if (indicator.parentNode) {
        indicator.parentNode.removeChild(indicator);
      }
      appendMessage('qiyu', replyText);
      if (i < replyMessages.length - 1) {
        await new Promise(resolve => setTimeout(resolve, 200));
      }
    }

    isTyping = false;
    
    if (trialState.trialTurnsCount >= 3) {
      inviteBox.style.display = 'flex';
      input.placeholder = '试用额度已满，请开启正式对话';
      
      // Bind navigation correctly to the dynamically visible invite button
      const navBtn = inviteBox.querySelector('[data-nav-path]');
      if (navBtn) {
        navBtn.addEventListener('click', (e) => {
          e.preventDefault();
          context.router.navigate(navBtn.dataset.navPath);
        });
      }
    } else {
      input.disabled = false;
      form.querySelector('button').disabled = false;
      input.focus();
    }
  });
}
