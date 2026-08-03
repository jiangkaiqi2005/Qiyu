import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/home.js';

test('homepage onboarding state分流 test', async () => {
  let savedItems = {};
  let routeNavigated = '';
  globalThis.window = {
    location: { pathname: '/' },
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

  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({ hasLlm: false })
  });

  const container = {
    innerHTML: '',
    querySelector(selector) {
      return {
        addEventListener() {},
        style: { display: 'none' }
      };
    },
    querySelectorAll() {
      return [];
    }
  };

  const router = {
    navigate(path) {
      window.location.pathname = path;
      routeNavigated = path;
    }
  };

  // 1. Render as a brand-new user with no API config
  render(container, { router });
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.equal(routeNavigated, '/onboarding');

  // 2. Render as a completed onboarding user直接进入夜话
  routeNavigated = '';
  savedItems['qiyu_preferences'] = JSON.stringify({
    onboardingState: 'completed'
  });
  render(container, { router });
  assert.equal(routeNavigated, '/chat');
  assert.doesNotMatch(container.innerHTML, /qiyu-home/);

  delete globalThis.window;
  delete globalThis.fetch;
});

test('homepage does not force onboarding when API is already configured', async () => {
  let routeNavigated = '';
  globalThis.window = {
    location: { pathname: '/' },
    addEventListener() {},
    localStorage: {
      getItem() { return null; },
      setItem() {}
    }
  };

  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({ hasLlm: true })
  });

  const container = {
    innerHTML: '',
    querySelector() {
      return {
        addEventListener() {},
        style: { display: 'none' }
      };
    },
    querySelectorAll() {
      return [];
    }
  };

  render(container, {
    router: {
      navigate(path) {
        routeNavigated = path;
      }
    }
  });

  await new Promise(resolve => setTimeout(resolve, 0));
  assert.equal(routeNavigated, '/chat');
  assert.doesNotMatch(container.innerHTML, /开始相识设置/);
  assert.doesNotMatch(container.innerHTML, /qiyu-home/);

  delete globalThis.window;
  delete globalThis.fetch;
});
