import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/lab.js';

test('lab screen renders titles and action buttons', () => {
  globalThis.window = {
    location: { pathname: '/lab' },
    addEventListener() {},
    localStorage: {
      getItem() { return 'true'; },
      setItem() {}
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
  assert.match(container.innerHTML, /质量实验室/);
  assert.match(container.innerHTML, /运行黄金测试集/);

  delete globalThis.window;
  delete globalThis.document;
});
