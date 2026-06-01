import { readFile } from 'node:fs/promises';
import { runSuite } from '../src/qiyu/eval-runner.js';

const cases = JSON.parse(
  await readFile(new URL('../eval/golden-cases.json', import.meta.url), 'utf8')
);

const report = runSuite(cases);

for (const res of report.results) {
  if (!res.passed) {
    console.error(`FAIL: ${res.name} -> ${res.failureReason}`);
    process.exit(1);
  }
}

console.log(`Qiyu evals passed: ${report.passedCount}/${report.totalCount}`);
