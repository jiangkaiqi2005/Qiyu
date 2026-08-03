import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { render } from '../../src/screens/settings.js';

const root = new URL('../../', import.meta.url);

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

test('settings screen uses quiet product language instead of dashboard labels', () => {
  let savedItems = {};
  installWindow(savedItems);
  installDocument();
  globalThis.fetch = async () => {
    return {
      ok: true,
      json: async () => ({
        apiUrl: '',
        apiKey: '',
        model: '',
        temperature: 0.8,
        timeoutMs: 30000
      })
    };
  };

  const container = {
    innerHTML: '',
    querySelector() {
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

  render(container, { router: { navigate() {} } });

  assert.match(container.innerHTML, /settings-hero-state/);
  assert.match(container.innerHTML, /settings-section-eyebrow/);
  assert.match(container.innerHTML, /模型接入/);
  assert.match(container.innerHTML, /本地上下文/);
  assert.doesNotMatch(container.innerHTML, /calibration|night mode/);
  assert.doesNotMatch(container.innerHTML, /settings-section-head[^>]*>\s*<span>0[1-4]<\/span>/);
  assert.doesNotMatch(container.innerHTML, /记忆功能|印记/);
  assert.doesNotMatch(
    container.innerHTML,
    /灵魂引擎|Provider Preset|API URL|API Key|模型名称 \(Model\)|随机温度 \(Temperature\)|网络超时 \(Timeout\)|System Prompt|Live Context/
  );

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});

test('settings api health badge uses css state classes instead of inline dashboard colors', async () => {
  const settingsSource = await readFile(new URL('src/screens/settings.js', root), 'utf8');
  const stylesSource = await readFile(new URL('src/styles.css', root), 'utf8');

  assert.doesNotMatch(
    settingsSource,
    /#94a3b8|#eab308|#3b82f6|#22c55e|#ef4444|statusBadge\.style\.(color|backgroundColor|border)/
  );
  assert.match(settingsSource, /status-badge-connected/);
  assert.match(settingsSource, /status-badge-ready/);
  assert.match(settingsSource, /status-badge-fallback/);
  assert.match(stylesSource, /\.status-badge-connected/);
  assert.match(stylesSource, /\.status-badge-ready/);
  assert.match(stylesSource, /\.status-badge-fallback/);
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
    innerText: '查看',
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
  assert.equal(togglePwBtn.innerText, '查看');

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
    innerText: '查看',
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
    innerText: '查看',
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
  assert.equal(togglePwBtn.innerText, '隐藏');
  assert.equal(togglePwBtn.attrs['aria-label'], '隐藏访问密钥');

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
    innerText: '隐藏',
    attrs: { 'aria-label': '隐藏访问密钥' },
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
  assert.equal(togglePwBtn.innerText, '查看');
  assert.equal(togglePwBtn.attrs['aria-label'], '显示访问密钥');

  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
});
