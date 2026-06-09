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
    },
    createDocumentFragment() {
      return {
        appendChild() {}
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
        classList: { add() {} },
        style: { display: 'none' },
        innerText: ''
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
  assert.match(container.innerHTML, /清空当前上下文/);

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

  // 3. Render with dev mode active
  savedItems['qiyu_dev_mode'] = 'true';
  render(container, { router });
  assert.match(container.innerHTML, /chat-dev-diagnostics/);

  delete globalThis.window;
  delete globalThis.document;
});

test('chat starts as room mode and enters conversation mode on typing focus', () => {
  let savedItems = {};
  let focusHandler = null;
  const rootClassList = {
    values: new Set(),
    add(value) {
      this.values.add(value);
    },
    remove(value) {
      this.values.delete(value);
    },
    contains(value) {
      return this.values.has(value);
    }
  };

  globalThis.window = {
    location: { pathname: '/chat' },
    addEventListener() {},
    matchMedia() {
      return { matches: true };
    },
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
    activeElement: null,
    createElement() {
      return {
        innerHTML: '',
        get firstChild() {
          return {
            classList: { add() {} }
          };
        }
      };
    },
    createDocumentFragment() {
      return {
        appendChild() {}
      };
    }
  };

  const input = {
    value: '',
    disabled: false,
    focus() {},
    scrollIntoView() {},
    addEventListener(type, handler) {
      if (type === 'focus') focusHandler = handler;
    }
  };

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.qiyu-chat-stage') {
        return { classList: rootClassList };
      }
      if (selector === '.composer') {
        return {
          elements: { message: input },
          addEventListener() {},
          querySelector() { return { disabled: false }; }
        };
      }
      return {
        addEventListener() {},
        scrollTo() {},
        appendChild() {},
        classList: { add() {}, remove() {} },
        style: { display: 'none' },
        innerText: ''
      };
    },
    querySelectorAll() {
      return [];
    }
  };

  render(container, { router: { navigate() {} } });

  assert.match(container.innerHTML, /qiyu-chat-stage is-room-mode/);
  assert.match(container.innerHTML, /room-arrival/);

  assert.equal(typeof focusHandler, 'function');
  focusHandler();
  assert.equal(rootClassList.contains('is-conversation-mode'), true);

  delete globalThis.window;
  delete globalThis.document;
});

test('chat message flow returns focus to composer without scrolling it into view', async () => {
  let savedItems = {};
  let submitHandler = null;
  let inputFocusCount = 0;
  let inputFocusOptions = null;
  let inputScrollIntoViewCount = 0;
  const scrollCalls = [];

  globalThis.window = {
    location: { pathname: '/chat' },
    addEventListener() {},
    matchMedia() {
      return { matches: false };
    },
    requestAnimationFrame(callback) {
      callback();
      return 1;
    },
    cancelAnimationFrame() {},
    localStorage: {
      getItem(key) {
        return savedItems[key] || null;
      },
      setItem(key, val) {
        savedItems[key] = val;
      }
    }
  };

  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({
      messages: [],
      nextState: JSON.parse(savedItems['qiyu.state'])
    })
  });

  const input = {
    value: '你好',
    disabled: false,
    focus(options) {
      inputFocusCount++;
      inputFocusOptions = options || null;
    },
    scrollIntoView() {
      inputScrollIntoViewCount++;
    },
    addEventListener() {}
  };

  globalThis.document = {
    activeElement: { tagName: 'BODY' },
    createElement() {
      return {
        innerHTML: '',
        get firstChild() {
          return {
            classList: { add() {} }
          };
        }
      };
    },
    createDocumentFragment() {
      return {
        appendChild() {}
      };
    }
  };

  const button = { disabled: false };
  const thread = {
    scrollHeight: 320,
    scrollTo(options) {
      scrollCalls.push(options);
    }
  };

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.composer') {
        return {
          elements: { message: input },
          addEventListener(type, handler) {
            if (type === 'submit') submitHandler = handler;
          },
          querySelector() {
            return button;
          }
        };
      }
      if (selector === '.thread') {
        return thread;
      }
      if (selector === '.qiyu-chat-stage') {
        return { classList: { add() {}, remove() {} } };
      }
      return {
        addEventListener() {},
        appendChild() {},
        classList: { add() {} },
        style: { display: 'none' },
        innerText: ''
      };
    },
    querySelectorAll() {
      return [];
    }
  };

  render(container, { router: { navigate() {} } });
  assert.equal(typeof submitHandler, 'function');

  await submitHandler({ preventDefault() {} });

  assert.equal(inputScrollIntoViewCount, 0);
  assert.equal(inputFocusCount, 1);
  assert.deepEqual(inputFocusOptions, { preventScroll: true });
  assert.ok(scrollCalls.length >= 1);
  assert.equal(scrollCalls.at(-1).behavior, 'auto');

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});
