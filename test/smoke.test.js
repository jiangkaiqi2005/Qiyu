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
  assert.match(layout, /SIDEBAR_HOVER_INTENT_DELAY_MS = 760/);
});

test('app metadata presents Qiyu as a quiet direct-chat app', async () => {
  const html = await readFile(new URL('index.html', root), 'utf8');
  const manifest = JSON.parse(await readFile(new URL('public/manifest.webmanifest', root), 'utf8'));

  assert.match(html, /<meta name="description" content="栖语是一间安静的深夜夜话空间/);
  assert.match(html, /<meta name="apple-mobile-web-app-capable" content="yes">/);
  assert.match(html, /<link rel="apple-touch-icon" href="\/public\/icons\/icon-192\.png">/);
  assert.match(html, /<meta property="og:title" content="栖语">/);
  assert.doesNotMatch(`${html}\n${manifest.description}`, /AI 伴侣/);

  assert.equal(manifest.id, '/');
  assert.equal(manifest.scope, '/');
  assert.equal(manifest.start_url, '/chat');
  assert.equal(manifest.theme_color, '#0b0a08');
  assert.equal(manifest.icons.length, 2);
  assert.ok(manifest.shortcuts.some(shortcut => shortcut.url === '/chat'));
  assert.ok(manifest.shortcuts.some(shortcut => shortcut.url === '/settings'));
});

test('chat composer uses nested material structure instead of a bare input rectangle', async () => {
  const chat = await readFile(new URL('src/screens/chat.js', root), 'utf8');
  const styles = await readFile(new URL('src/styles.css', root), 'utf8');

  assert.match(chat, /class="composer-field"/);
  assert.match(chat, /class="send-mark"/);
  assert.match(styles, /\.composer-field/);
  assert.match(styles, /\.send-mark/);
  assert.doesNotMatch(styles, /\.composer\s+textarea\s*\{[^}]*border:\s*1px/);
});
