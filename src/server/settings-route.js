import { writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { loadRuntimeConfig } from './config.js';
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

export async function handleSettingsRequest(req, res) {
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
      const config = await loadRuntimeConfig();
      const masked = {
        ...config.llm,
        apiKey: config.llm.apiKey ? '••••••••' : ''
      };
      sendJson(res, 200, {
        ...masked,
        csrfToken
      });
      return;
    }

    if (req.method === 'POST' && path === '/api/settings') {
      const body = await readJsonBody(req);
      const current = await loadRuntimeConfig();

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

      await writeFile('qiyu.config.local.json', JSON.stringify(newConfig, null, 2), 'utf8');
      sendJson(res, 200, { success: true });
      return;
    }

    if (req.method === 'POST' && path === '/api/settings/test') {
      const body = await readJsonBody(req);
      const current = await loadRuntimeConfig();
      const apiKey = body.apiKey === '••••••••' ? current.llm.apiKey : body.apiKey;

      const testLlm = {
        apiUrl: body.apiUrl || '',
        apiKey: apiKey || '',
        model: body.model || '',
        temperature: 0.1,
        timeoutMs: 10000
      };

      try {
        await callChatCompletions({
          config: testLlm,
          messages: [{ role: 'user', content: 'ping' }]
        });
        sendJson(res, 200, { success: true });
      } catch (err) {
        sendJson(res, 200, { success: false, error: err.message });
      }
      return;
    }

    sendJson(res, 404, { error: 'Not found' });
  } catch (err) {
    // Sanitize stack traces to prevent absolute server path leaks
    sendJson(res, 500, { error: 'Internal Server Error' });
  }
}
