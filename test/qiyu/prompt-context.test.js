import test from 'node:test';
import assert from 'node:assert/strict';
import { buildPromptContext } from '../../src/qiyu/prompt-context.js';
import { createInitialState, rememberUserFact, recordTurn } from '../../src/qiyu/state.js';

test('prompt context injects relationship stage, memories, and forbidden phrases', () => {
  let state = createInitialState('local-user');
  state = { ...state, sessionCount: 14 };
  state = rememberUserFact(state, {
    key: 'work.general',
    value: '最近项目快 deadline，经常加班',
    source: '用户连续几天提到项目'
  });
  state = rememberUserFact(state, {
    key: 'family.general',
    value: '和妈妈沟通时容易吵起来',
    source: '用户说今天跟妈妈吵架'
  });
  state = recordTurn(state, 'user', '今天好累');

  const context = buildPromptContext({ state, userText: '今天又加班到很晚' });

  assert.equal(context.role, 'system');
  assert.match(context.content, /关系阶段：朋友/);
  assert.match(context.content, /最近项目快 deadline/);
  assert.match(context.content, /禁用语/);
  assert.match(context.content, /我理解你的感受/);
  assert.match(context.content, /最近对话/);
});
