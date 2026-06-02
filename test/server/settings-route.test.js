import test from 'node:test';
import assert from 'node:assert/strict';
import { handleSettingsRequest, csrfToken } from '../../src/server/settings-route.js';
import { loadRuntimeConfig } from '../../src/server/config.js';
import { rm } from 'node:fs/promises';

test('settings route GET and POST endpoints', async () => {
  // Clean up any existing config file first
  try {
    await rm('qiyu.config.local.json');
  } catch {}

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

  await handleSettingsRequest(mockReqGet, mockRes);
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

  await handleSettingsRequest(mockReqPost, mockRes);
  assert.equal(writeHeadCalls[1].status, 200);

  // 3. GET saved config (masks API Key)
  await handleSettingsRequest(mockReqGet, mockRes);
  assert.equal(writeHeadCalls[2].status, 200);
  assert.match(endCalls[2], /"apiUrl":"https:\/\/test\.api\.com"/);
  assert.match(endCalls[2], /"apiKey":"••••••••"/);

  // Clean up config file
  try {
    await rm('qiyu.config.local.json');
  } catch {}
});
