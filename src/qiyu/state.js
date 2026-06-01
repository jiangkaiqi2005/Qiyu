export function createInitialState(userId) {
  return {
    userId,
    sessionCount: 0,
    turns: [],
    memories: [],
    lastEmotion: { kind: 'neutral', intensity: 0 },
    currentSessionStart: null
  };
}

export function startSession(state, now = new Date()) {
  return {
    ...state,
    sessionCount: state.sessionCount + 1,
    currentSessionStart: now.toISOString()
  };
}

export function recordTurn(state, speaker, text, now = new Date()) {
  return {
    ...state,
    turns: [
      ...state.turns,
      {
        speaker,
        text,
        at: now.toISOString()
      }
    ].slice(-80)
  };
}

export function rememberUserFact(state, fact, now = new Date()) {
  const nextFact = {
    key: fact.key,
    value: fact.value,
    source: fact.source,
    updatedAt: now.toISOString()
  };
  const existingIndex = state.memories.findIndex((item) => item.key === fact.key);

  if (existingIndex === -1) {
    return { ...state, memories: [...state.memories, nextFact] };
  }

  const memories = state.memories.slice();
  memories[existingIndex] = nextFact;
  return { ...state, memories };
}

function tokensFor(text) {
  const normalized = text.toLowerCase();
  const wordTokens = normalized.split(/[\s,，。.!！?？、；;：:（）()]+/).filter(Boolean);
  const cjkTokens = Array.from(normalized)
    .map((_, index, chars) => chars.slice(index, index + 2).join(''))
    .filter((token) => token.length === 2);
  return [...new Set([...wordTokens, ...cjkTokens])];
}

export function recallRelevantFacts(state, text) {
  const tokens = tokensFor(text).filter((token) => token.length > 1);
  return state.memories
    .filter((item) => !item.frozen && !item.excludeFromContext)
    .filter((item) => {
      const searchable = `${item.key} ${item.value} ${item.source}`.toLowerCase();
      return tokens.some((token) => searchable.includes(token));
    });
}

function sanitizeTurn(turn) {
  if (!turn || (turn.speaker !== 'user' && turn.speaker !== 'qiyu') || typeof turn.text !== 'string') {
    return null;
  }

  return {
    speaker: turn.speaker,
    text: turn.text,
    at: typeof turn.at === 'string' ? turn.at : new Date().toISOString()
  };
}

function sanitizeMemory(memory) {
  if (
    !memory ||
    typeof memory.key !== 'string' ||
    typeof memory.value !== 'string' ||
    typeof memory.source !== 'string'
  ) {
    return null;
  }

  return {
    key: memory.key,
    value: memory.value,
    source: memory.source,
    updatedAt: typeof memory.updatedAt === 'string' ? memory.updatedAt : new Date().toISOString()
  };
}

export function loadBrowserState(storage, userId = 'local-user') {
  const raw = storage.getItem('qiyu.state');
  if (!raw) {
    return createInitialState(userId);
  }

  try {
    const parsed = JSON.parse(raw);
    const initial = createInitialState(userId);
    return {
      ...initial,
      userId,
      sessionCount: Number.isInteger(parsed.sessionCount) && parsed.sessionCount >= 0 ? parsed.sessionCount : 0,
      lastEmotion: parsed.lastEmotion && typeof parsed.lastEmotion === 'object' ? parsed.lastEmotion : (typeof parsed.lastEmotion === 'string' ? { kind: parsed.lastEmotion, intensity: 0 } : initial.lastEmotion),
      currentSessionStart: typeof parsed.currentSessionStart === 'string' ? parsed.currentSessionStart : null,
      turns: Array.isArray(parsed.turns) ? parsed.turns.map(sanitizeTurn).filter(Boolean) : [],
      memories: Array.isArray(parsed.memories) ? parsed.memories.map(sanitizeMemory).filter(Boolean) : []
    };
  } catch {
    return createInitialState(userId);
  }
}

export function saveBrowserState(storage, state) {
  storage.setItem('qiyu.state', JSON.stringify(state));
}
