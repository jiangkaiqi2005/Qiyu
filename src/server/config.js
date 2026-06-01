import { readFile } from 'node:fs/promises';

async function readJsonIfPresent(configPath) {
  try {
    const raw = await readFile(configPath, 'utf8');
    return JSON.parse(raw);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return {};
    }
    throw error;
  }
}

function numberFrom(value, fallback) {
  if (value === undefined || value === null || value === '') {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export async function loadRuntimeConfig({
  env = process.env,
  configPath = 'qiyu.config.local.json'
} = {}) {
  const fileConfig = await readJsonIfPresent(configPath);
  const fileLlm = fileConfig.llm || {};

  const llm = {
    apiUrl: env.LLM_API_URL || fileLlm.apiUrl || '',
    apiKey: env.LLM_API_KEY || fileLlm.apiKey || '',
    model: env.LLM_MODEL || fileLlm.model || '',
    temperature: numberFrom(env.LLM_TEMPERATURE ?? fileLlm.temperature, 0.8),
    timeoutMs: numberFrom(env.LLM_TIMEOUT_MS ?? fileLlm.timeoutMs, 30000)
  };

  return {
    llm,
    hasLlm: Boolean(llm.apiUrl && llm.apiKey && llm.model)
  };
}
