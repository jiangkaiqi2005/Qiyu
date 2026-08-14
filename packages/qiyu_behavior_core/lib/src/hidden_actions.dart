import 'dart:convert';

/// 伪 Agent 隐藏动作白名单。模型只能在回复之外提出这三类动作，
/// 任何其它动作名一律丢弃并记入诊断。
enum HiddenActionKind {
  memorySignal('memory_signal'),
  memoryRecall('memory_recall'),
  noAction('no_action');

  const HiddenActionKind(this.wireName);

  final String wireName;

  static HiddenActionKind? tryParseWireName(String value) {
    for (final kind in values) {
      if (kind.wireName == value) {
        return kind;
      }
    }
    return null;
  }
}

/// 单条隐藏动作在可见回复中的最大数量。超出部分直接丢弃。
const maxHiddenActionsPerReply = 2;

/// memory_signal 的摘要与原话摘录长度上限（runes）。
const maxHiddenSummaryRunes = 120;
const maxHiddenEvidenceRunes = 200;

/// memory_recall 的检索意图长度上限（runes）。
const maxHiddenQueryRunes = 100;

/// 动作诊断码：只进入本机诊断，绝不展示给用户。
class HiddenActionDiagnostics {
  static const invalidFormat = 'hidden_action_invalid_format';
  static const unknownAction = 'hidden_action_unknown';
  static const invalidFields = 'hidden_action_invalid_fields';
  static const sensitiveContent = 'hidden_action_sensitive';
  static const privilegeViolation = 'hidden_action_privilege';
  static const overLimit = 'hidden_action_over_limit';
  static const multipleBlocks = 'hidden_action_multiple_blocks';
}

final class HiddenAction {
  const HiddenAction({
    required this.kind,
    this.summary,
    this.evidence,
    this.query,
  });

  final HiddenActionKind kind;
  final String? summary;
  final String? evidence;
  final String? query;

  Map<String, Object?> toJson() => {
    'action': kind.wireName,
    if (summary != null) 'summary': summary,
    if (evidence != null) 'evidence': evidence,
    if (query != null) 'query': query,
  };

  @override
  bool operator ==(Object other) =>
      other is HiddenAction &&
      other.kind == kind &&
      other.summary == summary &&
      other.evidence == evidence &&
      other.query == query;

  @override
  int get hashCode => Object.hash(kind, summary, evidence, query);
}

final class HiddenActionParse {
  HiddenActionParse({
    required this.visibleText,
    required List<HiddenAction> actions,
    required List<String> diagnostics,
  }) : actions = List.unmodifiable(actions),
       diagnostics = List.unmodifiable(diagnostics);

  final String visibleText;
  final List<HiddenAction> actions;
  final List<String> diagnostics;
}

final _hiddenActionBlock = RegExp(
  r'<\s*qiyu[-_]actions?\s*>([\s\S]*?)<\s*/\s*qiyu[-_]actions?\s*>',
  caseSensitive: false,
);

/// 越权内容特征：路径、URL、命令分隔、可执行结构。动作字段只能描述
/// 对话内容本身，命中任一特征的动作整体丢弃。
final _privilegePatterns = [
  RegExp(r'(?:https?|file|ftp)://', caseSensitive: false),
  RegExp(r'[A-Za-z]:\\'),
  RegExp(r'(?:^|\s)/(?:etc|usr|bin|tmp|proc|home|Users|var)(?:/|\s|$)'),
  RegExp(r'[;|&`]|&&|\|\|'),
  RegExp(r'\b(?:exec|powershell|cmd\.exe|bash|sh -c)\b', caseSensitive: false),
];

/// 秘密特征：命中即不允许提升为记忆。与 sessions 脱敏规则保持一致的
/// 保守集合，覆盖密码、Key、令牌、验证码、私钥、证件与银行卡号。
final _secretPatterns = [
  RegExp(r'sk-[A-Za-z0-9_-]{16,}', caseSensitive: false),
  RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
  RegExp(
    r'(?:api[_ -]?key|token|cookie|password|密码|口令|私钥|密钥)\s*[:=：]\s*[^\s；;，,]+',
    caseSensitive: false,
  ),
  RegExp(r'(?:验证码|otp|verification code)\s*[:=：]?\s*\d{4,8}', caseSensitive: false),
  RegExp(r'(?<!\d)\d{17}[\dXx](?!\d)'),
  RegExp(r'(?<!\d)(?:\d[ -]?){15,18}\d(?!\d)'),
  RegExp(
    r'-----BEGIN [^-]+ PRIVATE KEY-----[\s\S]*?-----END [^-]+ PRIVATE KEY-----',
    caseSensitive: false,
  ),
];

/// 从模型原始输出中分离隐藏动作块与用户可见文本。
/// 解析失败、未知动作或越权字段只被忽略并记录诊断，绝不进入可见回复。
HiddenActionParse parseHiddenActions(String rawText) {
  final blocks = _hiddenActionBlock.allMatches(rawText).toList();
  final visibleText = rawText
      .replaceAll(_hiddenActionBlock, '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  if (blocks.isEmpty) {
    return HiddenActionParse(
      visibleText: visibleText,
      actions: const [],
      diagnostics: const [],
    );
  }

  final diagnostics = <String>[];
  if (blocks.length > 1) {
    diagnostics.add(HiddenActionDiagnostics.multipleBlocks);
  }

  final actions = <HiddenAction>[];
  Object? decoded;
  try {
    decoded = jsonDecode(blocks.first.group(1)!.trim());
  } on Object {
    diagnostics.add(HiddenActionDiagnostics.invalidFormat);
    return HiddenActionParse(
      visibleText: visibleText,
      actions: const [],
      diagnostics: diagnostics,
    );
  }
  final items = switch (decoded) {
    final List<Object?> list => list,
    final Map<String, Object?> map => <Object?>[map],
    _ => null,
  };
  if (items == null) {
    diagnostics.add(HiddenActionDiagnostics.invalidFormat);
    return HiddenActionParse(
      visibleText: visibleText,
      actions: const [],
      diagnostics: diagnostics,
    );
  }

  for (final item in items) {
    if (actions.length >= maxHiddenActionsPerReply) {
      diagnostics.add(HiddenActionDiagnostics.overLimit);
      break;
    }
    if (item is! Map<String, Object?>) {
      diagnostics.add(HiddenActionDiagnostics.invalidFields);
      continue;
    }
    final action = _validateAction(item, diagnostics);
    if (action != null) {
      actions.add(action);
    }
  }

  return HiddenActionParse(
    visibleText: visibleText,
    actions: actions,
    diagnostics: diagnostics,
  );
}

HiddenAction? _validateAction(
  Map<String, Object?> item,
  List<String> diagnostics,
) {
  final actionName = item['action'];
  if (actionName is! String) {
    diagnostics.add(HiddenActionDiagnostics.invalidFields);
    return null;
  }
  final kind = HiddenActionKind.tryParseWireName(actionName.trim());
  if (kind == null) {
    diagnostics.add(HiddenActionDiagnostics.unknownAction);
    return null;
  }

  switch (kind) {
    case HiddenActionKind.memorySignal:
      final summary = _cleanFieldValue(item['summary']);
      final evidence = _cleanFieldValue(item['evidence']);
      if (summary == null || summary.runes.length > maxHiddenSummaryRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      if (evidence != null && evidence.runes.length > maxHiddenEvidenceRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      if (_violatesPrivilege(summary) ||
          (evidence != null && _violatesPrivilege(evidence))) {
        diagnostics.add(HiddenActionDiagnostics.privilegeViolation);
        return null;
      }
      if (_containsSecret(summary) ||
          (evidence != null && _containsSecret(evidence))) {
        diagnostics.add(HiddenActionDiagnostics.sensitiveContent);
        return null;
      }
      return HiddenAction(kind: kind, summary: summary, evidence: evidence);
    case HiddenActionKind.memoryRecall:
      final query = _cleanFieldValue(item['query']);
      if (query == null || query.runes.length > maxHiddenQueryRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      if (_violatesPrivilege(query) || _containsSecret(query)) {
        diagnostics.add(HiddenActionDiagnostics.privilegeViolation);
        return null;
      }
      return HiddenAction(kind: kind, query: query);
    case HiddenActionKind.noAction:
      return HiddenAction(kind: kind);
  }
}

String? _cleanFieldValue(Object? value) {
  if (value is! String) {
    return null;
  }
  final trimmed = value
      .split('\n')
      .map((line) => line.trim())
      .join(' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool _violatesPrivilege(String value) =>
    _privilegePatterns.any((pattern) => pattern.hasMatch(value));

bool _containsSecret(String value) =>
    _secretPatterns.any((pattern) => pattern.hasMatch(value));
