import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'daily_finalization.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_text_primitives.dart';
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

/// 「近日仍活跃」清单（每日状态包定稿 2026-09-22）：日终模型从当天
/// 整理记录、现状态包近日投影与未闭环事项里判断「哪些事仍然活跃、
/// 会影响当前对话」，随当天理解一并产出。条目是自然语言短句，数量
/// 与 daily-state 的近日活跃条数上限一致（状态包装配再按同一预算
/// 截一次）；单条上限与其余理解短句字段同一量级，渲染时仍受
/// daily-state 每条预算约束。
const understandingMaxActiveItems = 6;
const understandingActiveItemMaxRunes = 30;

/// 阶段描述的长度上限（runes）：日终模型结合具体用户生成的一段
/// 自然语言，随 relationship.md 的阶段描述落盘（该行不受写入关
/// 裁剪，故解析侧就要限住）。
const understandingStageDescriptionMaxRunes = 60;

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

/// episode 条目的 keep 取值白名单（与隐藏动作协议同一套取值）：
/// 只收 month——本条值得进入月压缩候选；其余记忆流向由 kind、提升
/// 流程与 memory_ban 承担，不经这个字段。
const _understandingKeepWhitelist = {memorySignalKeepMonth};

/// 待跟进候选（白名单校验后）。
typedef UnderstandingLoopCandidate = ({
  String title,
  String? due,
  String? proactive,
  String? note,
  String? keep,
});

/// 闭环判断（白名单校验后）。
typedef UnderstandingLoopClosure = ({String title, String? result});

/// 关系信号（白名单校验后）。
typedef UnderstandingSignal = ({String signal, String summary, String? keep});

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
  String? keep,
});

/// 日终一次模型理解调用的产出（Memory.md 日终归档定稿 2026-08-16）。
///
/// 所有字段都经过白名单校验、脱敏与禁提过滤；不合规字段在解析时
/// 按字段丢弃，全废时整体视作无产出。[entryCount]/[lastEntryId]
/// 记录本理解覆盖的当天条目范围：条目变化后理解作废，防止用旧
/// 理解归档新增内容。[activeItems] 是「近日仍活跃」清单（每日
/// 状态包定稿 2026-09-22）：空清单表示模型未输出，状态包装配按
/// 日期截取兜底。[relationshipStage]/[stageDescription] 是日终模型
/// 对这个用户的关系阶段做的整体语义判断（T20 定稿：判断是「目标」，
/// 升降由宿主的棘轮与每日一级决定）：阶段取值为既有
/// [RelationshipStage] 的 wire 名，描述是模型结合具体用户生成的
/// 一段自然语言；从未持久化过判断时阶段维持现状。
final class DayUnderstanding {
  const DayUnderstanding({
    this.summary,
    this.mood,
    this.loopCandidates = const [],
    this.loopClosures = const [],
    this.relationshipSignals = const [],
    this.relationshipStage,
    this.stageDescription,
    this.indexKeywords = const [],
    this.personaHints = const [],
    this.episodeEntries = const [],
    this.activeItems = const [],
    this.coveredRequestIds = const [],
    this.entryCount,
    this.lastEntryId,
  });

  final String? summary;
  final String? mood;
  final List<UnderstandingLoopCandidate> loopCandidates;
  final List<UnderstandingLoopClosure> loopClosures;
  final List<UnderstandingSignal> relationshipSignals;

  /// 日终模型判定的目标关系阶段（[RelationshipStage] 的 wire 名）；
  /// 没有判断时为 null。宿主只在它高于当前阶段时按棘轮前进。
  final String? relationshipStage;

  /// 模型结合这个具体用户生成的阶段描述；没有输出时为 null，
  /// relationship.md 回落阶段表行为边界文案。
  final String? stageDescription;
  final List<String> indexKeywords;
  final List<UnderstandingPersonaHint> personaHints;
  final List<UnderstandingEpisodeEntry> episodeEntries;

  /// 「近日仍活跃」清单：仍会影响当前对话的事项，供 daily-state 的
  /// 「近日活跃」节投影；条目为自然语言短句，与 open-loop 的排重由
  /// 状态包装配按文字规范化相等执行。
  final List<String> activeItems;
  final List<String> coveredRequestIds;
  final int? entryCount;
  final String? lastEntryId;

  bool get isEmpty =>
      summary == null &&
      mood == null &&
      loopCandidates.isEmpty &&
      loopClosures.isEmpty &&
      relationshipSignals.isEmpty &&
      relationshipStage == null &&
      stageDescription == null &&
      indexKeywords.isEmpty &&
      personaHints.isEmpty &&
      episodeEntries.isEmpty &&
      activeItems.isEmpty &&
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
    relationshipStage: relationshipStage,
    stageDescription: stageDescription,
    indexKeywords: indexKeywords,
    personaHints: personaHints,
    activeItems: activeItems,
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
              keep: candidate.keep,
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
          .map(
            (signal) => (
              signal: signal.signal,
              summary: signal.summary,
              keep: signal.keep,
            ),
          )
          .toList(),
      // 阶段 wire 名是枚举取值，无禁提面；描述是模型生成的用户相关
      // 文案，命中禁提整段置空（relationship.md 回落阶段表文案）。
      relationshipStage: relationshipStage,
      stageDescription: _dropBanned(stageDescription, bannedTitles),
      indexKeywords: indexKeywords.where((keyword) => !hit(keyword)).toList(),
      personaHints: personaHints.where((hint) => !hit(hint.summary)).toList(),
      episodeEntries: episodeEntries
          .where((entry) => !hit(entry.summary))
          .map(
            (entry) => (
              requestId: entry.requestId,
              summary: entry.summary,
              evidence: _dropBanned(entry.evidence, bannedTitles),
              keep: entry.keep,
            ),
          )
          .toList(),
      // 与解析侧策略一致：命中禁提整条丢弃，不留半句进状态包。
      activeItems: activeItems.where((item) => !hit(item)).toList(),
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
            if (candidate.keep != null) 'keep': candidate.keep,
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
          {
            'signal': signal.signal,
            'summary': signal.summary,
            if (signal.keep != null) 'keep': signal.keep,
          },
      ],
    if (relationshipStage != null) 'relationshipStage': relationshipStage,
    if (stageDescription != null) 'stageDescription': stageDescription,
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
    if (activeItems.isNotEmpty) 'activeItems': activeItems,
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
        keep: _persistedKeep(item['keep']),
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
      signals.add((
        signal: signal,
        summary: summary,
        keep: _persistedKeep(item['keep']),
      ));
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
    // 「近日仍活跃」清单：旧元数据没有该字段时按空清单还原（状态包
    // 装配侧对空清单走日期截取兜底，旧数据行为不变）。
    final activeItems = <String>[];
    final rawActiveItems = json['activeItems'];
    if (rawActiveItems is List<Object?>) {
      for (final item in rawActiveItems.whereType<String>()) {
        final clipped = _clipText(item, understandingActiveItemMaxRunes);
        if (clipped != null) {
          activeItems.add(clipped);
        }
      }
    }
    final entryCount = json['entryCount'];
    final lastEntryId = json['lastEntryId'];
    // 阶段判断的持久化还原：只认既有 RelationshipStage 的 wire 名，
    // 其余（缺失、非字符串、越界值）一律按无判断处理——阶段维持
    // 现状。描述与解析侧同一管道（脱敏 + 截断），缺失按 null。
    final rawStage = json['relationshipStage'];
    final stageWire = rawStage is String
        ? relationshipStageFromWire(rawStage.trim())?.wireName
        : null;
    return DayUnderstanding(
      summary: text('summary'),
      mood: text('mood'),
      loopCandidates: candidates,
      loopClosures: closures,
      relationshipSignals: signals,
      relationshipStage: stageWire,
      stageDescription: _clipText(
        json['stageDescription'],
        understandingStageDescriptionMaxRunes,
      ),
      indexKeywords: keywords,
      personaHints: hints,
      activeItems: activeItems,
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

/// 持久化 keep 的保守还原：只认白名单内的字符串，其余（缺失、非
/// 字符串、越界值）一律按未标记处理。
String? _persistedKeep(Object? value) =>
    value is String && _understandingKeepWhitelist.contains(value)
    ? value
    : null;

/// keep 字段的统一解析（episode_entries / loop_candidates /
/// relationship_signals 三类模型产出条目共用）：白名单外取值按字段
/// 丢弃并记诊断，条目本身保留。
String? _parseUnderstandingKeep(
  Object? value,
  void Function(String reason) dropped,
  String reason,
) {
  if (value is! String) {
    return null;
  }
  if (_understandingKeepWhitelist.contains(value)) {
    return value;
  }
  dropped(reason);
  return null;
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
  String? appellation,
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
        appellation: appellation,
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
      keep: _parseUnderstandingKeep(
        item['keep'],
        dropped,
        'episode entry keep not in whitelist',
      ),
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
      keep: _parseUnderstandingKeep(
        item['keep'],
        dropped,
        'loop candidate keep not in whitelist',
      ),
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
    signals.add((
      signal: signal,
      summary: summaryText,
      keep: _parseUnderstandingKeep(
        item['keep'],
        dropped,
        'relationship signal keep not in whitelist',
      ),
    ));
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

  // 「近日仍活跃」清单（每日状态包定稿 2026-09-22）：数量上限按收纳
  // 条目计，越界即停；超长条目截断保留（与其余理解字段同一口径），
  // 无效与命中禁提的条目整条丢弃，都记诊断。
  final activeItems = <String>[];
  final rawActiveItems = json['active_items'];
  if (rawActiveItems is List<Object?>) {
    for (final item in rawActiveItems.whereType<String>()) {
      if (activeItems.length >= understandingMaxActiveItems) {
        dropped('active items over count limit');
        break;
      }
      // 与 _clipText 同一管道（脱敏 + 去空白 + 截断），另记越界诊断。
      final cleaned = redactSessionText(item).trim();
      if (cleaned.isEmpty) {
        dropped('active item invalid');
        continue;
      }
      if (cleaned.runes.length > understandingActiveItemMaxRunes) {
        dropped('active item over rune limit');
      }
      final text = clipRunes(cleaned, understandingActiveItemMaxRunes);
      if (banned(text)) {
        dropped('active item banned');
        continue;
      }
      activeItems.add(text);
    }
  }

  // 关系阶段的整体语义判断（T20 定稿）：阶段取值白名单化（与
  // relationship.md 同一套 wire 名），描述与其余短句同一管道；
  // 描述只在有阶段判断时被宿主消费，单独输出不产生效果。
  final rawStage = json['relationship_stage'];
  final stageWire = rawStage is String
      ? relationshipStageFromWire(rawStage.trim())?.wireName
      : null;
  if (rawStage is String && stageWire == null) {
    dropped('relationship stage not in whitelist');
  }
  final stageDescription = _clipText(
    json['stage_description'],
    understandingStageDescriptionMaxRunes,
  );
  if (stageDescription != null && banned(stageDescription)) {
    dropped('stage description banned');
  }

  return DayUnderstanding(
    summary: _dropBanned(summary, bannedTitles),
    mood: _dropBanned(mood, bannedTitles),
    loopCandidates: candidates,
    loopClosures: closures,
    relationshipSignals: signals,
    relationshipStage: stageWire,
    stageDescription: _dropBanned(stageDescription, bannedTitles),
    indexKeywords: keywords,
    personaHints: hints,
    episodeEntries: episodeEntries,
    activeItems: activeItems,
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
  String? appellation,
}) {
  // 记忆表述惯例（称呼定稿 2026-09-03）：有称呼用称呼、无称呼用
  // 「用户」。称呼格式受控（无换行与控制字符、限长），可安全内嵌；
  // 值与主链画像块同源，进提示前套用同一份脱敏规则。
  final safeAppellation = appellation == null
      ? null
      : redactSessionText(appellation);
  final appellationRule = safeAppellation == null
      ? '6. 整理出的内容指称用户时一律写「用户」，不要替用户起昵称。'
      : '6. 整理出的内容指称用户时一律用称呼「$safeAppellation」，不要写'
            '「用户」，也不要替用户起昵称。';
  final system =
      '''
你是栖语日终归档的本机记忆整理模块。给你某一天的原始会话、已有对话整理记录与当前记忆状态，请产出当天的理解材料。要求：
1. 只输出一个 JSON 对象，不要输出任何其它文字、解释或代码块标记。
2. 所有内容必须来自给定材料，不得编造、不得引入材料外的事实；只做当天理解，不做跨天深度重组。
3. 没有把握或材料中没有依据的字段直接省略。
4. 密码、密钥、证件号、银行卡号等敏感内容一律不得出现。
5. 从已有 sessions 补建缺失的 episode，而不是只处理已经存在的 episode。只补“待补 requestId”标出的用户轮；日常琐事、临时状态、随口提到的生活细节和项目进展也要记录，不要只挑长期稳定或重大事项。寒暄、重复内容和纯测试话语可以不生成 episode，但仍要在完整处理后写入 covered_request_ids。
$appellationRule
字段白名单：
- episode_entries: 数组，从待补用户轮整理出的 episode；每项 {"request_id": 必须取自待补 requestId, "summary": 不超过60字的事实概括, "evidence": 可选的用户原话摘录，不超过80字, "keep": 可选的 "month"，只给值得进入月压缩的长期记忆}。同一轮有多件小事可以分成多项。日常琐事、临时状态、随口提到的生活细节不要标 keep。
- covered_request_ids: 数组。只有完整检查过全部待补用户轮时才输出；直接从「## 待补 requestId 清单」原样复制全部条目，不得遗漏、改写或编造。
- summary: 字符串，当天发生了什么的一句话概括，不超过60字，只复述记录中真实出现的事。
- mood: 字符串，用户当天留下的情绪气氛余波，不超过20字；材料中没有情绪线索就省略。
- active_items: 数组，最多6项，近日仍然活跃、会影响当前对话的事项。结合当天的对话整理记录、现状态包的近日投影与未闭环事项判断；每项不超过30字的自然语言短句，不带日期前缀，按对当前对话的重要性从高到低排列。已经结束、已闭环、只随口出现过一次就过去的小事不要列；不要因为上一期状态包的近日投影里出现过就继续列出，要按本次读到的材料重新判断哪些仍然影响当前对话；未闭环事项清单里已有的事不要重复列（一事只进其一，宿主还会按文字再排重一次）。没有仍然活跃的事项就省略本字段。
- loop_candidates: 数组，最多2项，用户提到且之后可能需要跟进的事；每项 {"title": 不超过24字的简称, "due": 可选的跟进时间, "note": 可选说明不超过30字, "keep": 可选的 "month"，只给即使整月未闭环也值得进月压缩的重要事项}；材料中已有跟进安排或已闭环的事项不要重复。日常琐事与临时任务不要标 keep。
- loop_closures: 数组，最多1项，未闭环事项清单中已有结果、可以闭环的事项；每项 {"title": 与清单中完全一致的事项名称, "result": 不超过20字的结果}。
- relationship_signals: 数组，最多1项，当天互动体现出的关系信号；每项 {"signal": deep_talk、temperature、boundary_open、boundary_close 之一, "summary": 自然抽象的状态描述，不超过30字，不复制原话, "keep": 可选的 "month"，只给体现关系阶段明显变化、值得进月压缩的信号}。一时的语气起伏不要标 keep。
- relationship_stage: 字符串，结合当天完整互动对这个用户当前的关系阶段做整体语义判断，取值为 初识、熟悉、朋友、深交 之一。依据当天的对话整理记录、关系信号与待补会话综合判断，不要数互动条数、活跃天数或时间跨度；深谈信号（deep_talk）可以独立支持升级；只能判定到有依据的级别，没有把握或看不出变化就省略本字段（省略不会让阶段回退，宿主也不会自行发明判断；此前日子已持久化的目标仍会按每天最多一级继续兑现，判断结果永远不会让阶段下降）。
- stage_description: 字符串，结合这个具体用户的相处实况写一段不超过60字的自然语言阶段描述，体现当前阶段能聊什么、不能做什么，以及你和这个用户之间真实的状态；不要写认识天数或统计数字，不要复述用户原话。没有输出 relationship_stage 时省略本字段。
- index_keywords: 数组，3到4个当天主题词，每个不超过10字；要提炼主题，不要截断句子。
- persona_hints: 数组，最多1项，用户稳定画像（身份、性格表达、价值原则、偏好习惯、边界禁区）的新线索；每项 {"branch": identity、expression、values、preferences、boundaries 之一, "nature": self_report表示用户明确说过，behavior表示行为观察, "summary": 不超过30字}；identity 只允许 self_report。''';

  final entryLines = StringBuffer();
  for (final entry in entries) {
    if (bannedMemoryText(entry.summary, bannedTitles)) {
      continue;
    }
    final label = switch (entry.kind) {
      episodeKindMemory => '记忆',
      episodeKindOpenLoopCandidate => '待跟进候选',
      episodeKindOpenLoopEvent => '跟进状态变化',
      // 其余（含关系信号与未知 kind）一律按关系信号渲染。
      _ => '关系信号${entry.signal == null ? '' : ':${entry.signal}'}',
    };
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
    ModelMessage(ModelMessageRole.system, system),
    ModelMessage(ModelMessageRole.user, user.toString()),
  ];
}
