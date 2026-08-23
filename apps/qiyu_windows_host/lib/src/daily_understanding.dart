import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'daily_finalization.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_controls.dart';
import 'model_gateway.dart';
import 'model_text_protocol.dart';
import 'persona_tree.dart';
import 'provider_settings_service.dart';

/// 情绪余波投影到 daily-state「近日气氛」的长度上限（runes）。
const understandingMoodMaxRunes = 30;

/// 模型理解各条目的长度上限（runes）：理解只留线索，细节回证据。
const understandingTitleMaxRunes = 30;
const understandingNoteMaxRunes = 40;
const understandingDueMaxRunes = 40;
const understandingResultMaxRunes = 30;

/// 白名单数量上限：代码侧闸门。提示词里另声明了更严格的写作限值
/// （如 summary 60 字），超限输出会被保留，但仍在既有落盘预算内。
const understandingMaxLoopCandidates = 2;
const understandingMaxLoopClosures = 1;
const understandingMaxRelationshipSignals = 1;
const understandingMaxPersonaHints = 1;
const understandingMaxEpisodeEntries = 40;
const understandingEvidenceMaxRunes = 80;

/// 日终理解调用的输出预算：一次要返回当天全部 episode 条目（上限
/// 40 条 × 摘要 60 字 + 摘录 80 字）加整份 covered_request_ids 清单
/// 的单个 JSON 对象，远超聊天的少说护栏。按旧 tokenizer 汉字可到
/// 2 token/字估算最坏输出可超 1 万 token，预算不足时输出被截断，
/// JSON 解析必失败，归档会整体推迟（8-20 起三天的真实事故）。
const understandingMaxOutputTokens = 16384;

/// open-loop proactive 字段白名单。
const _understandingProactiveWhitelist = {'no', 'once', 'yes'};

/// 关系信号白名单（与隐藏动作协议同一套取值）。
const _understandingSignalWhitelist = {
  'deep_talk',
  'temperature',
  'boundary_open',
  'boundary_close',
};

/// 画像来源性质白名单。
const _understandingNatureWhitelist = {'self_report', 'behavior'};

/// 待跟进候选（白名单校验后）。
typedef UnderstandingLoopCandidate = ({
  String title,
  String? due,
  String? proactive,
  String? note,
});

/// 闭环判断（白名单校验后）。
typedef UnderstandingLoopClosure = ({String title, String? result});

/// 关系信号（白名单校验后）。
typedef UnderstandingSignal = ({String signal, String summary});

/// 画像候选提示（白名单校验后）。
typedef UnderstandingPersonaHint = ({
  String branch,
  String nature,
  String summary,
});

/// 日终从 sessions 补建的 episode 候选。requestId 只能引用本次递给
/// 模型的待补用户轮，代码侧还会做成员校验。
typedef UnderstandingEpisodeEntry = ({
  String requestId,
  String summary,
  String? evidence,
});

/// 日终一次模型理解调用的产出（Memory.md 日终归档定稿 2026-08-16）。
///
/// 所有字段都经过白名单校验、脱敏与禁提过滤；不合规字段在解析时
/// 按字段丢弃，全废时整体视作无产出。[entryCount]/[lastEntryId]
/// 记录本理解覆盖的当天条目范围：条目变化后理解作废，防止用旧
/// 理解归档新增内容。
final class DayUnderstanding {
  const DayUnderstanding({
    this.summary,
    this.mood,
    this.loopCandidates = const [],
    this.loopClosures = const [],
    this.relationshipSignals = const [],
    this.indexKeywords = const [],
    this.personaHints = const [],
    this.episodeEntries = const [],
    this.coveredRequestIds = const [],
    this.entryCount,
    this.lastEntryId,
  });

  final String? summary;
  final String? mood;
  final List<UnderstandingLoopCandidate> loopCandidates;
  final List<UnderstandingLoopClosure> loopClosures;
  final List<UnderstandingSignal> relationshipSignals;
  final List<String> indexKeywords;
  final List<UnderstandingPersonaHint> personaHints;
  final List<UnderstandingEpisodeEntry> episodeEntries;
  final List<String> coveredRequestIds;
  final int? entryCount;
  final String? lastEntryId;

  bool get isEmpty =>
      summary == null &&
      mood == null &&
      loopCandidates.isEmpty &&
      loopClosures.isEmpty &&
      relationshipSignals.isEmpty &&
      indexKeywords.isEmpty &&
      personaHints.isEmpty &&
      episodeEntries.isEmpty &&
      coveredRequestIds.isEmpty;

  /// 本理解是否仍覆盖当前条目集合（条目只追加不删除，比较数量与
  /// 末条 ID 即可）。
  bool covers(List<EpisodeEntry> entries) =>
      entryCount == entries.length &&
      (entries.isEmpty || lastEntryId == entries.last.id);

  DayUnderstanding withCoverage(List<EpisodeEntry> entries) => DayUnderstanding(
    summary: summary,
    mood: mood,
    loopCandidates: loopCandidates,
    loopClosures: loopClosures,
    relationshipSignals: relationshipSignals,
    indexKeywords: indexKeywords,
    personaHints: personaHints,
    coveredRequestIds: coveredRequestIds,
    entryCount: entries.length,
    lastEntryId: entries.isEmpty ? null : entries.last.id,
  );

  /// 按当前禁提清单逐字段丢弃违规内容。持久化时已过滤过一次；
  /// 复用已持久化理解前再查一次，覆盖「模型调用与失败重试之间用户
  /// 新增禁提」的窗口，防止被禁内容经重跑复活进投影与注入。
  DayUnderstanding filterBanned(Set<String> bannedTitles) {
    if (bannedTitles.isEmpty) {
      return this;
    }
    bool hit(String text) => bannedMemoryText(text, bannedTitles);
    return DayUnderstanding(
      summary: _dropBanned(summary, bannedTitles),
      mood: _dropBanned(mood, bannedTitles),
      // 与解析侧策略一致：标题命中禁提整条丢弃；子字段命中只置空。
      loopCandidates: [
        for (final candidate in loopCandidates)
          if (!hit(candidate.title))
            (
              title: candidate.title,
              due: _dropBanned(candidate.due, bannedTitles),
              proactive: candidate.proactive,
              note: _dropBanned(candidate.note, bannedTitles),
            ),
      ],
      loopClosures: [
        for (final closure in loopClosures)
          if (!hit(closure.title))
            (
              title: closure.title,
              result: _dropBanned(closure.result, bannedTitles),
            ),
      ],
      relationshipSignals: relationshipSignals
          .where((signal) => !hit(signal.summary))
          .toList(),
      indexKeywords: indexKeywords.where((keyword) => !hit(keyword)).toList(),
      personaHints: personaHints.where((hint) => !hit(hint.summary)).toList(),
      episodeEntries: episodeEntries
          .where((entry) => !hit(entry.summary))
          .map(
            (entry) => (
              requestId: entry.requestId,
              summary: entry.summary,
              evidence: _dropBanned(entry.evidence, bannedTitles),
            ),
          )
          .toList(),
      coveredRequestIds: coveredRequestIds,
      entryCount: entryCount,
      lastEntryId: lastEntryId,
    );
  }

  Map<String, Object?> toJson() => {
    if (summary != null) 'summary': summary,
    if (mood != null) 'mood': mood,
    if (loopCandidates.isNotEmpty)
      'loopCandidates': [
        for (final candidate in loopCandidates)
          {
            'title': candidate.title,
            if (candidate.due != null) 'due': candidate.due,
            if (candidate.proactive != null) 'proactive': candidate.proactive,
            if (candidate.note != null) 'note': candidate.note,
          },
      ],
    if (loopClosures.isNotEmpty)
      'loopClosures': [
        for (final closure in loopClosures)
          {
            'title': closure.title,
            if (closure.result != null) 'result': closure.result,
          },
      ],
    if (relationshipSignals.isNotEmpty)
      'relationshipSignals': [
        for (final signal in relationshipSignals)
          {'signal': signal.signal, 'summary': signal.summary},
      ],
    if (indexKeywords.isNotEmpty) 'indexKeywords': indexKeywords,
    if (personaHints.isNotEmpty)
      'personaHints': [
        for (final hint in personaHints)
          {
            'branch': hint.branch,
            'nature': hint.nature,
            'summary': hint.summary,
          },
      ],
    if (coveredRequestIds.isNotEmpty) 'coveredRequestIds': coveredRequestIds,
    if (entryCount != null) 'entryCount': entryCount,
    if (lastEntryId != null) 'lastEntryId': lastEntryId,
  };

  /// 从持久化元数据还原；逐个字段重新走保守校验，损坏字段按字段丢。
  static DayUnderstanding fromJson(Map<String, Object?> json) {
    String? text(String key) {
      final value = json[key];
      if (value is! String) {
        return null;
      }
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    List<Map<String, Object?>> objects(String key) {
      final value = json[key];
      if (value is! List<Object?>) {
        return const [];
      }
      return value.whereType<Map<String, Object?>>().toList();
    }

    final candidates = <UnderstandingLoopCandidate>[];
    for (final item in objects('loopCandidates')) {
      final title = _clipText(item['title'], understandingTitleMaxRunes);
      if (title == null) {
        continue;
      }
      final proactive = item['proactive'];
      candidates.add((
        title: title,
        due: _clipText(item['due'], understandingDueMaxRunes),
        proactive:
            proactive is String &&
                _understandingProactiveWhitelist.contains(proactive)
            ? proactive
            : null,
        note: _clipText(item['note'], understandingNoteMaxRunes),
      ));
    }
    final closures = <UnderstandingLoopClosure>[];
    for (final item in objects('loopClosures')) {
      final title = _clipText(item['title'], understandingTitleMaxRunes);
      if (title == null) {
        continue;
      }
      closures.add((
        title: title,
        result: _clipText(item['result'], understandingResultMaxRunes),
      ));
    }
    final signals = <UnderstandingSignal>[];
    for (final item in objects('relationshipSignals')) {
      final signal = item['signal'];
      final summary = _clipText(item['summary'], understandingTitleMaxRunes);
      if (signal is! String ||
          !_understandingSignalWhitelist.contains(signal) ||
          summary == null) {
        continue;
      }
      signals.add((signal: signal, summary: summary));
    }
    final keywords = <String>[];
    final keywordValue = json['indexKeywords'];
    if (keywordValue is List<Object?>) {
      for (final keyword in keywordValue.whereType<String>()) {
        final clipped = _clipText(keyword, indexKeywordMaxRunes);
        if (clipped != null) {
          keywords.add(clipped);
        }
      }
    }
    final hints = <UnderstandingPersonaHint>[];
    for (final item in objects('personaHints')) {
      final branch = item['branch'];
      final nature = item['nature'];
      final summary = _clipText(item['summary'], understandingTitleMaxRunes);
      if (branch is! String ||
          personaBranchForWire(branch) == null ||
          nature is! String ||
          !_understandingNatureWhitelist.contains(nature) ||
          summary == null) {
        continue;
      }
      if (branch == 'identity' && nature != 'self_report') {
        continue;
      }
      hints.add((branch: branch, nature: nature, summary: summary));
    }
    final coveredRequestIds = _coveredRequestIds(json['coveredRequestIds']);
    final entryCount = json['entryCount'];
    final lastEntryId = json['lastEntryId'];
    return DayUnderstanding(
      summary: text('summary'),
      mood: text('mood'),
      loopCandidates: candidates,
      loopClosures: closures,
      relationshipSignals: signals,
      indexKeywords: keywords,
      personaHints: hints,
      coveredRequestIds: coveredRequestIds,
      entryCount: entryCount is int ? entryCount : null,
      lastEntryId: lastEntryId is String ? lastEntryId : null,
    );
  }
}

String? _clipText(Object? value, int maxRunes) {
  if (value is! String) {
    return null;
  }
  final cleaned = redactSessionText(value).trim();
  if (cleaned.isEmpty) {
    return null;
  }
  return clipRunes(cleaned, maxRunes);
}

/// 禁提子字段过滤的统一形态：命中禁提置 null，其余原样返回。
String? _dropBanned(String? value, Set<String> bannedTitles) =>
    value != null && bannedMemoryText(value, bannedTitles) ? null : value;

/// covered_request_ids 的统一解析（持久化键与模型输出键共用）：只收
/// 非空且未重复的 requestId，保持原序。
List<String> _coveredRequestIds(Object? value) {
  if (value is! List<Object?>) {
    return const [];
  }
  final ids = <String>[];
  for (final requestId in value.whereType<String>()) {
    final trimmed = requestId.trim();
    if (trimmed.isNotEmpty && !ids.contains(trimmed)) {
      ids.add(trimmed);
    }
  }
  return ids;
}

/// 执行日终一次模型理解调用。未配置 Provider（返回 null）、调用失败
/// 或输出全废时返回 null，调用方走既有确定性路径。
Future<DayUnderstanding?> fetchDayUnderstanding({
  required ProviderChatClient client,
  required String date,
  required List<EpisodeEntry> entries,
  required String? openLoops,
  required String? relationship,
  required String? dailyState,
  required Set<String> bannedTitles,
  List<RawSession> sessions = const [],
  Set<String> pendingRequestIds = const <String>{},
  void Function(String message)? diagnosticsSink,
}) async {
  final sink = diagnosticsSink ?? stderrDiagnostics;
  ModelCompletion? completion;
  try {
    completion = await client.complete(
      _understandingMessages(
        date: date,
        entries: entries,
        openLoops: openLoops,
        relationship: relationship,
        dailyState: dailyState,
        sessions: sessions,
        pendingRequestIds: pendingRequestIds,
        bannedTitles: bannedTitles,
      ),
      maxTokens: understandingMaxOutputTokens,
    );
  } on Object catch (error) {
    sink('day understanding deferred [$error] date=$date');
    return null;
  }
  if (completion == null) {
    // 未配置 Provider：静默走确定性路径。
    return null;
  }
  final text = completion.text;
  if (text == null) {
    sink(
      'day understanding deferred [${completion.failure?.name ?? 'failure'}] '
      'date=$date',
    );
    return null;
  }
  final understanding = parseDayUnderstanding(
    text,
    bannedTitles: bannedTitles,
    diagnosticsSink: sink,
    dateForDiagnostics: date,
  );
  if (understanding == null) {
    sink('day understanding dropped reason=unparseable date=$date');
    return null;
  }
  if (understanding.isEmpty) {
    sink('day understanding dropped reason=empty date=$date');
    return null;
  }
  return understanding;
}

/// 解析并白名单校验模型输出：只认 JSON 对象；每个字段独立校验，
/// 不合规按字段丢；整体无法解析返回 null。
DayUnderstanding? parseDayUnderstanding(
  String raw, {
  required Set<String> bannedTitles,
  void Function(String message)? diagnosticsSink,
  String? dateForDiagnostics,
}) {
  final sink = diagnosticsSink ?? stderrDiagnostics;
  final dateLabel = dateForDiagnostics == null
      ? ''
      : ' date=$dateForDiagnostics';
  void dropped(String reason) =>
      sink('day understanding field dropped [$reason]$dateLabel');

  final json = extractJsonObject(raw);
  if (json == null) {
    return null;
  }
  bool banned(String text) => bannedMemoryText(text, bannedTitles);

  final summary = _clipText(json['summary'], dailySummaryMaxRunes);
  if (summary != null && banned(summary)) {
    dropped('summary banned');
  }
  final mood = _clipText(json['mood'], understandingMoodMaxRunes);
  if (mood != null && banned(mood)) {
    dropped('mood banned');
  }

  final episodeEntries = <UnderstandingEpisodeEntry>[];
  for (final item in _objects(json['episode_entries'])) {
    if (episodeEntries.length >= understandingMaxEpisodeEntries) {
      break;
    }
    final requestId = item['request_id'];
    final summaryText = _clipText(item['summary'], dailySummaryMaxRunes);
    if (requestId is! String ||
        requestId.trim().isEmpty ||
        summaryText == null ||
        banned(summaryText)) {
      dropped('episode entry invalid or banned');
      continue;
    }
    final evidence = _clipText(item['evidence'], understandingEvidenceMaxRunes);
    episodeEntries.add((
      requestId: requestId.trim(),
      summary: summaryText,
      evidence: _dropBanned(evidence, bannedTitles),
    ));
  }
  final coveredRequestIds = _coveredRequestIds(json['covered_request_ids']);

  // 数量上限按「收纳条目」计：先校验后计数，无效项不占名额。
  final candidates = <UnderstandingLoopCandidate>[];
  for (final item in _objects(json['loop_candidates'])) {
    if (candidates.length >= understandingMaxLoopCandidates) {
      break;
    }
    final title = _clipText(item['title'], understandingTitleMaxRunes);
    if (title == null) {
      dropped('loop candidate missing title');
      continue;
    }
    if (banned(title)) {
      dropped('loop candidate banned');
      continue;
    }
    final proactive = item['proactive'];
    final note = _clipText(item['note'], understandingNoteMaxRunes);
    // due 同样落盘进 open-loops.md 并随状态包注入，必须过禁提。
    final due = _clipText(item['due'], understandingDueMaxRunes);
    candidates.add((
      title: title,
      due: _dropBanned(due, bannedTitles),
      proactive:
          proactive is String &&
              _understandingProactiveWhitelist.contains(proactive)
          ? proactive
          : null,
      note: _dropBanned(note, bannedTitles),
    ));
  }

  final closures = <UnderstandingLoopClosure>[];
  for (final item in _objects(json['loop_closures'])) {
    if (closures.length >= understandingMaxLoopClosures) {
      break;
    }
    final title = _clipText(item['title'], understandingTitleMaxRunes);
    if (title == null || banned(title)) {
      dropped('loop closure invalid or banned');
      continue;
    }
    final result = _clipText(item['result'], understandingResultMaxRunes);
    closures.add((title: title, result: _dropBanned(result, bannedTitles)));
  }

  final signals = <UnderstandingSignal>[];
  for (final item in _objects(json['relationship_signals'])) {
    if (signals.length >= understandingMaxRelationshipSignals) {
      break;
    }
    final signal = item['signal'];
    final summaryText = _clipText(item['summary'], understandingTitleMaxRunes);
    if (signal is! String || !_understandingSignalWhitelist.contains(signal)) {
      dropped('relationship signal not in whitelist');
      continue;
    }
    if (summaryText == null || banned(summaryText)) {
      dropped('relationship signal invalid or banned');
      continue;
    }
    signals.add((signal: signal, summary: summaryText));
  }

  final keywords = <String>[];
  final rawKeywords = json['index_keywords'];
  if (rawKeywords is List<Object?>) {
    for (final keyword in sanitizeIndexKeywords(
      rawKeywords.whereType<String>(),
    )) {
      if (banned(keyword)) {
        continue;
      }
      keywords.add(keyword);
    }
  }

  final hints = <UnderstandingPersonaHint>[];
  for (final item in _objects(json['persona_hints'])) {
    if (hints.length >= understandingMaxPersonaHints) {
      break;
    }
    final branch = item['branch'];
    final nature = item['nature'];
    final summaryText = _clipText(item['summary'], understandingTitleMaxRunes);
    if (branch is! String || personaBranchForWire(branch) == null) {
      dropped('persona hint branch not in whitelist');
      continue;
    }
    if (nature is! String || !_understandingNatureWhitelist.contains(nature)) {
      dropped('persona hint nature not in whitelist');
      continue;
    }
    if (branch == 'identity' && nature != 'self_report') {
      dropped('identity hint must be self_report');
      continue;
    }
    if (summaryText == null || banned(summaryText)) {
      dropped('persona hint invalid or banned');
      continue;
    }
    hints.add((branch: branch, nature: nature, summary: summaryText));
  }

  return DayUnderstanding(
    summary: _dropBanned(summary, bannedTitles),
    mood: _dropBanned(mood, bannedTitles),
    loopCandidates: candidates,
    loopClosures: closures,
    relationshipSignals: signals,
    indexKeywords: keywords,
    personaHints: hints,
    episodeEntries: episodeEntries,
    coveredRequestIds: coveredRequestIds,
  );
}

Iterable<Map<String, Object?>> _objects(Object? value) sync* {
  if (value is! List<Object?>) {
    return;
  }
  for (final item in value) {
    if (item is Map<String, Object?>) {
      yield item;
    }
  }
}

/// 轮次文本经消息侧清洗管道（脱敏 + 结构清洗）后是否还有可送模型的
/// 内容；无可送内容返回 null。pending 判定与消息渲染必须共用这一份
/// 实现：两边口径分叉会造出「pending 里有、消息里没有」的死锁轮次，
/// 模型永远无法覆盖它。
String? backfillableTurnText(String text) {
  final safeText = sanitizeUserInput(redactSessionText(text)).trim();
  return safeText.isEmpty ? null : safeText;
}

List<ModelMessage> _understandingMessages({
  required String date,
  required List<EpisodeEntry> entries,
  required String? openLoops,
  required String? relationship,
  required String? dailyState,
  required List<RawSession> sessions,
  required Set<String> pendingRequestIds,
  required Set<String> bannedTitles,
}) {
  const system = '''
你是栖语日终归档的本机记忆整理模块。给你某一天的原始会话、已有对话整理记录与当前记忆状态，请产出当天的理解材料。要求：
1. 只输出一个 JSON 对象，不要输出任何其它文字、解释或代码块标记。
2. 所有内容必须来自给定材料，不得编造、不得引入材料外的事实；只做当天理解，不做跨天深度重组。
3. 没有把握或材料中没有依据的字段直接省略。
4. 密码、密钥、证件号、银行卡号等敏感内容一律不得出现。
5. 从已有 sessions 补建缺失的 episode，而不是只处理已经存在的 episode。只补“待补 requestId”标出的用户轮；日常琐事、临时状态、随口提到的生活细节和项目进展也要记录，不要只挑长期稳定或重大事项。寒暄、重复内容和纯测试话语可以不生成 episode，但仍要在完整处理后写入 covered_request_ids。
字段白名单：
- episode_entries: 数组，从待补用户轮整理出的 episode；每项 {"request_id": 必须取自待补 requestId, "summary": 不超过60字的事实概括, "evidence": 可选的用户原话摘录，不超过80字}。同一轮有多件小事可以分成多项。
- covered_request_ids: 数组。只有完整检查过全部待补用户轮时才输出；直接从「## 待补 requestId 清单」原样复制全部条目，不得遗漏、改写或编造。
- summary: 字符串，当天发生了什么的一句话概括，不超过60字，只复述记录中真实出现的事。
- mood: 字符串，用户当天留下的情绪气氛余波，不超过20字；材料中没有情绪线索就省略。
- loop_candidates: 数组，最多2项，用户提到且之后可能需要跟进的事；每项 {"title": 不超过24字的简称, "due": 可选的跟进时间, "note": 可选说明不超过30字}；材料中已有跟进安排或已闭环的事项不要重复。
- loop_closures: 数组，最多1项，未闭环事项清单中已有结果、可以闭环的事项；每项 {"title": 与清单中完全一致的事项名称, "result": 不超过20字的结果}。
- relationship_signals: 数组，最多1项，当天互动体现出的关系信号；每项 {"signal": deep_talk、temperature、boundary_open、boundary_close 之一, "summary": 自然抽象的状态描述，不超过30字，不复制原话}。
- index_keywords: 数组，3到4个当天主题词，每个不超过10字；要提炼主题，不要截断句子。
- persona_hints: 数组，最多1项，用户稳定画像（身份、性格表达、价值原则、偏好习惯、边界禁区）的新线索；每项 {"branch": identity、expression、values、preferences、boundaries 之一, "nature": self_report表示用户明确说过，behavior表示行为观察, "summary": 不超过30字}；identity 只允许 self_report。''';

  final entryLines = StringBuffer();
  for (final entry in entries) {
    if (bannedMemoryText(entry.summary, bannedTitles)) {
      continue;
    }
    final label = entry.kind == episodeKindMemory
        ? '记忆'
        : entry.kind == episodeKindOpenLoopCandidate
        ? '待跟进候选'
        : entry.kind == episodeKindOpenLoopEvent
        ? '跟进状态变化'
        : '关系信号${entry.signal == null ? '' : ':${entry.signal}'}';
    entryLines.writeln('- [$label] ${redactSessionText(entry.summary).trim()}');
  }
  final sessionLines = StringBuffer();
  for (final session in sessions) {
    for (final turn in session.turns) {
      if (!pendingRequestIds.contains(turn.requestId)) {
        continue;
      }
      final speaker = turn.speaker == Speaker.user ? '用户' : '栖语';
      final backfillable = backfillableTurnText(turn.text);
      if (backfillable == null) {
        continue;
      }
      var safeText = backfillable;
      if (bannedMemoryText(safeText, bannedTitles)) {
        safeText = '[受记忆控制内容已隐藏]';
      }
      sessionLines.writeln(
        '- [${session.id}][${turn.requestId}][$speaker] $safeText',
      );
    }
  }
  // 记忆文件段（open-loops / relationship / daily-state）逐段脱敏。
  // 绝不能对整包 user 消息再做一次脱敏：requestId 与 session id 是
  // 协议标识，其中的长数字段会被卡号样式规则误伤成 [已脱敏]，
  // 模型从此无法复述完整 id，补建覆盖校验会无限推迟（8-20 死锁）。
  String guardedSection(String? section) =>
      section == null ? '' : redactSessionText(section);
  // 待补 id 以纯清单单独给出：模型从长对话行里逐字抠 id 极易遗漏，
  // 清单化后 covered_request_ids 只是原样复制。
  final idList = StringBuffer();
  for (final requestId in pendingRequestIds) {
    idList.writeln('- $requestId');
  }
  final user = StringBuffer()
    ..writeln('日期：$date')
    ..writeln()
    ..writeln('## 当天对话整理记录')
    ..write(entryLines.isEmpty ? '（无）\n' : entryLines.toString())
    ..writeln()
    ..writeln('## sessions 待补范围')
    ..write(sessionLines.isEmpty ? '（无）\n' : sessionLines.toString())
    ..writeln()
    ..writeln('## 未闭环事项')
    ..writeln(sectionOrEmpty(guardedSection(openLoops)))
    ..writeln()
    ..writeln('## 关系状态')
    ..writeln(sectionOrEmpty(guardedSection(relationship)))
    ..writeln()
    ..writeln('## 现状态包')
    ..write(sectionOrEmpty(guardedSection(dailyState)))
    ..writeln()
    ..writeln()
    ..writeln('## 待补 requestId 清单')
    ..write(idList.isEmpty ? '（无）\n' : idList.toString());
  return [
    const ModelMessage(ModelMessageRole.system, system),
    ModelMessage(ModelMessageRole.user, user.toString()),
  ];
}
