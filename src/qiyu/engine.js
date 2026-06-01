import { assertNoForbiddenPhrase } from './persona.js';
import { planReply, decayEmotion } from './reply-policy.js';
import { classifySafety, safetyReply } from './safety.js';
import { recordTurn, rememberUserFact } from './state.js';
import { rememberFactsFromText } from './memory-extraction.js';


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
