import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/settings.js';

function installWindow(savedItems = {}) {
  globalThis.window = {
    location: { pathname: '/settings' },
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
}

function installDocument() {
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
}

function installSettingsFetchSequence(responses) {
  const queue = responses.map((response) => {
    let resolveLoaded;
    return {
      response,
      loaded: new Promise((resolve) => {
        resolveLoaded = resolve;
      }),
      resolveLoaded
    };
  });
  let index = 0;

  globalThis.fetch = async () => {
    const current = queue[index] || queue[queue.length - 1];
    index += 1;
    return {
      ok: current.response.ok ?? true,
      json: async () => {
        current.resolveLoaded();
        return current.response.body;
      }
    };
  };

  return {
    async waitForCall(callIndex) {
      await queue[callIndex].loaded;
      await Promise.resolve();
    }
  };
}

test('settings screen render elements and controls', () => {
  let savedItems = {};
  installWindow(savedItems);
  installDocument();
  globalThis.fetch = async () => {
    return {
      ok: true,
      json: async () => ({
        apiUrl: 'https://mock.api',
        apiKey: '••••••••',
        model: 'gpt-4',
        temperature: 0.8,
        timeoutMs: 30000
      })
    };
  };

  const container = {
    innerHTML: '',
    querySelector(selector) {
      return {
        addEventListener() {},
        style: { display: 'none' },
        elements: {},
        value: '',
        innerText: '',
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

  render(container, { router });
  assert.match(container.innerHTML, /默契中心/);

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});

test('settings screen explains that masked api keys cannot be revealed from the eye toggle', async () => {
  let savedItems = {};
  let noticeHtml = '';
  const listeners = {};
  const settingsFetch = installSettingsFetchSequence([
    {
      body: {
        apiUrl: 'https://mock.api',
        apiKey: '••••••••',
        model: 'gpt-4',
        temperature: 0.8,
        timeoutMs: 30000
      }
    }
  ]);
  const apiKeyInlineNotice = {
    innerText: '',
    style: { display: 'none' }
  };
  const apiKeyInput = {
    value: '',
    type: 'password',
    style: { display: 'none' },
    dataset: {},
    addEventListener(event, fn) {
      listeners['[name="apiKey"]:' + event] = fn;
    },
    focus() {
      this.focused = true;
    }
  };
  const togglePwBtn = {
    innerText: '👁️',
    attrs: {},
    addEventListener(event, fn) {
      listeners['.toggle-pw-btn:' + event] = fn;
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    }
  };
  const noticeArea = {
    get innerHTML() {
      return noticeHtml;
    },
    set innerHTML(value) {
      noticeHtml = value;
    }
  };

  installWindow(savedItems);
  installDocument();

  const genericNode = {
    addEventListener() {},
    style: { display: 'none' },
    value: '',
    checked: false,
    innerText: '',
    innerHTML: '',
    appendChild() {},
    classList: { add() {} },
    querySelectorAll() { return []; }
  };

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.settings-notice-area') return noticeArea;
      if (selector === '.api-key-inline-notice') return apiKeyInlineNotice;
      if (selector === '.toggle-pw-btn') return togglePwBtn;
      if (selector === '[name="apiKey"]') return apiKeyInput;
      return { ...genericNode };
    },
    querySelectorAll() {
      return [];
    }
  };

  render(container, { router: { navigate() {} } });
  await settingsFetch.waitForCall(0);
  await listeners['.toggle-pw-btn:click']();

  assert.match(apiKeyInlineNotice.innerText, /脱敏/);
  assert.equal(apiKeyInlineNotice.style.display, 'block');
  assert.equal(apiKeyInput.type, 'password');
  assert.equal(togglePwBtn.innerText, '👁️');

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});

test('settings screen still warns for masked placeholder values even without masked dataset state', async () => {
  let savedItems = {};
  let noticeHtml = '';
  const listeners = {};
  installSettingsFetchSequence([
    {
      body: {
        apiUrl: 'https://mock.api',
        apiKey: '',
        model: 'gpt-4',
        temperature: 0.8,
        timeoutMs: 30000
      }
    }
  ]);
  const apiKeyInput = {
    value: '••••••••',
    type: 'password',
    style: { display: 'none' },
    dataset: {},
    addEventListener(event, fn) {
      listeners['[name="apiKey"]:' + event] = fn;
    },
    focus() {
      this.focused = true;
    }
  };
  const togglePwBtn = {
    innerText: '👁️',
    attrs: {},
    addEventListener(event, fn) {
      listeners['.toggle-pw-btn:' + event] = fn;
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    }
  };
  const noticeArea = {
    get innerHTML() {
      return noticeHtml;
    },
    set innerHTML(value) {
      noticeHtml = value;
    }
  };

  installWindow(savedItems);
  installDocument();

  const genericNode = {
    addEventListener() {},
    style: { display: 'none' },
    value: '',
    checked: false,
    innerText: '',
    innerHTML: '',
    appendChild() {},
    classList: { add() {} },
    querySelectorAll() { return []; }
  };

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.settings-notice-area') return noticeArea;
      if (selector === '.toggle-pw-btn') return togglePwBtn;
      if (selector === '[name="apiKey"]') return apiKeyInput;
      return { ...genericNode };
    },
    querySelectorAll() {
      return [];
    }
  };

  render(container, { router: { navigate() {} } });
  await listeners['.toggle-pw-btn:click']();

  assert.match(noticeHtml, /脱敏/);
  assert.equal(apiKeyInput.type, 'password');
  assert.equal(apiKeyInput.focused, true);

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});

test('settings screen still toggles visibility after user enters a real api key', async () => {
  let savedItems = {};
  const listeners = {};
  const settingsFetch = installSettingsFetchSequence([
    {
      body: {
        apiUrl: 'https://mock.api',
        apiKey: '••••••••',
        model: 'gpt-4',
        temperature: 0.8,
        timeoutMs: 30000
      }
    }
  ]);
  const apiKeyInlineNotice = {
    innerText: '',
    style: { display: 'none' }
  };
  const apiKeyInput = {
    value: '',
    type: 'password',
    style: { display: 'none' },
    dataset: {},
    addEventListener(event, fn) {
      listeners['[name="apiKey"]:' + event] = fn;
    }
  };
  const togglePwBtn = {
    innerText: '👁️',
    attrs: {},
    addEventListener(event, fn) {
      listeners['.toggle-pw-btn:' + event] = fn;
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    }
  };

  installWindow(savedItems);
  installDocument();

  const genericNode = {
    addEventListener() {},
    style: { display: 'none' },
    value: '',
    checked: false,
    innerText: '',
    innerHTML: '',
    appendChild() {},
    classList: { add() {} },
    querySelectorAll() { return []; }
  };

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.api-key-inline-notice') return apiKeyInlineNotice;
      if (selector === '.toggle-pw-btn') return togglePwBtn;
      if (selector === '[name="apiKey"]') return apiKeyInput;
      return { ...genericNode };
    },
    querySelectorAll() {
      return [];
    }
  };

  render(container, { router: { navigate() {} } });
  await settingsFetch.waitForCall(0);
  apiKeyInput.value = 'real-key';
  apiKeyInput.dataset.masked = 'true';
  apiKeyInlineNotice.innerText = '当前显示的是脱敏占位符';
  apiKeyInlineNotice.style.display = 'block';
  await listeners['[name="apiKey"]:input']();
  await listeners['.toggle-pw-btn:click']();

  assert.equal(apiKeyInlineNotice.innerText, '');
  assert.equal(apiKeyInlineNotice.style.display, 'none');
  assert.equal(apiKeyInput.type, 'text');
  assert.equal(togglePwBtn.innerText, '🔒');
  assert.equal(togglePwBtn.attrs['aria-label'], '隐藏 API 密钥');

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});

test('settings screen resets the eye toggle after masked config reloads from the server', async () => {
  let savedItems = {};
  const listeners = {};
  const settingsFetch = installSettingsFetchSequence([
    {
      body: {
        apiUrl: 'https://mock.api',
        apiKey: '••••••••',
        model: 'gpt-4',
        temperature: 0.8,
        timeoutMs: 30000
      }
    }
  ]);
  const apiKeyInput = {
    value: '',
    type: 'text',
    style: { display: 'none' },
    dataset: {},
    addEventListener(event, fn) {
      listeners['[name="apiKey"]:' + event] = fn;
    }
  };
  const togglePwBtn = {
    innerText: '🔒',
    attrs: { 'aria-label': '隐藏 API 密钥' },
    addEventListener(event, fn) {
      listeners['.toggle-pw-btn:' + event] = fn;
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    }
  };

  installWindow(savedItems);
  installDocument();

  const genericNode = {
    addEventListener() {},
    style: { display: 'none' },
    value: '',
    checked: false,
    innerText: '',
    innerHTML: '',
    appendChild() {},
    classList: { add() {} },
    querySelectorAll() { return []; }
  };

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.toggle-pw-btn') return togglePwBtn;
      if (selector === '[name="apiKey"]') return apiKeyInput;
      return { ...genericNode };
    },
    querySelectorAll() {
      return [];
    }
  };

  render(container, { router: { navigate() {} } });
  await settingsFetch.waitForCall(0);

  assert.equal(apiKeyInput.type, 'password');
  assert.equal(togglePwBtn.innerText, '👁️');
  assert.equal(togglePwBtn.attrs['aria-label'], '显示 API 密钥');

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});
