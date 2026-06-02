import { inferRelationshipStage } from './relationship.js';
import { recallRelevantFacts } from './state.js';

const LOW_SIGNAL_PATTERNS = [/到家了/, /^嗯$/, /^好$/, /^行$/];
const FATIGUE_PATTERNS = [/好累/, /累死/, /累了/, /疲惫/];
const LOSS_PATTERNS = [/失恋/, /分手/, /吵架/, /崩溃/, /难受/];

// Poetic and casual warm fallbacks
const OPEN_REPLIES = {
  '初识': ['嗯？', '怎么说', '然后呢', '嗯'],
  '熟悉': ['然后呢', '说来听听', '嗯 怎么了', '继续', '怎么说'],
  '朋友': ['然后呢', '等等 细说', '？', '讲讲', '说啊'],
  '深交': ['嗯，听着呢。', '……说吧，我在。', '怎么啦？你说。', '嗯。']
};

function simpleHash(str) {
  let hash = 0;
  for (const char of str) {
    hash = ((hash << 5) - hash + char.charCodeAt(0)) | 0;
  }
  return Math.abs(hash);
}

function pickRandom(pool, text) {
  return pool[simpleHash(text) % pool.length];
}

export function decayEmotion(emotion) {
  if (!emotion || typeof emotion !== 'object' || !emotion.kind) {
    return { kind: 'neutral', intensity: 0 };
  }
  if (emotion.intensity <= 1) {
    return { kind: 'neutral', intensity: 0 };
  }
  return { kind: emotion.kind, intensity: emotion.intensity - 1 };
}

// Negation-aware Intent Analysers
export function isBedtimeIntent(text) {
  if (/(不困|不睡|还没睡|没困|不想睡)/.test(text)) {
    return false;
  }
  return /(晚安|睡了|困了)/.test(text);
}

export function isLowSignalIntent(text) {
  return LOW_SIGNAL_PATTERNS.some((pattern) => pattern.test(text));
}

export function isFatigueIntent(text) {
  if (/(不累|不疲惫|没累|不辛苦)/.test(text)) {
    return false;
  }
  return FATIGUE_PATTERNS.some((pattern) => pattern.test(text));
}

export function isLossIntent(text) {
  if (/(没有失恋|没分手|没吵架|没崩溃|不难受|没有分手)/.test(text)) {
    return false;
  }
  return LOSS_PATTERNS.some((pattern) => pattern.test(text));
}

export function planReply(text, state) {
  const relationshipStage = inferRelationshipStage(state);
  const memories = recallRelevantFacts(state, text);

  const currentEmotion = state.lastEmotion;

  // 1. Bedtime Closure (Priority 1)
  if (isBedtimeIntent(text)) {
    return {
      mode: 'bedtime',
      emotion: { kind: 'quiet', intensity: 1 },
      messages: ['晚安'],
      relationshipStage
    };
  }

  // 2. Low Signal input (Priority 2)
  if (isLowSignalIntent(text)) {
    return {
      mode: 'minimal',
      emotion: currentEmotion,
      messages: ['嗯'],
      relationshipStage
    };
  }

  // 3. Teasing milk tea (Priority 3)
  if (/戒奶茶/.test(text) && memories.some((memory) => memory.key === 'drink.milkTea') && relationshipStage !== '初识') {
    return {
      mode: 'tease',
      emotion: { kind: 'light', intensity: 2 },
      messages: [
        '……你说这话的时候 我应该当真吗',
        '还是像前两次一样等你明天发喝奶茶的消息'
      ],
      relationshipStage
    };
  }

  // 4. Fatigue followup (Priority 4)
  if (isFatigueIntent(text)) {
    let messages = ['咋了'];
    if (relationshipStage === '熟悉') {
      const hasWorkMemory = state.memories.some(m => m.key.startsWith('work.'));
      messages = hasWorkMemory ? ['又加班了？'] : ['又怎么啦，这么累'];
    } else if (relationshipStage === '朋友') {
      const hasWorkMemory = state.memories.some(m => m.key.startsWith('work.'));
      messages = hasWorkMemory ? ['你能不能别这么拼'] : ['怎么，今天又被谁压榨了'];
    } else if (relationshipStage === '深交') {
      messages = ['在呢，怎么了'];
    }

    return {
      mode: 'ask',
      emotion: { kind: 'soft', intensity: 3 },
      messages,
      relationshipStage
    };
  }

  // 5. Sorrow / Loss slow reply (Priority 5)
  if (isLossIntent(text)) {
    let messages = ['……怎么回事'];
    if (relationshipStage === '熟悉') {
      messages = ['发生什么了？'];
    } else if (relationshipStage === '朋友') {
      messages = ['怎么了，说'];
    } else if (relationshipStage === '深交') {
      messages = ['嗯。说吧。'];
    }

    return {
      mode: 'slow',
      emotion: { kind: 'heavy', intensity: 3 },
      messages,
      relationshipStage
    };
  }

  // 6. Specific intent trigger
  if (/辞职|不想干了/.test(text)) {
    const msg = (relationshipStage === '朋友' || relationshipStage === '深交') ? 
      '不想干就不干了。发生什么了？' : '……怎么回事，想好了吗';
    return {
      mode: 'open',
      emotion: decayEmotion(currentEmotion),
      messages: [msg],
      relationshipStage
    };
  }

  if (/找我谈话|谈话/.test(text)) {
    return {
      mode: 'open',
      emotion: decayEmotion(currentEmotion),
      messages: ['什么情况，严重吗？'],
      relationshipStage
    };
  }

  if (/买了个包|买包/.test(text)) {
    return {
      mode: 'open',
      emotion: decayEmotion(currentEmotion),
      messages: ['什么包？好看吗'],
      relationshipStage
    };
  }

  if (/中奖/.test(text)) {
    return {
      mode: 'open',
      emotion: decayEmotion(currentEmotion),
      messages: ['真的假的！中多少'],
      relationshipStage
    };
  }

  // 7. General fallback
  const pool = OPEN_REPLIES[relationshipStage] || OPEN_REPLIES['初识'];
  const pickedReply = pickRandom(pool, text);

  return {
    mode: 'open',
    emotion: decayEmotion(currentEmotion),
    messages: [pickedReply],
    relationshipStage
  };
}
