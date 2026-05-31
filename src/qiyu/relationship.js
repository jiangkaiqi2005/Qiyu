const DEEP_KEYS = ['family.', 'work.', 'health.', 'sleep.', 'emotion.'];

export function inferRelationshipStage(state) {
  const memories = state.memories || [];
  const turns = state.turns || [];
  const deepMemoryCount = memories.filter((memory) =>
    DEEP_KEYS.some((prefix) => memory.key.startsWith(prefix))
  ).length;
  const userTurns = turns.filter((turn) => turn.speaker === 'user').length;

  if (state.sessionCount >= 30 && deepMemoryCount >= 4 && userTurns >= 4) {
    return '深交';
  }

  if (state.sessionCount >= 12 && deepMemoryCount >= 2 && userTurns >= 1) {
    return '朋友';
  }

  if (state.sessionCount >= 3 && memories.length >= 1) {
    return '熟悉';
  }

  return '初识';
}
