import test from 'node:test';
import assert from 'node:assert/strict';
import { Router } from '../../src/router.js';

test('router matches routes and falls back gracefully', () => {
  globalThis.window = {
    location: { pathname: '/' },
    history: {
      pushState(state, title, url) {
        window.location.pathname = url;
      }
    },
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
            classList: {
              add() {}
            }
          };
        }
      };
    }
  };

  const container = {
    innerHTML: '',
    querySelector(selector) {
      if (selector === '.composer' || selector === '.trial-composer') {
        return {
          elements: { message: { focus() {}, value: '' } },
          addEventListener() {},
          querySelector() { return { disabled: false }; }
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

  const router = new Router(container);

  // Test home route
  window.location.pathname = '/';
  router.resolve();
  assert.match(container.innerHTML, /栖语/);

  // Test navigation
  router.navigate('/chat');
  assert.equal(window.location.pathname, '/chat');
  assert.match(container.innerHTML, /栖语/);

  // Test unknown route
  router.navigate('/some-nonexistent-route');
  assert.equal(window.location.pathname, '/some-nonexistent-route');
  assert.match(container.innerHTML, /404/);

  delete globalThis.window;
  delete globalThis.document;
});
