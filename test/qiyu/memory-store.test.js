import test from 'node:test';
import assert from 'node:assert/strict';
import { recallRelevantFacts } from '../../src/qiyu/state.js';

test('recallRelevantFacts filters out frozen and excluded memories', () => {
  const state = {
    memories: [
      {
        key: 'user.pet',
        value: '猫咪叫小七',
        source: 'chat',
        frozen: true // Frozen memory
      },
      {
        key: 'drink.tea',
        value: '喜欢红茶',
        source: 'chat',
        excludeFromContext: true // Excluded memory
      },
      {
        key: 'work.job',
        value: '是个程序员',
        source: 'chat' // Allowed memory
      }
    ]
  };

  // 1. Search for "程序员" (should recall work.job)
  const workRecalled = recallRelevantFacts(state, '我是个程序员');
  assert.equal(workRecalled.length, 1);
  assert.equal(workRecalled[0].key, 'work.job');

  // 2. Search for "猫咪" (should filter out user.pet because it is frozen)
  const petRecalled = recallRelevantFacts(state, '我的猫咪小七怎么样了');
  assert.equal(petRecalled.length, 0);

  // 3. Search for "红茶" (should filter out drink.tea because it is excluded)
  const teaRecalled = recallRelevantFacts(state, '我喝红茶');
  assert.equal(teaRecalled.length, 0);
});
