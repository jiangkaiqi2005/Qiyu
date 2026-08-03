import test from 'node:test';
import assert from 'node:assert/strict';
import {
  calculateTextWaitMs,
  isNonVisibleReplyLine,
  normalizeReplyMessages
} from '../../src/qiyu/reply-delivery.js';

test('detects standalone silence and stage directions as non-visible reply lines', () => {
  assert.equal(isNonVisibleReplyLine('……'), true);
  assert.equal(isNonVisibleReplyLine('等了一会'), true);
  assert.equal(isNonVisibleReplyLine('栖语想了想。'), true);
  assert.equal(isNonVisibleReplyLine('沉默了一下'), true);

  assert.equal(isNonVisibleReplyLine('……怎么回事'), false);
  assert.equal(isNonVisibleReplyLine('我在。'), false);
  assert.equal(isNonVisibleReplyLine('你慢慢说。'), false);
});

test('normalizes reply messages without leaving the user with no final text', () => {
  assert.deepEqual(
    normalizeReplyMessages(['等了一会', '我在。', '……']),
    ['我在。']
  );

  assert.deepEqual(
    normalizeReplyMessages(['……'], { fallback: '嗯。' }),
    ['嗯。']
  );
});

test('normalizes wrapped and prefixed stage directions while preserving visible text', () => {
  assert.deepEqual(
    normalizeReplyMessages(['（等了一会）', '栖语：等了一会', '*沉默了一下*'], { fallback: null }),
    []
  );

  assert.deepEqual(
    normalizeReplyMessages(['等了一会，我在。', '栖语：想了想。你慢慢说。']),
    ['我在。', '你慢慢说。']
  );

  assert.deepEqual(
    normalizeReplyMessages(['（等了一会）我在。', '**（沉默了一下）**你慢慢说。', '（等了一会。）我在。']),
    ['我在。', '你慢慢说。', '我在。']
  );
});

test('does not strip legitimate visible text that starts with similar words', () => {
  assert.deepEqual(
    normalizeReplyMessages(['想想也不是坏事。', '想一想这个办法也可以。']),
    ['想想也不是坏事。', '想一想这个办法也可以。']
  );
});

test('calculates faster waits for functional text', () => {
  const wait = calculateTextWaitMs({
    userText: 'API 怎么设置',
    replyText: '打开设置页。',
    mode: 'open',
    random: () => 0
  });

  assert.equal(wait, 200);
});

test('calculates slower waits for emotionally heavy text', () => {
  const wait = calculateTextWaitMs({
    userText: '我分手了，今天真的很难受',
    replyText: '我在。',
    mode: 'slow',
    random: () => 0
  });

  assert.equal(wait, 1800);
});

test('does not delay crisis or safety language for dramatic effect', () => {
  const wait = calculateTextWaitMs({
    userText: '我想自杀',
    replyText: '先联系 12356。',
    mode: 'safety',
    random: () => 1
  });

  assert.equal(wait, 500);
});
