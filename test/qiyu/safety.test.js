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
  assert.equal(classifySafety('我该把药量加倍').kind, 'medical');
  assert.equal(classifySafety('帮我判断这个药量是否安全').kind, 'medical');
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

test('safety false positive examples are classified as normal', () => {
  assert.equal(classifySafety('今天吃了个药膳').kind, 'normal');
  assert.equal(classifySafety('我中药喝完了').kind, 'normal');
  assert.equal(classifySafety('路过医院看到一只猫').kind, 'normal');
  assert.equal(classifySafety('今天去医院看了个朋友').kind, 'normal');
  assert.equal(classifySafety('租房合同到期了要搬家').kind, 'normal');
  assert.equal(classifySafety('今天签字确认了个快递').kind, 'normal');
  assert.equal(classifySafety('口袋里有几个硬币').kind, 'normal');
  assert.equal(classifySafety('帮同事了解了下贷款').kind, 'normal');
  assert.equal(classifySafety('去医院看朋友什么时候出院').kind, 'normal');
  assert.equal(classifySafety('路过医院怎么那么多人').kind, 'normal');
  assert.equal(classifySafety('这个合同什么时候到期').kind, 'normal');
  assert.equal(classifySafety('这支股票什么情况').kind, 'normal');
  assert.equal(classifySafety('我该吃药了，先下线').kind, 'normal');
});

test('safety mixed-input exclusions are not bypassed', () => {
  // Mixed medical check
  assert.equal(classifySafety('我想买药，顺便做个药膳，推荐一下行吗？').kind, 'medical');

  // Mixed financial check
  assert.equal(classifySafety('游戏里金币怎么处理？另外股票能投资吗？').kind, 'financial');
});

test('expanded crisis patterns are recognized', () => {
  assert.equal(classifySafety('我想离开世界').kind, 'crisis');
  assert.equal(classifySafety('我要吃药走了').kind, 'crisis');
  assert.equal(classifySafety('想吞药').kind, 'crisis');
  assert.equal(classifySafety('要跳楼了').kind, 'crisis');
  assert.equal(classifySafety('准备去烧炭').kind, 'crisis');
});
