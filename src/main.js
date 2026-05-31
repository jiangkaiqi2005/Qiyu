import { createQiyuReply } from './qiyu/engine.js';
import {
  createInitialState,
  startSession,
  loadBrowserState,
  saveBrowserState
} from './qiyu/state.js';
import { renderThread } from './ui/render.js';

const app = document.querySelector('#app');
const storage = window.localStorage;
let state = startSession(loadBrowserState(storage));
saveBrowserState(storage, state);
let messages = state.turns.length
  ? state.turns.map((turn) => ({ speaker: turn.speaker === 'user' ? 'user' : 'qiyu', text: turn.text }))
  : [{ speaker: 'qiyu', text: '嗨。我是栖语。' }];

function draw() {
  app.innerHTML = `
    <main class="shell">
      <section class="thread" aria-label="栖语对话">
        <div class="presence" aria-hidden="true">
          <span class="mark">栖</span>
          <span>深夜在线</span>
        </div>
        ${renderThread(messages)}
      </section>
      <form class="composer" aria-label="发送消息">
        <input name="message" autocomplete="off" placeholder="今天过得怎么样">
        <button type="submit">发送</button>
      </form>
      <button class="reset" type="button">清空本地对话</button>
    </main>
  `;

  const form = app.querySelector('.composer');
  const reset = app.querySelector('.reset');
  const input = form.elements.message;
  input.focus();

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text) {
      return;
    }

    messages = [...messages, { speaker: 'user', text }];
    const result = createQiyuReply(text, state);
    state = result.nextState;
    messages = [
      ...messages,
      ...result.messages.map((message) => ({ speaker: 'qiyu', text: message }))
    ];
    saveBrowserState(storage, state);
    draw();
  });

  reset.addEventListener('click', () => {
    state = createInitialState('local-user');
    storage.removeItem('qiyu.state');
    messages = [{ speaker: 'qiyu', text: '嗨。我是栖语。' }];
    draw();
  });
}

draw();
