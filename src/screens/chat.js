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
  let state = startSession(loadBrowserState(storage));
  saveBrowserState(storage, state);

  const innerHtml = `
    <div class="shell">
      <section class="thread" aria-label="与 栖语 的深夜夜话" role="log" aria-live="polite">
        <div class="message-container"></div>
      </section>
      <form class="composer" aria-label="发送消息">
        <input name="message" autocomplete="off" placeholder="今天过得怎么样" aria-label="写下你的心里话">
        <button type="submit" class="btn primary">发送</button>
      </form>
      <button class="reset" type="button" aria-label="抹去深夜里的所有相遇痕迹">抹去深夜里的所有相遇痕迹</button>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/chat');
  bindNavigation(container, context.router);

  const thread = container.querySelector('.thread');
  const msgContainer = container.querySelector('.message-container');
  const form = container.querySelector('.composer');
  const reset = container.querySelector('.reset');
  const input = form.elements.message;

  function scrollToBottom(options = {}) {
    // Accessibility check: Query system preferences for prefers-reduced-motion
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

  // SOTA High Performance: Document Fragment batch DOM rendering (Reduces reflows from N to 1)
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
    appendMessage('qiyu', '你来了。今晚，外面安静下来了吗？');
  }

  // Removed autofocus hijacking input.focus() to satisfy WCAG A11y standards

  let isTyping = false;

  async function processReplyQueue(replyMessages) {
    isTyping = true;
    input.disabled = true;
    form.querySelector('button').disabled = true;

    try {
      for (let i = 0; i < replyMessages.length; i++) {
        const text = replyMessages[i];
        const indicator = appendTypingIndicator();

        const delay = Math.min(Math.max(text.length * 50 + 250, 300), 1000);
        await new Promise(resolve => setTimeout(resolve, delay));

        if (indicator.parentNode) {
          indicator.parentNode.removeChild(indicator);
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
    }
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (isTyping) return;

    const text = input.value.trim();
    if (!text) return;

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

    await processReplyQueue(result.messages);
  });

  reset.addEventListener('click', () => {
    if (isTyping) return;
    state = createInitialState('local-user');
    saveBrowserState(storage, state);
    msgContainer.innerHTML = '';
    appendMessage('qiyu', '你来了。今晚，外面安静下来了吗？');
  });
}
