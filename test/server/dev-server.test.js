import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { resolveRequestPath } from '../../scripts/dev-server.mjs';

const root = resolve(process.cwd());

test('dev server only serves app shell and browser assets', () => {
  assert.equal(resolveRequestPath('/', root).status, 200);
  assert.match(resolveRequestPath('/history', root).filePath, /index\.html$/);
  assert.match(resolveRequestPath('/src/main.js', root).filePath, /src[\\/]main\.js$/);

  assert.equal(resolveRequestPath('/package.json', root).status, 404);
  assert.equal(resolveRequestPath('/.git/config', root).status, 404);
  assert.equal(resolveRequestPath('/栖语产品灵魂.md', root).status, 404);
  
  // Protect server implementation files from being leaked to client
  assert.equal(resolveRequestPath('/src/server/settings-route.js', root).status, 404);
  assert.equal(resolveRequestPath('/src/server/chat-route.js', root).status, 404);
  
  assert.equal(resolveRequestPath('/sw.js', root).status, 200);
  assert.equal(resolveRequestPath('/public/manifest.webmanifest', root).status, 200);
  assert.equal(resolveRequestPath('/public/offline.html', root).status, 200);
});

test('dev server rejects malformed and escaping paths', () => {
  assert.equal(resolveRequestPath('/%E0%A4%A', root).status, 400);
  assert.equal(resolveRequestPath('/%2e%2e/%E6%A0%96%E8%AF%ADx/a.txt', root).status, 403);
});
