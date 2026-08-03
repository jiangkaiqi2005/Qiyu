import test from 'node:test';
import assert from 'node:assert/strict';
import {
  applyProviderPreset,
  detectProviderPreset,
  renderProviderPresetOptions
} from '../../src/ui/provider-presets.js';

test('renderProviderPresetOptions includes the expanded popular providers', () => {
  const html = renderProviderPresetOptions();

  assert.match(html, /DeepSeek/);
  assert.match(html, /Anthropic \(原生 Messages API\)/);
  assert.match(html, /智谱 GLM/);
  assert.match(html, /阿里云百炼 Qwen \(北京\)/);
  assert.match(html, /MiniMax/);
  assert.match(html, /OpenRouter/);
  assert.match(html, /火山方舟 \/ 豆包/);
});

test('applyProviderPreset fills api url and model for known provider', () => {
  const apiUrlInput = { value: '' };
  const modelInput = { value: '' };

  const preset = applyProviderPreset('zhipu', { apiUrlInput, modelInput });

  assert.equal(apiUrlInput.value, 'https://open.bigmodel.cn/api/paas/v4');
  assert.equal(modelInput.value, 'glm-4.7-flash');
  assert.match(preset.notice, /智谱 GLM/);
});

test('applyProviderPreset uses the current MiniMax compatible endpoint', () => {
  const apiUrlInput = { value: '' };
  const modelInput = { value: '' };

  applyProviderPreset('minimax', { apiUrlInput, modelInput });

  assert.equal(apiUrlInput.value, 'https://api.minimax.io/v1');
  assert.equal(modelInput.value, 'MiniMax-M2.7');
});

test('detectProviderPreset matches normalized saved config urls', () => {
  assert.equal(
    detectProviderPreset({
      apiUrl: 'https://api.deepseek.com/chat/completions',
      model: 'deepseek-v4-flash'
    }),
    'deepseek'
  );

  assert.equal(
    detectProviderPreset({
      apiUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
      model: 'qwen3.6-plus'
    }),
    'aliyun-beijing'
  );

  assert.equal(
    detectProviderPreset({
      apiUrl: 'https://api.anthropic.com/v1/messages',
      model: 'claude-sonnet-4-20250514'
    }),
    'anthropic'
  );

  assert.equal(
    detectProviderPreset({
      apiUrl: 'https://unknown.example.com/v1/chat/completions',
      model: 'mystery-model'
    }),
    'custom'
  );
});
