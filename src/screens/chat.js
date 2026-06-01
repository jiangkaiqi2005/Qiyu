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

  container.innerHTML = `
    <main class="shell">
      <header class="chat-header">
        <button data-path="/" class="nav-back-btn">← 返回</button>
        <div class="presence" aria-hidden="true">
          <span class="mark">栖</span>
          <span>深夜在线</span>
        </div>
      </header>
      <section class="thread" aria-label="栖语对话" role="log" aria-live="polite">
        <div class="message-container"></div>
      </section>
      <form class="composer" aria-label="发送消息">
        <input name="message" autocomplete="off" placeholder="今天过得怎么样">
        <button type="submit">发送</button>
      </form>
      <button class="reset" type="button">清空本地对话</button>
    </main>
  `;

  const thread = container.querySelector('.thread');
  const msgContainer = container.querySelector('.message-container');
  const form = container.querySelector('.composer');
  const reset = container.querySelector('.reset');
  const input = form.elements.message;
  const backBtn = container.querySelector('.nav-back-btn');

  backBtn.addEventListener('click', () => {
    context.router.navigate('/');
  });

  function scrollToBottom() {
    thread.scrollTo({
      top: thread.scrollHeight,
      behavior: 'smooth'
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
    indicator.setAttribute('aria-label', '栖语正在输入...');
    indicator.innerHTML = '<span>.</span><span>.</span><span>.</span>';
    msgContainer.appendChild(indicator);
    scrollToBottom();
    return indicator;
  }

  // Load history
  const historyTurns = state.turns;
  if (historyTurns.length) {
    historyTurns.forEach(turn => {
      appendMessage(turn.speaker === 'user' ? 'user' : 'qiyu', turn.text);
    });
  } else {
    appendMessage('qiyu', '嗨。我是栖语。');
  }
  input.focus();

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
      input.focus();
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
    appendMessage('qiyu', '嗨。我是栖语。');
    input.focus();
  });
}
