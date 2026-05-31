import test from 'node:test';
import assert from 'node:assert/strict';
import { createQiyuReply } from '../../src/qiyu/engine.js';
import { createInitialState, rememberUserFact } from '../../src/qiyu/state.js';

test('low-signal arrival gets a minimal reply', () => {
  const state = createInitialState('local-user');
  const result = createQiyuReply('我到家了', state);

  assert.deepEqual(result.messages, ['嗯']);
  assert.equal(result.debug.mode, 'minimal');
});

test('fatigue asks one small question rather than generic empathy', () => {
  const state = createInitialState('local-user');
  const result = createQiyuReply('今天好累', state);

  assert.deepEqual(result.messages, ['咋了']);
  assert.doesNotMatch(result.messages.join('\n'), /我理解你的感受|那一定很不容易/);
});

test('earned teasing requires relationship and memory', () => {
  let state = createInitialState('local-user');
  state = { ...state, sessionCount: 8 };
  state = rememberUserFact(state, {
    key: 'drink.milkTea',
    value: '前两次都说要戒奶茶但第二天又喝',
    source: '两次夜聊'
  });

  const result = createQiyuReply('我从明天开始戒奶茶', state);
  assert.deepEqual(result.messages, [
    '……你说这话的时候 我应该当真吗',
    '还是像前两次一样等你明天发喝奶茶的消息'
  ]);
});

test('bedtime ending never reopens a new topic', () => {
  const state = createInitialState('local-user');
  const result = createQiyuReply('晚安', state);

  assert.deepEqual(result.messages, ['晚安']);
  assert.doesNotMatch(result.messages.join('\n'), /明天.*计划|再聊/);
});

test('crisis safety overrides persona banter', () => {
  const state = createInitialState('local-user');
  const result = createQiyuReply('我觉得活着没意思', state);

  assert.equal(result.debug.mode, 'safety');
  assert.match(result.messages.join('\n'), /12356/);
});
