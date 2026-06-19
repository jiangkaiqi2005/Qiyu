import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { createQiyuReply } from '../qiyu/engine.js';
import {
  startSession,
  loadBrowserState,
  saveBrowserState,
  getConversationDate
} from '../qiyu/state.js';
import { loadPreferences } from '../qiyu/preferences.js';
import { renderBubble } from '../ui/render.js';
import { sendChatMessage } from '../ui/chat-api.js';
import { confirmAction } from '../ui/confirm-dialog.js';
import { calculateTextWaitMs, normalizeReplyMessages } from '../qiyu/reply-delivery.js';

export function render(container, context) {
  const storage = window.localStorage;
  const prefs = loadPreferences(storage);
  const loadedState = loadBrowserState(storage);

  const prevDate = loadedState.activeConversationDate;
  const currentDate = getConversationDate(new Date());

  let state = startSession(loadedState);

  // If day crossed, clear turns to show welcome
  if (prevDate && prevDate !== currentDate) {
    state.turns = [];
  }

  // Sync preferences to state
  state.companionshipStyle = prefs.companionshipStyle || 'gentle';
  state.sleepTime = prefs.sleepTime || '23:00';
  state.userName = prefs.userName || '你';
  saveBrowserState(storage, state);

  const initialStageClass = 'is-conversation-mode';

  const innerHtml = `
    <div class="qiyu-chat-stage ${initialStageClass}">
      <div class="shell">
        <div class="conversation-panel">
          <div class="chat-header">
            <div class="presence">
              <span class="mark" aria-hidden="true">栖</span>
              <div class="presence-copy">
                <span class="presence-name">栖语</span>
                <span class="presence-state">深夜里，有我倾听你的声音</span>
              </div>
            </div>
            <button class="reset-chat-btn" type="button" aria-label="清空当前上下文">清空当前上下文</button>
          </div>
          <div class="chat-dev-diagnostics"></div>
          <section class="thread" aria-label="与 栖语 的深夜夜话" role="log" aria-live="polite">
            <div class="message-container"></div>
          </section>
        </div>
        <form class="composer" aria-label="发送消息">
          <div class="composer-field">
            <textarea class="composer-input" name="message" autocomplete="off" rows="1" placeholder="今天过得怎么样" aria-label="写下你的心里话"></textarea>
          </div>
          <button type="submit" class="btn primary">
            <span class="send-label">发送</span>
            <span class="send-mark" aria-hidden="true">↵</span>
          </button>
        </form>
      </div>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/chat');
  bindNavigation(container, context.router);

  const thread = container.querySelector('.thread');
  const msgContainer = container.querySelector('.message-container');
  const form = container.querySelector('.composer');
  const resetBtn = container.querySelector('.reset-chat-btn');
  const input = form.elements.message;
  const devDiagnostics = container.querySelector('.chat-dev-diagnostics');
  const chatStage = container.querySelector('.qiyu-chat-stage');

  function getWelcomeMessage(st) {
    return st.userName && st.userName !== '你'
      ? `你来了，${st.userName}。今晚，外面安静下来了吗？`
      : '你来了。今晚，外面安静下来了吗？';
  }

  function enterConversationMode() {
    if (!chatStage) return;
    chatStage.classList.add('is-conversation-mode');
  }

  function syncComposerSize() {
    if (!input?.style) return;
    input.style.height = 'auto';
    const nextHeight = Math.min(Math.max(Number(input.scrollHeight) || 44, 44), 132);
    input.style.height = `${nextHeight}px`;
  }

  function submitComposerFromKeyboard(event) {
    if (event.key !== 'Enter' || event.shiftKey || event.isComposing) return;
    event.preventDefault();

    if (typeof form.requestSubmit === 'function') {
      form.requestSubmit();
      return;
    }

    if (typeof form.dispatchEvent === 'function' && typeof Event === 'function') {
      form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    }
  }

  if (typeof input.addEventListener === 'function') {
    input.addEventListener('focus', enterConversationMode);
    input.addEventListener('input', () => {
      enterConversationMode();
      syncComposerSize();
    });
    input.addEventListener('keydown', submitComposerFromKeyboard);
  }
  syncComposerSize();

  const isDev = storage.getItem('qiyu_dev_mode') === 'true';
  if (devDiagnostics && isDev) {
    devDiagnostics.style.display = 'block';
    devDiagnostics.innerText = '[调试] 开发者模式已激活。发送消息后将在此输出实时 API 连接诊断信息。';
  }

  let pendingScrollFrame = null;

  function scrollToBottom(options = {}) {
    const isReduced = typeof window.matchMedia === 'function' ? window.matchMedia('(prefers-reduced-motion: reduce)').matches : false;
    const behavior = options.behavior || (isReduced ? 'auto' : 'auto');

    if (pendingScrollFrame && typeof window.cancelAnimationFrame === 'function') {
      window.cancelAnimationFrame(pendingScrollFrame);
    }

    const applyScroll = () => {
      pendingScrollFrame = null;
      thread.scrollTo({
        top: thread.scrollHeight,
        behavior
      });
    };

    if (typeof window.requestAnimationFrame === 'function') {
      pendingScrollFrame = window.requestAnimationFrame(applyScroll);
    } else {
      applyScroll();
    }
  }

  function focusComposerQuietly() {
    const applyFocus = () => {
      if (typeof document !== 'undefined' && document.activeElement === input) return;
      try {
        input.focus({ preventScroll: true });
      } catch {
        input.focus();
      }
    };

    if (typeof window.requestAnimationFrame === 'function') {
      window.requestAnimationFrame(applyFocus);
    } else {
      setTimeout(applyFocus, 0);
    }
  }

  function shouldAutofocusComposer() {
    if (typeof window.matchMedia !== 'function') return true;
    return window.matchMedia('(pointer: fine)').matches;
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

  // Document Fragment batch DOM rendering
  const historyTurns = state.turns;
  if (historyTurns.length) {
    const fragment = document.createDocumentFragment();
    historyTurns.forEach(turn => {
      const html = renderBubble({ speaker: turn.speaker === 'user' ? 'user' : 'qiyu', text: turn.text });
      const tempDiv = document.createElement('div');
      tempDiv.innerHTML = html.trim();
      const bubble = tempDiv.firstChild;
      bubble.classList.add('bubble-fadeIn');
      fragment.appendChild(bubble);
    });
    msgContainer.appendChild(fragment);
    scrollToBottom({ behavior: 'auto' });
  } else {
    // Welcoming first sentence承接 onboarding preferences
    const welcome = getWelcomeMessage(state);
    appendMessage('qiyu', welcome);
    if (shouldAutofocusComposer()) {
      focusComposerQuietly();
    }
  }

  let isTyping = false;

  async function processReplyQueue(replyMessages, deliveryContext = {}) {
    isTyping = true;
    input.disabled = true;
    form.querySelector('button').disabled = true;

    try {
      const visibleMessages = normalizeReplyMessages(replyMessages, { fallback: null });

      for (let i = 0; i < visibleMessages.length; i++) {
        const text = visibleMessages[i];
        const indicator = appendTypingIndicator();
        const delay = calculateTextWaitMs({
          userText: deliveryContext.userText,
          replyText: text,
          mode: deliveryContext.mode
        });

        await new Promise(resolve => setTimeout(resolve, delay));

        if (indicator && indicator.parentNode) {
          indicator.parentNode.removeChild(indicator);
        }
        appendMessage('qiyu', text);

        if (i < visibleMessages.length - 1) {
          await new Promise(resolve => setTimeout(resolve, 300));
        }
      }
    } finally {
      isTyping = false;
      input.disabled = false;
      form.querySelector('button').disabled = false;
      focusComposerQuietly();
    }
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (isTyping) return;

    const text = input.value.trim();
    if (!text) return;

    enterConversationMode();
    input.value = '';
    syncComposerSize();
    appendMessage('user', text);

    let result;
    try {
      result = await sendChatMessage({ text, state });
    } catch {
      result = createQiyuReply(text, state);
    }

    state = result.nextState;
    saveBrowserState(storage, state);

    if (devDiagnostics && storage.getItem('qiyu_dev_mode') === 'true') {
      const source = result.source || 'local';
      const latency = result.latencyMs ? `${result.latencyMs}ms` : 'N/A';
      let debugText = `[调试] 回复来源: ${source === 'llm' ? 'LLM' : '本地兜底'} | 延迟: ${latency}`;
      
      if (source === 'local') {
        const reason = result.fallbackReason || 'network_error';
        let reasonCn = '未知原因';
        if (reason === 'safety') reasonCn = '敏感词/安全过滤';
        if (reason === 'no_llm_config') reasonCn = '未配置大模型';
        if (reason === 'forbidden_phrases') reasonCn = '大模型输出命中违禁词';
        if (reason === 'llm_error') reasonCn = `大模型请求异常 (${result.providerError || '未知错误'})`;
        if (reason === 'network_error') reasonCn = '服务端网络不可达/抛错';
        
        debugText += `\n[调试] 回退原因: ${reasonCn}`;
        storage.setItem('qiyu_api_health_status', 'chat_fallback');
      } else {
        storage.setItem('qiyu_api_health_status', 'chat_connected');
      }
      devDiagnostics.innerText = debugText;
    }

    await processReplyQueue(result.messages, {
      userText: text,
      mode: result.debug?.mode
    });
  });

  if (resetBtn) {
    resetBtn.addEventListener('click', async () => {
      if (isTyping) return;
      const confirmed = await confirmAction({
        title: '清空当前上下文',
        message: '这会清空此刻的对话上下文，不会删除历史归档记录。',
        confirmLabel: '清空'
      });
      if (confirmed) {
        state.turns = [];
        saveBrowserState(storage, state);
        msgContainer.innerHTML = '';
        const welcome = getWelcomeMessage(state);
        appendMessage('qiyu', welcome);
      }
    });
  }
}
