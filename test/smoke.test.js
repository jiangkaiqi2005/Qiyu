import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../', import.meta.url);

test('project scaffold exposes app shell and scripts', async () => {
  const pkg = JSON.parse(await readFile(new URL('package.json', root), 'utf8'));
  const html = await readFile(new URL('index.html', root), 'utf8');

  assert.equal(pkg.type, 'module');
  assert.equal(pkg.scripts.test, 'node --test "test/**/*.test.js"');
  assert.equal(pkg.scripts.dev, 'node scripts/dev-server.mjs');
  assert.match(html, /<div id="app"><\/div>/);
  assert.match(html, /src="\.\/src\/main\.js"/);
});

test('app shell avoids inline script and event handlers under CSP', async () => {
  const html = await readFile(new URL('index.html', root), 'utf8');
  const router = await readFile(new URL('src/router.js', root), 'utf8');

  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>[\s\S]*?<\/script>/i);
  assert.doesNotMatch(`${html}\n${router}`, /\son[a-z]+\s*=/i);
});
