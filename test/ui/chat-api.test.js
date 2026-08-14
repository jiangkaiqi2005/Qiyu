import test from 'node:test';
import assert from 'node:assert/strict';
import { sendChatMessage } from '../../src/ui/chat-api.js';
import { createInitialState } from '../../src/qiyu/state.js';

const CSRF_TOKEN = 'test-csrf-token';

test('sendChatMessage posts text and state to api route with CSRF header', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    if (url === '/api/settings') {
      return {
        ok: true,
        status: 200,
        async json() {
          return { csrfToken: CSRF_TOKEN };
        }
      };
    }
    return {
      ok: true,
      status: 200,
      async json() {
        return {
          messages: ['咋了'],
          nextState: createInitialState('local-user'),
          debug: { mode: 'llm' },
          source: 'llm'
        };
      }
    };
  };

  const state = createInitialState('local-user');
  const result = await sendChatMessage({ text: '今天好累', state, fetchImpl });

  assert.deepEqual(result.messages, ['咋了']);
  const chatCall = calls.find((call) => call.url === '/api/chat');
  assert.equal(chatCall.options.method, 'POST');
  assert.equal(chatCall.options.headers['X-CSRF-Token'], CSRF_TOKEN);
  assert.equal(JSON.parse(chatCall.options.body).text, '今天好累');
});

test('sendChatMessage posts with empty CSRF header when token cannot be fetched', async () => {
  delete globalThis.qiyuCsrfToken;
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    if (url === '/api/settings') {
      return { ok: false, status: 500, async json() { return {}; } };
    }
    return {
      ok: true,
      status: 200,
      async json() {
        return {
          messages: ['咋了'],
          nextState: createInitialState('local-user'),
          debug: { mode: 'llm' },
          source: 'llm'
        };
      }
    };
  };

  await sendChatMessage({
    text: '今天好累',
    state: createInitialState('local-user'),
    fetchImpl
  });

  const chatCall = calls.find((call) => call.url === '/api/chat');
  assert.equal(chatCall.options.headers['X-CSRF-Token'], '');
});

test('sendChatMessage reports bad api responses', async () => {
  await assert.rejects(
    () => sendChatMessage({
      text: '今天好累',
      state: createInitialState('local-user'),
      fetchImpl: async (url) => {
        if (url === '/api/settings') {
          return { ok: true, status: 200, async json() { return { csrfToken: CSRF_TOKEN }; } };
        }
        return {
          ok: false,
          status: 500,
          async text() {
            return '{"error":"bad"}';
          }
        };
      }
    }),
    /Chat API failed: 500/
  );
});
