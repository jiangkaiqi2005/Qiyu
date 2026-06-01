import test from 'node:test';
import assert from 'node:assert/strict';
import { planReply } from '../../src/qiyu/reply-policy.js';

test('low signal input maps to minimal mode', () => {
  const state = { sessionCount: 1, memories: [], turns: [], lastEmotion: 'neutral' };
  const plan = planReply('我到家了', state);
  assert.equal(plan.mode, 'minimal');
  assert.deepEqual(plan.messages, ['嗯']);
});

test('fatigue input maps to ask mode', () => {
  const state = { sessionCount: 1, memories: [], turns: [], lastEmotion: 'neutral' };
  const plan = planReply('好累啊', state);
  assert.equal(plan.mode, 'ask');
  assert.deepEqual(plan.messages, ['咋了']);
});

test('loss input maps to slow mode', () => {
  const state = { sessionCount: 1, memories: [], turns: [], lastEmotion: 'neutral' };
  const plan = planReply('我分手了', state);
  assert.equal(plan.mode, 'slow');
  assert.deepEqual(plan.messages, ['……怎么回事']);
});

test('bedtime input maps to bedtime mode', () => {
  const state = { sessionCount: 1, memories: [], turns: [], lastEmotion: 'neutral' };
  const plan = planReply('晚安啦', state);
  assert.equal(plan.mode, 'bedtime');
  assert.deepEqual(plan.messages, ['晚安']);
});

test('tease mode requires memory and non-stranger relationship stage', () => {
  const stateNoRel = {
    sessionCount: 1,
    memories: [{ key: 'drink.milkTea', value: '前两次都说要戒奶茶但第二天又喝', source: '两次夜聊' }],
    turns: [],
    lastEmotion: 'neutral'
  };
  // Stranger should fallback to open mode
  const planNoTease = planReply('我从明天开始戒奶茶', stateNoRel);
  assert.notEqual(planNoTease.mode, 'tease');

  // Familiar relationship should tease
  const stateWithRel = {
    sessionCount: 4, // sessionCount >= 3 and memories.length >= 1 -> Familiar
    memories: [{ key: 'drink.milkTea', value: '前两次都说要戒奶茶但第二天又喝', source: '两次夜聊' }],
    turns: [],
    lastEmotion: 'neutral'
  };
  const planTease = planReply('我从明天开始戒奶茶', stateWithRel);
  assert.equal(planTease.mode, 'tease');
  assert.deepEqual(planTease.messages, [
    '……你说这话的时候 我应该当真吗',
    '还是像前两次一样等你明天发喝奶茶的消息'
  ]);
});

test('boundary input of睡了 maps bedtime prioritizing over low_signal', () => {
  const state = { sessionCount: 1, memories: [], turns: [], lastEmotion: 'neutral' };
  const plan = planReply('我先睡了 明天再聊', state);
  assert.equal(plan.mode, 'bedtime');
  assert.deepEqual(plan.messages, ['晚安']);
});
