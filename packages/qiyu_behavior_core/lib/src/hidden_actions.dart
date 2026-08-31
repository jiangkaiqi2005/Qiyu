import 'dart:convert';

/// 伪 Agent 隐藏动作白名单。模型只能在回复之外提出这些动作，
/// 任何其它动作名一律丢弃并记入诊断。
enum HiddenActionKind {
  memorySignal('memory_signal'),
  memoryRecall('memory_recall'),
  noAction('no_action'),

  /// 日终候选：模型认为本轮出现了真正未完、值得以后跟进的事项。
  /// 是否提升为正式 Open-loop 由 Host 在日终归档时校验决定。
  openLoopCandidate('open_loop_candidate'),

  /// Open-loop 状态变化：用户回复让某事项闭环、暂缓或重新活跃。
  openLoopStatus('open_loop_status'),

  /// 用户要求不再提及某事项：立即禁提，属于用户记忆控制。
  memoryBan('memory_ban'),

  /// 用户要求本轮内容不要进入记忆：当轮生效，不产生持久控制记录。
  memoryForget('memory_forget'),

  /// 用户要求冻结某内容：停止注入、检索与自动整理，保留可见原文，
  /// 只有用户明确解除才恢复。
  memoryFreeze('memory_freeze'),

  /// 用户明确解除冻结；解除后内容恢复正常参与注入与整理。
  memoryUnfreeze('memory_unfreeze'),

  /// 用户要求删除某记忆：先记录抽象防复活范围，再清除全部派生内容。
  memoryDelete('memory_delete'),

  /// 关系证据：深谈信号、温度变化、边界开合。对话中只落 episode，
  /// 日终归档才据此更新 relationship.md（阶段与温度）。
  relationshipSignal('relationship_signal');

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

/// memory_recall 选择字段的合法形态。选择数量不设上限（跨月跨年
/// 检索定稿）：Provider 输出预算天然约束块大小，Host 成员校验才是
/// 真正的闸门。
final _recallMonthPattern = RegExp(r'^\d{4}-\d{2}$');
final _recallDatePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// 动作块剥除后的空行折叠与字段内空白折叠。
final _blankLinesPattern = RegExp(r'\n{3,}');
final _fieldWhitespaceRunsPattern = RegExp(r'\s{2,}');

/// Open-loop 动作的字段长度上限（runes）。标题走 summary 字段，
/// 比 memory_signal 的摘要更短——事项名应当简短。
/// memory_ban/forget/freeze/unfreeze/delete 五个用户记忆控制动作的
/// summary 也按此限长。
const maxLoopTitleRunes = 60;
const maxLoopNoteRunes = 120;
const maxLoopResultRunes = 120;

/// due 的合法形态：日期 + 可选时段（中英文皆可，与日终解析一致）。
final _loopDuePattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}'
  r'(?: (?:早晨|上午|中午|下午|晚上|深夜|morning|afternoon|evening|night))?$',
);

/// open_loop_status 的目标状态白名单。
const loopStatusValues = {'active', 'paused', 'closed'};

/// open_loop_candidate 的 proactive 白名单；缺省由 Host 按 once 处理。
const loopProactiveValues = {'no', 'once', 'yes'};

/// relationship_signal 的摘要长度上限（runes）。摘要必须是自然、抽象的
/// 状态描述，不复制原话。
const maxRelationshipSummaryRunes = 60;

/// memory_signal 可携带的画像分支白名单（PersonaTree 真树机制定稿的
/// 五个主分支）。画像提示只影响叶指针归类，缺失时记忆照常写入。
const personaBranchValues = {
  'identity',
  'expression',
  'values',
  'preferences',
  'boundaries',
};

/// memory_signal 画像信号的来源性质白名单：用户明确自述 / 栖语行为观察。
/// 来源性质是叶节点唯一的置信维度（定稿不引入数值 confidence）。
const personaNatureValues = {'self_report', 'behavior'};

/// relationship_signal 的信号类型白名单：
/// deep_talk 深谈信号；temperature 冷暖变化；
/// boundary_open 用户接受某相处方式；boundary_close 用户回避或拒绝。
const relationshipSignalValues = {
  'deep_talk',
  'temperature',
  'boundary_open',
  'boundary_close',
};

/// 动作诊断码：只进入本机诊断，绝不展示给用户。
class HiddenActionDiagnostics {
  static const invalidFormat = 'hidden_action_invalid_format';
  static const unknownAction = 'hidden_action_unknown';
  static const invalidFields = 'hidden_action_invalid_fields';
  static const sensitiveContent = 'hidden_action_sensitive';
  static const privilegeViolation = 'hidden_action_privilege';
  static const overLimit = 'hidden_action_over_limit';
  static const multipleBlocks = 'hidden_action_multiple_blocks';
  static const duplicateRelationshipSignal =
      'hidden_action_duplicate_relationship_signal';

  /// 画像提示（branch/nature）不合法被丢弃；记忆信号本身保留。
  static const personaHintDropped = 'hidden_action_persona_hint_dropped';
}

final class HiddenAction {
  const HiddenAction({
    required this.kind,
    this.summary,
    this.evidence,
    this.query,
    this.months,
    this.dates,
    this.branch,
    this.nature,
    this.due,
    this.proactive,
    this.note,
    this.result,
    this.status,
    this.signal,
  });

  final HiddenActionKind kind;
  final String? summary;
  final String? evidence;
  final String? query;

  /// memory_recall 轮内查找的月份选择（`YYYY-MM`），只出现在选择调用
  /// 的回应里；聊天轮的检索请求只有 query。
  final List<String>? months;

  /// memory_recall 轮内查找的日期选择（`YYYY-MM-DD`）。
  final List<String>? dates;

  /// memory_signal 画像提示：所属 PersonaTree 分支
  /// （identity/expression/values/preferences/boundaries）。
  final String? branch;

  /// memory_signal 画像提示：来源性质（self_report / behavior）。
  final String? nature;

  /// open_loop_candidate：最早可跟进时间（`YYYY-MM-DD[ 时段]`）。
  final String? due;

  /// open_loop_candidate：no / once / yes。
  final String? proactive;

  /// open_loop_candidate：跟进时需要知道的背景。
  final String? note;

  /// open_loop_status：闭环结果的追溯说明。
  final String? result;

  /// open_loop_status：目标状态（active / paused / closed）。
  final String? status;

  /// relationship_signal：信号类型
  /// （deep_talk / temperature / boundary_open / boundary_close）。
  final String? signal;

  Map<String, Object?> toJson() => {
    'action': kind.wireName,
    if (summary != null) 'summary': summary,
    if (evidence != null) 'evidence': evidence,
    if (query != null) 'query': query,
    if (months != null) 'months': months,
    if (dates != null) 'dates': dates,
    if (branch != null) 'branch': branch,
    if (nature != null) 'nature': nature,
    if (due != null) 'due': due,
    if (proactive != null) 'proactive': proactive,
    if (note != null) 'note': note,
    if (result != null) 'result': result,
    if (status != null) 'status': status,
    if (signal != null) 'signal': signal,
  };

  @override
  bool operator ==(Object other) =>
      other is HiddenAction &&
      other.kind == kind &&
      other.summary == summary &&
      other.evidence == evidence &&
      other.query == query &&
      _sameSelections(other.months, months) &&
      _sameSelections(other.dates, dates) &&
      other.branch == branch &&
      other.nature == nature &&
      other.due == due &&
      other.proactive == proactive &&
      other.note == note &&
      other.result == result &&
      other.status == status &&
      other.signal == signal;

  @override
  int get hashCode => Object.hash(
    kind,
    summary,
    evidence,
    query,
    Object.hashAll(months ?? const []),
    Object.hashAll(dates ?? const []),
    branch,
    nature,
    due,
    proactive,
    note,
    result,
    status,
    signal,
  );
}

bool _sameSelections(List<String>? left, List<String>? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left == null || right == null || left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
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

/// open_loop_status 的目标状态（定稿白名单的定型形态）。
enum LoopStatus {
  active('active'),
  paused('paused'),
  closed('closed');

  const LoopStatus(this.wireName);

  final String wireName;

  static LoopStatus? tryParseWireName(String value) {
    for (final status in values) {
      if (status.wireName == value) {
        return status;
      }
    }
    return null;
  }
}

/// open_loop_candidate 是否主动跟进（定稿白名单的定型形态）。
enum LoopProactive {
  no('no'),
  once('once'),
  yes('yes');

  const LoopProactive(this.wireName);

  final String wireName;

  static LoopProactive? tryParseWireName(String value) {
    for (final proactive in values) {
      if (proactive.wireName == value) {
        return proactive;
      }
    }
    return null;
  }
}

/// memory_signal 画像提示的 PersonaTree 分支（定稿白名单的定型形态）。
enum PersonaTreeBranch {
  identity('identity'),
  expression('expression'),
  valuePrinciples('values'),
  preferences('preferences'),
  boundaries('boundaries');

  const PersonaTreeBranch(this.wireName);

  final String wireName;

  static PersonaTreeBranch? tryParseWireName(String value) {
    for (final branch in values) {
      if (branch.wireName == value) {
        return branch;
      }
    }
    return null;
  }
}

/// memory_signal 画像提示的来源性质（定稿白名单的定型形态）。
enum PersonaNature {
  selfReport('self_report'),
  behavior('behavior');

  const PersonaNature(this.wireName);

  final String wireName;

  static PersonaNature? tryParseWireName(String value) {
    for (final nature in values) {
      if (nature.wireName == value) {
        return nature;
      }
    }
    return null;
  }
}

/// relationship_signal 的信号类型（定稿白名单的定型形态）。
enum RelationshipSignal {
  deepTalk('deep_talk'),
  temperature('temperature'),
  boundaryOpen('boundary_open'),
  boundaryClose('boundary_close');

  const RelationshipSignal(this.wireName);

  final String wireName;

  static RelationshipSignal? tryParseWireName(String value) {
    for (final signal in values) {
      if (signal.wireName == value) {
        return signal;
      }
    }
    return null;
  }
}

/// memory_signal 的画像提示：分支与来源性质成对出现，缺一即整体不成立。
final class PersonaHint {
  const PersonaHint({required this.branch, required this.nature});

  final PersonaTreeBranch branch;
  final PersonaNature nature;

  @override
  bool operator ==(Object other) =>
      other is PersonaHint &&
      other.branch == branch &&
      other.nature == nature;

  @override
  int get hashCode => Object.hash(branch, nature);
}

/// 隐藏动作的定型模型：每种 kind 一个子类，各自只携带解析器已校验的
/// 精确字段，「kind 与字段不匹配」的状态在类型上无法构造。序列化仍走
/// 原扁平协议的 wire 键；[toLegacy] 提供旧扁平视图，供尚未迁移的消费层
/// 继续使用（扩-收模式的扩展步，消费层迁移完成后移除）。
sealed class TypedHiddenAction {
  const TypedHiddenAction();

  HiddenActionKind get kind;

  /// 与旧扁平结构逐字段一致的 wire 序列化。
  Map<String, Object?> toJson();

  /// 旧扁平兼容视图：字段取值与解析器旧输出完全一致。
  HiddenAction toLegacy();
}

/// memory_signal：值得记下的事实。summary 必填；evidence 可选；
/// 画像提示成对可选。
final class MemorySignalAction extends TypedHiddenAction {
  const MemorySignalAction({required this.summary, this.evidence, this.hint});

  final String summary;
  final String? evidence;
  final PersonaHint? hint;

  @override
  HiddenActionKind get kind => HiddenActionKind.memorySignal;

  @override
  Map<String, Object?> toJson() => {
    'action': kind.wireName,
    'summary': summary,
    if (evidence != null) 'evidence': evidence,
    if (hint != null) 'branch': hint!.branch.wireName,
    if (hint != null) 'nature': hint!.nature.wireName,
  };

  @override
  HiddenAction toLegacy() => HiddenAction(
    kind: kind,
    summary: summary,
    evidence: evidence,
    branch: hint?.branch.wireName,
    nature: hint?.nature.wireName,
  );

  @override
  bool operator ==(Object other) =>
      other is MemorySignalAction &&
      other.summary == summary &&
      other.evidence == evidence &&
      other.hint == hint;

  @override
  int get hashCode => Object.hash(summary, evidence, hint);
}

/// memory_recall：轮内查找。聊天轮只带 query；选择调用的回应才带
/// months/dates 选择。
final class MemoryRecallAction extends TypedHiddenAction {
  MemoryRecallAction({required this.query, List<String>? months, List<String>? dates})
    : months = months == null ? null : List.unmodifiable(months),
      dates = dates == null ? null : List.unmodifiable(dates);

  final String query;

  /// 月份选择（`YYYY-MM`），未选择为 null。
  final List<String>? months;

  /// 日期选择（`YYYY-MM-DD`），未选择为 null。
  final List<String>? dates;

  @override
  HiddenActionKind get kind => HiddenActionKind.memoryRecall;

  @override
  Map<String, Object?> toJson() => {
    'action': kind.wireName,
    'query': query,
    if (months != null) 'months': months,
    if (dates != null) 'dates': dates,
  };

  @override
  HiddenAction toLegacy() => HiddenAction(
    kind: kind,
    query: query,
    months: months,
    dates: dates,
  );

  @override
  bool operator ==(Object other) =>
      other is MemoryRecallAction &&
      other.query == query &&
      _sameSelections(other.months, months) &&
      _sameSelections(other.dates, dates);

  @override
  int get hashCode => Object.hash(
    query,
    Object.hashAll(months ?? const []),
    Object.hashAll(dates ?? const []),
  );
}

/// no_action：模型明确表示没有动作。
final class NoAction extends TypedHiddenAction {
  const NoAction();

  @override
  HiddenActionKind get kind => HiddenActionKind.noAction;

  @override
  Map<String, Object?> toJson() => {'action': kind.wireName};

  @override
  HiddenAction toLegacy() => HiddenAction(kind: kind);

  @override
  bool operator ==(Object other) => other is NoAction;

  @override
  int get hashCode => kind.hashCode;
}

/// open_loop_candidate：日终候选事项。title 走 wire 的 summary 键。
final class OpenLoopCandidateAction extends TypedHiddenAction {
  const OpenLoopCandidateAction({
    required this.title,
    this.evidence,
    this.due,
    this.proactive,
    this.note,
  });

  final String title;
  final String? evidence;

  /// 最早可跟进时间（`YYYY-MM-DD[ 时段]`）。
  final String? due;
  final LoopProactive? proactive;

  /// 跟进时需要知道的背景。
  final String? note;

  @override
  HiddenActionKind get kind => HiddenActionKind.openLoopCandidate;

  @override
  Map<String, Object?> toJson() => {
    'action': kind.wireName,
    'summary': title,
    if (evidence != null) 'evidence': evidence,
    if (due != null) 'due': due,
    if (proactive != null) 'proactive': proactive!.wireName,
    if (note != null) 'note': note,
  };

  @override
  HiddenAction toLegacy() => HiddenAction(
    kind: kind,
    summary: title,
    evidence: evidence,
    due: due,
    proactive: proactive?.wireName,
    note: note,
  );

  @override
  bool operator ==(Object other) =>
      other is OpenLoopCandidateAction &&
      other.title == title &&
      other.evidence == evidence &&
      other.due == due &&
      other.proactive == proactive &&
      other.note == note;

  @override
  int get hashCode => Object.hash(title, evidence, due, proactive, note);
}

/// open_loop_status：事项闭环、暂缓或重新活跃。
final class OpenLoopStatusAction extends TypedHiddenAction {
  const OpenLoopStatusAction({required this.title, required this.status, this.result});

  final String title;
  final LoopStatus status;

  /// 闭环结果的追溯说明。
  final String? result;

  @override
  HiddenActionKind get kind => HiddenActionKind.openLoopStatus;

  @override
  Map<String, Object?> toJson() => {
    'action': kind.wireName,
    'summary': title,
    'status': status.wireName,
    if (result != null) 'result': result,
  };

  @override
  HiddenAction toLegacy() => HiddenAction(
    kind: kind,
    summary: title,
    status: status.wireName,
    result: result,
  );

  @override
  bool operator ==(Object other) =>
      other is OpenLoopStatusAction &&
      other.title == title &&
      other.status == status &&
      other.result == result;

  @override
  int get hashCode => Object.hash(title, status, result);
}

/// 用户记忆控制动作（禁提 / 当轮遗忘 / 冻结 / 解冻 / 删除）的共同形状：
/// 只携带控制对象的话题简称。
sealed class MemoryControlAction extends TypedHiddenAction {
  const MemoryControlAction({required this.title});

  final String title;

  @override
  Map<String, Object?> toJson() => {'action': kind.wireName, 'summary': title};

  @override
  HiddenAction toLegacy() => HiddenAction(kind: kind, summary: title);
}

/// memory_ban：用户要求不再提及。
final class MemoryBanAction extends MemoryControlAction {
  const MemoryBanAction({required super.title});

  @override
  HiddenActionKind get kind => HiddenActionKind.memoryBan;

  @override
  bool operator ==(Object other) =>
      other is MemoryBanAction && other.title == title;

  @override
  int get hashCode => Object.hash(kind, title);
}

/// memory_forget：用户要求本轮内容不进入记忆。
final class MemoryForgetAction extends MemoryControlAction {
  const MemoryForgetAction({required super.title});

  @override
  HiddenActionKind get kind => HiddenActionKind.memoryForget;

  @override
  bool operator ==(Object other) =>
      other is MemoryForgetAction && other.title == title;

  @override
  int get hashCode => Object.hash(kind, title);
}

/// memory_freeze：用户要求冻结内容，只有明确解除才恢复。
final class MemoryFreezeAction extends MemoryControlAction {
  const MemoryFreezeAction({required super.title});

  @override
  HiddenActionKind get kind => HiddenActionKind.memoryFreeze;

  @override
  bool operator ==(Object other) =>
      other is MemoryFreezeAction && other.title == title;

  @override
  int get hashCode => Object.hash(kind, title);
}

/// memory_unfreeze：用户明确解除冻结。
final class MemoryUnfreezeAction extends MemoryControlAction {
  const MemoryUnfreezeAction({required super.title});

  @override
  HiddenActionKind get kind => HiddenActionKind.memoryUnfreeze;

  @override
  bool operator ==(Object other) =>
      other is MemoryUnfreezeAction && other.title == title;

  @override
  int get hashCode => Object.hash(kind, title);
}

/// memory_delete：用户要求删除记忆。
final class MemoryDeleteAction extends MemoryControlAction {
  const MemoryDeleteAction({required super.title});

  @override
  HiddenActionKind get kind => HiddenActionKind.memoryDelete;

  @override
  bool operator ==(Object other) =>
      other is MemoryDeleteAction && other.title == title;

  @override
  int get hashCode => Object.hash(kind, title);
}

/// relationship_signal：深谈信号、温度变化、边界开合。边界开合必须带
/// evidence 的约束属于字段间校验，由解析器执行。
final class RelationshipSignalAction extends TypedHiddenAction {
  const RelationshipSignalAction({
    required this.summary,
    required this.signal,
    this.evidence,
  });

  final String summary;
  final RelationshipSignal signal;
  final String? evidence;

  @override
  HiddenActionKind get kind => HiddenActionKind.relationshipSignal;

  @override
  Map<String, Object?> toJson() => {
    'action': kind.wireName,
    'summary': summary,
    if (evidence != null) 'evidence': evidence,
    'signal': signal.wireName,
  };

  @override
  HiddenAction toLegacy() => HiddenAction(
    kind: kind,
    summary: summary,
    signal: signal.wireName,
    evidence: evidence,
  );

  @override
  bool operator ==(Object other) =>
      other is RelationshipSignalAction &&
      other.summary == summary &&
      other.signal == signal &&
      other.evidence == evidence;

  @override
  int get hashCode => Object.hash(summary, signal, evidence);
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
      .replaceAll(_blankLinesPattern, '\n\n')
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
  // JSON 解析失败与非数组、标量载荷同属 invalid_format：丢弃动作块并记诊断。
  Object? decoded;
  try {
    decoded = jsonDecode(blocks.first.group(1)!.trim());
  } on Object {
    decoded = null;
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
    if (action == null) {
      continue;
    }
    // 协议约定一轮最多一个 relationship_signal：多余的丢弃并记诊断。
    if (action.kind == HiddenActionKind.relationshipSignal &&
        actions.any((kept) => kept.kind == HiddenActionKind.relationshipSignal)) {
      diagnostics.add(HiddenActionDiagnostics.duplicateRelationshipSignal);
      continue;
    }
    actions.add(action);
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
      final security = _fieldSecurityDiagnostic([summary, evidence]);
      if (security != null) {
        diagnostics.add(security);
        return null;
      }
      // 画像提示是归类的附加线索：不合法时只丢提示、不丢记忆信号。
      // 身份事实禁止行为推断（PersonaTree 定稿），违规组合同样丢提示。
      final branch = _cleanFieldValue(item['branch']);
      final nature = _cleanFieldValue(item['nature']);
      String? personaBranch;
      String? personaNature;
      if (branch != null || nature != null) {
        if (branch != null &&
            nature != null &&
            personaBranchValues.contains(branch) &&
            personaNatureValues.contains(nature) &&
            !(branch == 'identity' && nature != 'self_report')) {
          personaBranch = branch;
          personaNature = nature;
        } else {
          diagnostics.add(HiddenActionDiagnostics.personaHintDropped);
        }
      }
      return HiddenAction(
        kind: kind,
        summary: summary,
        evidence: evidence,
        branch: personaBranch,
        nature: personaNature,
      );
    case HiddenActionKind.memoryRecall:
      final query = _cleanFieldValue(item['query']);
      if (query == null || query.runes.length > maxHiddenQueryRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      // 锁定行为：检索词命中越权或秘密一律记 privilegeViolation，
      // 不走其它动作的 privilege/secret 分流（有测试钉住，勿"统一"）。
      if (_violatesPrivilege(query) || _containsSecret(query)) {
        diagnostics.add(HiddenActionDiagnostics.privilegeViolation);
        return null;
      }
      // 轮内查找的选择字段（只出现在选择调用回应里）：逐项做格式校验，
      // 不合规的项丢弃并记诊断。成员校验（选择必须来自 Host 递过的
      // 目录）在 Host 编排层执行。
      final months = _parseSelections(
        item['months'],
        _recallMonthPattern,
        diagnostics,
      );
      final dates = _parseSelections(
        item['dates'],
        _recallDatePattern,
        diagnostics,
      );
      return HiddenAction(
        kind: kind,
        query: query,
        months: months,
        dates: dates,
      );
    case HiddenActionKind.noAction:
      return HiddenAction(kind: kind);
    case HiddenActionKind.openLoopCandidate:
      final title = _cleanFieldValue(item['summary']);
      if (title == null || title.runes.length > maxLoopTitleRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final evidence = _cleanFieldValue(item['evidence']);
      if (evidence != null && evidence.runes.length > maxHiddenEvidenceRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final due = _cleanFieldValue(item['due']);
      if (due != null && !_loopDuePattern.hasMatch(due)) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final proactive = _cleanFieldValue(item['proactive']);
      if (proactive != null && !loopProactiveValues.contains(proactive)) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final note = _cleanFieldValue(item['note']);
      if (note != null && note.runes.length > maxLoopNoteRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final security = _fieldSecurityDiagnostic([title, evidence, note]);
      if (security != null) {
        diagnostics.add(security);
        return null;
      }
      return HiddenAction(
        kind: kind,
        summary: title,
        evidence: evidence,
        due: due,
        proactive: proactive,
        note: note,
      );
    case HiddenActionKind.openLoopStatus:
      final title = _cleanFieldValue(item['summary']);
      if (title == null || title.runes.length > maxLoopTitleRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final status = _cleanFieldValue(item['status']);
      if (status == null || !loopStatusValues.contains(status)) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final result = _cleanFieldValue(item['result']);
      if (result != null && result.runes.length > maxLoopResultRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final security = _fieldSecurityDiagnostic([title, result]);
      if (security != null) {
        diagnostics.add(security);
        return null;
      }
      return HiddenAction(
        kind: kind,
        summary: title,
        status: status,
        result: result,
      );
    case HiddenActionKind.memoryBan:
    case HiddenActionKind.memoryForget:
    case HiddenActionKind.memoryFreeze:
    case HiddenActionKind.memoryUnfreeze:
    case HiddenActionKind.memoryDelete:
      // 用户记忆控制动作共用同一校验：summary 是控制对象的话题简称，
      // 必填、限长、不越权、不含秘密。
      final title = _cleanFieldValue(item['summary']);
      if (title == null || title.runes.length > maxLoopTitleRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final security = _fieldSecurityDiagnostic([title]);
      if (security != null) {
        diagnostics.add(security);
        return null;
      }
      return HiddenAction(kind: kind, summary: title);
    case HiddenActionKind.relationshipSignal:
      final summary = _cleanFieldValue(item['summary']);
      if (summary == null ||
          summary.runes.length > maxRelationshipSummaryRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final signal = _cleanFieldValue(item['signal']);
      if (signal == null || !relationshipSignalValues.contains(signal)) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final evidence = _cleanFieldValue(item['evidence']);
      if (evidence != null && evidence.runes.length > maxHiddenEvidenceRunes) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      // 边界开合会投影进「当前相处方式」，定稿要求每条带依据，evidence 必备。
      if ((signal == 'boundary_open' || signal == 'boundary_close') &&
          evidence == null) {
        diagnostics.add(HiddenActionDiagnostics.invalidFields);
        return null;
      }
      final security = _fieldSecurityDiagnostic([summary, evidence]);
      if (security != null) {
        diagnostics.add(security);
        return null;
      }
      return HiddenAction(
        kind: kind,
        summary: summary,
        signal: signal,
        evidence: evidence,
      );
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
      .replaceAll(_fieldWhitespaceRunsPattern, ' ')
      .trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 解析 memory_recall 的选择数组：字段缺失返回 null（未选择）；
/// 存在但非数组、或数组里没有合法项时同样返回 null，违规项记诊断。
/// 数量不设上限（跨月跨年检索定稿），重复项折叠。
List<String>? _parseSelections(
  Object? value,
  RegExp pattern,
  List<String> diagnostics,
) {
  if (value == null) {
    return null;
  }
  if (value is! List<Object?>) {
    diagnostics.add(HiddenActionDiagnostics.invalidFields);
    return null;
  }
  final selections = <String>[];
  for (final item in value) {
    final selection = item is String ? item.trim() : null;
    if (selection == null || !pattern.hasMatch(selection)) {
      diagnostics.add(HiddenActionDiagnostics.invalidFields);
      continue;
    }
    if (!selections.contains(selection)) {
      selections.add(selection);
    }
  }
  return selections.isEmpty ? null : selections;
}

bool _violatesPrivilege(String value) =>
    _privilegePatterns.any((pattern) => pattern.hasMatch(value));

bool _containsSecret(String value) =>
    _secretPatterns.any((pattern) => pattern.hasMatch(value));

/// 对动作字段做内容安全筛查：任一字段命中越权特征返回 privilegeViolation，
/// 否则任一字段命中秘密特征返回 sensitiveContent，全部干净返回 null。
/// 越权优先于秘密判定；null 字段跳过（可空字段不参与筛查）。
String? _fieldSecurityDiagnostic(List<String?> fields) {
  for (final field in fields) {
    if (field != null && _violatesPrivilege(field)) {
      return HiddenActionDiagnostics.privilegeViolation;
    }
  }
  for (final field in fields) {
    if (field != null && _containsSecret(field)) {
      return HiddenActionDiagnostics.sensitiveContent;
    }
  }
  return null;
}
