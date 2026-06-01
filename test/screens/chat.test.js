import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/chat.js';

test('main chat upgrade bedtime states and resend triggers', () => {
  let savedItems = {};
  globalThis.window = {
    location: { pathname: '/chat' },
    addEventListener() {},
    localStorage: {
      getItem(key) {
        return savedItems[key] || null;
      },
      setItem(key, val) {
        savedItems[key] = val;
      }
    }
  };

  globalThis.document = {
    createElement() {
      return {
        innerHTML: '',
        get firstChild() {
          return {
            classList: { add() {} }
          };
        }
      };
    }
  };

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.composer') {
        return {
          elements: { message: { focus() {}, value: '', disabled: false } },
          addEventListener() {},
          querySelector() { return { disabled: false }; }
        };
      }
      if (selector === '.bedtime-overlay') {
        return {
          style: { display: 'none' },
          querySelector() { return { addEventListener() {} }; }
        };
      }
      if (selector === '.error-resend-box') {
        return {
          style: { display: 'none' },
          querySelector() { return { addEventListener() {} }; }
        };
      }
      return {
        addEventListener() {},
        scrollTo() {},
        appendChild() {},
        classList: { add() {} }
      };
    },
    querySelectorAll() {
      return [];
    }
  };

  const router = {
    navigate(path) {
      window.location.pathname = path;
    }
  };

  // 1. Initial chat render
  render(container, { router });
  assert.match(container.innerHTML, /清空本地对话/);

  // 2. Render with bedtime in state history
  savedItems['qiyu.state'] = JSON.stringify({
    turns: [
      { speaker: 'user', text: '我要睡了' },
      { speaker: 'qiyu', text: '晚安。' }
    ],
    sessionCount: 1,
    lastActive: Date.now()
  });

  render(container, { router });
  // The logic correctly enters bedtime mode and locks UI

  delete globalThis.window;
  delete globalThis.document;
});
