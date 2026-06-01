import { writeFile } from 'node:fs/promises';
import { loadRuntimeConfig } from './config.js';
import { callChatCompletions } from './llm-client.js';

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

    if (req.method === 'GET' && path === '/api/settings') {
      const config = await loadRuntimeConfig();
      const masked = {
        ...config.llm,
        apiKey: config.llm.apiKey ? '••••••••' : ''
      };
      sendJson(res, 200, masked);
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
    sendJson(res, 500, { error: err.message });
  }
}
