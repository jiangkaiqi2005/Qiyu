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

test('callChatCompletions handles content array format and filters text parts', async () => {
  const fetchImpl = async () => ({
    ok: true,
    status: 200,
    async json() {
      return {
        choices: [
          {
            message: {
              content: [
                { type: 'text', text: '你好，' },
                { type: 'text', text: '我是栖语。' }
              ]
            }
          }
        ]
      };
    }
  });

  const text = await callChatCompletions({
    config: {
      apiUrl: 'https://llm.example.test/v1/chat/completions',
      apiKey: 'test-api-key',
      model: 'test-model',
      temperature: 0.8,
      timeoutMs: 30000
    },
    messages: [],
    fetchImpl
  });

  assert.equal(text, '你好，我是栖语。');
});

test('callChatCompletions redacts API Key in error message if key length > 3', async () => {
  const fetchImpl = async () => ({
    ok: false,
    status: 400,
    async text() {
      return 'Invalid credential for secret-long-key';
    }
  });

  await assert.rejects(
    () => callChatCompletions({
      config: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'secret-long-key',
        model: 'test-model',
        temperature: 0.8,
        timeoutMs: 30000
      },
      messages: [],
      fetchImpl
    }),
    /Invalid credential for \[redacted\]/
  );
});

test('callChatCompletions catches Abort timeout and throws structured message', async () => {
  const fetchImpl = async () => {
    return new Promise((_, reject) => {
      const err = new Error('The user aborted a request.');
      err.name = 'AbortError';
      reject(err);
    });
  };

  await assert.rejects(
    () => callChatCompletions({
      config: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'test-key',
        model: 'test-model',
        temperature: 0.8,
        timeoutMs: 120
      },
      messages: [],
      fetchImpl
    }),
    /LLM request timeout after 120ms/
  );
});
