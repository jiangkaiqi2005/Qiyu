import { assertNoForbiddenPhrase } from './persona.js';
import { planReply } from './reply-policy.js';
import { classifySafety, safetyReply } from './safety.js';
import { recordTurn, rememberUserFact } from './state.js';

function rememberFactsFromText(state, text) {
  let nextState = state;

  if (/杨枝甘露|奶茶/.test(text)) {
    nextState = rememberUserFact(nextState, {
      key: 'drink.milkTea',
      value: text.includes('戒奶茶') ? '说要戒奶茶' : '提到奶茶或杨枝甘露',
      source: text
    });
  }

  if (/咖啡/.test(text)) {
    nextState = rememberUserFact(nextState, {
      key: 'drink.coffee',
      value: '提到咖啡',
      source: text
    });
  }

  return nextState;
}

export function createQiyuReply(text, state) {
  const trimmed = text.trim();
  const safety = classifySafety(trimmed);

  if (safety.kind !== 'normal') {
    const reply = safetyReply(safety);
    assertNoForbiddenPhrase(reply);
    const nextState = recordTurn(recordTurn(state, 'user', trimmed), 'qiyu', reply);
    return {
      messages: reply.split('\n'),
      nextState: {
        ...nextState,
        lastEmotion: safety.kind === 'crisis' ? 'heavy' : state.lastEmotion
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
