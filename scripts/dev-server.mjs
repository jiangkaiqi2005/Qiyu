import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, isAbsolute, join, normalize, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(process.cwd());
const port = Number(process.env.PORT || 5173);
const host = process.env.HOST || '127.0.0.1';

const contentTypes = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8']
]);

function isAllowedStaticFile(relativePath) {
  const parts = relativePath.split(/[\\/]+/);
  if (parts.some((part) => part.startsWith('.'))) {
    return false;
  }

  return relativePath === 'index.html' || parts[0] === 'src';
}

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

  const requestPath = decoded === '/' ? 'index.html' : decoded;
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

export function createStaticServer(staticRoot = root) {
  return createServer(async (req, res) => {
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

      res.writeHead(200, {
        'Content-Type': contentTypes.get(extname(resolved.filePath)) || 'application/octet-stream'
      });
      createReadStream(resolved.filePath).pipe(res);
    } catch {
      res.writeHead(404);
      res.end('Not found');
    }
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  createStaticServer().listen(port, host, () => {
    console.log(`栖语 MVP running at http://${host}:${port}`);
  });
}
