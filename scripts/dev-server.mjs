import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, isAbsolute, join, normalize, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createGzip } from 'node:zlib';
import { handleChatRequest } from '../src/server/chat-route.js';
import { handleSettingsRequest, csrfToken } from '../src/server/settings-route.js';
import { loadRuntimeConfig } from '../src/server/config.js';
import { loadProductSoul } from '../src/server/system-prompt.js';
import { readJsonBody, sendJson, validateCsrfAndOrigin } from '../src/server/http-utils.js';
import { SPA_ROUTES } from '../src/router.js';

const root = resolve(process.cwd());
const port = Number(process.env.PORT || 5173);
const host = process.env.HOST || '127.0.0.1';

const contentTypes = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.webmanifest', 'application/manifest+json; charset=utf-8'],
  ['.png', 'image/png']
]);

function isAllowedStaticFile(relativePath) {
  const parts = relativePath.split(/[\\/]+/);
  if (parts.some((part) => part.startsWith('.'))) {
    return false;
  }

  // Security Hardening: Block direct static access to server-only routes code
  if (parts[0] === 'src' && parts[1] === 'server') {
    return false;
  }

  return relativePath === 'index.html' || 
         relativePath === 'sw.js' || 
         parts[0] === 'src' || 
         parts[0] === 'public';
}

// Shared with the client router; sw.js precache is intentionally manual
// (a classic service worker cannot import ESM).
const spaRoutes = new Set(SPA_ROUTES);

export function resolveRequestPath(urlPath, staticRoot = root) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath.split('?')[0]);
  } catch {
    return { status: 400 };
  }

  if (decoded.includes('\0')) {
    return { status: 400 };
  }

  let requestPath = decoded;
  if (spaRoutes.has(decoded)) {
    requestPath = 'index.html';
  }

  const candidate = normalize(join(staticRoot, requestPath));
  const relativePath = relative(staticRoot, candidate);

  if (relativePath.startsWith('..') || isAbsolute(relativePath)) {
    return { status: 403 };
  }

  if (!isAllowedStaticFile(relativePath)) {
    return { status: 404 };
  }

  return { status: 200, filePath: candidate };
}

export async function createStaticServer(staticRoot = root) {
  const productSoul = await loadProductSoul(join(staticRoot, '栖语产品灵魂.md'));

  return createServer(async (req, res) => {
    if (req.url?.startsWith('/api/chat')) {
      const runtimeConfig = await loadRuntimeConfig();
      await handleChatRequest(req, res, { runtimeConfig, productSoul, csrfToken });
      return;
    }

    if (req.url?.startsWith('/api/settings')) {
      await handleSettingsRequest(req, res);
      return;
    }

    if (req.url?.startsWith('/api/dev/context')) {
      if (req.method === 'POST') {
        try {
          if (!validateCsrfAndOrigin(req, res, csrfToken)) {
            return;
          }

          const { buildPromptContext } = await import('../src/qiyu/prompt-context.js');
          const { buildSystemPrompt } = await import('../src/server/system-prompt.js');
          
          const body = await readJsonBody(req);
          const state = body.state || { userId: 'dev', memories: [], turns: [] };
          const userText = body.text || 'ping';

          const systemPrompt = buildSystemPrompt(productSoul);
          const contextObj = buildPromptContext({ state, userText, includeHistory: false });

          sendJson(res, 200, {
            systemPrompt: systemPrompt,
            liveContext: contextObj.content
          });
        } catch {
          sendJson(res, 500, { error: '服务器内部错误' });
        }
      } else {
        res.writeHead(405);
        res.end('Method Not Allowed');
      }
      return;
    }

    if (req.url?.startsWith('/api/eval/run')) {
      if (req.method !== 'POST') {
        res.writeHead(405);
        res.end('Method Not Allowed');
        return;
      }
      if (!validateCsrfAndOrigin(req, res, csrfToken)) {
        return;
      }
      try {
        const { runSuite } = await import('../src/qiyu/eval-runner.js');
        const { readFile } = await import('node:fs/promises');
        const cases = JSON.parse(await readFile(join(staticRoot, 'eval/golden-cases.json'), 'utf8'));
        const report = runSuite(cases);
        sendJson(res, 200, report);
      } catch {
        sendJson(res, 500, { error: '服务器内部错误' });
      }
      return;
    }

    const resolved = resolveRequestPath(req.url || '/', staticRoot);
    if (resolved.status !== 200) {
      res.writeHead(resolved.status);
      const messages = { 400: 'Bad request', 403: 'Forbidden', 404: 'Not found' };
      res.end(messages[resolved.status] || 'Error');
      return;
    }

    try {
      const info = await stat(resolved.filePath);
      if (!info.isFile()) {
        res.writeHead(404);
        res.end('Not found');
        return;
      }

      const ext = extname(resolved.filePath);
      const contentType = contentTypes.get(ext) || 'application/octet-stream';
      const headers = { 
        'Content-Type': contentType,
        'X-Content-Type-Options': 'nosniff'
      };

      // Set highly optimized Cache-Control headers
      const srcDir = join(staticRoot, 'src');
      const relToSrc = relative(srcDir, resolved.filePath);
      const isSrcFile = !relToSrc.startsWith('..') && !isAbsolute(relToSrc);
      if (ext === '.html' || isSrcFile) {
        headers['Cache-Control'] = 'no-cache, no-store, must-revalidate';
      } else if (['.js', '.css', '.webmanifest', '.png'].includes(ext)) {
        headers['Cache-Control'] = 'public, max-age=31536000, immutable';
      }

      // Check client capabilities for dynamic Gzip compression
      const acceptEncoding = req.headers['accept-encoding'] || '';
      const compressableTypes = ['.html', '.js', '.css', '.json', '.webmanifest'];
      const shouldCompress = compressableTypes.includes(ext);

      if (shouldCompress && acceptEncoding.includes('gzip')) {
        headers['Content-Encoding'] = 'gzip';
        res.writeHead(200, headers);
        createReadStream(resolved.filePath).pipe(createGzip()).pipe(res);
      } else {
        res.writeHead(200, headers);
        createReadStream(resolved.filePath).pipe(res);
      }
    } catch {
      res.writeHead(404);
      res.end('Not found');
    }
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const server = await createStaticServer();
  server.listen(port, host, () => {
    console.log(`栖语 MVP running at http://${host}:${port}`);
  });
}
