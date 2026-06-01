import test from 'node:test';
import assert from 'node:assert/strict';
import { sendChatMessage } from '../../src/ui/chat-api.js';
import { createInitialState } from '../../src/qiyu/state.js';

test('sendChatMessage posts text and state to api route', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
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
  assert.equal(calls[0].url, '/api/chat');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(JSON.parse(calls[0].options.body).text, '今天好累');
});

test('sendChatMessage reports bad api responses', async () => {
  await assert.rejects(
    () => sendChatMessage({
      text: '今天好累',
      state: createInitialState('local-user'),
      fetchImpl: async () => ({
        ok: false,
        status: 500,
        async text() {
          return '{"error":"bad"}';
        }
      })
    }),
    /Chat API failed: 500/
  );
});
