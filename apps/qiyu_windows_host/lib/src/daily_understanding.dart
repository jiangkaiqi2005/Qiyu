import 'dart:convert';

import 'daily_finalization.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'open_loop_store.dart';
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
  final int? entryCount;
  final String? lastEntryId;

  bool get isEmpty =>
      summary == null &&
      mood == null &&
      loopCandidates.isEmpty &&
      loopClosures.isEmpty &&
      relationshipSignals.isEmpty &&
      indexKeywords.isEmpty &&
      personaHints.isEmpty;

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
    bool hit(String text) =>
        bannedTitleMatches(normalizeMemoryText(text), bannedTitles);
    return DayUnderstanding(
      summary: summary != null && hit(summary!) ? null : summary,
      mood: mood != null && hit(mood!) ? null : mood,
      // 与解析侧策略一致：标题命中禁提整条丢弃；子字段命中只置空。
      loopCandidates: [
        for (final candidate in loopCandidates)
          if (!hit(candidate.title))
            (
              title: candidate.title,
              due: candidate.due != null && hit(candidate.due!)
                  ? null
                  : candidate.due,
              proactive: candidate.proactive,
              note: candidate.note != null && hit(candidate.note!)
                  ? null
                  : candidate.note,
            ),
      ],
      loopClosures: [
        for (final closure in loopClosures)
          if (!hit(closure.title))
            (
              title: closure.title,
              result: closure.result != null && hit(closure.result!)
                  ? null
                  : closure.result,
            ),
      ],
      relationshipSignals: relationshipSignals
          .where((signal) => !hit(signal.summary))
          .toList(),
      indexKeywords: indexKeywords.where((keyword) => !hit(keyword)).toList(),
      personaHints: personaHints
          .where((hint) => !hit(hint.summary))
          .toList(),
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
          {'branch': hint.branch, 'nature': hint.nature, 'summary': hint.summary},
      ],
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
        proactive: proactive is String &&
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
      final summary = _clipText(
        item['summary'],
        understandingTitleMaxRunes,
      );
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
      ),
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
  final dateLabel = dateForDiagnostics == null ? '' : ' date=$dateForDiagnostics';
  void dropped(String reason) =>
      sink('day understanding field dropped [$reason]$dateLabel');

  final json = _extractJsonObject(raw);
  if (json == null) {
    return null;
  }
  bool banned(String text) =>
      bannedTitleMatches(normalizeMemoryText(text), bannedTitles);

  final summary = _clipText(json['summary'], dailySummaryMaxRunes);
  if (summary != null && banned(summary)) {
    dropped('summary banned');
  }
  final mood = _clipText(json['mood'], understandingMoodMaxRunes);
  if (mood != null && banned(mood)) {
    dropped('mood banned');
  }

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
      due: due != null && banned(due) ? null : due,
      proactive: proactive is String &&
              _understandingProactiveWhitelist.contains(proactive)
          ? proactive
          : null,
      note: note != null && banned(note) ? null : note,
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
    closures.add((
      title: title,
      result: result != null && banned(result) ? null : result,
    ));
  }

  final signals = <UnderstandingSignal>[];
  for (final item in _objects(json['relationship_signals'])) {
    if (signals.length >= understandingMaxRelationshipSignals) {
      break;
    }
    final signal = item['signal'];
    final summaryText = _clipText(
      item['summary'],
      understandingTitleMaxRunes,
    );
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
    final summaryText = _clipText(
      item['summary'],
      understandingTitleMaxRunes,
    );
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
    summary: summary != null && !banned(summary) ? summary : null,
    mood: mood != null && !banned(mood) ? mood : null,
    loopCandidates: candidates,
    loopClosures: closures,
    relationshipSignals: signals,
    indexKeywords: keywords,
    personaHints: hints,
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

/// 从模型输出中提取 JSON 对象：容忍代码块围栏与前后多余文字，
/// 只取第一个 `{` 到最后一个 `}` 之间的内容。
Map<String, Object?>? _extractJsonObject(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return null;
  }
  try {
    final decoded = jsonDecode(raw.substring(start, end + 1));
    return decoded is Map<String, Object?> ? decoded : null;
  } on Object {
    return null;
  }
}

List<ModelMessage> _understandingMessages({
  required String date,
  required List<EpisodeEntry> entries,
  required String? openLoops,
  required String? relationship,
  required String? dailyState,
}) {
  const system = '''
你是栖语日终归档的本机记忆整理模块。给你某一天的对话整理记录与当前记忆状态，请产出当天的理解材料。要求：
1. 只输出一个 JSON 对象，不要输出任何其它文字、解释或代码块标记。
2. 所有内容必须来自给定材料，不得编造、不得引入材料外的事实；只做当天理解，不做跨天深度重组。
3. 没有把握或材料中没有依据的字段直接省略。
4. 密码、密钥、证件号、银行卡号等敏感内容一律不得出现。
字段白名单：
- summary: 字符串，当天发生了什么的一句话概括，不超过60字，只复述记录中真实出现的事。
- mood: 字符串，用户当天留下的情绪气氛余波，不超过20字；材料中没有情绪线索就省略。
- loop_candidates: 数组，最多2项，用户提到且之后可能需要跟进的事；每项 {"title": 不超过24字的简称, "due": 可选的跟进时间, "note": 可选说明不超过30字}；材料中已有跟进安排或已闭环的事项不要重复。
- loop_closures: 数组，最多1项，未闭环事项清单中已有结果、可以闭环的事项；每项 {"title": 与清单中完全一致的事项名称, "result": 不超过20字的结果}。
- relationship_signals: 数组，最多1项，当天互动体现出的关系信号；每项 {"signal": deep_talk、temperature、boundary_open、boundary_close 之一, "summary": 自然抽象的状态描述，不超过30字，不复制原话}。
- index_keywords: 数组，3到4个当天主题词，每个不超过10字；要提炼主题，不要截断句子。
- persona_hints: 数组，最多1项，用户稳定画像（身份、性格表达、价值原则、偏好习惯、边界禁区）的新线索；每项 {"branch": identity、expression、values、preferences、boundaries 之一, "nature": self_report表示用户明确说过，behavior表示行为观察, "summary": 不超过30字}；identity 只允许 self_report。''';

  final entryLines = StringBuffer();
  for (final entry in entries) {
    final label = entry.kind == episodeKindMemory
        ? '记忆'
        : entry.kind == episodeKindOpenLoopCandidate
        ? '待跟进候选'
        : entry.kind == episodeKindOpenLoopEvent
        ? '跟进状态变化'
        : '关系信号${entry.signal == null ? '' : ':${entry.signal}'}';
    entryLines.writeln('- [$label] ${redactSessionText(entry.summary).trim()}');
  }
  final user = StringBuffer()
    ..writeln('日期：$date')
    ..writeln()
    ..writeln('## 当天对话整理记录')
    ..write(
      entryLines.isEmpty ? '（无）\n' : entryLines.toString(),
    )
    ..writeln()
    ..writeln('## 未闭环事项')
    ..writeln(_sectionOrEmpty(openLoops))
    ..writeln()
    ..writeln('## 关系状态')
    ..writeln(_sectionOrEmpty(relationship))
    ..writeln()
    ..writeln('## 现状态包')
    ..write(_sectionOrEmpty(dailyState));
  return [
    const ModelMessage(ModelMessageRole.system, system),
    ModelMessage(ModelMessageRole.user, redactSessionText(user.toString())),
  ];
}

String _sectionOrEmpty(String? contents) {
  final trimmed = contents?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return '（无）';
  }
  return trimmed;
}
