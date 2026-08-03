import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/screens/history.js';

test('history screen empty state and detailed logs display', () => {
  let savedItems = {};
  globalThis.window = {
    location: { pathname: '/history' },
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

  const listeners = [];
  const container = {
    innerHTML: '',
    querySelector(selector) {
      return {
        style: { display: 'none' },
        set innerHTML(val) {
          container.innerHTML += ' ' + val;
        },
        set innerText(val) {
          container.innerHTML += ' ' + val;
        },
        querySelectorAll() {
          return [];
        },
        addEventListener(event, fn) {
          listeners.push({ event, fn });
        }
      };
    },
    querySelectorAll() {
      return [];
    },
    addEventListener(event, fn) {
      listeners.push({ event, fn });
    }
  };

  const router = {
    navigate() {}
  };

  // 1. Initial render with no history
  render(container, { router });
  assert.match(container.innerHTML, /这里还没有深夜里的夜话记录呢/);
  assert.doesNotMatch(container.innerHTML, /conversation archive|nights kept|empty archive|select a night/);

  // 2. Render with daily conversations
  savedItems['qiyu.state'] = JSON.stringify({
    dailyConversations: [
      {
        date: '2026-06-03',
        title: '6月3日 夜话',
        startedAt: '2026-06-03T20:00:00.000Z',
        updatedAt: '2026-06-03T20:10:00.000Z',
        turns: [
          { speaker: 'user', text: '昨天说了啥', at: '2026-06-03T20:00:00.000Z' },
          { speaker: 'qiyu', text: '昨天的事', at: '2026-06-03T20:01:00.000Z' }
        ]
      },
      {
        date: '2026-06-04',
        title: '6月4日 <script>alert(1)</script> 夜话',
        startedAt: '2026-06-04T21:00:00.000Z',
        updatedAt: '2026-06-04T21:10:00.000Z',
        turns: [
          { speaker: 'user', text: '今天也来了<img src=x onerror=alert(1)>', at: '2026-06-04T21:00:00.000Z' }
        ]
      }
    ]
  });

  container.innerHTML = '';
  render(container, { router });

  assert.match(container.innerHTML, /6月3日 夜话/);
  assert.match(container.innerHTML, /6月4日 &lt;script&gt;alert\(1\)&lt;\/script&gt; 夜话/);
  assert.match(container.innerHTML, /今天也来了/);
  assert.doesNotMatch(container.innerHTML, /<script>alert\(1\)<\/script>/);
  assert.doesNotMatch(container.innerHTML, /<img src=x onerror=alert\(1\)>/);
  assert.doesNotMatch(container.innerHTML, /conversation archive|nights kept|empty archive|select a night/);

  delete globalThis.window;
  delete globalThis.document;
});
