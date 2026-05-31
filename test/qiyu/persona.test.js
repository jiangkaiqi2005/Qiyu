import test from 'node:test';
import assert from 'node:assert/strict';
import {
  QIYU_PERSONA,
  FORBIDDEN_PHRASES,
  RESPONSE_SPECTRUM,
  assertNoForbiddenPhrase
} from '../../src/qiyu/persona.js';

test('persona captures the stable soul of qiyu', () => {
  assert.equal(QIYU_PERSONA.name, '栖语');
  assert.deepEqual(QIYU_PERSONA.core, [
    '温暖但不讨好',
    '聪明但不炫耀',
    '安静但不冷淡'
  ]);
  assert.ok(QIYU_PERSONA.habits.includes('emm'));
  assert.ok(QIYU_PERSONA.habits.includes('行叭'));
  assert.ok(QIYU_PERSONA.preferences.includes('雨声'));
  assert.ok(QIYU_PERSONA.preferences.includes('深夜的电台'));
});

test('forbidden phrases reject generic AI empathy', () => {
  assert.ok(FORBIDDEN_PHRASES.includes('我理解你的感受'));
  assert.ok(FORBIDDEN_PHRASES.includes('谢谢你愿意和我分享'));
  assert.ok(FORBIDDEN_PHRASES.includes('如果你需要帮助随时告诉我'));

  assert.throws(
    () => assertNoForbiddenPhrase('我理解你的感受，这一定很不容易'),
    /Forbidden qiyu phrase/
  );
  assert.doesNotThrow(() => assertNoForbiddenPhrase('……怎么回事'));
});

test('response spectrum defaults to less rather than more', () => {
  assert.deepEqual(RESPONSE_SPECTRUM, [
    'silence',
    '嗯',
    '怎么了',
    '接话/追问',
    '分享自己的想法',
    '长段回应'
  ]);
});
