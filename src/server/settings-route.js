import { writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { loadRuntimeConfig, normalizeChatCompletionsUrl } from './config.js';
import { callChatCompletions } from './llm-client.js';
import { readJsonBody, sendJson, validateCsrfAndOrigin, redactSecret } from './http-utils.js';

export const csrfToken = randomBytes(24).toString('hex');

// Sentinel shown to clients instead of the real key; echoed back unchanged on save
export const MASKED_API_KEY = '••••••••';

function resolveApiKey(bodyApiKey, currentApiKey) {
  return bodyApiKey === MASKED_API_KEY ? currentApiKey : bodyApiKey;
}

function resolveTestTimeoutMs(body, current, fallback = 30000) {
  const rawTimeoutMs = typeof body.timeoutMs !== 'undefined' ? body.timeoutMs : current.llm.timeoutMs;
  const timeoutMs = Number(rawTimeoutMs);
  return Number.isFinite(timeoutMs) && timeoutMs >= 1000 ? timeoutMs : fallback;
}

export async function handleSettingsRequest(req, res, {
  configPath = 'qiyu.config.local.json',
  loadRuntimeConfigImpl = loadRuntimeConfig,
  writeFileImpl = writeFile,
  callChatCompletionsImpl = callChatCompletions,
  productSoul = ''
} = {}) {
  try {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname;

    // CSRF and SSRF Origin Verification Protection
    if (!validateCsrfAndOrigin(req, res, csrfToken)) {
      return;
    }

    if (req.method === 'GET' && path === '/api/settings') {
      const config = await loadRuntimeConfigImpl({ configPath });
      const masked = {
        ...config.llm,
        apiKey: config.llm.apiKey ? MASKED_API_KEY : ''
      };
      sendJson(res, 200, {
        ...masked,
        hasLlm: config.hasLlm,
        source: config.source,
        csrfToken
      });
      return;
    }

    if (req.method === 'POST' && path === '/api/settings') {
      const body = await readJsonBody(req);
      const current = await loadRuntimeConfigImpl({ configPath });

      const apiKey = resolveApiKey(body.apiKey, current.llm.apiKey);

      const newConfig = {
        llm: {
          apiUrl: body.apiUrl || '',
          apiKey: apiKey || '',
          model: body.model || '',
          temperature: typeof body.temperature !== 'undefined' ? Number(body.temperature) : 0.8,
          timeoutMs: typeof body.timeoutMs !== 'undefined' ? Number(body.timeoutMs) : 30000
        }
      };

      await writeFileImpl(configPath, JSON.stringify(newConfig, null, 2), 'utf8');
      const savedConfig = await loadRuntimeConfigImpl({ configPath });
      sendJson(res, 200, {
        success: true,
        apiUrl: savedConfig.llm.apiUrl,
        model: savedConfig.llm.model,
        temperature: savedConfig.llm.temperature,
        timeoutMs: savedConfig.llm.timeoutMs,
        hasLlm: savedConfig.hasLlm,
        source: savedConfig.source
      });
      return;
    }

    if (req.method === 'POST' && path === '/api/settings/test') {
      const body = await readJsonBody(req);
      const current = await loadRuntimeConfigImpl({ configPath });
      const apiKey = resolveApiKey(body.apiKey, current.llm.apiKey);

      const normalizedApiUrl = normalizeChatCompletionsUrl(body.apiUrl || '');
      const testLlm = {
        apiUrl: normalizedApiUrl,
        apiKey: apiKey || '',
        model: body.model || '',
        temperature: 0.1,
        timeoutMs: resolveTestTimeoutMs(body, current),
        maxTokens: 32
      };

      const start = Date.now();
      try {
        await callChatCompletionsImpl({
          config: testLlm,
          messages: [
            { role: 'system', content: '这是 Provider 连通性测试。只回复 OK。' },
            { role: 'user', content: 'connection_test' }
          ]
        });
        const latencyMs = Date.now() - start;
        sendJson(res, 200, {
          success: true,
          normalizedApiUrl,
          model: testLlm.model,
          latencyMs,
          responseReceived: true
        });
      } catch (err) {
        const latencyMs = Date.now() - start;
        const errMsg = redactSecret(err.message || String(err), apiKey);
        sendJson(res, 200, {
          success: false,
          normalizedApiUrl,
          model: testLlm.model,
          latencyMs,
          error: errMsg
        });
      }
      return;
    }

    if (req.method === 'POST' && path === '/api/settings/test-chat') {
      const body = await readJsonBody(req);
      const current = await loadRuntimeConfigImpl({ configPath });
      const apiKey = resolveApiKey(body.apiKey, current.llm.apiKey);

      const normalizedApiUrl = normalizeChatCompletionsUrl(body.apiUrl || '');
      const testLlm = {
        apiUrl: normalizedApiUrl,
        apiKey: apiKey || '',
        model: body.model || '',
        temperature: 0.8,
        timeoutMs: resolveTestTimeoutMs(body, current)
      };

      const start = Date.now();
      try {
        const { buildPromptContext } = await import('../qiyu/prompt-context.js');
        const { assertNoForbiddenPhrase } = await import('../qiyu/persona.js');
        const { buildSystemPrompt } = await import('./system-prompt.js');
        const { createInitialState } = await import('../qiyu/state.js');

        const state = createInitialState('test-user');
        state.userName = '小雨';
        state.companionshipStyle = 'gentle';

        const systemPrompt = buildSystemPrompt(productSoul);
        const context = buildPromptContext({ state, userText: '今天好累', includeHistory: false });

        const reply = await callChatCompletionsImpl({
          config: testLlm,
          messages: [
            { role: 'system', content: systemPrompt },
            context,
            { role: 'user', content: '今天好累' }
          ]
        });

        assertNoForbiddenPhrase(reply);

        const latencyMs = Date.now() - start;
        sendJson(res, 200, {
          success: true,
          reply,
          latencyMs
        });
      } catch (err) {
        const latencyMs = Date.now() - start;
        const errMsg = redactSecret(err.message || String(err), apiKey);
        sendJson(res, 200, {
          success: false,
          error: errMsg,
          latencyMs
        });
      }
      return;
    }

    sendJson(res, 404, { error: 'Not found' });
  } catch (err) {
    // Sanitize stack traces to prevent absolute server path leaks
    sendJson(res, 500, { error: 'Internal Server Error' });
  }
}
