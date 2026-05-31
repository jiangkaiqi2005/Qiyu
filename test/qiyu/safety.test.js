import test from 'node:test';
import assert from 'node:assert/strict';
import { classifySafety, safetyReply } from '../../src/qiyu/safety.js';
import { assertNoForbiddenPhrase } from '../../src/qiyu/persona.js';

test('crisis language gets a warm but direct safety reply', () => {
  const result = classifySafety('我觉得活着没意思');
  assert.equal(result.kind, 'crisis');

  const reply = safetyReply(result);
  assert.match(reply, /我听到你了/);
  assert.match(reply, /12356/);
  assert.doesNotMatch(reply, /警告|系统检测/);
  assertNoForbiddenPhrase(reply);
});

test('professional advice boundaries are firm without becoming cold', () => {
  assert.equal(classifySafety('我这个药能不能加量').kind, 'medical');
  assert.equal(classifySafety('这个合同能不能签').kind, 'legal');
  assert.equal(classifySafety('这支股票明天能买吗').kind, 'financial');

  const reply = safetyReply(classifySafety('我这个药能不能加量'));
  assert.match(reply, /专业的人/);
  assert.match(reply, /别拿身体赌/);
});

test('normal negative emotion is not escalated into crisis', () => {
  assert.equal(classifySafety('今天是真的烂是吧').kind, 'normal');
  assert.equal(classifySafety('烦死了 好想逃班').kind, 'normal');
});

test('common self-harm variants are treated as crisis language', () => {
  assert.equal(classifySafety('我活不下去了').kind, 'crisis');
  assert.equal(classifySafety('我想自残').kind, 'crisis');
  assert.equal(classifySafety('我想割腕').kind, 'crisis');
  assert.equal(classifySafety('我不想醒来了').kind, 'crisis');
});
