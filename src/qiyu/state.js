const MAX_HISTORY_DAYS = 180;
const MAX_SESSION_TURNS = 80;

export function getConversationDate(now = new Date()) {
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function createInitialState(userId) {
  return {
    userId,
    sessionCount: 0,
    turns: [],
    memories: [],
    lastEmotion: { kind: 'neutral', intensity: 0 },
    currentSessionStart: null,
    relationshipStage: '初识', // Sticky persistent state
    companionshipStyle: 'gentle', // gentle, playful, quiet
    sleepTime: '23:00',
    userName: '你',
    dailyConversations: [],
    activeConversationDate: ''
  };
}

function nightTalkTitle(date) {
  return `${date.getMonth() + 1}月${date.getDate()}日 夜话`;
}

function createConversationEntry(dateStr, titleDate, iso, turns = []) {
  return {
    date: dateStr,
    title: nightTalkTitle(titleDate),
    startedAt: iso,
    updatedAt: iso,
    turns
  };
}

export function startSession(state, now = new Date()) {
  const dateStr = getConversationDate(now);
  let dailyConversations = [...(state.dailyConversations || [])];
  const existingIndex = dailyConversations.findIndex(c => c.date === dateStr);
  if (existingIndex === -1) {
    dailyConversations.push(createConversationEntry(dateStr, now, now.toISOString()));
  }
  return {
    ...state,
    sessionCount: state.sessionCount + 1,
    currentSessionStart: now.toISOString(),
    dailyConversations,
    activeConversationDate: dateStr
  };
}

export function recordTurn(state, speaker, text, now = new Date()) {
  const nextTurn = {
    speaker,
    text,
    at: now.toISOString()
  };

  const dateStr = state.activeConversationDate || getConversationDate(now);
  let dailyConversations = [...(state.dailyConversations || [])];
  let existingIndex = dailyConversations.findIndex(c => c.date === dateStr);

  if (existingIndex === -1) {
    dailyConversations.push(createConversationEntry(dateStr, now, now.toISOString(), [nextTurn]));
  } else {
    const currentConv = dailyConversations[existingIndex];
    dailyConversations[existingIndex] = {
      ...currentConv,
      updatedAt: now.toISOString(),
      turns: [...currentConv.turns, nextTurn]
    };
  }

  // Keep maximum 180 days of daily history
  dailyConversations = dailyConversations.slice(-MAX_HISTORY_DAYS);

  return {
    ...state,
    turns: [...(state.turns || []), nextTurn].slice(-MAX_SESSION_TURNS),
    dailyConversations,
    activeConversationDate: dateStr
  };
}

export function rememberUserFact(state, fact, now = new Date()) {
  const nextFact = {
    key: fact.key,
    value: fact.value,
    source: fact.source,
    updatedAt: now.toISOString(),
    category: fact.category || fact.key.split('.')[0] || 'general',
    sensitiveLevel: typeof fact.sensitiveLevel === 'number' ? fact.sensitiveLevel : 0,
    originalText: fact.originalText || fact.source,
    lastUsedAt: fact.lastUsedAt || null,
    useCount: typeof fact.useCount === 'number' ? fact.useCount : 0,
    frozen: typeof fact.frozen === 'boolean' ? fact.frozen : false,
    excludeFromContext: typeof fact.excludeFromContext === 'boolean' ? fact.excludeFromContext : false
  };
  const existingIndex = state.memories.findIndex((item) => item.key === fact.key);

  if (existingIndex === -1) {
    return { ...state, memories: [...state.memories, nextFact] };
  }

  const memories = state.memories.slice();
  memories[existingIndex] = {
    ...memories[existingIndex],
    ...nextFact
  };
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
    updatedAt: typeof memory.updatedAt === 'string' ? memory.updatedAt : new Date().toISOString(),
    frozen: Boolean(memory.frozen),
    excludeFromContext: Boolean(memory.excludeFromContext),
    category: typeof memory.category === 'string' ? memory.category : (memory.key.split('.')[0] || 'general'),
    sensitiveLevel: typeof memory.sensitiveLevel === 'number' ? memory.sensitiveLevel : 0,
    originalText: typeof memory.originalText === 'string' ? memory.originalText : memory.source,
    lastUsedAt: typeof memory.lastUsedAt === 'string' ? memory.lastUsedAt : null,
    useCount: typeof memory.useCount === 'number' ? memory.useCount : 0
  };
}

function sanitizeDailyConversation(c) {
  if (!c || typeof c.date !== 'string') return null;
  return {
    date: c.date,
    title: typeof c.title === 'string' ? c.title : `${c.date} 夜话`,
    startedAt: typeof c.startedAt === 'string' ? c.startedAt : new Date().toISOString(),
    updatedAt: typeof c.updatedAt === 'string' ? c.updatedAt : new Date().toISOString(),
    turns: Array.isArray(c.turns) ? c.turns.map(sanitizeTurn).filter(Boolean) : []
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
    
    // Group and migrate old turns if dailyConversations is missing
    let dailyConversations = [];
    if (Array.isArray(parsed.dailyConversations)) {
      dailyConversations = parsed.dailyConversations;
    } else if (Array.isArray(parsed.turns) && parsed.turns.length > 0) {
      const groups = {};
      parsed.turns.forEach(t => {
        const turn = sanitizeTurn(t);
        if (!turn) return;
        const d = new Date(turn.at);
        const dateStr = getConversationDate(isNaN(d.getTime()) ? new Date() : d);
        if (!groups[dateStr]) {
          groups[dateStr] = createConversationEntry(dateStr, isNaN(d.getTime()) ? new Date() : d, turn.at);
        }
        groups[dateStr].turns.push(turn);
        groups[dateStr].updatedAt = turn.at;
      });
      dailyConversations = Object.values(groups).sort((a, b) => a.date.localeCompare(b.date));
    }

    return {
      ...initial,
      userId,
      sessionCount: Number.isInteger(parsed.sessionCount) && parsed.sessionCount >= 0 ? parsed.sessionCount : 0,
      lastEmotion: parsed.lastEmotion && typeof parsed.lastEmotion === 'object' ? parsed.lastEmotion : (typeof parsed.lastEmotion === 'string' ? { kind: parsed.lastEmotion, intensity: 0 } : initial.lastEmotion),
      currentSessionStart: typeof parsed.currentSessionStart === 'string' ? parsed.currentSessionStart : null,
      relationshipStage: typeof parsed.relationshipStage === 'string' ? parsed.relationshipStage : initial.relationshipStage,
      turns: Array.isArray(parsed.turns) ? parsed.turns.map(sanitizeTurn).filter(Boolean) : [],
      memories: Array.isArray(parsed.memories) ? parsed.memories.map(sanitizeMemory).filter(Boolean) : [],
      companionshipStyle: typeof parsed.companionshipStyle === 'string' ? parsed.companionshipStyle : initial.companionshipStyle,
      sleepTime: typeof parsed.sleepTime === 'string' ? parsed.sleepTime : initial.sleepTime,
      userName: typeof parsed.userName === 'string' ? parsed.userName : initial.userName,
      dailyConversations: dailyConversations.map(sanitizeDailyConversation).filter(Boolean),
      activeConversationDate: typeof parsed.activeConversationDate === 'string' ? parsed.activeConversationDate : ''
    };
  } catch {
    return createInitialState(userId);
  }
}

export function saveBrowserState(storage, state) {
  storage.setItem('qiyu.state', JSON.stringify(state));
}
