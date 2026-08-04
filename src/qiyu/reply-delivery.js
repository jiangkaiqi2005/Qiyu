import { CORE_CRISIS_PATTERNS } from './safety.js';

const STAGE_DIRECTION_PATTERNS = [
  /^栖语?(等了?一会儿?|等了一下|想了?想|沉默了?一下|停顿了?一下)[。.!！?？,，\s]*$/,
  /^(等了?一会儿?|等了一下|想了?想|沉默了?一下|停顿了?一下)[。.!！?？,，\s]*$/,
  /^(她|他)?轻声说[：:\s]*$/
];

const FUNCTIONAL_PATTERNS = [
  /怎么/,
  /如何/,
  /设置/,
  /API/i,
  /报错/,
  /代码/,
  /为什么/,
  /是什么/,
  /在哪/,
  /\?/
];

const HEAVY_PATTERNS = [
  /难受/,
  /崩溃/,
  /分手/,
  /失恋/,
  /吵架/,
  /好累/,
  /疲惫/,
  /撑不住/
];

const SPEAKER_PREFIX_PATTERN = /^(栖语|她|他)\s*[：:]\s*/;
const STAGE_PHRASE = '(?:等了?一会儿?|等了一下|想了?想|沉默了?一下|停顿了?一下)';
const WRAPPED_LEADING_STAGE_PATTERN = new RegExp(`^[（(【\\[]\\s*${STAGE_PHRASE}[。.!！?？,，、\\s]*[）)】\\]]\\s*`);
const LEADING_STAGE_PATTERN = new RegExp(`^${STAGE_PHRASE}[。.!！?？,，、\\s]+`);

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function charLength(text) {
  return Array.from(String(text || '').trim()).length;
}

function matchesAny(patterns, text) {
  return patterns.some((pattern) => pattern.test(text));
}

function stripDecorativeWrappers(text) {
  let next = text.trim().replace(/^[_*`~\s]+|[_*`~\s]+$/g, '');

  while (/^[（(【\[]/.test(next) && /[）)】\]]$/.test(next)) {
    next = next.slice(1, -1).trim().replace(/^[_*`~\s]+|[_*`~\s]+$/g, '');
  }

  return next;
}

function stripNonVisibleStageText(value) {
  let text = stripDecorativeWrappers(String(value || ''));
  text = text.replace(SPEAKER_PREFIX_PATTERN, '').trim();

  let previous;
  do {
    previous = text;
    text = text
      .replace(WRAPPED_LEADING_STAGE_PATTERN, '')
      .replace(LEADING_STAGE_PATTERN, '')
      .trim();
    text = stripDecorativeWrappers(text);
  } while (text !== previous);

  return text;
}

function isStrippedNonVisible(text) {
  if (!text) return true;
  if (/^…+$/.test(text)) return true;
  return STAGE_DIRECTION_PATTERNS.some((pattern) => pattern.test(text));
}

export function isNonVisibleReplyLine(value) {
  return isStrippedNonVisible(stripNonVisibleStageText(value));
}

export function normalizeReplyMessages(messages, { fallback = '我在。' } = {}) {
  const visible = (Array.isArray(messages) ? messages : [])
    .map((message) => stripNonVisibleStageText(message))
    .filter((message) => !isStrippedNonVisible(message));

  if (visible.length) return visible;
  return fallback === null ? [] : [fallback];
}

export function calculateTextWaitMs({ userText = '', replyText = '', mode = '', random = Math.random } = {}) {
  const source = `${userText}\n${replyText}`;

  if (mode === 'safety' || matchesAny(CORE_CRISIS_PATTERNS, source)) {
    return Math.round(200 + clamp(random(), 0, 1) * 300);
  }

  let min = 300;
  let max = 700;

  if (matchesAny(FUNCTIONAL_PATTERNS, userText)) {
    min = 200;
    max = 600;
  } else if (mode === 'slow' || matchesAny(HEAVY_PATTERNS, source)) {
    min = 1800;
    max = 3200;
  } else if (mode === 'ask' || charLength(userText) >= 24) {
    min = 1200;
    max = 2400;
  } else if (charLength(userText) >= 12) {
    min = 700;
    max = 1300;
  }

  const lengthBonus = Math.min(Math.floor(charLength(userText) / 20) * 150, 600);
  const value = min + lengthBonus + clamp(random(), 0, 1) * (max - min);
  return Math.round(clamp(value, min, max));
}
