import test from 'node:test';
import assert from 'node:assert/strict';
import { callChatCompletions } from '../../src/server/llm-client.js';

test('callChatCompletions posts OpenAI-compatible request', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return {
      ok: true,
      status: 200,
      async json() {
        return { choices: [{ message: { content: '……怎么回事' } }] };
      }
    };
  };

  const text = await callChatCompletions({
    config: {
      apiUrl: 'https://llm.example.test/v1/chat/completions',
      apiKey: 'key',
      model: 'qiyu-test-model',
      temperature: 0.8,
      timeoutMs: 30000
    },
    messages: [{ role: 'system', content: '你是栖语' }],
    fetchImpl
  });

  assert.equal(text, '……怎么回事');
  assert.equal(calls[0].url, 'https://llm.example.test/v1/chat/completions');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.headers.Authorization, 'Bearer key');
  assert.equal(JSON.parse(calls[0].options.body).model, 'qiyu-test-model');
});

test('callChatCompletions reports provider errors', async () => {
  const fetchImpl = async () => ({
    ok: false,
    status: 401,
    async text() {
      return 'bad key';
    }
  });

  await assert.rejects(
    () => callChatCompletions({
      config: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'key',
        model: 'qiyu-test-model',
        temperature: 0.8,
        timeoutMs: 30000
      },
      messages: [],
      fetchImpl
    }),
    /LLM request failed: 401 bad key/
  );
});
