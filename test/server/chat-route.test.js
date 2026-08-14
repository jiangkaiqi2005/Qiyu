import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable, Writable } from 'node:stream';
import { handleChatRequest } from '../../src/server/chat-route.js';
import { createInitialState } from '../../src/qiyu/state.js';

const CSRF_TOKEN = 'test-csrf-token';

function reqWithJson(body) {
  const req = Readable.from([JSON.stringify(body)]);
  req.method = 'POST';
  req.url = '/api/chat';
  req.headers = { 'x-csrf-token': CSRF_TOKEN };
  return req;
}

function captureRes() {
  const chunks = [];
  const res = new Writable({
    write(chunk, encoding, callback) {
      chunks.push(Buffer.from(chunk));
      callback();
    }
  });
  res.statusCode = 200;
  res.headers = {};
  res.writeHead = (status, headers = {}) => {
    res.statusCode = status;
    res.headers = headers;
  };
  res.body = () => Buffer.concat(chunks).toString('utf8');
  return res;
}

test('chat route falls back to local engine when LLM is disabled', async () => {
  const req = reqWithJson({ text: '今天好累', state: createInitialState('local-user') });
  const res = captureRes();

  await handleChatRequest(req, res, {
    runtimeConfig: { hasLlm: false, llm: {} },
    csrfToken: CSRF_TOKEN,
    productSoul: '# 栖语',
    fetchImpl: async () => { throw new Error('fetch should not be called'); }
  });

  const body = JSON.parse(res.body());
  assert.equal(res.statusCode, 200);
  assert.deepEqual(body.messages, ['咋了']);
  assert.equal(body.source, 'local');
  assert.equal(body.fallbackReason, 'no_llm_config');
});

test('chat route uses LLM when configured and injects context', async () => {
  const calls = [];
  const req = reqWithJson({ text: '今天又加班了', state: createInitialState('local-user') });
  const res = captureRes();

  await handleChatRequest(req, res, {
    runtimeConfig: {
      hasLlm: true,
      llm: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'key',
        model: 'qiyu-test-model',
        temperature: 0.8,
        timeoutMs: 30000
      }
    },
    csrfToken: CSRF_TOKEN,
    productSoul: '# 栖语\n\n一致性。',
    fetchImpl: async (url, options) => {
      calls.push(JSON.parse(options.body));
      return {
        ok: true,
        status: 200,
        async json() {
          return { choices: [{ message: { content: '又加班了？' } }] };
        }
      };
    }
  });

  const body = JSON.parse(res.body());
  assert.equal(body.source, 'llm');
  assert.deepEqual(body.messages, ['又加班了？']);
  assert.equal(body.debug.relationshipStage, '初识');
  assert.ok(typeof body.latencyMs === 'number');
  assert.match(calls[0].messages[0].content, /产品灵魂原文/);
  assert.match(calls[0].messages[1].content, /关系阶段/);
  assert.match(calls[0].messages[1].content, /禁用语/);
});

test('chat route removes LLM stage directions before returning and recording reply text', async () => {
  const req = reqWithJson({ text: '我今天很难受', state: createInitialState('local-user') });
  const res = captureRes();

  await handleChatRequest(req, res, {
    runtimeConfig: {
      hasLlm: true,
      llm: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'key',
        model: 'qiyu-test-model',
        temperature: 0.8,
        timeoutMs: 30000
      }
    },
    csrfToken: CSRF_TOKEN,
    productSoul: '# 栖语',
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      async json() {
        return { choices: [{ message: { content: '（等了一会）我在。\n栖语想了想。' } }] };
      }
    })
  });

  const body = JSON.parse(res.body());

  assert.equal(body.source, 'llm');
  assert.deepEqual(body.messages, ['我在。']);
  assert.equal(body.nextState.turns.at(-1).speaker, 'qiyu');
  assert.equal(body.nextState.turns.at(-1).text, '我在。');
  assert.doesNotMatch(JSON.stringify(body.nextState), /等了一会|栖语想了想|（等了一会）/);
});

test('chat route falls back local when LLM returns forbidden phrase', async () => {
  const req = reqWithJson({ text: '聊聊', state: createInitialState('local-user') });
  const res = captureRes();

  await handleChatRequest(req, res, {
    runtimeConfig: {
      hasLlm: true,
      llm: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'key',
        model: 'qiyu-test-model',
        temperature: 0.8,
        timeoutMs: 30000
      }
    },
    csrfToken: CSRF_TOKEN,
    productSoul: '# 栖语',
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      async json() { return { choices: [{ message: { content: '我理解你的感受，这确实很难' } }] }; }
    })
  });

  const body = JSON.parse(res.body());
  assert.equal(body.source, 'local');
  assert.equal(body.fallbackReason, 'forbidden_phrases');
  assert.ok(typeof body.latencyMs === 'number');
});

test('chat route rejects requests without a matching CSRF token', async () => {
  const req = reqWithJson({ text: '你好', state: createInitialState('local-user') });
  req.headers = {};
  const res = captureRes();

  await handleChatRequest(req, res, {
    csrfToken: CSRF_TOKEN,
    runtimeConfig: {
      hasLlm: true,
      llm: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'key',
        model: 'qiyu-test-model',
        temperature: 0.8,
        timeoutMs: 30000
      }
    },
    productSoul: '# 栖语',
    fetchImpl: async () => { throw new Error('fetch should not be called'); }
  });

  assert.equal(res.statusCode, 403);
  assert.match(res.body(), /CSRF token mismatch/);
});

test('chat route exposes only allowlisted diagnostics when API request fails', async () => {
  const sensitiveInput = 'SENSITIVE_INPUT_123';
  const req = reqWithJson({ text: sensitiveInput, state: createInitialState('local-user') });
  const res = captureRes();

  await handleChatRequest(req, res, {
    runtimeConfig: {
      hasLlm: true,
      llm: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'key',
        model: 'qiyu-test-model',
        temperature: 0.8,
        timeoutMs: 30000
      }
    },
    csrfToken: CSRF_TOKEN,
    productSoul: '# 栖语',
    fetchImpl: async () => ({
      ok: false,
      status: 500,
      async text() {
        return 'Authorization: Bearer leaked-token; Cookie: sid=session-secret; SENSITIVE_INPUT_123';
      }
    })
  });

  const body = JSON.parse(res.body());
  assert.equal(body.source, 'local');
  assert.equal(body.fallbackReason, 'llm_error');
  assert.equal(body.providerError, '模型服务暂时不可用');
  assert.equal(body.debug.error, 'provider_request_failed');
  assert.doesNotMatch(res.body(), /leaked-token|session-secret|Authorization|Cookie/);
  assert.doesNotMatch(
    JSON.stringify({ providerError: body.providerError, debug: body.debug }),
    /SENSITIVE_INPUT_123/
  );
  assert.ok(typeof body.latencyMs === 'number');
});
