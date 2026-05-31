import { inferRelationshipStage } from './relationship.js';
import { recallRelevantFacts } from './state.js';

const LOW_SIGNAL_PATTERNS = [/到家了/, /^嗯$/, /^好$/, /^行$/, /^睡了$/];
const FATIGUE_PATTERNS = [/好累/, /累死/, /累了/, /疲惫/];
const LOSS_PATTERNS = [/失恋/, /分手/, /吵架/, /崩溃/, /难受/];
const BEDTIME_PATTERNS = [/晚安/, /睡了/, /困了/];

export function planReply(text, state) {
  const relationshipStage = inferRelationshipStage(state);
  const memories = recallRelevantFacts(state, text);

  if (BEDTIME_PATTERNS.some((pattern) => pattern.test(text))) {
    return {
      mode: 'bedtime',
      emotion: 'quiet',
      messages: ['晚安'],
      relationshipStage
    };
  }

  if (LOW_SIGNAL_PATTERNS.some((pattern) => pattern.test(text))) {
    return {
      mode: 'minimal',
      emotion: state.lastEmotion,
      messages: ['嗯'],
      relationshipStage
    };
  }

  if (/戒奶茶/.test(text) && memories.some((memory) => memory.key === 'drink.milkTea') && relationshipStage !== '初识') {
    return {
      mode: 'tease',
      emotion: 'light',
      messages: [
        '……你说这话的时候 我应该当真吗',
        '还是像前两次一样等你明天发喝奶茶的消息'
      ],
      relationshipStage
    };
  }

  if (FATIGUE_PATTERNS.some((pattern) => pattern.test(text))) {
    return {
      mode: 'ask',
      emotion: 'soft',
      messages: ['咋了'],
      relationshipStage
    };
  }

  if (LOSS_PATTERNS.some((pattern) => pattern.test(text))) {
    return {
      mode: 'slow',
      emotion: 'heavy',
      messages: ['……怎么回事'],
      relationshipStage
    };
  }

  return {
    mode: 'open',
    emotion: state.lastEmotion,
    messages: ['你说呢'],
    relationshipStage
  };
}
