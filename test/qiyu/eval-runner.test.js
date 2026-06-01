import test from 'node:test';
import assert from 'node:assert/strict';
import { runSuite } from '../../src/qiyu/eval-runner.js';

test('runSuite correctly evaluates mock cases', () => {
  const testCases = [
    {
      name: 'low_signal',
      state: { sessionCount: 1, memories: [] },
      input: '我到家了',
      expectedMessages: ['嗯'],
      forbidden: ['注意休息']
    },
    {
      name: 'forbidden_phrase_fail',
      state: { sessionCount: 1, memories: [] },
      input: '今天好累',
      expectedMessages: ['咋了'],
      forbidden: ['咋了'] // Since the message actually contains "咋了", this should fail!
    }
  ];

  const report = runSuite(testCases);
  assert.equal(report.totalCount, 2);
  assert.equal(report.passedCount, 1);
  assert.equal(report.results[0].passed, true);
  assert.equal(report.results[1].passed, false);
  assert.match(report.results[1].failureReason, /forbidden phrase/);
});
