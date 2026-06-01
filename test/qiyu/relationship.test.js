import test from 'node:test';
import assert from 'node:assert/strict';
import { inferRelationshipStage } from '../../src/qiyu/relationship.js';

test('initial relationship stage is stranger', () => {
  const state = { sessionCount: 0, memories: [], turns: [] };
  assert.equal(inferRelationshipStage(state), '初识');
});

test('familiar requires sessionCount >= 3 and memories >= 1', () => {
  const stateNotEnoughSessions = { sessionCount: 2, memories: [{ key: 'drink.coffee', value: '咖啡' }] };
  assert.equal(inferRelationshipStage(stateNotEnoughSessions), '初识');

  const stateNotEnoughMemories = { sessionCount: 3, memories: [] };
  assert.equal(inferRelationshipStage(stateNotEnoughMemories), '初识');

  const stateFamiliar = { sessionCount: 3, memories: [{ key: 'drink.coffee', value: '咖啡' }] };
  assert.equal(inferRelationshipStage(stateFamiliar), '熟悉');
});

test('friend stage requires sessionCount >= 12, deep memories >= 2, and user turns >= 1', () => {
  const stateFriend = {
    sessionCount: 12,
    memories: [
      { key: 'family.mom', value: '妈妈' },
      { key: 'work.job', value: '工作' }
    ],
    turns: [{ speaker: 'user', text: 'hello' }]
  };
  assert.equal(inferRelationshipStage(stateFriend), '朋友');

  // boundary: sessionCount is enough, but deep memory is not enough (only 1 deep memory)
  const stateNotEnoughDeepMemories = {
    sessionCount: 12,
    memories: [
      { key: 'family.mom', value: '妈妈' },
      { key: 'drink.coffee', value: '不是深层的记忆' }
    ],
    turns: [{ speaker: 'user', text: 'hello' }]
  };
  assert.equal(inferRelationshipStage(stateNotEnoughDeepMemories), '熟悉'); // should fall back to familiar
});

test('soulmate stage requires sessionCount >= 30, deep memories >= 4, and user turns >= 4', () => {
  const stateSoulmate = {
    sessionCount: 30,
    memories: [
      { key: 'family.mom', value: '妈妈' },
      { key: 'work.job', value: '工作' },
      { key: 'health.body', value: '健康' },
      { key: 'sleep.rest', value: '睡眠' }
    ],
    turns: [
      { speaker: 'user', text: '1' },
      { speaker: 'user', text: '2' },
      { speaker: 'user', text: '3' },
      { speaker: 'user', text: '4' }
    ]
  };
  assert.equal(inferRelationshipStage(stateSoulmate), '深交');

  // boundary: sessionCount enough but not enough user turns
  const stateNotEnoughTurns = {
    sessionCount: 30,
    memories: [
      { key: 'family.mom', value: '妈妈' },
      { key: 'work.job', value: '工作' },
      { key: 'health.body', value: '健康' },
      { key: 'sleep.rest', value: '睡眠' }
    ],
    turns: [
      { speaker: 'user', text: '1' },
      { speaker: 'user', text: '2' },
      { speaker: 'user', text: '3' }
    ]
  };
  assert.equal(inferRelationshipStage(stateNotEnoughTurns), '朋友'); // falls back to friend
});
