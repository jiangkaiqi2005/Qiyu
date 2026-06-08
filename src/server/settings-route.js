import { writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { loadRuntimeConfig, normalizeChatCompletionsUrl } from './config.js';
import { callChatCompletions } from './llm-client.js';

export const csrfToken = randomBytes(24).toString('hex');

async function readJsonBody(req, limitBytes = 65536) {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (Buffer.byteLength(raw, 'utf8') > limitBytes) {
      throw new Error('Request body too large');
    }
  }
  return JSON.parse(raw || '{}');
}

function sendJson(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(payload));
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
    const headers = req.headers || {};
    const host = headers.host;
    const origin = headers.origin;
    const referer = headers.referer;

    if (origin && host) {
      try {
        const originUrl = new URL(origin);
        if (originUrl.host !== host) {
          sendJson(res, 403, { error: 'Forbidden cross-origin request' });
          return;
        }
      } catch {
        sendJson(res, 400, { error: 'Invalid Origin header' });
        return;
      }
    } else if (referer && host) {
      try {
        const refererUrl = new URL(referer);
        if (refererUrl.host !== host) {
          sendJson(res, 403, { error: 'Forbidden cross-origin request' });
          return;
        }
      } catch {
        // Skip malformed referers
      }
    }

    if (req.method === 'POST') {
      const csrfHeader = headers['x-csrf-token'];
      if (!csrfHeader || csrfHeader !== csrfToken) {
        sendJson(res, 403, { error: 'Forbidden: CSRF token mismatch' });
        return;
      }
    }

    if (req.method === 'GET' && path === '/api/settings') {
      const config = await loadRuntimeConfigImpl({ configPath });
      const masked = {
        ...config.llm,
        apiKey: config.llm.apiKey ? '••••••••' : ''
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

      const apiKey = body.apiKey === '••••••••' ? current.llm.apiKey : body.apiKey;

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
      const apiKey = body.apiKey === '••••••••' ? current.llm.apiKey : body.apiKey;

      const normalizedApiUrl = normalizeChatCompletionsUrl(body.apiUrl || '');
      const testLlm = {
        apiUrl: normalizedApiUrl,
        apiKey: apiKey || '',
        model: body.model || '',
        temperature: 0.1,
        timeoutMs: 10000
      };

      const start = Date.now();
      try {
        const sampleText = await callChatCompletionsImpl({
          config: testLlm,
          messages: [{ role: 'user', content: 'ping' }]
        });
        const latencyMs = Date.now() - start;
        sendJson(res, 200, {
          success: true,
          normalizedApiUrl,
          model: testLlm.model,
          latencyMs,
          sampleText
        });
      } catch (err) {
        const latencyMs = Date.now() - start;
        let errMsg = err.message || String(err);
        if (apiKey) {
          errMsg = errMsg.split(apiKey).join('[redacted]');
        }
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
      const apiKey = body.apiKey === '••••••••' ? current.llm.apiKey : body.apiKey;

      const normalizedApiUrl = normalizeChatCompletionsUrl(body.apiUrl || '');
      const testLlm = {
        apiUrl: normalizedApiUrl,
        apiKey: apiKey || '',
        model: body.model || '',
        temperature: 0.8,
        timeoutMs: 15000
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
        let errMsg = err.message || String(err);
        if (apiKey) {
          errMsg = errMsg.split(apiKey).join('[redacted]');
        }
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
