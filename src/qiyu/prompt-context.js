import { FORBIDDEN_PHRASES, QIYU_PERSONA } from './persona.js';
import { inferRelationshipStage } from './relationship.js';
import { recallRelevantFacts } from './state.js';

function formatMemories(memories) {
  if (!memories.length) {
    return '- 暂无相关记忆。不要假装记得用户没有说过的事。';
  }

  return memories
    .map((memory) => `- ${memory.key}: ${memory.value}（来源：${memory.source}）`)
    .join('\n');
}

function formatRecentTurns(turns) {
  const recent = turns.slice(-8);
  if (!recent.length) {
    return '- 没有最近对话。';
  }

  return recent
    .map((turn) => `- ${turn.speaker === 'user' ? '用户' : '栖语'}：${turn.text}`)
    .join('\n');
}

export function buildPromptContext({ state, userText, includeHistory = true }) {
  const relationshipStage = inferRelationshipStage(state);
  let relevantMemories = recallRelevantFacts(state, userText);
  if (relevantMemories.length > 3) {
    relevantMemories = relevantMemories.slice(0, 3);
  }

  // Track memory usage in context
  relevantMemories.forEach(m => {
    m.useCount = (m.useCount || 0) + 1;
    m.lastUsedAt = new Date().toISOString();
  });

  const companionshipStyle = state.companionshipStyle || 'gentle';
  const companionshipStyleDesc = companionshipStyle === 'playful' 
    ? '轻松调侃（带着善意的幽默和轻度调侃，不改变睡前温和的关怀人格）' 
    : companionshipStyle === 'quiet' 
      ? '安静聆听（倾向于少言寡语，只在旁边默默守候，回复极其简短，允许适当沉默）' 
      : '温柔倾听（体贴倾听用户的疲惫，给予细腻、包容的回应）';

  const parts = [
    '当前对话上下文：',
    `- 关系阶段：${relationshipStage}`,
    `- 陪伴风格：${companionshipStyleDesc}`,
    `- 用户昵称：${state.userName || '你'}`,
    `- 当前情绪惯性：${state.lastEmotion?.kind || 'neutral'}，强度 ${state.lastEmotion?.intensity ?? 0}`,
    `- 栖语口癖：${QIYU_PERSONA.habits.join('、')}`,
    '',
    '相关记忆：',
    formatMemories(relevantMemories),
    ''
  ];

  if (includeHistory) {
    parts.push(
      '最近对话：',
      formatRecentTurns(state.turns || []),
      ''
    );
  }

  parts.push(
    '禁用语：',
    FORBIDDEN_PHRASES.map((phrase) => `- ${phrase}`).join('\n'),
    '',
    '回复约束：',
    '- 默认短，不要为了完整而长。',
    '- 不要复述用户的话来假装共情。',
    '- 可以有停顿、口癖和不完整句。',
    '- 如果用户只是低信号消息，可以只回一个短句。',
    '- 如果用户说晚安、困了、睡了，只收束。'
  );

  return {
    role: 'system',
    content: parts.join('\n')
  };
}
