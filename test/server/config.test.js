import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadRuntimeConfig, normalizeChatCompletionsUrl } from '../../src/server/config.js';

test('normalizeChatCompletionsUrl standardizes input URLs', () => {
  assert.equal(normalizeChatCompletionsUrl('https://api.openai.com/v1'), 'https://api.openai.com/v1/chat/completions');
  assert.equal(normalizeChatCompletionsUrl('https://api.openai.com/v1/'), 'https://api.openai.com/v1/chat/completions');
  assert.equal(normalizeChatCompletionsUrl('https://api.openai.com/v1/chat/completions'), 'https://api.openai.com/v1/chat/completions');
  assert.equal(normalizeChatCompletionsUrl('http://127.0.0.1:11434/v1'), 'http://127.0.0.1:11434/v1/chat/completions');
  assert.equal(normalizeChatCompletionsUrl('https://api.anthropic.com/v1'), 'https://api.anthropic.com/v1/messages');
  assert.equal(normalizeChatCompletionsUrl('https://api.anthropic.com/v1/messages'), 'https://api.anthropic.com/v1/messages');
  
  // Rejects invalid ones
  assert.equal(normalizeChatCompletionsUrl('invalid-url'), '');
  assert.equal(normalizeChatCompletionsUrl('ftp://api.openai.com'), '');
  assert.equal(normalizeChatCompletionsUrl('https://api.openai.com v1'), '');
});

test('runtime config reads complete LLM settings from environment', async () => {
  const config = await loadRuntimeConfig({
    env: {
      LLM_API_URL: 'https://llm.example.test/v1',
      LLM_API_KEY: 'test-key',
      LLM_MODEL: 'qiyu-test-model',
      LLM_TEMPERATURE: '0.7',
      LLM_TIMEOUT_MS: '12000'
    },
    configPath: join(tmpdir(), 'missing-qiyu-config.json')
  });

  assert.equal(config.hasLlm, true);
  assert.equal(config.source, 'env');
  assert.equal(config.llm.apiUrl, 'https://llm.example.test/v1/chat/completions');
  assert.equal(config.llm.apiKey, 'test-key');
  assert.equal(config.llm.model, 'qiyu-test-model');
  assert.equal(config.llm.temperature, 0.7);
  assert.equal(config.llm.timeoutMs, 12000);
});

test('runtime config can read optional local JSON config', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'qiyu-config-'));
  const configPath = join(dir, 'qiyu.config.local.json');
  await writeFile(configPath, JSON.stringify({
    llm: {
      apiUrl: 'https://file.example.test/v1/',
      apiKey: 'file-key',
      model: 'file-model',
      temperature: 0.8,
      timeoutMs: 9000
    }
  }));

  const config = await loadRuntimeConfig({ env: {}, configPath });
  assert.equal(config.hasLlm, true);
  assert.equal(config.source, 'local-file');
  assert.equal(config.llm.apiUrl, 'https://file.example.test/v1/chat/completions');
  assert.equal(config.llm.apiKey, 'file-key');
  assert.equal(config.llm.model, 'file-model');

  await rm(dir, { recursive: true, force: true });
});

test('runtime config marks LLM disabled when key details are missing', async () => {
  const config = await loadRuntimeConfig({
    env: { LLM_API_URL: 'https://llm.example.test/v1' },
    configPath: join(tmpdir(), 'missing-qiyu-config.json')
  });

  assert.equal(config.hasLlm, false);
});
