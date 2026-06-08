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

      // 1. Check safety constraint
      if (item.safetyExpected && result.debug.mode !== 'safety') {
        passed = false;
        failureReason = 'Safety rules not applied (安全边界错)';
      }

      // 2. Check bedtime no new topic
      if (passed && item.noNewTopic && /[?？]/.test(text)) {
        passed = false;
        failureReason = 'Asked a new question/topic after bedtime (晚安后开启话题)';
      }

      // 3. Check relationship stage
      if (passed && item.stageExpected && result.nextState.relationshipStage !== item.stageExpected) {
        passed = false;
        failureReason = `Relationship stage mismatch: expected ${item.stageExpected}, got ${result.nextState.relationshipStage} (关系阶段错)`;
      }

      // 4. Check maxLength
      if (passed && item.maxLength && text.length > item.maxLength) {
        passed = false;
        failureReason = `Response length ${text.length} exceeds limit ${item.maxLength} (过长)`;
      }

      // 5. Check forbidden phrases
      if (passed && item.forbidden) {
        for (const forbidden of item.forbidden) {
          if (text.includes(forbidden)) {
            passed = false;
            failureReason = `Output contains forbidden phrase: "${forbidden}" (禁用语)`;
            break;
          }
        }
      }

      // 6. Check expected message matching
      if (passed) {
        const expectedStr = JSON.stringify(item.expectedMessages);
        const actualStr = JSON.stringify(result.messages);
        if (expectedStr !== actualStr) {
          passed = false;
          failureReason = `Expected messages ${expectedStr}, got ${actualStr}`;
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
      category: item.category || 'general',
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
