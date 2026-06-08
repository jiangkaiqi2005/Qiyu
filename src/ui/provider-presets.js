const DEFAULT_PROVIDER_PRESET = 'custom';

export const PROVIDER_PRESETS = [
  {
    id: DEFAULT_PROVIDER_PRESET,
    label: 'OpenAI-compatible Custom (自定义)',
    apiUrl: '',
    model: '',
    notice: '已切换到自定义服务商，请手动填入 API URL 和模型名称。'
  },
  {
    id: 'openai',
    label: 'OpenAI (官方)',
    apiUrl: 'https://api.openai.com/v1',
    model: 'gpt-4o',
    notice: '已载入 OpenAI 官方预设，请填入您的 API Key 后保存。'
  },
  {
    id: 'deepseek',
    label: 'DeepSeek',
    apiUrl: 'https://api.deepseek.com',
    model: 'deepseek-v4-flash',
    notice: '已载入 DeepSeek 预设，请填入您的 API Key 后保存。'
  },
  {
    id: 'anthropic',
    label: 'Anthropic (原生 Messages API)',
    apiUrl: 'https://api.anthropic.com/v1',
    model: 'claude-sonnet-4-20250514',
    notice: '已载入 Anthropic 原生 Messages API 预设，保存后会按 Anthropic 官方协议发起请求。'
  },
  {
    id: 'zhipu',
    label: '智谱 GLM',
    apiUrl: 'https://open.bigmodel.cn/api/paas/v4',
    model: 'glm-4.7-flash',
    notice: '已载入智谱 GLM 预设，请填入您的 API Key 后保存。'
  },
  {
    id: 'aliyun-beijing',
    label: '阿里云百炼 Qwen (北京)',
    apiUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen3.6-plus',
    notice: '已载入阿里云百炼北京地域预设，请确认您使用的是北京地域 API Key。'
  },
  {
    id: 'moonshot',
    label: 'Moonshot AI / Kimi',
    apiUrl: 'https://api.moonshot.cn/v1',
    model: 'kimi-k2.5',
    notice: '已载入 Moonshot AI / Kimi 预设，请填入您的 API Key 后保存。'
  },
  {
    id: 'minimax',
    label: 'MiniMax',
    apiUrl: 'https://api.minimax.io/v1',
    model: 'MiniMax-M2.7',
    notice: '已载入 MiniMax 预设。MiniMax 兼容层可能返回 <think> 内容，本地链路会自动清理。'
  },
  {
    id: 'groq',
    label: 'Groq',
    apiUrl: 'https://api.groq.com/openai/v1',
    model: 'llama-3.3-70b-versatile',
    notice: '已载入 Groq 预设，请填入您的 API Key 后保存。'
  },
  {
    id: 'openrouter',
    label: 'OpenRouter',
    apiUrl: 'https://openrouter.ai/api/v1',
    model: 'openrouter/auto',
    notice: '已载入 OpenRouter 预设。若需上榜展示，可额外配置 HTTP-Referer 与 X-Title。'
  },
  {
    id: 'volcengine-ark',
    label: '火山方舟 / 豆包',
    apiUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    model: 'doubao-seed-2-0-lite-260215',
    notice: '已载入火山方舟预设，请填入您的 API Key 后保存。'
  },
  {
    id: 'ollama',
    label: 'Local Ollama (本地 Ollama)',
    apiUrl: 'http://127.0.0.1:11434/v1',
    model: 'llama3',
    notice: '已载入本地 Ollama 预设，请确保本地 Ollama 服务已启动。'
  }
];

function normalizePresetApiUrl(apiUrl) {
  return String(apiUrl || '')
    .replace(/\/chat\/completions\/?$/i, '')
    .replace(/\/messages\/?$/i, '')
    .replace(/\/+$/g, '');
}

export function renderProviderPresetOptions(selectedId = DEFAULT_PROVIDER_PRESET) {
  return PROVIDER_PRESETS.map((preset) => {
    const selected = preset.id === selectedId ? ' selected' : '';
    return `<option value="${preset.id}"${selected}>${preset.label}</option>`;
  }).join('');
}

export function getProviderPreset(id) {
  return PROVIDER_PRESETS.find((preset) => preset.id === id) || PROVIDER_PRESETS[0];
}

export function applyProviderPreset(id, { apiUrlInput, modelInput } = {}) {
  const preset = getProviderPreset(id);
  if (apiUrlInput) apiUrlInput.value = preset.apiUrl;
  if (modelInput) modelInput.value = preset.model;
  return preset;
}

export function detectProviderPreset({ apiUrl = '', model = '' } = {}) {
  const normalizedApiUrl = normalizePresetApiUrl(apiUrl);

  const matched = PROVIDER_PRESETS.find((preset) => {
    if (!preset.apiUrl) return false;
    return normalizePresetApiUrl(preset.apiUrl) === normalizedApiUrl;
  });

  return matched ? matched.id : DEFAULT_PROVIDER_PRESET;
}
