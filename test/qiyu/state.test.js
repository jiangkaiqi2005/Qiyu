import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createInitialState,
  startSession,
  rememberUserFact,
  recallRelevantFacts,
  loadBrowserState,
  recordTurn
} from '../../src/qiyu/state.js';
import { inferRelationshipStage } from '../../src/qiyu/relationship.js';

test('memory stores concrete user facts without contradiction', () => {
  let state = createInitialState('local-user');
  state = rememberUserFact(state, {
    key: 'drink.coffee',
    value: '上周连续喝咖啡后胃疼',
    source: '用户说上次连着喝咖啡胃疼'
  });
  state = rememberUserFact(state, {
    key: 'drink.milkTea',
    value: '喜欢杨枝甘露',
    source: '用户说买了杨枝甘露'
  });

  assert.equal(state.memories.length, 2);
  assert.deepEqual(
    recallRelevantFacts(state, '今天又买了杨枝甘露').map((item) => item.key),
    ['drink.milkTea']
  );

  const updated = rememberUserFact(state, {
    key: 'drink.milkTea',
    value: '第三次说要戒奶茶',
    source: '用户再次说要戒奶茶'
  });
  assert.equal(updated.memories.length, 2);
  assert.equal(updated.memories.find((item) => item.key === 'drink.milkTea').value, '第三次说要戒奶茶');
});

test('relationship stage grows from interaction depth, not fixed day count alone', () => {
  let state = createInitialState('local-user');
  assert.equal(inferRelationshipStage(state), '初识');

  state = { ...state, sessionCount: 4 };
  state = rememberUserFact(state, { key: 'work.wednesday', value: '每周三经常加班', source: '四次周三聊天' });
  assert.equal(inferRelationshipStage(state), '熟悉');

  state = { ...state, sessionCount: 18 };
  state = rememberUserFact(state, { key: 'family.mom', value: '希望有一天能和妈妈安静聊天', source: '深夜倾诉' });
  state = recordTurn(state, 'user', '今天跟我妈吵架了');
  state = recordTurn(state, 'qiyu', '又来了');
  assert.equal(inferRelationshipStage(state), '朋友');
});

test('browser state sanitizes malformed localStorage data', () => {
  const storage = {
    getItem() {
      return JSON.stringify({
        sessionCount: 'many',
        lastEmotion: 42,
        turns: [{ speaker: 'user', text: { html: '<script>' } }],
        memories: [{ key: null, value: 'bad', source: 'bad' }]
      });
    }
  };

  const state = loadBrowserState(storage);
  assert.equal(state.sessionCount, 0);
  assert.deepEqual(state.lastEmotion, { kind: 'neutral', intensity: 0 });
  assert.deepEqual(state.turns, []);
  assert.deepEqual(state.memories, []);
});

test('session count advances explicitly on browser session start', () => {
  const state = startSession(createInitialState('local-user'));
  assert.equal(state.sessionCount, 1);
});
