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

  const hasHistory = state.turns.length > 0;
  const initialStageClass = hasHistory ? 'is-conversation-mode' : 'is-room-mode';
  const arrivalLine = state.userName && state.userName !== '你'
    ? `你来了，${state.userName}。`
    : '你来了。';

  const innerHtml = `
    <div class="qiyu-chat-stage ${initialStageClass}">
      <section class="room-arrival" aria-label="深夜抵达">
        <div class="room-lamp" aria-hidden="true"></div>
        <div class="room-arrival-panel">
          <span class="room-kicker">今晚</span>
          <h1>栖语</h1>
          <p>${arrivalLine}</p>
          <p class="room-arrival-muted">不用整理好再说。先写下一句就行。</p>
        </div>
      </section>

      <div class="shell">
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
        <form class="composer" aria-label="发送消息">
          <input name="message" autocomplete="off" placeholder="今天过得怎么样" aria-label="写下你的心里话">
          <button type="submit" class="btn primary">发送</button>
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

  function enterConversationMode() {
    if (!chatStage) return;
    chatStage.classList.remove('is-room-mode');
    chatStage.classList.add('is-conversation-mode');
  }

  if (typeof input.addEventListener === 'function') {
    input.addEventListener('focus', enterConversationMode);
    input.addEventListener('input', enterConversationMode);
  }

  const isDev = storage.getItem('qiyu_dev_mode') === 'true';
  if (devDiagnostics && isDev) {
    devDiagnostics.style.display = 'block';
    devDiagnostics.innerText = '[调试] 开发者模式已激活。发送消息后将在此输出实时 API 连接诊断信息。';
  }

  function scrollToBottom(options = {}) {
    const isReduced = typeof window.matchMedia === 'function' ? window.matchMedia('(prefers-reduced-motion: reduce)').matches : false;
    const defaultBehavior = isReduced ? 'auto' : 'smooth';
    
    // Stagger layout calculation to next tick to ensure DOM paints first
    setTimeout(() => {
      thread.scrollTo({
        top: thread.scrollHeight,
        behavior: options.behavior || defaultBehavior
      });
      // Scroll input field directly into view to solve mobile keyboard layout bugs
      if (typeof document !== 'undefined' && document.activeElement === input) {
        input.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      }
    }, 50);
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
    const welcome = state.userName && state.userName !== '你'
      ? `你来了，${state.userName}。今晚，外面安静下来了吗？`
      : '你来了。今晚，外面安静下来了吗？';
    appendMessage('qiyu', welcome);
  }

  let isTyping = false;

  async function processReplyQueue(replyMessages) {
    isTyping = true;
    input.disabled = true;
    form.querySelector('button').disabled = true;

    try {
      for (let i = 0; i < replyMessages.length; i++) {
        const text = replyMessages[i];
        const isSilence = text === '……';
        let indicator;

        if (!isSilence) {
          indicator = appendTypingIndicator();
          const isHeavy = text.length > 15 || /难受|分手|吵架|累|疲惫/.test(text);
          const delay = isHeavy 
            ? Math.min(Math.max(text.length * 60 + 300, 450), 2000)
            : Math.min(Math.max(text.length * 30 + 150, 200), 1000);
          await new Promise(resolve => setTimeout(resolve, delay));
          if (indicator && indicator.parentNode) {
            indicator.parentNode.removeChild(indicator);
          }
        } else {
          // Silence pause without showing any indicator layout
          await new Promise(resolve => setTimeout(resolve, 600));
        }

        appendMessage('qiyu', text);

        if (i < replyMessages.length - 1) {
          await new Promise(resolve => setTimeout(resolve, 300));
        }
      }
    } finally {
      isTyping = false;
      input.disabled = false;
      form.querySelector('button').disabled = false;
      // Refocus input field after processing replies for seamless typing
      input.focus();
    }
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (isTyping) return;

    const text = input.value.trim();
    if (!text) return;

    enterConversationMode();
    input.value = '';
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

    await processReplyQueue(result.messages);
  });

  if (resetBtn) {
    resetBtn.addEventListener('click', () => {
      if (isTyping) return;
      if (confirm('确认清空当前对话上下文吗？这不会删除您的历史归档记录。')) {
        state.turns = [];
        saveBrowserState(storage, state);
        msgContainer.innerHTML = '';
        const welcome = state.userName && state.userName !== '你'
          ? `你来了，${state.userName}。今晚，外面安静下来了吗？`
          : '你来了。今晚，外面安静下来了吗？';
        appendMessage('qiyu', welcome);
      }
    });
  }
}
