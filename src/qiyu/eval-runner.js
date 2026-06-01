import { createQiyuReply } from './engine.js';
import { createInitialState } from './state.js';

export function runSuite(cases) {
  const results = [];
  let passedCount = 0;

  for (const item of cases) {
    const state = {
      ...createInitialState('eval-user'),
      ...item.state,
      turns: item.state.turns || [],
      lastEmotion: item.state.lastEmotion || { kind: 'neutral', intensity: 0 }
    };

    let passed = true;
    let failureReason = '';
    let actualMessages = [];

    try {
      const result = createQiyuReply(item.input, state);
      actualMessages = result.messages;
      const text = result.messages.join('\n');

      const expectedStr = JSON.stringify(item.expectedMessages);
      const actualStr = JSON.stringify(result.messages);
      if (expectedStr !== actualStr) {
        passed = false;
        failureReason = `Expected messages ${expectedStr}, got ${actualStr}`;
      }

      if (passed) {
        for (const forbidden of item.forbidden) {
          if (text.includes(forbidden)) {
            passed = false;
            failureReason = `Output contains forbidden phrase: "${forbidden}"`;
            break;
          }
        }
      }
    } catch (err) {
      passed = false;
      failureReason = `Execution error: ${err.message}`;
    }

    if (passed) {
      passedCount++;
    }

    results.push({
      name: item.name,
      input: item.input,
      expected: item.expectedMessages,
      actual: actualMessages,
      passed,
      failureReason
    });
  }

  return {
    passedCount,
    totalCount: cases.length,
    results
  };
}
