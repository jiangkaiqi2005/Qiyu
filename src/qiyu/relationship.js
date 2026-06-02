const DEEP_KEYS = ['family.', 'work.', 'health.', 'sleep.', 'emotion.'];

export function inferRelationshipStage(state) {
  const memories = state.memories || [];
  const turns = state.turns || [];
  const deepMemoryCount = memories.filter((memory) =>
    DEEP_KEYS.some((prefix) => memory.key.startsWith(prefix))
  ).length;
  const userTurns = turns.filter((turn) => turn.speaker === 'user').length;

  let inferred = '初识';
  if (state.sessionCount >= 30 && deepMemoryCount >= 4 && userTurns >= 4) {
    inferred = '深交';
  } else if (state.sessionCount >= 12 && deepMemoryCount >= 2 && userTurns >= 1) {
    inferred = '朋友';
  } else if (state.sessionCount >= 3 && memories.length >= 1) {
    inferred = '熟悉';
  }

  // Sticky stage behavior to prevent history roll-off downgrades
  const stageWeights = { '初识': 0, '熟悉': 1, '朋友': 2, '深交': 3 };
  const currentStage = state.relationshipStage || '初识';
  if (stageWeights[currentStage] > stageWeights[inferred]) {
    return currentStage;
  }
  return inferred;
}
