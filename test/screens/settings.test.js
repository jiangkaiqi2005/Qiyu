import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/settings.js';

test('settings screen render elements and controls', () => {
  let savedItems = {};
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
