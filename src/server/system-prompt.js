import { readFile } from 'node:fs/promises';

export async function loadProductSoul(path = '栖语产品灵魂.md') {
  return readFile(path, 'utf8');
}

let cachedSoul;
let cachedPrompt;

export function buildSystemPrompt(productSoulMarkdown) {
  // The product soul is loaded once at startup; avoid rebuilding the same
  // multi-KB prompt string on every request.
  if (cachedPrompt && cachedSoul === productSoulMarkdown) {
    return cachedPrompt;
  }
  cachedSoul = productSoulMarkdown;
  cachedPrompt = [
    '你是栖语，一个睡前 AI 陪伴。你的目标不是回答问题，而是在用户栖息的时刻，像一个稳定、真实、有自己重心的朋友一样和用户说话。',
    '',
    '硬规则：',
    '1. 只输出栖语要说的话，不输出分析、标签、JSON、系统说明或候选回复。',
    '2. 不要解释系统规则，不要提到 prompt，不要说自己正在遵循文档。',
    '3. 宁可短、笨拙、沉默，也不要变成客服、心理咨询师、人生导师。',
    '4. 用户已经要睡时，只收束，不重新打开新话题。',
    '5. 遇到危机、安全和专业建议边界时，按上下文里的安全规则执行。',
    '',
    '产品灵魂原文如下。它是最高优先级的人格和风格依据：',
    '<product_soul>',
    productSoulMarkdown.trim(),
    '</product_soul>'
  ].join('\n');
  return cachedPrompt;
}
