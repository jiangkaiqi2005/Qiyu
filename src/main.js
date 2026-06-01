import { createQiyuReply } from './qiyu/engine.js';
import {
  createInitialState,
  startSession,
  loadBrowserState,
  saveBrowserState
} from './qiyu/state.js';
import { renderBubble } from './ui/render.js';
import { sendChatMessage } from './ui/chat-api.js';

const app = document.querySelector('#app');
const storage = window.localStorage;
let state = startSession(loadBrowserState(storage));
saveBrowserState(storage, state);

// 渲染 App Shell 结构（仅在初始化时执行一次）
app.innerHTML = `
  <main class="shell">
    <section class="thread" aria-label="栖语对话" role="log" aria-live="polite">
      <div class="presence" aria-hidden="true">
        <span class="mark">栖</span>
        <span>深夜在线</span>
      </div>
      <div class="message-container"></div>
    </section>
    <form class="composer" aria-label="发送消息">
      <input name="message" autocomplete="off" placeholder="今天过得怎么样">
      <button type="submit">发送</button>
    </form>
    <button class="reset" type="button">清空本地对话</button>
  </main>
`;

const thread = app.querySelector('.thread');
const container = app.querySelector('.message-container');
const form = app.querySelector('.composer');
const reset = app.querySelector('.reset');
const input = form.elements.message;

// 辅助函数：平滑滚动到聊天底端
function scrollToBottom() {
  thread.scrollTo({
    top: thread.scrollHeight,
    behavior: 'smooth'
  });
}

// 增量添加普通消息气泡
function appendMessage(speaker, text) {
  const html = renderBubble({ speaker, text });
  const tempDiv = document.createElement('div');
  tempDiv.innerHTML = html.trim();
  const bubble = tempDiv.firstChild;
  bubble.classList.add('bubble-fadeIn');
  container.appendChild(bubble);
  scrollToBottom();
}

// 显示“正在输入…”跳动指示器
function appendTypingIndicator() {
  const indicator = document.createElement('p');
  indicator.className = 'qiyu typing-indicator bubble-fadeIn';
  indicator.setAttribute('role', 'status');
  indicator.setAttribute('aria-label', '栖语正在输入...');
  indicator.innerHTML = '<span>.</span><span>.</span><span>.</span>';
  container.appendChild(indicator);
  scrollToBottom();
  return indicator;
}

// 初始化加载历史消息
const historyTurns = state.turns;
if (historyTurns.length) {
  historyTurns.forEach(turn => {
    appendMessage(turn.speaker === 'user' ? 'user' : 'qiyu', turn.text);
  });
} else {
  appendMessage('qiyu', '嗨。我是栖语。');
}
input.focus();

// 处理消息输入与延迟队列
let isTyping = false;

async function processReplyQueue(replyMessages) {
  isTyping = true;
  input.disabled = true;
  form.querySelector('button').disabled = true;

  try {
    for (let i = 0; i < replyMessages.length; i++) {
      const text = replyMessages[i];
      const indicator = appendTypingIndicator();

      // 延迟时间根据字数计算，在 300ms 到 1000ms 之间
      const delay = Math.min(Math.max(text.length * 50 + 250, 300), 1000);
      await new Promise(resolve => setTimeout(resolve, delay));

      // 移除指示器并追加真实消息
      if (indicator.parentNode) {
        indicator.parentNode.removeChild(indicator);
      }
      appendMessage('qiyu', text);

      // 如果还有后续消息，额外多等待 300ms 做视觉区分，拟真度更高
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

  processReplyQueue(result.messages);
});

reset.addEventListener('click', () => {
  if (isTyping) return;
  state = createInitialState('local-user');
  saveBrowserState(storage, state);
  container.innerHTML = '';
  appendMessage('qiyu', '嗨。我是栖语。');
  input.focus();
});
