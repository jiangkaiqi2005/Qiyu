import test from 'node:test';
import assert from 'node:assert/strict';
import { escapeHtml, renderBubble } from '../../src/ui/render.js';

test('escapeHtml protects rendered chat content', () => {
  assert.equal(escapeHtml('<script>alert(1)</script>'), '&lt;script&gt;alert(1)&lt;/script&gt;');
});

test('renderBubble marks speaker and preserves line breaks', () => {
  assert.equal(
    renderBubble({ speaker: 'qiyu', text: '……\n怎么回事' }),
    '<p class="qiyu">……<br>怎么回事</p>'
  );
  assert.equal(
    renderBubble({ speaker: 'user', text: '今天好累' }),
    '<p class="user">今天好累</p>'
  );
});
