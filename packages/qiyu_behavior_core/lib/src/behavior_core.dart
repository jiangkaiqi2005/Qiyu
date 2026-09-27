import 'contracts.dart';
import 'shared_patterns.dart';

const _maxVisibleReplyCharacters = 2000;

/// 模型原始增量的总上限（runes）：交付层流式循环按它给进入清洗前的原始
/// 缓冲记账，超限按不兼容响应处理——已见文字留半句，无文字走本地兜底。
/// 与可见侧的 2000 rune 截断（[_maxVisibleReplyCharacters]）是两道闸：
/// 这道防失控的 Provider 流在超时前耗尽内存，那道约束最终上屏长度。
///
/// 与模型网关发给 Provider 的 8192 token 上限同数字不同单位（runes 是
/// 字符数、tokens 是请求计费单位），勿混改。
const maxModelReplyRunes = 8192;

// —— 用户输入净化（sanitizeUserInput）。各遍替换顺序即语义，勿合并勿换序。——
final _controlCharacterPattern = RegExp(
  r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]',
);
final _commentDelimiterPattern = RegExp(r'<!--|-->|<!\[CDATA\[|\]\]>');
final _specialTokenPattern = RegExp(r'<\|[\s\S]{1,200}?\|>');
final _chatTemplateMarkerPattern = RegExp(
  r'\[\s*/?\s*INST\s*\]|<<\s*/?\s*SYS\s*>>',
  caseSensitive: false,
);
final _tagPattern = RegExp(
  r'<\s*/?\s*[A-Za-z_][A-Za-z0-9_.:-]*(?:\s+[\s\S]*?)?\s*/?\s*>',
);
final _directivePattern = RegExp(r'<\?[^>]*\?>|<![^>]*>');
final _roleLinePattern = RegExp(
  r'^\s*(?:system|assistant|developer|tool|function)(?:\s*[:：]\s*|\s*$)',
  caseSensitive: false,
  multiLine: true,
);
final _roleFenceLinePattern = RegExp(
  r'^\s*```(?:system|assistant|developer|tool|function)?\s*$',
  caseSensitive: false,
  multiLine: true,
);
final _leftAngleBracketPattern = RegExp(r'<(?=[!?/]?[A-Za-z_])');
final _inlineSpacePattern = RegExp(r'[ \t]+');

// —— 安全分类（_classifySafety）。——
final _crisisPattern = RegExp(
  r'活着没意思|不想活|自杀|伤害自己|想死|自残|割腕|轻生|活不下去|不想醒来|结束生命|撑不下去|离开世界|吃药.*走|吞药|跳楼|烧炭|上吊',
);
final _adviceSeekingPattern = RegExp(
  r'能不能|要不要|应不应该|可以吗|行不行|该不该|推荐|建议|行吗|能.{0,4}吗|该.{0,4}吗|会不会有问题|帮我(?:判断|看看|确认|分析)|是否(?:安全|合适|应该|可以)|我该.{0,12}(?:加倍|加量|减量|停药|换药|签字|起诉|买入|卖出|贷款|投资)',
);
final _medicalKeywordPattern = RegExp(r'药|剂量|诊断|手术|症状|医院|医生');
final _legalKeywordPattern = RegExp(r'合同|起诉|律师|违法|法律|赔偿|签字');
final _financialKeywordPattern = RegExp(r'股票|基金|币|投资|买入|卖出|贷款');

// —— 本地规则回复（_localReply）。——
final _fatiguePattern = RegExp(r'累|疲惫|困');

// —— 模型候选回复校验（CandidateReplyStream / _cleanVisibleLine）。——
// 只做协议与格式卫生：隐藏结构剥离、控制模式、逐行清洗、长度上限、
// 空回复兜底。人格与话术约束在提示词层由模型自判断（ADR 0017），
// 输出侧不再用正则判决。
/// 可见区的模型控制结构词表：XML 标签与动作键/值形态两个模式共用，
const _modelControlWords =
    'action|tool|function|tool_call|function_call|qiyu_action|memory_action';

/// 隐藏块剥除后残留的模型控制结构：XML 标签、动作键形态与动作值形态。
/// 三者同判 invalid_model_response，故可合并为单一列表匹配。
final _modelControlPatterns = [
  RegExp(r'<\s*/?\s*[A-Za-z_][^>\r\n]*>'),
  RegExp(
    r'''["']?(?:''' + _modelControlWords + r''')["']?\s*[:=]''',
    caseSensitive: false,
  ),
  RegExp(
    r'''[:=]\s*["'](?:''' + _modelControlWords + r''')["']''',
    caseSensitive: false,
  ),
];

final _codeFenceLinePattern = RegExp(r'^```(?:[A-Za-z0-9_-]+)?$');
final _speakerPrefixPattern = RegExp(r'^(?:栖语|她|他)\s*[：:]\s*');

/// 行首消息时刻前缀的唯一权威：`[YYYY-MM-DD HH:mm]`——本地时区、完整
/// 日期防跨零点歧义、分钟粒度、无时区偏移后缀（单机单用户时区恒定，
/// 偏移后缀是噪音）。
///
/// 装配器生成前缀与候选清洗剥离前缀都必须走这里：[format] 渲染出的
/// 前缀一定被 [pattern] 整段吃掉，core 测试的 lockstep 用例锁住同形。
abstract final class MomentPrefix {
  /// 行首时刻前缀的剥离模式：只吃 [format] 渲染出的整段前缀，模型
  /// 复述装配痕迹时不进入可见回复。
  static final RegExp pattern = RegExp(
    r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\]\s*',
  );

  /// 渲染行首消息时刻前缀。
  static String format(DateTime at) {
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '[${local.year.toString().padLeft(4, '0')}-'
        '${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}]';
  }
}

final _bracketedPausePrefixPattern = RegExp(
  r'^[（(【\[]\s*(?:等了?一会儿?|等了一下|想了?想|沉默了?一下|停顿了?一下)[。.!！?？,，、\s]*[）)】\]]\s*',
);
final _ellipsisOnlyPattern = RegExp(r'^(?:…+|\.\.\.)$');

/// 舞台提示行的词干交替串：清洗正则（[_barePauseLinePattern]）与流式
/// 扣留的候选表（[_barePauseCandidates]）共用同一份字符串——候选表由
/// [_expandBarePauseStems] 从它生成，结构上不可能漂移。`?` 表示前一个
/// 字符可省，`(?:她|他)?` 表示整组可省。
///
/// **刻意不同源的一处**：[_bracketedPausePrefixPattern]（行首括号停顿
/// 前缀）内联了自己的词干且不含「轻声说」——那是语义使然（括号里只包
/// 住动作性沉默，「轻声说」是说话方式不是沉默），改词干时那一处要单独
/// 决定要不要跟着改，「只改 const 一处」的承诺覆盖不到它。
const _barePauseStems = '等了?一会儿?|等了一下|想了?想|沉默了?一下|停顿了?一下|(?:她|他)?轻声说';

final _barePauseLinePattern = RegExp('^(?:$_barePauseStems)[。.!！?？,，\\s：:]*\$');

final class QiyuBehaviorCore {
  const QiyuBehaviorCore();

  ChatOutcome reply(
    ChatRequest request,
    StateSnapshot state, {
    String? candidateReply,
    FallbackReason? modelFailure,
  }) {
    final text = sanitizeUserInput(request.text);
    if (text.isEmpty) {
      return ErrorResult(
        requestId: request.requestId,
        code: ChatErrorCode.invalidRequest,
        message: '消息不能为空',
        retryable: false,
      );
    }

    final safety = _classifySafety(text);
    // 危机等敏感输入不再拦截外呼（ADR 0010）：有合格模型候选就照常参与
    // 对话；分类结果只在降级时挑选本地兜底话术（危机→热线兜底，其余
    // 类别→现行本地话术），正常输入维持极简回复三分支。分类标注只随
    // 敏感轮的结果出现。
    final fallbackSafety = safety == SafetyKind.normal ? null : safety;

    if (modelFailure != null) {
      return _localResult(
        request: request,
        state: state,
        text: text,
        fallbackReason: modelFailure,
        safety: fallbackSafety,
      );
    }

    if (candidateReply != null) {
      final candidate = _validateCandidateReply(candidateReply);
      if (candidate.failure == null) {
        return _result(
          request: request,
          state: state,
          text: text,
          messages: candidate.messages,
          source: ReplySource.llm,
          mode: 'llm',
          safety: fallbackSafety,
        );
      }

      return _localResult(
        request: request,
        state: state,
        text: text,
        fallbackReason: candidate.failure!,
        safety: fallbackSafety,
      );
    }

    return _localResult(
      request: request,
      state: state,
      text: text,
      fallbackReason: fallbackSafety == null
          ? FallbackReason.noLlmConfig
          : FallbackReason.safety,
      safety: fallbackSafety,
    );
  }

  ChatResult _localResult({
    required ChatRequest request,
    required StateSnapshot state,
    required String text,
    required FallbackReason fallbackReason,
    SafetyKind? safety,
  }) {
    final localReply = safety == null
        ? _localReply(text)
        : (messages: _safetyMessages(safety), mode: 'safety');
    return _result(
      request: request,
      state: state,
      text: text,
      messages: localReply.messages,
      source: ReplySource.local,
      fallbackReason: fallbackReason,
      mode: localReply.mode,
      safety: safety,
    );
  }

  ChatResult _result({
    required ChatRequest request,
    required StateSnapshot state,
    required String text,
    required List<String> messages,
    required ReplySource source,
    required String mode,
    FallbackReason? fallbackReason,
    SafetyKind? safety,
  }) {
    final replyText = messages.join('\n');
    final nextState = state.append(
      userTurn: ChatTurn(speaker: Speaker.user, text: text),
      qiyuTurn: ChatTurn(speaker: Speaker.qiyu, text: replyText),
    );

    return ChatResult(
      requestId: request.requestId,
      messages: messages,
      nextState: nextState,
      source: source,
      fallbackReason: fallbackReason,
      mode: mode,
      safety: safety,
    );
  }
}

String sanitizeUserInput(String value) {
  var text = value
      .replaceAll(_controlCharacterPattern, ' ')
      .replaceAll(_commentDelimiterPattern, ' ')
      .replaceAll(_specialTokenPattern, ' ')
      .replaceAll(_chatTemplateMarkerPattern, ' ')
      .replaceAll(_tagPattern, ' ')
      .replaceAll(_directivePattern, ' ')
      .replaceAll(_roleLinePattern, '')
      .replaceAll(_roleFenceLinePattern, '')
      .replaceAllMapped(_leftAngleBracketPattern, (_) => '＜');
  text = text
      .split('\n')
      .map((line) => line.replaceAll(_inlineSpacePattern, ' ').trim())
      .join('\n');
  return text.replaceAll(blankLinesPattern, '\n\n').trim();
}

/// 解析层共用的 BOM 剥离：手动编辑过的本机文件可能以 BOM（U+FEFF）开头，
/// 配置与会话、记忆文件的解析入口先剥再解析，保证「带 BOM 与无 BOM 解析
/// 结果一致」。只剥开头一个 BOM 字符；文件尾字节不受影响，落盘格式不变。
String stripUtf8Bom(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;

({List<String> messages, String mode}) _localReply(String text) {
  if (text == '我到家了') {
    return (messages: const ['嗯'], mode: 'minimal');
  }
  if (_fatiguePattern.hasMatch(text)) {
    return (messages: const ['咋了'], mode: 'fatigue');
  }
  return (messages: const ['嗯？'], mode: 'open');
}

SafetyKind _classifySafety(String text) {
  if (_crisisPattern.hasMatch(text)) {
    return SafetyKind.crisis;
  }

  if (!_adviceSeekingPattern.hasMatch(text)) {
    return SafetyKind.normal;
  }

  final withoutMedicalExclusions = text.replaceAll('药膳', '');
  if (_medicalKeywordPattern.hasMatch(withoutMedicalExclusions)) {
    return SafetyKind.medical;
  }
  if (_legalKeywordPattern.hasMatch(text)) {
    return SafetyKind.legal;
  }
  final withoutFinancialExclusions = text
      .replaceAll('硬币', '')
      .replaceAll('纸币', '')
      .replaceAll('金币', '');
  if (_financialKeywordPattern.hasMatch(withoutFinancialExclusions)) {
    return SafetyKind.financial;
  }
  return SafetyKind.normal;
}

List<String> _safetyMessages(SafetyKind safety) {
  return switch (safety) {
    SafetyKind.crisis => const [
      '我听到你了。你现在承受的好多。',
      '这句不是随便说说的那种难过，我会认真对待。',
      '现在先别一个人扛。全国 24 小时心理援助热线 12356，随时都有人在。也可以马上找身边一个真人，别让自己单独待着。',
    ],
    SafetyKind.medical => const ['这个别听我瞎猜。药量这种事要问专业的人，别拿身体赌。'],
    SafetyKind.legal => const ['合同和签字这类事，最好让专业的人看一眼。我能陪你把担心的点列出来，但不能替你下法律判断。'],
    SafetyKind.financial => const ['这个我不能替你做买卖决定。钱的事要按你的风险承受来，我可以陪你把理由和风险拆开看。'],
    SafetyKind.normal => const [],
  };
}

({List<String> messages, FallbackReason? failure}) _validateCandidateReply(
  String value,
) {
  // 批处理与流式交付共用同一份清洗实现：逐行清洗、隐藏结构剥离、控制
  // 模式与长度上限的判定规则完全一致。两条路的终局策略不同——批处理
  // 一律否决，流式由调用方按「有没有可见文字」决定本地兜底还是留半句
  // ——因此同一段文本的终局消息可能不同，这不是规则漂移。
  final stream = CandidateReplyStream();
  stream.add(value);
  final messages = stream.finalizeMessages();
  if (stream.rejected) {
    return (messages: const [], failure: FallbackReason.invalidModelResponse);
  }
  if (messages.isEmpty) {
    return (messages: const [], failure: FallbackReason.emptyModelReply);
  }
  return (messages: messages, failure: null);
}

/// 候选回复的增量卫生处理器（票一 文字流式输出）：Provider 增量到达后
/// 一边收一边产出可见前缀，批处理校验（[_validateCandidateReply]）与
/// 流式交付共用这同一份清洗实现。
///
/// 保留的卫生检查都是协议与格式卫生，不是人格判断：
/// - 隐藏结构剥离：思维链与动作块闭合前整块扣住，绝不吐半个隐藏行；
/// - 控制模式：可见区出现 XML 标签或动作键/值形态即一票否决；
/// - 逐行清洗：说话人前缀、代码围栏、纯省略号行、舞台提示行、行首
///   时刻前缀，规则与批处理完全一致（各剥一次、顺序相同）；
/// - 2000 runes 上限；没有任何可见文字时由调用方走本地兜底。
///
/// 已吐出的文本只会是最终可见文本的前缀：未完结行只吐「确定性
/// 前缀」——还可能被整行丢弃、被剥掉行首前缀、被 trim 掉行尾空白、
/// 或改写形态（未落定尖括号、控制词前缀）的一律扣住不吐，因此流式
/// 交付不会出现「吐出去又收回来」。唯一例外是控制模式否决时受污染
/// 行整体撤下（该行此前吐出的确定性前缀随行撤回），此时页面会看到
/// 该行被本地兜底替换——模型那行本来就不是合格回复。
final class CandidateReplyStream {
  final StringBuffer _hiddenBuffer = StringBuffer();

  /// 已吐出的可见文本（页面上已经看到的内容）。协议失败留半句时，
  /// 落盘与交付的就是它。
  String _visible = '';

  /// 当前未完结行的原始文本（含尚未落定的尖括号尾巴）。
  String _line = '';

  /// 当前未完结行已吐出的确定性前缀长度（runes）。
  int _partialEmitted = 0;

  /// 隐藏结构开标签名；非空即整块扣住中。
  String? _hiddenTag;

  bool _rejected = false;
  bool _finalized = false;

  /// 可见区出现控制模式或超过长度上限：一票否决，不再产出新文本。
  bool get rejected => _rejected;

  /// 已吐出的可见消息（按行）。未完结行只含已吐出的确定性前缀。
  List<String> get visibleMessages =>
      _visible.isEmpty ? const [] : _visible.split('\n');

  /// 喂入一段 Provider 原始增量，返回本次新吐出、可以上屏的文本。
  String add(String chunk) {
    if (_finalized || _rejected || chunk.isEmpty) {
      return '';
    }
    final before = _visible.length;
    var work = '$_line${_normalizeNewlines(chunk)}';
    _line = '';
    while (work.isNotEmpty) {
      if (_hiddenTag != null) {
        _hiddenBuffer.write(work);
        final buffer = _hiddenBuffer.toString();
        final close = hiddenModelStructureClosePattern.firstMatch(buffer);
        if (close == null) {
          return _settle(before);
        }
        _hiddenBuffer.clear();
        _hiddenTag = null;
        work = buffer.substring(close.end);
        continue;
      }
      final open = hiddenModelStructureOpenPattern.firstMatch(work);
      if (open == null) {
        _consumeVisible(work);
        return _settle(before);
      }
      _consumeVisible(work.substring(0, open.start));
      _hiddenTag = _hiddenTagOf(open.group(0)!);
      work = work.substring(open.end);
    }
    return _settle(before);
  }

  /// 收尾：补完结尾行、剥离未闭合的可剥隐藏结构，返回最终可见消息。
  /// 已被否决（控制模式/超长）时原样返回已吐内容——半句如实是半句。
  List<String> finalizeMessages() {
    if (!_finalized) {
      completeTrailingLine();
      _finalized = true;
    }
    return visibleMessages;
  }

  /// 补完结尾行并返回新增的可见文本：流式交付在终局 message 之前把它
  /// 补排一次分片，保证「终局文本 = 已显示文本」。清洗规则与批处理
  /// 一致（含未落定扣留），因此两条路对同一段原始文本得到同一个终局。
  ///
  /// **幂等**：Host 显式调一次排片、[finalizeMessages] 内部再调一次，
  /// 第二次 `_line` 已空、`_hiddenTag` 已清，是空操作（返回 ''）。这是
  /// 承重前提——两处调用点靠它才不会把结尾行补两遍。
  String completeTrailingLine() {
    if (_finalized || _rejected) {
      return '';
    }
    if (_hiddenTag != null) {
      if (_strippableUnclosedTagPattern.hasMatch(_hiddenTag!)) {
        _hiddenBuffer.clear();
        _hiddenTag = null;
      } else {
        // 未闭合的工具调用等结构：批处理同判 invalid_model_response。
        _rejected = true;
        return '';
      }
    }
    final before = _visible.length;
    _completeLine(_line);
    _line = '';
    return _settle(before);
  }

  /// 每次喂入（与结尾行补完）后的总判定：控制模式与长度上限都看完整
  /// 可见文本，跨增量、跨行的形态（如上一行结尾的 action 配本行开头的
  /// 冒号）因此不会漏判。
  ///
  /// 控制模式否决时回滚到**上一个换行边界**：受污染行整体撤下，此前
  /// 已完成的行不受影响；整轮再无卫生文本时可见文本为空，由调用方走
  /// 本地兜底（与批处理一致）。两种撤回形态都不要「修」成过度扣留：
  /// - 同行分裂（`在。刚` + `{"type":"tool_call":"x"}`）：`{"type":` 之类
  ///   前缀由 [_safePrefix] 的花括号/控制尾扣留挡在上屏之前，行边界回滚
  ///   只是兜底；
  /// - 跨行分裂（`action` + `\n: x`）：行 1 是合格文本，作为半句留下，
  ///   与批处理对全量的整体否决终局不同——这是 ADR 0017 认可的取舍
  ///   （撤回点恒在行边界，不追讨已完成的干净行）。
  String _settle(int before) {
    if (_visible.length == before) {
      return '';
    }
    if (_modelControlPatterns.any((pattern) => pattern.hasMatch(_visible))) {
      // 受污染行只可能是末行（已完成的行在补完成时就过过判定）：连它
      // 前面的行分隔符一起撤，避免留下一个空行。
      final separator = _visible.lastIndexOf('\n');
      _visible = _visible.substring(0, separator < 0 ? 0 : separator);
      _partialEmitted = 0;
      _rejected = true;
      return '';
    }
    if (_visible.runes.length > _maxVisibleReplyCharacters) {
      // 截到限额内；第 2000 个 rune 恰为换行时再收掉它，否则可见消息
      // 会多出一个空串尾巴。
      final allowed = String.fromCharCodes(
        _visible.runes.take(_maxVisibleReplyCharacters),
      ).replaceFirst(RegExp(r'\n$'), '');
      _visible = allowed;
      _rejected = true;
      return allowed.length <= before ? '' : allowed.substring(before);
    }
    return _visible.substring(before);
  }

  /// 处理一段确定不含隐藏开标签的原始文本：完整行逐行清洗，尾部
  /// 未完结行只吐确定性前缀。
  void _consumeVisible(String region) {
    final combined = '$_line$region';
    _line = '';
    if (combined.isEmpty) {
      return;
    }
    final parts = combined.split('\n');
    for (var index = 0; index < parts.length - 1; index += 1) {
      _completeLine(parts[index]);
    }
    _line = parts.last;
    _flushPartial();
  }

  /// 把当前未完结行的确定性前缀吐出去（没有新增就什么都不做）。
  void _flushPartial() {
    final prefix = _safePrefix(_line);
    final prefixRunes = prefix.runes.toList(growable: false);
    if (prefixRunes.length <= _partialEmitted) {
      return;
    }
    final increment = String.fromCharCodes(prefixRunes.skip(_partialEmitted));
    final startsLine = _partialEmitted == 0;
    _partialEmitted = prefixRunes.length;
    if (startsLine && _visible.isNotEmpty) {
      _visible = '$_visible\n';
    }
    _visible = '$_visible$increment';
  }

  /// 完结一行：清洗后入列。被整行丢弃的行此前没有吐出过任何字符
  /// （未完结行的扣留保证），因此不会出现吐出去又收回来。
  void _completeLine(String raw) {
    final cleaned = _cleanVisibleLine(raw);
    final emitted = _partialEmitted;
    _partialEmitted = 0;
    if (cleaned == null) {
      return;
    }
    if (emitted > 0) {
      _visible =
          '$_visible${String.fromCharCodes(cleaned.runes.skip(emitted))}';
      return;
    }
    if (_visible.isNotEmpty) {
      _visible = '$_visible\n';
    }
    _visible = '$_visible$cleaned';
  }

  /// 未完结行的确定性前缀：剥掉必然被剥的前导空白，按 [_cleanVisibleLine]
  /// 的固定顺序各剥一次行首前缀，扣住尚未落定的尖括号、还可能长成控制
  /// 构造的尾部与行尾空白，再扣住一切还可能改变整行命运的形态（省略号
  /// 行、代码围栏、舞台提示行、说话人前缀、行首时刻前缀）。
  String _safePrefix(String line) {
    var text = line.replaceFirst(RegExp(r'^\s+'), '');
    // 行首前缀与批处理同序、各剥一次：循环剥会被模型复述的装配痕迹
    // 钻空子（[时刻][时刻]嗯 在两条路上产出不同结果）。
    final moment = MomentPrefix.pattern.matchAsPrefix(text);
    if (moment != null && moment.end > 0) {
      text = text.substring(moment.end);
    }
    final speaker = _speakerPrefixPattern.matchAsPrefix(text);
    if (speaker != null && speaker.end > 0) {
      text = text.substring(speaker.end);
    }
    final pause = _bracketedPausePrefixPattern.matchAsPrefix(text);
    if (pause != null && pause.end > 0) {
      text = text.substring(pause.end);
    }
    // 未落定尖括号：可能长成隐藏开标签（整块扣住）或控制标签（一票
    // 否决），落定之前一律不吐。后面跟的不是字母（如「3 < 5」）则
    // 不可能成标签，照常吐。
    final unresolved = _unresolvedAngleBracket(text);
    if (unresolved >= 0) {
      text = String.fromCharCodes(text.runes.take(unresolved));
    }
    // 行尾未闭合的 `{`：JSON 控制载荷（`{"type":"tool_call":…}`）往往是
    // 整块到达，但分裂到达时开头会先闪一下；从 `{` 扣住，行内此前的
    // 干净文字照常吐。必须先于控制尾扣留——`action {"type":` 这类行
    // 砍掉花括号后尾部才露出控制词前缀。
    final unclosedBrace = _unresolvedJsonObject(text);
    if (unclosedBrace >= 0) {
      text = String.fromCharCodes(text.runes.take(unclosedBrace));
    }
    // 行尾控制构造前缀：`action`＋`: x` 这类跨增量拼成的控制形态，
    // 前缀一个字符都不能先上屏。
    final controlTail = _unresolvedControlTail(text);
    if (controlTail >= 0) {
      text = String.fromCharCodes(text.runes.take(controlTail));
    }
    // 行尾空白会被整行 trim 掉：先不吐，避免「显示过空格、落盘没有」。
    text = text.replaceFirst(RegExp(r'\s+$'), '');
    if (_undecidedIncompleteLine(text)) {
      return '';
    }
    return text;
  }

  /// 行尾未闭合的 JSON 对象起点：`\{[^{}\n]*$` 命中则从 `{` 扣起。
  /// 已闭合的对象（`{…}` 完整）不扣——那已经不是「未落定」形态。
  int _unresolvedJsonObject(String text) {
    final open = text.lastIndexOf('{');
    if (open < 0) {
      return -1;
    }
    final rest = text.substring(open);
    if (rest.contains('}') || rest.contains('\n')) {
      return -1;
    }
    return open;
  }

  /// 行尾是否还可能长成动作键/值控制构造（[_modelControlPatterns] 后两
  /// 项的前缀形态）：控制词左侧必须有边界（行首或空白/引号/冒号/逗号/
  /// 方括号），普通拉丁词尾（data、chat、方案A）因此不会被误扣。
  /// 返回形态起点（扣到此处），不可能成控制构造时返回 -1。这是流式
  /// 专属扣留——批处理看全量文本，不需要它。
  int _unresolvedControlTail(String text) {
    final match = _controlTailPattern.firstMatch(text);
    return match == null ? -1 : match.start;
  }

  /// 行内最后一个尚未落定的尖括号起点：它可能长成隐藏开标签（整块
  /// 扣住）或控制标签（一票否决），落定之前一律不吐。后面跟的不是
  /// 字母（如「3 < 5」）则不可能成标签，照常吐。
  int _unresolvedAngleBracket(String text) {
    final open = text.lastIndexOf('<');
    if (open < 0 || text.indexOf('>', open) >= 0) {
      return -1;
    }
    final after = text
        .substring(open + 1)
        .replaceFirst(RegExp(r'^\s*/?\s*'), '');
    if (after.isEmpty || RegExp(r'^[A-Za-z_]').hasMatch(after)) {
      return open;
    }
    return -1;
  }

  bool _undecidedIncompleteLine(String text) {
    if (text.isEmpty) {
      return false;
    }
    if (_ellipsisOnlyProgressPattern.hasMatch(text)) {
      return true; // 可能整行都是省略号
    }
    if (_codeFenceProgressPattern.hasMatch(text)) {
      return true; // 可能整行是代码围栏
    }
    if (_momentPrefixProgressPattern.hasMatch(text)) {
      return true; // 可能继续长成行首时刻前缀
    }
    if (_bracketedPauseProgressPattern.hasMatch(text)) {
      return true; // 可能长成括号停顿前缀
    }
    if (_couldBeSpeakerPrefix(text) || _couldBeBarePauseLine(text)) {
      return true;
    }
    return false;
  }

  bool _couldBeSpeakerPrefix(String text) {
    for (final name in _speakerPrefixNames) {
      if (name.startsWith(text)) {
        return true;
      }
      if (text.startsWith(name) &&
          RegExp(r'^\s*$').hasMatch(text.substring(name.length))) {
        return true;
      }
    }
    return false;
  }

  /// 是否还可能长成一条舞台提示行（整行丢弃）。候选串是
  /// [_barePauseLinePattern] 的展开，尾部标点与正则同形；改正则必须
  /// 同步这里（core 测试的 lockstep 用例钉住两边一致）。
  bool _couldBeBarePauseLine(String text) {
    for (final candidate in _barePauseCandidates) {
      if (candidate.startsWith(text)) {
        return true;
      }
      if (text.startsWith(candidate) &&
          _pauseTailPattern.hasMatch(text.substring(candidate.length))) {
        return true;
      }
    }
    return false;
  }

  String _hiddenTagOf(String tagText) {
    return RegExp(
          r'^<\s*/?\s*([A-Za-z0-9_-]+)',
        ).firstMatch(tagText)?.group(1) ??
        tagText;
  }
}

/// 未完结行的形态扣留：整行都可能被丢弃或被剥掉行首时一律不吐。
final _ellipsisOnlyProgressPattern = RegExp(r'^[.…]*$');

/// 代码围栏行的前缀形态：1–3 个反引号（可带语言名）。与
/// [_codeFenceLinePattern] 同形——4 个反引号不是围栏行，照常吐。
final _codeFenceProgressPattern = RegExp(r'^`{1,3}[A-Za-z0-9_-]*$');
final _momentPrefixProgressPattern = RegExp(r'^\[\d');
final _bracketedPauseProgressPattern = RegExp(r'^[（(【\[]\s*(?:[等想沉停]|$)');
final _pauseTailPattern = RegExp(r'^[。.!！?？,，\s：:]*$');

/// 控制词的全部前缀（流式扣留用）：行尾出现其中任一形态（可带引号、
/// 可带 `[:=]\s*` 前导）时，整段还可能长成动作键/值控制构造。
final _controlWordPrefixes = _buildControlWordPrefixes();

/// 控制构造的未落定尾部形态：动作键/值模式（[_modelControlPatterns] 后
/// 两项）的前缀。控制词左侧必须有边界，普通词尾不会被误扣。流式专属
/// 扣留——批处理看全量文本，不需要它。
final _controlTailPattern = RegExp(
  r'''(?:^|[\s"':{,\[])(?:[:=]\s*)?["']?(?:''' +
      _controlWordPrefixes +
      r''')["']?\s*$''',
  caseSensitive: false,
);

String _buildControlWordPrefixes() {
  final prefixes = <String>{};
  for (final word in _modelControlWords.split('|')) {
    for (var length = word.length; length >= 1; length -= 1) {
      prefixes.add(word.substring(0, length));
    }
  }
  // 长前缀优先：同一起点上正则优先吃掉最长的可能形态。
  final sorted = prefixes.toList()
    ..sort((left, right) => right.length.compareTo(left.length));
  return sorted.map(RegExp.escape).join('|');
}

/// 可整体剥除的未闭合隐藏结构标签名：批处理剥离与流式 finalize 共用
/// 同一份 const（[strippableUnclosedHiddenTags]）——两边因此不可能漂移。
final _strippableUnclosedTagPattern = RegExp(
  '^(?:$strippableUnclosedHiddenTags)\$',
  caseSensitive: false,
);

const _speakerPrefixNames = ['栖语', '她', '他'];

/// 舞台提示行的完整词表：由 [_barePauseStems] 展开生成（`?` 可省字符
/// 与 `(?:a|b)?` 可省组各展开成全部形态），与 [_barePauseLinePattern]
/// 因此严格同形。改正词干只改 const 一处。
final _barePauseCandidates = _expandBarePauseStems(_barePauseStems);

/// 舞台提示词干的展开：先按顶层 `|` 切分支，再在每个分支里展开 `?`
/// （前一个字符或整个 `(?:…)` 组可省）。够用且不引入正则引擎依赖。
List<String> _expandBarePauseStems(String stems) {
  final results = <String>[];
  for (final branch in _splitTopLevelAlternation(stems)) {
    results.addAll(_expandOptionalParts(branch));
  }
  return results;
}

/// 按顶层 `|` 切交替分支：组内的 `|`（括号深度 > 0）不切。
List<String> _splitTopLevelAlternation(String stems) {
  final branches = <String>[];
  var depth = 0;
  var start = 0;
  for (var index = 0; index < stems.length; index += 1) {
    final char = stems[index];
    if (char == '(') {
      depth += 1;
    } else if (char == ')') {
      depth -= 1;
    } else if (char == '|' && depth == 0) {
      branches.add(stems.substring(start, index));
      start = index + 1;
    }
  }
  branches.add(stems.substring(start));
  return branches;
}

/// 展开单个分支里的可省部分：字符后紧跟 `?` 或整个 `(?:…)` 组后紧跟
/// `?` 时，各产生「带 / 不带」两条分支。
List<String> _expandOptionalParts(String branch) {
  final results = <String>[];
  var prefix = '';
  var index = 0;
  while (index < branch.length) {
    final char = branch[index];
    if (char == '(') {
      final close = branch.indexOf(')', index);
      if (close < 0) {
        return [branch];
      }
      final inner = branch.substring(index + 1, close);
      final body = inner.startsWith('?:') ? inner.substring(2) : inner;
      final optional = close + 1 < branch.length && branch[close + 1] == '?';
      final rest = branch.substring(optional ? close + 2 : close + 1);
      for (final alternative in body.split('|')) {
        results.addAll(_expandOptionalParts('$prefix$alternative$rest'));
      }
      if (optional) {
        results.addAll(_expandOptionalParts('$prefix$rest'));
      }
      return results;
    }
    if (index + 1 < branch.length && branch[index + 1] == '?') {
      final rest = branch.substring(index + 2);
      results.addAll(_expandOptionalParts('$prefix$char$rest'));
      results.addAll(_expandOptionalParts('$prefix$rest'));
      return results;
    }
    prefix += char;
    index += 1;
  }
  results.add(prefix);
  return results;
}

String _normalizeNewlines(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String? _cleanVisibleLine(String value) {
  var text = value.trim();
  if (_codeFenceLinePattern.hasMatch(text)) {
    return null;
  }
  text = text.replaceFirst(MomentPrefix.pattern, '').trim();
  text = text.replaceFirst(_speakerPrefixPattern, '').trim();
  text = text.replaceFirst(_bracketedPausePrefixPattern, '').trim();
  if (text.isEmpty || _ellipsisOnlyPattern.hasMatch(text)) {
    return null;
  }
  if (_barePauseLinePattern.hasMatch(text)) {
    return null;
  }
  return text;
}
