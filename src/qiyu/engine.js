import { assertNoForbiddenPhrase } from './persona.js';
import { planReply, decayEmotion } from './reply-policy.js';
import { classifySafety, safetyReply } from './safety.js';
import { recordTurn, rememberUserFact } from './state.js';
import { rememberFactsFromText } from './memory-extraction.js';
import { inferRelationshipStage } from './relationship.js';

export function createQiyuReply(text, state) {
  const trimmed = text.trim();
  const safety = classifySafety(trimmed);

  const currentEmotion = state.lastEmotion;

  if (safety.kind !== 'normal') {
    const reply = safetyReply(safety);
    assertNoForbiddenPhrase(reply);
    
    // Process user turn and memory first
    const stateWithMemory = rememberFactsFromText(state, trimmed);
    const withUserTurn = recordTurn(stateWithMemory, 'user', trimmed);
    
    // Evaluate relationship stage on the updated state
    const relationshipStage = inferRelationshipStage(withUserTurn);
    const currentStage = state.relationshipStage || '初识';
    const stageWeights = { '初识': 0, '熟悉': 1, '朋友': 2, '深交': 3 };
    const nextStage = stageWeights[currentStage] > stageWeights[relationshipStage] ? currentStage : relationshipStage;
    
    const activeState = { ...withUserTurn, relationshipStage: nextStage };
    const nextState = recordTurn(activeState, 'qiyu', reply);
    
    return {
      messages: reply.split('\n'),
      nextState: {
        ...nextState,
        lastEmotion: safety.kind === 'crisis' ? { kind: 'heavy', intensity: 3 } : decayEmotion(currentEmotion)
      },
      debug: { mode: 'safety', safety: safety.kind }
    };
  }

  // Record user turn and extract facts first
  const stateWithMemory = rememberFactsFromText(state, trimmed);
  const withUserTurn = recordTurn(stateWithMemory, 'user', trimmed);
  
  // Calculate relationship stage based on the updated state
  const relationshipStage = inferRelationshipStage(withUserTurn);
  const currentStage = state.relationshipStage || '初识';
  const stageWeights = { '初识': 0, '熟悉': 1, '朋友': 2, '深交': 3 };
  const nextStage = stageWeights[currentStage] > stageWeights[relationshipStage] ? currentStage : relationshipStage;
  
  const activeState = { ...withUserTurn, relationshipStage: nextStage };

  // Plan rules-based reply using the updated stage
  const plan = planReply(trimmed, activeState);
  const replyText = plan.messages.join('\n');
  assertNoForbiddenPhrase(replyText);

  const withQiyuTurns = plan.messages.reduce(
    (nextState, message) => recordTurn(nextState, 'qiyu', message),
    activeState
  );

  return {
    messages: plan.messages,
    nextState: {
      ...withQiyuTurns,
      lastEmotion: plan.emotion
    },
    debug: {
      mode: plan.mode,
      relationshipStage: nextStage
    }
  };
}
