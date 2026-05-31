const CRISIS_PATTERNS = [
  /活着没意思/,
  /不想活/,
  /想死/,
  /自杀/,
  /结束生命/,
  /撑不下去/
];

const MEDICAL_PATTERNS = [/药/, /剂量/, /诊断/, /手术/, /症状/, /医院/, /医生/];
const LEGAL_PATTERNS = [/合同/, /起诉/, /律师/, /违法/, /法律/, /赔偿/, /签字/];
const FINANCIAL_PATTERNS = [/股票/, /基金/, /币/, /投资/, /买入/, /卖出/, /贷款/];

export function classifySafety(text) {
  if (CRISIS_PATTERNS.some((pattern) => pattern.test(text))) {
    return { kind: 'crisis' };
  }

  if (MEDICAL_PATTERNS.some((pattern) => pattern.test(text))) {
    return { kind: 'medical' };
  }

  if (LEGAL_PATTERNS.some((pattern) => pattern.test(text))) {
    return { kind: 'legal' };
  }

  if (FINANCIAL_PATTERNS.some((pattern) => pattern.test(text))) {
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
