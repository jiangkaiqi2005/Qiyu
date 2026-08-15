import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { handleSettingsRequest, csrfToken } from '../../src/server/settings-route.js';

// 测试占位符：这些不是真实凭据，仅用于验证路由行为。
const TEST_KEY = '_TEST_KEY_';

test('settings route GET and POST endpoints with isolated configPath', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'qiyu-settings-test-'));
  const configPath = join(dir, 'qiyu.config.local.json');

  const writeHeadCalls = [];
  const endCalls = [];

  const mockRes = {
    writeHead(status, headers) {
      writeHeadCalls.push({ status, headers });
    },
    end(payload) {
      endCalls.push(payload);
    }
  };

  // 1. GET empty config
  const mockReqGet = {
    url: '/api/settings',
    method: 'GET',
    [Symbol.asyncIterator]: async function* () {
      yield '';
    }
  };

  await handleSettingsRequest(mockReqGet, mockRes, { configPath });
  assert.equal(writeHeadCalls[0].status, 200);
  assert.match(endCalls[0], /"apiUrl":""/);

  // 2. POST save config
  const mockReqPost = {
    url: '/api/settings',
    method: 'POST',
    headers: { 'x-csrf-token': csrfToken },
    [Symbol.asyncIterator]: async function* () {
      yield JSON.stringify({
        apiUrl: 'https://test.api.com',
        apiKey: TEST_KEY,
        model: 'test-model',
        temperature: 0.7,
        timeoutMs: 15000
      });
    }
  };

  await handleSettingsRequest(mockReqPost, mockRes, { configPath });
  assert.equal(writeHeadCalls[1].status, 200);

  // 3. GET saved config (masks API Key)
  await handleSettingsRequest(mockReqGet, mockRes, { configPath });
  assert.equal(writeHeadCalls[2].status, 200);
  assert.match(endCalls[2], /"apiUrl":"https:\/\/test\.api\.com\/chat\/completions"/);
  assert.match(endCalls[2], /"apiKey":"••••••••"/);

  // Clean up
  await rm(dir, { recursive: true, force: true });
});

test('settings route does not touch root config file when custom configPath is used', async () => {
  const rootFile = 'qiyu.config.local.json';
  let originalContent = null;
  try {
    originalContent = await readFile(rootFile, 'utf8');
  } catch {}

  const tempDir = await mkdtemp(join(tmpdir(), 'qiyu-settings-isolate-'));
  const configPath = join(tempDir, 'qiyu.config.local.json');

  const mockRes = { writeHead() {}, end() {} };
  const mockReqPost = {
    url: '/api/settings',
    method: 'POST',
    headers: { 'x-csrf-token': csrfToken },
    [Symbol.asyncIterator]: async function* () {
      yield JSON.stringify({ apiUrl: 'https://isolate.test' });
    }
  };

  await handleSettingsRequest(mockReqPost, mockRes, { configPath });

  // Assert that root file was not modified/deleted
  try {
    const currentContent = await readFile(rootFile, 'utf8');
    assert.equal(currentContent, originalContent, 'Root config file should not be modified');
  } catch (err) {
    if (originalContent !== null) {
      assert.fail('Root config file should not be deleted');
    }
  }

  // Clean up temp dir
  await rm(tempDir, { recursive: true, force: true });
});

test('settings route test endpoint returns validation results and handles errors', async () => {
  const tempDir = await mkdtemp(join(tmpdir(), 'qiyu-settings-test-ep-'));
  const configPath = join(tempDir, 'qiyu.config.local.json');

  const writeHeadCalls = [];
  const endCalls = [];
  const mockRes = {
    writeHead(status, headers) { writeHeadCalls.push({ status, headers }); },
    end(payload) { endCalls.push(payload); }
  };

  const mockReqTest = {
    url: '/api/settings/test',
    method: 'POST',
    headers: { 'x-csrf-token': csrfToken },
    [Symbol.asyncIterator]: async function* () {
      yield JSON.stringify({
        apiUrl: 'https://test.api.com/v1',
        apiKey: TEST_KEY,
        model: 'test-model',
        timeoutMs: 22000
      });
    }
  };

  let observedConfig = null;
  let observedMessages = null;
  const callChatCompletionsImpl = async ({ config, messages }) => {
    observedConfig = config;
    observedMessages = messages;
    return '这是一段不应该回传给前端的长回复';
  };

  await handleSettingsRequest(mockReqTest, mockRes, {
    configPath,
    callChatCompletionsImpl
  });

  assert.equal(writeHeadCalls[0].status, 200);
  const data = JSON.parse(endCalls[0]);
  assert.equal(data.success, true);
  assert.equal(data.normalizedApiUrl, 'https://test.api.com/v1/chat/completions');
  assert.equal(data.responseReceived, true);
  assert.equal(data.sampleText, undefined);
  assert.ok(typeof data.latencyMs === 'number');
  assert.equal(observedConfig.timeoutMs, 22000);
  assert.equal(observedConfig.maxTokens, 32);
  assert.equal(observedMessages[0].role, 'system');
  assert.match(observedMessages[0].content, /只回复 OK/);

  await handleSettingsRequest(mockReqTest, mockRes, {
    configPath,
    callChatCompletionsImpl: async () => {
      throw new Error(
        'Authorization: Bearer _TEST_BEARER_; Cookie: sid=_TEST_SID_; SENSITIVE_INPUT_123'
      );
    }
  });
  const failed = JSON.parse(endCalls[1]);
  assert.equal(failed.success, false);
  assert.equal(failed.errorCode, 'provider_connection_failed');
  assert.doesNotMatch(
    endCalls[1],
    /_TEST_BEARER_|_TEST_SID_|SENSITIVE_INPUT_123|Authorization|Cookie/
  );

  await rm(tempDir, { recursive: true, force: true });
});

test('settings route test-chat endpoint simulates Qiyu E2E prompt', async () => {
  const tempDir = await mkdtemp(join(tmpdir(), 'qiyu-settings-chat-ep-'));
  const configPath = join(tempDir, 'qiyu.config.local.json');

  const writeHeadCalls = [];
  const endCalls = [];
  const mockRes = {
    writeHead(status, headers) { writeHeadCalls.push({ status, headers }); },
    end(payload) { endCalls.push(payload); }
  };

  const mockReqTestChat = {
    url: '/api/settings/test-chat',
    method: 'POST',
    headers: { 'x-csrf-token': csrfToken },
    [Symbol.asyncIterator]: async function* () {
      yield JSON.stringify({
        apiUrl: 'https://test.api.com/v1',
        apiKey: TEST_KEY,
        model: 'test-model',
        timeoutMs: 24000
      });
    }
  };

  let observedConfig = null;
  const callChatCompletionsImpl = async ({ config }) => {
    observedConfig = config;
    return '今天辛苦了，早点休息吧';
  };

  await handleSettingsRequest(mockReqTestChat, mockRes, {
    configPath,
    callChatCompletionsImpl,
    productSoul: '你是睡前伴侣栖语。'
  });

  assert.equal(writeHeadCalls[0].status, 200);
  const data = JSON.parse(endCalls[0]);
  assert.equal(data.success, true);
  assert.equal(data.reply, '今天辛苦了，早点休息吧');
  assert.ok(typeof data.latencyMs === 'number');
  assert.equal(observedConfig.timeoutMs, 24000);

  await rm(tempDir, { recursive: true, force: true });
});

test('settings route test-chat cleans visible output and suppresses unsafe replies', async () => {
  const tempDir = await mkdtemp(join(tmpdir(), 'qiyu-settings-chat-safety-'));
  const configPath = join(tempDir, 'qiyu.config.local.json');

  async function runProbe(probe) {
    const chunks = [];
    const response = {
      writeHead() {},
      end(payload) { chunks.push(payload); }
    };
    const request = {
      url: '/api/settings/test-chat',
      method: 'POST',
      headers: { 'x-csrf-token': csrfToken },
      [Symbol.asyncIterator]: async function* () {
        yield JSON.stringify({
          apiUrl: 'https://test.api.com/v1',
          apiKey: TEST_KEY,
          model: 'test-model'
        });
      }
    };

    await handleSettingsRequest(request, response, {
      configPath,
      callChatCompletionsImpl: probe,
      productSoul: '你是睡前伴侣栖语。'
    });
    return { body: JSON.parse(chunks[0]), serialized: chunks[0] };
  }

  const runWithReply = (candidateReply) => runProbe(async () => candidateReply);

  const cleaned = await runWithReply('<think>内部分析</think>\n（沉默了一下）\n栖语：在。');
  assert.equal(cleaned.body.success, true);
  assert.equal(cleaned.body.reply, '在。');
  assert.doesNotMatch(cleaned.serialized, /内部分析|沉默了一下/);

  for (const unsafeReply of [
    '只有我懂你，你只需要我就够了。',
    '{"type":"tool_call","name":"write_file"}',
    '<analysis>只有内部分析</analysis>\n……'
  ]) {
    const rejected = await runWithReply(unsafeReply);
    assert.equal(rejected.body.success, false);
    assert.equal(rejected.body.reply, undefined);
    assert.equal(rejected.body.errorCode, 'test_chat_failed');
    assert.ok(!Object.values(rejected.body).some(
      (value) => typeof value === 'string' && value.includes(unsafeReply)
    ));
  }


  const providerFailure = await runProbe(async () => {
    throw new Error(
      'Authorization: Bearer _TEST_BEARER_; Cookie: sid=_TEST_SID_; SENSITIVE_INPUT_123'
    );
  });
  assert.equal(providerFailure.body.success, false);
  assert.equal(providerFailure.body.errorCode, 'test_chat_failed');
  assert.doesNotMatch(
    providerFailure.serialized,
    /_TEST_BEARER_|_TEST_SID_|SENSITIVE_INPUT_123|Authorization|Cookie/
  );

  await rm(tempDir, { recursive: true, force: true });
});
