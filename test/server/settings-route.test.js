import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { handleSettingsRequest, csrfToken } from '../../src/server/settings-route.js';

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
        apiKey: 'secret_key',
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
        apiKey: 'test-key',
        model: 'test-model'
      });
    }
  };

  const callChatCompletionsImpl = async () => 'pong';

  await handleSettingsRequest(mockReqTest, mockRes, {
    configPath,
    callChatCompletionsImpl
  });

  assert.equal(writeHeadCalls[0].status, 200);
  const data = JSON.parse(endCalls[0]);
  assert.equal(data.success, true);
  assert.equal(data.normalizedApiUrl, 'https://test.api.com/v1/chat/completions');
  assert.equal(data.sampleText, 'pong');
  assert.ok(typeof data.latencyMs === 'number');

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
        apiKey: 'test-key',
        model: 'test-model'
      });
    }
  };

  const callChatCompletionsImpl = async () => '今天辛苦了，早点休息吧';

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

  await rm(tempDir, { recursive: true, force: true });
});
