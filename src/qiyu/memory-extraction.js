import { rememberUserFact } from './state.js';

const FACT_EXTRACTORS = [
  {
    pattern: /杨枝甘露|奶茶/,
    key: 'drink.milkTea',
    category: 'preference',
    sensitiveLevel: 0,
    getValue: (text) => text.includes('戒奶茶') ? '说要戒奶茶' : '提到奶茶或杨枝甘露'
  },
  {
    pattern: /咖啡/,
    key: 'drink.coffee',
    category: 'preference',
    sensitiveLevel: 0,
    getValue: () => '提到咖啡'
  },
  {
    pattern: /加班|上班|工作|同事|领导|老板|项目/,
    key: 'work.general',
    category: 'work',
    sensitiveLevel: 0,
    getValue: () => '提到工作或加班'
  },
  {
    pattern: /妈|爸|家人|家里|父母/,
    key: 'family.general',
    category: 'family',
    sensitiveLevel: 0,
    getValue: () => '提到家人或父母'
  },
  {
    pattern: /失眠|熬夜|睡不着/,
    key: 'sleep.pattern',
    category: 'sleep',
    sensitiveLevel: 0,
    getValue: () => '提到睡眠问题或熬夜'
  },
  {
    pattern: /胃疼|头疼|感冒|发烧|生病|吃药|胃不舒服|身体不舒服|去医院/,
    key: 'health.status',
    category: 'health',
    sensitiveLevel: 0,
    getValue: () => '提到身体状况或生病'
  },
  {
    pattern: /难过|伤心|情绪低落|崩溃|开心|郁闷|烦躁|抑郁|难受|委屈/,
    key: 'emotion.status',
    category: 'emotion',
    sensitiveLevel: 0,
    getValue: () => '提到自身情绪状态'
  },
  {
    pattern: /密码|私密|密码是|身份证|账户|秘密/,
    key: 'security.secret',
    category: 'general',
    sensitiveLevel: 1, // Sensitive Level
    excludeFromContext: true, // Do not inject in context
    getValue: (text) => {
      // Partially mask text to protect raw secrets
      return '录入敏感私密数据: ' + text.replace(/.(?=.{2})/g, '*');
    }
  }
];

export function rememberFactsFromText(state, text) {
  return FACT_EXTRACTORS.reduce((nextState, extractor) => {
    if (!extractor.pattern.test(text)) {
      return nextState;
    }

    return rememberUserFact(nextState, {
      key: extractor.key,
      value: extractor.getValue(text),
      source: text,
      category: extractor.category,
      sensitiveLevel: extractor.sensitiveLevel || 0,
      excludeFromContext: extractor.excludeFromContext || false,
      originalText: text
    });
  }, state);
}
