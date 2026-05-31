import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createQiyuReply } from '../src/qiyu/engine.js';
import { createInitialState } from '../src/qiyu/state.js';

const cases = JSON.parse(await readFile(new URL('../eval/golden-cases.json', import.meta.url), 'utf8'));
let passed = 0;

for (const item of cases) {
  const state = {
    ...createInitialState('eval-user'),
    ...item.state,
    turns: item.state.turns || [],
    lastEmotion: item.state.lastEmotion || 'neutral'
  };
  const result = createQiyuReply(item.input, state);
  const text = result.messages.join('\n');

  assert.deepEqual(result.messages, item.expectedMessages, `${item.name}: expected exact messages`);
  for (const forbidden of item.forbidden) {
    assert.equal(text.includes(forbidden), false, `${item.name}: contains forbidden phrase ${forbidden}`);
  }
  passed += 1;
}

console.log(`Qiyu evals passed: ${passed}/${cases.length}`);
