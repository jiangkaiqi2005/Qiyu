import test from 'node:test';
import assert from 'node:assert/strict';
import { createInitialState } from '../../src/qiyu/state.js';
import { rememberFactsFromText } from '../../src/qiyu/memory-extraction.js';

test('rememberFactsFromText extracts reusable prompt memories', () => {
  const state = createInitialState('local-user');
  const next = rememberFactsFromText(state, '今天又加班到十点，还喝了咖啡');

  assert.deepEqual(next.memories.map((memory) => memory.key).sort(), [
    'drink.coffee',
    'work.general'
  ]);
});
