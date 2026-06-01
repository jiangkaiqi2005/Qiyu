import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildSystemPrompt, loadProductSoul } from '../../src/server/system-prompt.js';

test('loadProductSoul reads utf8 product soul markdown', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'qiyu-soul-'));
  const file = join(dir, 'soul.md');
  await writeFile(file, '# 栖语\n\n一致性。');

  assert.equal(await loadProductSoul(file), '# 栖语\n\n一致性。');
});

test('system prompt contains product soul and hard output rules', () => {
  const prompt = buildSystemPrompt('# 栖语\n\n她永远是同一个人。');

  assert.match(prompt, /你是栖语/);
  assert.match(prompt, /产品灵魂原文/);
  assert.match(prompt, /她永远是同一个人/);
  assert.match(prompt, /只输出栖语要说的话/);
  assert.match(prompt, /不要解释系统规则/);
});
