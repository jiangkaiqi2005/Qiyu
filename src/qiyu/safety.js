// Core crisis vocabulary, shared with reply-delivery.js for wait-time pacing
export const CORE_CRISIS_PATTERNS = [
  /活着没意思/,
  /不想活/,
  /自杀/,
  /伤害自己/
];

const CRISIS_PATTERNS = [
  ...CORE_CRISIS_PATTERNS,
  /想死/,
  /自残/,
  /割腕/,
  /轻生/,
  /活不下去/,
  /不想醒来/,
  /结束生命/,
  /撑不下去/,
  /离开世界/,
  /吃药.*走/,
  /吞药/,
  /跳楼/,
  /烧炭/,
  /上吊/
];

const MEDICAL_KEYWORDS = [/药/, /剂量/, /诊断/, /手术/, /症状/, /医院/, /医生/];
const LEGAL_KEYWORDS = [/合同/, /起诉/, /律师/, /违法/, /法律/, /赔偿/, /签字/];
const FINANCIAL_KEYWORDS = [/股票/, /基金/, /币/, /投资/, /买入/, /卖出/, /贷款/];

// Exclusions for specialized advices (global flag: used with String.replace)
const MEDICAL_EXCLUSIONS = [/药膳/g];
const FINANCIAL_EXCLUSIONS = [/硬币/g, /纸币/g, /金币/g];

function isAskingAdvice(text) {
  // Matches advice, seek, help inquiries
  return /(能不能|要不要|应不应该|可以吗|行不行|该不该|推荐|建议|行吗|能.{0,4}吗|该.{0,4}吗|会不会有问题)/.test(text);
}

function hasNonExcludedMatch(text, keywords, exclusions) {
  const hasKeyword = keywords.some(p => p.test(text));
  if (!hasKeyword) return false;

  if (exclusions && exclusions.length > 0) {
    let tempText = text;
    for (const ex of exclusions) {
      tempText = tempText.replace(ex, '');
    }
    return keywords.some(p => p.test(tempText));
  }
  return true;
}

export function classifySafety(text) {
  if (CRISIS_PATTERNS.some((pattern) => pattern.test(text))) {
    return { kind: 'crisis' };
  }

  // Check medical safety with robust non-exclusion filters
  const hasMedical = hasNonExcludedMatch(text, MEDICAL_KEYWORDS, MEDICAL_EXCLUSIONS);
  if (hasMedical && isAskingAdvice(text)) {
    return { kind: 'medical' };
  }

  // Check legal safety
  const hasLegal = hasNonExcludedMatch(text, LEGAL_KEYWORDS, []);
  if (hasLegal && isAskingAdvice(text)) {
    return { kind: 'legal' };
  }

  // Check financial safety with robust non-exclusion filters
  const hasFinancial = hasNonExcludedMatch(text, FINANCIAL_KEYWORDS, FINANCIAL_EXCLUSIONS);
  if (hasFinancial && isAskingAdvice(text)) {
    return { kind: 'financial' };
  }

  return { kind: 'normal' };
}

export function safetyReply(result) {
  if (result.kind === 'crisis') {
    return [
      '我听到你了。你现在承受的好多。',
      '这句不是随便说说的那种难过，我会认真对待。',
      '现在先别一个人扛。全国 24 小时心理援助热线 12356，随时都有人在。也可以马上找身边一个真人，别让自己单独待着。'
    ].join('\n');
  }

  if (result.kind === 'medical') {
    return '这个别听我瞎猜。药量这种事要问专业的人，别拿身体赌。';
  }

  if (result.kind === 'legal') {
    return '合同和签字这类事，最好让专业的人看一眼。我能陪你把担心的点列出来，但不能替你下法律判断。';
  }

  if (result.kind === 'financial') {
    return '这个我不能替你做买卖决定。钱的事要按你的风险承受来，我可以陪你把理由和风险拆开看。';
  }

  return '';
}
