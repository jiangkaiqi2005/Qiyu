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

test('engine writes concrete user facts for later local recall', () => {
  const state = createInitialState('local-user');
  const result = createQiyuReply('今天买了杨枝甘露', state);

  assert.deepEqual(
    result.nextState.memories.map((memory) => memory.key),
    ['drink.milkTea']
  );
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

test('continuous dialogue state transitions and fact accumulation', () => {
  let state = createInitialState('local-user');
  
  // Turn 1
  let res = createQiyuReply('我今天好累，加班到很晚', state);
  state = res.nextState;
  assert.equal(state.turns.length, 2); // user + qiyu
  assert.ok(state.memories.some(m => m.key === 'work.general'));

  // Turn 2
  res = createQiyuReply('我中奖了', state);
  state = res.nextState;
  assert.equal(state.turns.length, 4); // user + qiyu + user + qiyu
  assert.deepEqual(res.messages, ['真的假的！中多少']);

  // Turn 3
  res = createQiyuReply('中了个硬币，哈哈', state);
  state = res.nextState;
  assert.equal(state.turns.length, 6);
  assert.equal(res.debug.mode, 'open');
});

test('emotional inertia decays gradually across turns', () => {
  let state = createInitialState('local-user');
  
  // Loss triggers heavy emotion with intensity 3
  let res = createQiyuReply('我分手了，很难受', state);
  state = res.nextState;
  assert.equal(state.lastEmotion.kind, 'heavy');
  assert.equal(state.lastEmotion.intensity, 3);

  // Turn 2: normal conversation, emotion decays to intensity 2
  res = createQiyuReply('你觉得天气怎么样', state);
  state = res.nextState;
  assert.equal(state.lastEmotion.kind, 'heavy');
  assert.equal(state.lastEmotion.intensity, 2);

  // Turn 3: normal conversation, emotion decays to intensity 1
  res = createQiyuReply('对的', state);
  state = res.nextState;
  assert.equal(state.lastEmotion.kind, 'heavy');
  assert.equal(state.lastEmotion.intensity, 1);

  // Turn 4: normal conversation, emotion decays and resets to neutral with intensity 0
  res = createQiyuReply('好吧', state);
  state = res.nextState;
  assert.equal(state.lastEmotion.kind, 'neutral');
  assert.equal(state.lastEmotion.intensity, 0);
});

