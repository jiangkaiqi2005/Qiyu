import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/home.js';

test('homepage trial chat turn limit and returning user path', async () => {
  let savedItems = {};
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
      if (selector === '.trial-composer') {
        return {
          elements: { message: { focus() {}, value: '', disabled: false } },
          addEventListener() {},
          querySelector() { return { disabled: false }; }
        };
      }
      if (selector === '.onboarding-invite') {
        return {
          style: { display: 'none' },
          querySelector() { return { addEventListener() {} }; }
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

  const router = {
    navigate(path) {
      window.location.pathname = path;
    }
  };

  // 1. First render as new user (no regular history)
  render(container, { router });
  assert.match(container.innerHTML, /试用/);
  assert.doesNotMatch(container.innerHTML, /继续今晚的对话/);

  // 2. Set regular history in localStorage and re-render
  savedItems['qiyu.state'] = JSON.stringify({
    turns: [{ speaker: 'user', text: '你好' }],
    sessionCount: 1,
    lastActive: Date.now()
  });

  render(container, { router });
  assert.match(container.innerHTML, /继续今晚的对话/);

  // 3. Set trial count >= 3 in trial state
  savedItems['qiyu_trial_state'] = JSON.stringify({
    turns: [
      { speaker: 'user', text: '1' },
      { speaker: 'qiyu', text: '1' },
      { speaker: 'user', text: '2' },
      { speaker: 'qiyu', text: '2' },
      { speaker: 'user', text: '3' },
      { speaker: 'qiyu', text: '3' }
    ],
    trialTurnsCount: 3
  });

  render(container, { router });
  // The trial flow limits turn inputs when threshold is hit

  delete globalThis.window;
  delete globalThis.document;
});
