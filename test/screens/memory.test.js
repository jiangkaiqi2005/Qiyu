import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/memory.js';

test('memory screen renders grouped categories and details', () => {
  let savedItems = {};
  globalThis.window = {
    location: { pathname: '/memory' },
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

  savedItems['qiyu.state'] = JSON.stringify({
    turns: [],
    sessionCount: 1,
    lastActive: Date.now(),
    memories: [
      { key: 'user.pet', value: '猫咪叫小七', source: 'dialogue', updatedAt: new Date().toISOString() },
      { key: 'drink.milkTea', value: '喜欢少糖珍奶', source: 'dialogue', updatedAt: new Date().toISOString() },
      {
        key: 'bad"><script>alert(1)</script>',
        value: '<img src=x onerror=alert(1)>',
        source: 'dialogue',
        originalText: '原文<script>alert(2)</script>',
        updatedAt: new Date().toISOString()
      }
    ]
  });

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
        classList: { add() {} },
        querySelectorAll() { return []; },
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
  assert.match(container.innerHTML, /本地印记/);
  assert.match(container.innerHTML, /user\.pet/);
  assert.match(container.innerHTML, /drink\.milkTea/);
  assert.match(container.innerHTML, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.match(container.innerHTML, /原文&lt;script&gt;alert\(2\)&lt;\/script&gt;/);
  assert.doesNotMatch(container.innerHTML, /<img src=x onerror=alert\(1\)>/);
  assert.doesNotMatch(container.innerHTML, /<script>alert\(2\)<\/script>/);
  assert.doesNotMatch(container.innerHTML, /手动镌刻印记/);
  assert.doesNotMatch(container.innerHTML, /手动添加新对话印记事实/);

  delete globalThis.window;
  delete globalThis.document;
});
