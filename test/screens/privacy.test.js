import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/privacy.js';

test('privacy and safety screen renders key sections', () => {
  globalThis.window = {
    location: { pathname: '/privacy' },
    addEventListener() {},
    localStorage: {
      getItem() { return null; },
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
        addEventListener() {}
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
  assert.match(container.innerHTML, /隐私与安全边界/);
  assert.match(container.innerHTML, /危机安全与紧急干预行为/);
  assert.match(container.innerHTML, /大语言模型/);
  assert.match(container.innerHTML, /有所为与有所不为/);
  assert.match(container.innerHTML, /本地上下文/);
  assert.doesNotMatch(container.innerHTML, /<span>0[1-9]<\/span>/);
  assert.doesNotMatch(container.innerHTML, /本地印记|事实记忆/);
  assert.doesNotMatch(container.innerHTML, /privacy boundary|>principles</);

  delete globalThis.window;
  delete globalThis.document;
});
