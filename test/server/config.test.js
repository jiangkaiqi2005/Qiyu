import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadRuntimeConfig } from '../../src/server/config.js';

test('runtime config reads complete LLM settings from environment', async () => {
  const config = await loadRuntimeConfig({
    env: {
      LLM_API_URL: 'https://llm.example.test/v1/chat/completions',
      LLM_API_KEY: 'test-key',
      LLM_MODEL: 'qiyu-test-model',
      LLM_TEMPERATURE: '0.7',
      LLM_TIMEOUT_MS: '12000'
    },
    configPath: join(tmpdir(), 'missing-qiyu-config.json')
  });

  assert.equal(config.hasLlm, true);
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
      apiUrl: 'https://file.example.test/v1/chat/completions',
      apiKey: 'file-key',
      model: 'file-model',
      temperature: 0.8,
      timeoutMs: 9000
    }
  }));

  const config = await loadRuntimeConfig({ env: {}, configPath });
  assert.equal(config.hasLlm, true);
  assert.equal(config.llm.apiKey, 'file-key');
  assert.equal(config.llm.model, 'file-model');
});

test('runtime config marks LLM disabled when key details are missing', async () => {
  const config = await loadRuntimeConfig({
    env: { LLM_API_URL: 'https://llm.example.test/v1/chat/completions' },
    configPath: join(tmpdir(), 'missing-qiyu-config.json')
  });

  assert.equal(config.hasLlm, false);
});
