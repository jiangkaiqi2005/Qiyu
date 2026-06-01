import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable, Writable } from 'node:stream';
import { handleChatRequest } from '../../src/server/chat-route.js';
import { createInitialState } from '../../src/qiyu/state.js';

function reqWithJson(body) {
  const req = Readable.from([JSON.stringify(body)]);
  req.method = 'POST';
  req.url = '/api/chat';
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
    productSoul: '# 栖语',
    fetchImpl: async () => { throw new Error('fetch should not be called'); }
  });

  const body = JSON.parse(res.body());
  assert.equal(res.statusCode, 200);
  assert.deepEqual(body.messages, ['咋了']);
  assert.equal(body.source, 'local');
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
  assert.match(calls[0].messages[0].content, /产品灵魂原文/);
  assert.match(calls[0].messages[1].content, /关系阶段/);
  assert.match(calls[0].messages[1].content, /禁用语/);
});
