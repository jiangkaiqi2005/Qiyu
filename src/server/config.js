import { readFile } from 'node:fs/promises';

export function normalizeChatCompletionsUrl(input) {
  if (typeof input !== 'string') return '';
  const trimmed = input.trim();
  if (!trimmed) return '';
  if (trimmed.includes(' ')) return '';
  
  try {
    const url = new URL(trimmed);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      return '';
    }
    
    let pathname = url.pathname;
    if (pathname.endsWith('/')) {
      pathname = pathname.slice(0, -1);
    }

    if (url.hostname === 'api.anthropic.com') {
      if (!pathname.endsWith('/messages')) {
        pathname = pathname + '/messages';
      }
    } else if (!pathname.endsWith('/chat/completions')) {
      pathname = pathname + '/chat/completions';
    }
    
    // Clean double slashes
    pathname = pathname.replace(/\/+/g, '/');
    
    url.pathname = pathname;
    return url.toString();
  } catch {
    return '';
  }
}

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

  const hasEnvLlm = Boolean(env.LLM_API_URL && env.LLM_API_KEY && env.LLM_MODEL);
  const hasFileLlm = Boolean(fileLlm.apiUrl && fileLlm.apiKey && fileLlm.model);

  let llm;
  let source;

  if (hasEnvLlm) {
    llm = {
      apiUrl: normalizeChatCompletionsUrl(env.LLM_API_URL),
      apiKey: env.LLM_API_KEY,
      model: env.LLM_MODEL,
      temperature: numberFrom(env.LLM_TEMPERATURE, 0.8),
      timeoutMs: numberFrom(env.LLM_TIMEOUT_MS, 30000)
    };
    source = 'env';
  } else if (hasFileLlm) {
    llm = {
      apiUrl: normalizeChatCompletionsUrl(fileLlm.apiUrl),
      apiKey: fileLlm.apiKey,
      model: fileLlm.model,
      temperature: numberFrom(fileLlm.temperature, 0.8),
      timeoutMs: numberFrom(fileLlm.timeoutMs, 30000)
    };
    source = 'local-file';
  } else {
    const rawApiUrl = env.LLM_API_URL || fileLlm.apiUrl || '';
    llm = {
      apiUrl: normalizeChatCompletionsUrl(rawApiUrl),
      apiKey: env.LLM_API_KEY || fileLlm.apiKey || '',
      model: env.LLM_MODEL || fileLlm.model || '',
      temperature: numberFrom(env.LLM_TEMPERATURE ?? fileLlm.temperature, 0.8),
      timeoutMs: numberFrom(env.LLM_TIMEOUT_MS ?? fileLlm.timeoutMs, 30000)
    };
    source = 'empty';
  }

  const hasLlm = Boolean(llm.apiUrl && llm.apiKey && llm.model);

  return {
    llm,
    hasLlm,
    source
  };
}
