import test from 'node:test';
import assert from 'node:assert/strict';
import { Router } from '../../src/router.js';

test('router matches routes and falls back gracefully', async () => {
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
      if (selector === '.composer' || selector === '.trial-composer') {
        return {
          elements: { message: { focus() {}, value: '' } },
          addEventListener() {},
          querySelector() { return { disabled: false }; },
          querySelectorAll() { return []; }
        };
      }
      return {
        addEventListener() {},
        scrollTo() {},
        appendChild() {},
        classList: { add() {} },
        querySelectorAll() { return []; }
      };
    },
    querySelectorAll() {
      return [];
    },
    addEventListener() {}
  };

  const router = new Router(container);

  // Test home route
  window.location.pathname = '/';
  await router.resolve();
  assert.match(container.innerHTML, /栖语/);

  // Test navigation
  await router.navigate('/chat');
  assert.equal(window.location.pathname, '/chat');
  assert.match(container.innerHTML, /栖语/);

  // Test history navigation
  await router.navigate('/history');
  assert.equal(window.location.pathname, '/history');
  assert.match(container.innerHTML, /栖语/);

  // Test unknown route
  await router.navigate('/some-nonexistent-route');
  assert.equal(window.location.pathname, '/some-nonexistent-route');
  assert.match(container.innerHTML, /404/);

  delete globalThis.window;
  delete globalThis.document;
});
