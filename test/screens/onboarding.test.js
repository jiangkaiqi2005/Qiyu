import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/onboarding.js';

test('onboarding screen transitions and state updates', async () => {
  let savedItems = {};
  let routeNavigated = '';
  let postCount = 0;

  globalThis.window = {
    location: { pathname: '/onboarding' },
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

  globalThis.fetch = async (url, options) => {
    if (options && options.method === 'POST') {
      postCount++;
    }
    return {
      ok: true,
      json: async () => ({
        success: true,
        csrfToken: 'mock-csrf',
        apiUrl: 'https://mock.api',
        model: 'gpt-4'
      })
    };
  };

  const listeners = {};
  const container = {
    innerHTML: '',
    querySelector(selector) {
      return {
        value: selector === '[name="userName"]' ? '林深' : '23:00',
        checked: true,
        style: { display: 'none', visibility: 'visible' },
        elements: {
          message: { focus() {}, value: '', disabled: false },
          apiKey: { value: 'key' }
        },
        addEventListener(event, fn) {
          listeners[selector + ':' + event] = fn;
        },
        querySelectorAll() { return []; }
      };
    },
    querySelectorAll() {
      return [];
    }
  };

  const router = {
    navigate(path) {
      routeNavigated = path;
    }
  };

  // Render onboarding screen
  render(container, { router });

  assert.match(container.innerHTML, /首次相遇设置/);
  assert.match(container.innerHTML, /onboarding-layout/);
  assert.match(container.innerHTML, /step-rail/);
  assert.match(container.innerHTML, /API/);
  assert.match(container.innerHTML, /apiUrl/);
  assert.doesNotMatch(container.innerHTML, /<span>0[1-9]<\/span>/);
  assert.doesNotMatch(container.innerHTML, />记忆</);
  assert.doesNotMatch(container.innerHTML, /印记/);

  // Trigger next step transitions
  const nextListener = listeners['.next-btn:click'];
  assert.ok(nextListener);

  // Step 1 API -> 2
  await nextListener();
  // Step 2 -> 3
  await nextListener();
  // Step 3 -> 4
  await nextListener();
  // Step 4 -> 5
  await nextListener();
  // Step 5 -> Done
  await nextListener();

  assert.equal(routeNavigated, '/chat');
  assert.equal(postCount, 1);
  const prefs = JSON.parse(savedItems['qiyu_preferences']);
  assert.equal(prefs.onboardingState, 'completed');
  assert.equal(prefs.userName, '林深');

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});

test('onboarding frames local context as a privacy boundary instead of a memory feature', async () => {
  let savedItems = {};
  let contentHtml = '';
  const listeners = {};

  globalThis.window = {
    qiyuCsrfToken: 'mock-csrf',
    location: { pathname: '/onboarding' },
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

  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({ csrfToken: 'mock-csrf', success: true })
  });

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.onboarding-content') {
        return {
          get innerHTML() {
            return contentHtml;
          },
          set innerHTML(val) {
            contentHtml = val;
          }
        };
      }
      return {
        value: '',
        checked: true,
        style: { display: 'none', visibility: 'visible' },
        innerText: '',
        addEventListener(event, fn) {
          listeners[selector + ':' + event] = fn;
        },
        querySelectorAll() { return []; }
      };
    },
    querySelectorAll() {
      return [];
    }
  };

  const router = {
    navigate() {}
  };

  render(container, { router });

  const nextListener = listeners['.next-btn:click'];
  await nextListener();
  await nextListener();
  await nextListener();
  await nextListener();

  assert.match(contentHtml, /本地上下文/);
  assert.match(contentHtml, /边界/);
  assert.doesNotMatch(contentHtml, /印记/);
  assert.doesNotMatch(contentHtml, /记忆功能|记住少量本地偏好|本地记住少量偏好/);

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});

test('onboarding blocks progression when API settings save fails', async () => {
  let savedItems = {};
  let routeNavigated = '';
  let postCount = 0;
  let noticeHtml = '';

  globalThis.window = {
    qiyuCsrfToken: '',
    location: { pathname: '/onboarding' },
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

  globalThis.fetch = async (url, options) => {
    if (options && options.method === 'POST') {
      postCount++;
      return {
        ok: false,
        status: 403,
        json: async () => ({ error: 'Forbidden' })
      };
    }
    return {
      ok: true,
      json: async () => ({ csrfToken: 'mock-csrf' })
    };
  };

  const listeners = {};
  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.onboarding-notice-area') {
        return {
          get innerHTML() {
            return noticeHtml;
          },
          set innerHTML(val) {
            noticeHtml = val;
            container.innerHTML += val;
          }
        };
      }
      return {
        value: selector === '[name="apiKey"]' ? 'key' : selector === '[name="model"]' ? 'gpt-4' : 'https://mock.api/v1',
        checked: true,
        style: { display: 'none', visibility: 'visible' },
        innerText: '',
        addEventListener(event, fn) {
          listeners[selector + ':' + event] = fn;
        },
        querySelectorAll() { return []; },
        set innerHTML(val) {
          container.innerHTML += val;
        }
      };
    },
    querySelectorAll() {
      return [];
    }
  };

  const router = {
    navigate(path) {
      routeNavigated = path;
    }
  };

  render(container, { router });
  await listeners['.next-btn:click']();

  assert.equal(postCount, 1);
  assert.equal(routeNavigated, '');
  assert.match(noticeHtml, /API 配置保存失败：HTTP 403/);
  assert.doesNotMatch(savedItems['qiyu_preferences'] || '', /completed/);

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});
