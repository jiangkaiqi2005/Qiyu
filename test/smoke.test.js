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

test('core stylesheet uses explicit motion tokens instead of broad transitions', async () => {
  const styles = await readFile(new URL('src/styles.css', root), 'utf8');

  assert.match(styles, /--motion-base:/);
  assert.match(styles, /--ease-emphasized:/);
  assert.doesNotMatch(styles, /transition:\s*all\b/);
});

test('sidebar expansion is gated by an explicit interaction state', async () => {
  const styles = await readFile(new URL('src/styles.css', root), 'utf8');
  const layout = await readFile(new URL('src/ui/layout.js', root), 'utf8');

  assert.match(styles, /\.app-sidebar\[data-expanded="true"\]/);
  assert.doesNotMatch(styles, /\.app-sidebar:hover/);
  assert.match(layout, /bindSidebarHoverIntent/);
  assert.match(layout, /SIDEBAR_HOVER_INTENT_DELAY_MS = 420/);
});
