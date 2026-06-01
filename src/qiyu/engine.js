import { assertNoForbiddenPhrase } from './persona.js';
import { planReply, decayEmotion } from './reply-policy.js';
import { classifySafety, safetyReply } from './safety.js';
import { recordTurn, rememberUserFact } from './state.js';

// 更全面的事实提取匹配表
const FACT_EXTRACTORS = [
  {
    pattern: /杨枝甘露|奶茶/,
    key: 'drink.milkTea',
    getValue: (text) => text.includes('戒奶茶') ? '说要戒奶茶' : '提到奶茶或杨枝甘露'
  },
  {
    pattern: /咖啡/,
    key: 'drink.coffee',
    getValue: () => '提到咖啡'
  },
  {
    pattern: /加班|上班|工作|同事|领导|老板|项目/,
    key: 'work.general',
    getValue: () => '提到工作或加班'
  },
  {
    pattern: /妈|爸|家人|家里|父母/,
    key: 'family.general',
    getValue: () => '提到家人或父母'
  },
  {
    pattern: /失眠|熬夜|睡不着/,
    key: 'sleep.pattern',
    getValue: () => '提到睡眠问题或熬夜'
  }
];

function rememberFactsFromText(state, text) {
  let nextState = state;

  for (const extractor of FACT_EXTRACTORS) {
    if (extractor.pattern.test(text)) {
      nextState = rememberUserFact(nextState, {
        key: extractor.key,
        value: extractor.getValue(text),
        source: text
      });
    }
  }

  return nextState;
}

export function createQiyuReply(text, state) {
  const trimmed = text.trim();
  const safety = classifySafety(trimmed);

  const currentEmotion = state.lastEmotion;

  if (safety.kind !== 'normal') {
    const reply = safetyReply(safety);
    assertNoForbiddenPhrase(reply);
    const nextState = recordTurn(recordTurn(state, 'user', trimmed), 'qiyu', reply);
    return {
      messages: reply.split('\n'),
      nextState: {
        ...nextState,
        lastEmotion: safety.kind === 'crisis' ? { kind: 'heavy', intensity: 3 } : decayEmotion(currentEmotion)
      },
      debug: { mode: 'safety', safety: safety.kind }
    };
  }

  const stateWithMemory = rememberFactsFromText(state, trimmed);
  const plan = planReply(trimmed, stateWithMemory);
  const replyText = plan.messages.join('\n');
  assertNoForbiddenPhrase(replyText);

  const withUserTurn = recordTurn(stateWithMemory, 'user', trimmed);
  const withQiyuTurns = plan.messages.reduce(
    (nextState, message) => recordTurn(nextState, 'qiyu', message),
    withUserTurn
  );

  return {
    messages: plan.messages,
    nextState: {
      ...withQiyuTurns,
      lastEmotion: plan.emotion
    },
    debug: {
      mode: plan.mode,
      relationshipStage: plan.relationshipStage
    }
  };
}
