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
