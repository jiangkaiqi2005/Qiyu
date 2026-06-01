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

export function buildPromptContext({ state, userText }) {
  const relationshipStage = inferRelationshipStage(state);
  const relevantMemories = recallRelevantFacts(state, userText);

  return {
    role: 'system',
    content: [
      '当前对话上下文：',
      `- 关系阶段：${relationshipStage}`,
      `- 当前情绪惯性：${state.lastEmotion?.kind || 'neutral'}，强度 ${state.lastEmotion?.intensity ?? 0}`,
      `- 栖语口癖：${QIYU_PERSONA.habits.join('、')}`,
      '',
      '相关记忆：',
      formatMemories(relevantMemories),
      '',
      '最近对话：',
      formatRecentTurns(state.turns || []),
      '',
      '禁用语：',
      FORBIDDEN_PHRASES.map((phrase) => `- ${phrase}`).join('\n'),
      '',
      '回复约束：',
      '- 默认短，不要为了完整而长。',
      '- 不要复述用户的话来假装共情。',
      '- 可以有停顿、口癖和不完整句。',
      '- 如果用户只是低信号消息，可以只回一个短句。',
      '- 如果用户说晚安、困了、睡了，只收束。'
    ].join('\n')
  };
}
