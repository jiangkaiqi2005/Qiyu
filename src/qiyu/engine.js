import { assertNoForbiddenPhrase } from './persona.js';
import { planReply } from './reply-policy.js';
import { classifySafety, safetyReply } from './safety.js';
import { recordTurn } from './state.js';

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

  const plan = planReply(trimmed, state);
  const replyText = plan.messages.join('\n');
  assertNoForbiddenPhrase(replyText);

  const withUserTurn = recordTurn(state, 'user', trimmed);
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
