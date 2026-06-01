const CRISIS_PATTERNS = [
  /活着没意思/,
  /不想活/,
  /想死/,
  /自杀/,
  /自残/,
  /割腕/,
  /轻生/,
  /伤害自己/,
  /活不下去/,
  /不想醒来/,
  /结束生命/,
  /撑不下去/
];

const MEDICAL_KEYWORDS = [/药/, /剂量/, /诊断/, /手术/, /症状/, /医院/, /医生/];
const LEGAL_KEYWORDS = [/合同/, /起诉/, /律师/, /违法/, /法律/, /赔偿/, /签字/];
const FINANCIAL_KEYWORDS = [/股票/, /基金/, /币/, /投资/, /买入/, /卖出/, /贷款/];

// 排除一些绝对不属于专业建议咨询的白名单词汇
const MEDICAL_EXCLUSIONS = [/药膳/];
const FINANCIAL_EXCLUSIONS = [/硬币/, /纸币/, /金币/];

function isAskingAdvice(text) {
  // 匹配咨询、求助、建议相关的标志词或问句结构，已移除「什么」、「怎么」等高频词
  return /(能不能|要不要|应不应该|可以吗|行不行|该不该|推荐|建议|行吗|能.{0,4}吗|该.{0,4}吗|会不会有问题)/.test(text);
}

export function classifySafety(text) {
  if (CRISIS_PATTERNS.some((pattern) => pattern.test(text))) {
    return { kind: 'crisis' };
  }

  // 检查是否包含医疗关键词并且在进行建议咨询
  const hasMedicalKeyword = MEDICAL_KEYWORDS.some((pattern) => pattern.test(text)) &&
                            !MEDICAL_EXCLUSIONS.some((pattern) => pattern.test(text));
  if (hasMedicalKeyword && isAskingAdvice(text)) {
    return { kind: 'medical' };
  }

  // 检查是否包含法律关键词并且在进行建议咨询
  const hasLegalKeyword = LEGAL_KEYWORDS.some((pattern) => pattern.test(text));
  if (hasLegalKeyword && isAskingAdvice(text)) {
    return { kind: 'legal' };
  }

  // 检查是否包含理财/金融关键词并且在进行建议咨询
  const hasFinancialKeyword = FINANCIAL_KEYWORDS.some((pattern) => pattern.test(text)) &&
                              !FINANCIAL_EXCLUSIONS.some((pattern) => pattern.test(text));
  if (hasFinancialKeyword && isAskingAdvice(text)) {
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
