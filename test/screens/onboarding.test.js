import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/onboarding.js';

test('onboarding screen transitions and state updates', () => {
  let savedItems = {};
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

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.onboarding-card') {
        return {
          querySelector(sel) {
            return {
              addEventListener() {},
              value: '林深',
              checked: true
            };
          }
        };
      }
      return {
        addEventListener() {},
        scrollTo() {},
        appendChild() {},
        classList: { add() {} },
        style: { visibility: 'visible' },
        elements: {},
        set innerHTML(val) {
          container.innerHTML += ' ' + val;
        },
        set innerText(val) {
          container.innerHTML += ' ' + val;
        }
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
  assert.match(container.innerHTML, /首次相遇设置/);
  assert.match(container.innerHTML, /第 1 步/);

  delete globalThis.window;
  delete globalThis.document;
});
