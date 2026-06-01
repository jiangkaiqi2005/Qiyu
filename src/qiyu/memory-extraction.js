import { rememberUserFact } from './state.js';

const FACT_EXTRACTORS = [
  {
    pattern: /杨枝甘露|奶茶/,
    key: 'drink.milkTea',
    getValue: (text) => text.includes('戒奶茶') ? '说要戒奶茶' : '提到奶茶或杨枝甘露'
  },
  {
    pattern: /咖啡/,
    key: 'drink.coffee',
    getValue: () => '提到咖啡'
  },
  {
    pattern: /加班|上班|工作|同事|领导|老板|项目/,
    key: 'work.general',
    getValue: () => '提到工作或加班'
  },
  {
    pattern: /妈|爸|家人|家里|父母/,
    key: 'family.general',
    getValue: () => '提到家人或父母'
  },
  {
    pattern: /失眠|熬夜|睡不着/,
    key: 'sleep.pattern',
    getValue: () => '提到睡眠问题或熬夜'
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
      source: text
    });
  }, state);
}
