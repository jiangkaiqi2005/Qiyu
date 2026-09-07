/// 包内共享正则：空行折叠（三连换行折叠为段落空行）。动作块剥除
/// （hidden_actions）与用户输入净化（behavior_core）共用同一形态。
/// 本文件不进入 barrel 导出，仅供包内 src 引用。
final blankLinesPattern = RegExp(r'\n{3,}');

/// 闭合隐藏模型结构匹配（`<tag>...</tag>`）。覆盖思维链、模型工具调用与动作块。
final hiddenModelStructurePattern = RegExp(
  r'<\s*(?:think|analysis|reasoning|tool_call|function_call|qiyu[-_]actions?|actions?|memory_action)\b[^>]*>[\s\S]*?<\s*/\s*(?:think|analysis|reasoning|tool_call|function_call|qiyu[-_]actions?|actions?|memory_action)\s*>',
  caseSensitive: false,
);

/// 尾部未闭合的隐藏结构匹配（直到文本末尾）：覆盖常见思维链（think/analysis/reasoning）
/// 与动作块（qiyu-actions）。工具调用等结构由模型控制规则统一判定为 invalidModelResponse。
final trailingUnclosedHiddenStructurePattern = RegExp(
  r'<\s*(?:think|analysis|reasoning|qiyu[-_]actions?)\b[^>]*>[\s\S]*$',
  caseSensitive: false,
);

/// 仅针对 qiyu-actions 的尾部未闭合结构匹配（用于动作解析层诊断）。
final trailingUnclosedActionBlockPattern = RegExp(
  r'<\s*qiyu[-_]actions?\b[^>]*>[\s\S]*$',
  caseSensitive: false,
);

/// 剥除候选回复中的所有隐藏模型结构（含闭合与尾部未闭合）。
String stripHiddenStructures(String text) {
  return text
      .replaceAll(hiddenModelStructurePattern, '')
      .replaceFirst(trailingUnclosedHiddenStructurePattern, '');
}

