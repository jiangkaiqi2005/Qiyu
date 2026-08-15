import test from 'node:test';
import assert from 'node:assert/strict';
import { callChatCompletions } from '../../src/server/llm-client.js';

// 测试占位符：这些不是真实凭据，仅用于验证请求构造。
const TEST_KEY = '_TEST_KEY_';

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
      apiKey: TEST_KEY,
      model: 'qiyu-test-model',
      temperature: 0.8,
      timeoutMs: 30000,
      maxTokens: 16
    },
    messages: [{ role: 'system', content: '你是栖语' }],
    fetchImpl
  });

  assert.equal(text, '……怎么回事');
  assert.equal(calls[0].url, 'https://llm.example.test/v1/chat/completions');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.headers.Authorization, `Bearer ${TEST_KEY}`);
  const requestBody = JSON.parse(calls[0].options.body);
  assert.equal(requestBody.model, 'qiyu-test-model');
  assert.equal(requestBody.max_tokens, 16);
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
        apiKey: TEST_KEY,
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
      apiKey: TEST_KEY,
      model: 'test-model',
      temperature: 0.8,
      timeoutMs: 30000
    },
    messages: [],
    fetchImpl
  });

  assert.equal(text, '你好，我是栖语。');
});

test('callChatCompletions strips provider reasoning tags from content', async () => {
  const fetchImpl = async () => ({
    ok: true,
    status: 200,
    async json() {
      return {
        choices: [
          {
            message: {
              content: '<think>internal chain of thought</think>你好，今晚辛苦了。'
            }
          }
        ]
      };
    }
  });

  const text = await callChatCompletions({
    config: {
      apiUrl: 'https://llm.example.test/v1/chat/completions',
      apiKey: TEST_KEY,
      model: 'test-model',
      temperature: 0.8,
      timeoutMs: 30000
    },
    messages: [],
    fetchImpl
  });

  assert.equal(text, '你好，今晚辛苦了。');
});

test('callChatCompletions supports Anthropic messages API', async () => {
  const calls = [];
  const text = await callChatCompletions({
    config: {
      apiUrl: 'https://api.anthropic.com/v1/messages',
      apiKey: TEST_KEY,
      model: 'claude-sonnet-4-20250514',
      temperature: 0.6,
      timeoutMs: 30000
    },
    messages: [
      { role: 'system', content: '你是栖语。' },
      { role: 'user', content: '今天有点累。' }
    ],
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return {
        ok: true,
        status: 200,
        async json() {
          return {
            content: [
              { type: 'text', text: '<think>internal</think>抱抱你，先歇一会。' }
            ]
          };
        }
      };
    }
  });

  assert.equal(calls[0].url, 'https://api.anthropic.com/v1/messages');
  assert.equal(calls[0].options.headers['x-api-key'], TEST_KEY);
  assert.equal(calls[0].options.headers['anthropic-version'], '2023-06-01');
  assert.equal(calls[0].options.headers.Authorization, undefined);

  const requestBody = JSON.parse(calls[0].options.body);
  assert.equal(requestBody.system, '你是栖语。');
  assert.equal(requestBody.max_tokens, 1024);
  assert.deepEqual(requestBody.messages, [
    { role: 'user', content: '今天有点累。' }
  ]);
  assert.equal(text, '抱抱你，先歇一会。');
});

test('callChatCompletions redacts API Key in error message if key length > 3', async () => {
  const longKey = `${TEST_KEY}-longer-than-three`;
  const fetchImpl = async () => ({
    ok: false,
    status: 400,
    async text() {
      return `Invalid credential for ${longKey}`;
    }
  });

  await assert.rejects(
    () => callChatCompletions({
      config: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: longKey,
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
        apiKey: TEST_KEY,
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
