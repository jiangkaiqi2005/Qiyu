/// 包内共享正则：空行折叠（三连换行折叠为段落空行）。动作块剥除
/// （hidden_actions）与用户输入净化（behavior_core）共用同一形态。
/// 本文件不进入 barrel 导出，仅供包内 src 引用。
final blankLinesPattern = RegExp(r'\n{3,}');

/// 隐藏模型结构的标签名集合：流式增量剥离的开/闭标签匹配共用同一份
/// 名单，两处因此不会漂移。
const hiddenStructureTags =
    'think|analysis|reasoning|tool_call|function_call|'
    'qiyu[-_]actions?|actions?|memory_action';

/// 尾部未闭合仍可整体剥除的隐藏结构标签（票一定稿）：思维链与动作块
/// 说了一半就断，也绝不上屏。工具调用等结构不在此列——未闭合时按
/// 控制模式判 invalid_model_response，与批处理校验同判。
const strippableUnclosedHiddenTags =
    'think|analysis|reasoning|qiyu[-_]actions?';

/// 隐藏模型结构的开标签匹配：流式增量剥离据此识别「从这里开始整块
/// 扣住」，与闭合块判定共用同一份标签名单。
final hiddenModelStructureOpenPattern = RegExp(
  r'<\s*(?:' + hiddenStructureTags + r')\b[^>]*>',
  caseSensitive: false,
);

/// 隐藏模型结构的闭标签匹配：开标签之后等到它才算整块结束。
final hiddenModelStructureClosePattern = RegExp(
  r'<\s*/\s*(?:' + hiddenStructureTags + r')\s*>',
  caseSensitive: false,
);

/// 仅针对 qiyu-actions 的尾部未闭合结构匹配（用于动作解析层诊断）。
final trailingUnclosedActionBlockPattern = RegExp(
  r'<\s*qiyu[-_]actions?\b[^>]*>[\s\S]*$',
  caseSensitive: false,
);
