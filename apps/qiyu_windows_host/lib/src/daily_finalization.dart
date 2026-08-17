import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'daily_understanding.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'provider_settings_service.dart';
import 'relationship_lifecycle.dart';

/// 每日状态包分块预算来自设计笔记定稿：daily-state 100-300 tokens、
/// open-loops 100-250 tokens、relationship 150-300 tokens。
/// 此处保守地按 1 rune ≈ 1 token 估算，rune 上限即 token 上限。
const dailyStateMaxRunes = 300;

/// 日终写入当天 episode 的摘要上限；摘要只复述当天条目，不做推断。
const dailySummaryMaxRunes = 120;

/// 近日状态包重建窗口：近 7 天 episodes（含当天）。
const recentStateWindowDays = 7;

const _dailySummaryMaxEntries = 5;
const _dailyStateMaxActiveItems = 6;
const _dailyStateMaxRecentItems = 4;
const _dailyStateMaxItemRunes = 28;

/// 启动/跨日补扫一次至多让最近这几天走模型理解调用，其余日期走
/// 确定性路径（Memory.md 日终归档定稿 2026-08-16）。更旧的未归档
/// 日期会在后续触发里按新预算继续补做。
const catchUpModelDayBudget = 3;

/// 单日归档结果。
enum FinalizationStatus {
  /// 当天完成固定顺序归档，finalized 已置 true。
  finalized,

  /// 当天已是 finalized，幂等跳过。
  alreadyFinalized,

  /// 当天无 episode 文件：没有有效对话就不归档，不制造虚假记忆。
  skippedMissing,

  /// 当天文件存在但无法解析（损坏或用户手写）：绝不覆盖，等待恢复流程。
  skippedUnreadable,

  /// 当天文件存在但没有可投影条目：置 finalized，不写 daily-state，
  /// 但 store 级清理（闭环归档/过期/关系证据）照常执行。
  finalizedEmpty,

  /// 归档中途写入失败：finalized 保持 false，下次触发时幂等重试。
  failed,
}

final class FinalizationOutcome {
  const FinalizationOutcome({
    required this.date,
    required this.status,
    this.detail,
    this.usedModel = false,
  });

  final String date;
  final FinalizationStatus status;

  /// 失败时的诊断细节（错误码或异常摘要），只进本机诊断。
  final String? detail;

  /// 本次归档是否发起过一次新的模型理解尝试（复用已持久化理解不计；
  /// 未配置 Provider 时客户端立即返回空，同样计一次尝试，避免预算
  /// 被反复试探）。供补扫的模型日预算记账。
  final bool usedModel;
}

final class FinalizationReport {
  const FinalizationReport({required this.outcomes});

  final List<FinalizationOutcome> outcomes;
}

/// 日终归档（五段节奏第三动作）。触发点：晚安、日期切换、启动补扫。
///
/// 固定顺序：模型理解（可选）→ 当天摘要 → 待跟进候选 → 关系证据 →
/// 近日状态包 → 索引 → PersonaTree 中间理解 → 标记 finalized。
/// finalized 只在全部必要写入成功后设置；任一步失败保持 false，
/// 下一次触发从同一 checkpoint 幂等重试，不产生重复条目。
///
/// 晚安只触发日终归档；Dream 是五段节奏中独立的第五动作（ticket 16），
/// 本服务绝不调用它。日终只做当天理解，跨天深度重组归 Dream。
///
/// 模型理解调用（Memory.md 日终归档定稿 2026-08-16）：配置了
/// [modelClient] 时，每个有有效内容的归档日先做一次模型调用，输入是
/// 日终要读写的全部（当天 episodes、open-loops、relationship、现状态包，
/// 脱敏后整包），模型一次产出理解型材料——当天 summary、情绪余波、
/// open-loop 候选与闭环判断、关系信号、索引主题词、persona 候选提示。
/// 代码守全部闸门：材料按白名单逐字段校验，不合规按字段丢；各字段
/// 仍走下面既有步骤的预算、禁提、棘轮与幂等写入。未配置 Provider、
/// 调用失败或输出全废时整体降级为原有确定性路径，finalized 照常。
/// 已持久化在日文件元数据的理解直接复用，不重复调用；启动补扫一次
/// 至多 [catchUpModelDayBudget] 天走模型调用，其余确定性。
///
/// 无模型时全部为确定性投影（episodes → 摘要/状态包/索引），完整可用。
/// PersonaTree 中间理解（ticket 14）也由本服务在日终调用
/// [PersonaTreeStore] 执行。
final class DailyFinalizationService {
  /// 工厂构造统一兜底默认组件：缺省 PersonaTree 必须与日终自己的
  /// Open-loop 存储共享同一实例，否则日终禁提清扫会因拿不到禁提
  /// 列表而静默失效。
  factory DailyFinalizationService({
    required String memoryDirectory,
    required EpisodeMemoryPipeline episodePipeline,
    OpenLoopStore? openLoopStore,
    RelationshipLifecycle? relationshipLifecycle,
    EpisodeIndexStore? indexStore,
    PersonaTreeStore? personaTree,
    ProviderChatClient? modelClient,
    Clock? clock,
    AtomicTextWriter? atomicWriter,
    void Function(String message)? diagnosticsSink,
  }) {
    final effectiveClock = clock ?? DateTime.now;
    final effectiveAtomicWriter = atomicWriter ?? const IoAtomicTextWriter();
    final effectiveOpenLoopStore = openLoopStore ??
        OpenLoopStore(
          memoryDirectory: memoryDirectory,
          atomicWriter: effectiveAtomicWriter,
        );
    return DailyFinalizationService._(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      openLoopStore: effectiveOpenLoopStore,
      relationshipLifecycle: relationshipLifecycle ??
          RelationshipLifecycle(
            memoryDirectory: memoryDirectory,
            atomicWriter: effectiveAtomicWriter,
            clock: effectiveClock,
          ),
      indexStore: indexStore ??
          EpisodeIndexStore(
            memoryDirectory: memoryDirectory,
            episodePipeline: episodePipeline,
            atomicWriter: effectiveAtomicWriter,
          ),
      personaTree: personaTree ??
          PersonaTreeStore(
            memoryDirectory: memoryDirectory,
            episodePipeline: episodePipeline,
            openLoopStore: effectiveOpenLoopStore,
            atomicWriter: effectiveAtomicWriter,
          ),
      modelClient: modelClient,
      clock: effectiveClock,
      atomicWriter: effectiveAtomicWriter,
      diagnosticsSink: diagnosticsSink,
    );
  }

  DailyFinalizationService._({
    required this.memoryDirectory,
    required this.episodePipeline,
    required this._openLoopStore,
    required this._relationshipLifecycle,
    required this._indexStore,
    required this._personaTree,
    required this._modelClient,
    required this._clock,
    required this._atomicWriter,
    required void Function(String message)? diagnosticsSink,
  }) : _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final OpenLoopStore _openLoopStore;
  final RelationshipLifecycle _relationshipLifecycle;
  final EpisodeIndexStore _indexStore;
  final PersonaTreeStore _personaTree;

  /// 日终模型理解调用的 Provider 客户端；null 时全确定性路径。
  final ProviderChatClient? _modelClient;
  final Clock _clock;
  final AtomicTextWriter _atomicWriter;
  final void Function(String) _diagnosticsSink;

  File get _dailyStateFile => File(path.join(memoryDirectory, 'daily-state.md'));

  /// 晚安归档：先补做所有更早的未完成日期，最后归档用户说晚安的当天。
  /// 当天放在最后，保证近日状态包以最新一天为窗口终点重建。
  Future<FinalizationReport> finalizeForBedtime({required String date}) async {
    final catchUp = await catchUpUnfinalized(before: date);
    final outcomes = <FinalizationOutcome>[...catchUp.outcomes];
    try {
      outcomes.add(await finalizeDay(date));
    } on Object catch (error) {
      outcomes.add(
        FinalizationOutcome(
          date: date,
          status: FinalizationStatus.failed,
          detail: '$error',
        ),
      );
    }
    return FinalizationReport(outcomes: outcomes);
  }

  /// 启动/跨日补扫：归档全部早于 [before] 且未 finalized 的日期。
  /// 当天（before 本身）仍在进行中，只有晚安才归档它。
  /// 单个日期失败不阻断其余日期，失败记入结果供诊断。
  /// 补扫期间复用同一份日期列表，避免逐日重复扫描目录。
  ///
  /// 模型预算：循环前先圈定最近 [catchUpModelDayBudget] 个未归档日
  /// 授予模型理解调用，其余日期确定性归档；已持久化理解的复用不占
  /// 预算。写入仍按日期**升序**执行：近日状态包每日整文件重建，
  /// 最新日最后归档，最终投影才以最新日为窗口终点。
  Future<FinalizationReport> catchUpUnfinalized({required String before}) async {
    final dates = await episodePipeline.listEpisodeDates();
    final past = dates
        .where((date) => date.compareTo(before) < 0)
        .toList();
    final pending = <String>[];
    for (final date in past) {
      final day = await episodePipeline.readDay(date);
      if (day.exists && day.readable && !day.finalized) {
        pending.add(date);
      }
    }
    final modelDates = pending.reversed
        .take(catchUpModelDayBudget)
        .toSet();
    final outcomes = <FinalizationOutcome>[];
    for (final date in past) {
      try {
        outcomes.add(
          await finalizeDay(
            date,
            episodeDates: dates,
            allowModel: modelDates.contains(date),
          ),
        );
      } on Object catch (error) {
        outcomes.add(
          FinalizationOutcome(
            date: date,
            status: FinalizationStatus.failed,
            detail: '$error',
          ),
        );
      }
    }
    return FinalizationReport(outcomes: outcomes);
  }

  /// 对指定日期执行一次日终归档。写入失败时抛出异常且 finalized 保持
  /// false；重复调用幂等（已归档日期直接跳过）。[episodeDates] 供补扫
  /// 复用已扫描的日期列表；缺省时自行扫描。[allowModel] 为 false 时
  /// 不发起新的模型理解调用（已持久化理解仍复用），补扫预算外的
  /// 日期走该路径。
  Future<FinalizationOutcome> finalizeDay(
    String date, {
    List<String>? episodeDates,
    bool allowModel = true,
  }) => episodePipeline.synchronizedOnDayFiles(
    () => _finalizeDayLocked(date, episodeDates, allowModel),
  );

  Future<FinalizationOutcome> _finalizeDayLocked(
    String date,
    List<String>? episodeDates,
    bool allowModel,
  ) async {
    final dates = episodeDates ?? await episodePipeline.listEpisodeDates();
    final day = await episodePipeline.readDay(date);
    if (!day.exists) {
      return FinalizationOutcome(date: date, status: FinalizationStatus.skippedMissing);
    }
    if (!day.readable) {
      return FinalizationOutcome(
        date: date,
        status: FinalizationStatus.skippedUnreadable,
      );
    }
    if (day.finalized) {
      return FinalizationOutcome(
        date: date,
        status: FinalizationStatus.alreadyFinalized,
      );
    }
    final entries = validEpisodeEntries(day.entries);
    if (entries.isEmpty) {
      // 只有系统错误、敏感信息或纯簿记条目的一天没有可投影内容：
      // 不调模型、不写 daily-state。但热层的闭环归档与过期清理是
      // store 级动作，与当天条目无关，仍要执行，否则 closed 条目永远
      // 进不了归档；关系证据同理——只有深谈信号的一天也是真实互动，
      // relationship 更新必须照跑。
      await _writeStep(date, () async {
        await _openLoopStore.archiveClosed(date);
        await _openLoopStore.expireStale(_clock());
        await _relationshipLifecycle.updateAtEndOfDay(
          date,
          episodePipeline,
          dates,
        );
      });
      await episodePipeline.writeFinalization(
        date,
        entries: day.entries,
        finalized: true,
        finalizedAt: _clock().toUtc(),
      );
      return FinalizationOutcome(
        date: date,
        status: FinalizationStatus.finalizedEmpty,
      );
    }

    // 模型理解调用（可选第 0 步）：未配置/失败/全废时为 null，
    // 以下各步全部退回确定性材料，finalized 语义不受影响。
    final understandingResult = await _understandingFor(
      date,
      day,
      entries,
      allowModel,
    );
    final understanding = understandingResult.understanding;
    final persistedUnderstanding = understanding
        ?.withCoverage(entries)
        .toJson();

    // 固定顺序，任一步失败则 finalized 保持 false，下次整体重跑：
    // 1. 当天摘要；2. 待跟进候选；3. 关系证据；4. 近日状态包；5. 索引；
    // 6. PersonaTree 中间理解（先补齐当天叶，再建立/挂载/整理）。
    final summary = understanding?.summary ?? _buildSummary(entries);
    await _writeStep(date, () => episodePipeline.writeFinalization(
      date,
      entries: day.entries,
      summary: summary,
      finalized: false,
      understanding: persistedUnderstanding,
    ));
    await _writeStep(
      date,
      () => _processFollowUpCandidates(date, day.entries, understanding),
    );
    await _writeStep(
      date,
      () => _relationshipLifecycle.updateAtEndOfDay(date, episodePipeline, dates),
    );
    await _writeStep(
      date,
      () => _rebuildDailyState(date, dates, mood: understanding?.mood),
    );
    await _writeStep(date, () => _rebuildIndexes(includingDay: date));
    await _writeStep(
      date,
      () => _personaTree.processDay(
        date,
        extraEntries: _personaHintEntries(date, understanding),
      ),
    );
    await episodePipeline.writeFinalization(
      date,
      entries: day.entries,
      summary: summary,
      finalized: true,
      finalizedAt: _clock().toUtc(),
      understanding: persistedUnderstanding,
    );
    return FinalizationOutcome(
      date: date,
      status: FinalizationStatus.finalized,
      usedModel: understandingResult.usedModel,
    );
  }

  /// 取得当天模型理解：已持久化且仍覆盖当前条目的理解按当前禁提
  /// 复查后直接复用（不重复调用）；否则在预算与配置允许时发起一次
  /// 调用。返回值里 [usedModel] 表示本次是否发起了新的理解尝试，
  /// 供补扫预算记账。
  Future<({DayUnderstanding? understanding, bool usedModel})>
  _understandingFor(
    String date,
    EpisodeDay day,
    List<EpisodeEntry> entries,
    bool allowModel,
  ) async {
    final banned = await _openLoopStore.bannedTitles();
    final persisted = day.understanding;
    if (persisted != null) {
      final restored = DayUnderstanding.fromJson(persisted).filterBanned(banned);
      if (!restored.isEmpty && restored.covers(entries)) {
        return (understanding: restored, usedModel: false);
      }
    }
    final client = _modelClient;
    if (client == null || !allowModel) {
      return (understanding: null, usedModel: false);
    }
    final understanding = await fetchDayUnderstanding(
      client: client,
      date: date,
      // 簿记条目（禁提/状态变化事件）含禁提标题，按定稿排除在一切
      // 投影与注入外，也不发送给 Provider；关系信号条目是白名单校验
      // 过的抽象状态，作为理解上下文保留。
      entries: day.entries
          .where((entry) => entry.kind != episodeKindOpenLoopEvent)
          .toList(),
      openLoops: await _readMemoryFile('open-loops.md'),
      relationship: await _readMemoryFile('relationship.md'),
      dailyState: await _readMemoryFile('daily-state.md'),
      bannedTitles: banned,
      diagnosticsSink: _diagnosticsSink,
    );
    return (understanding: understanding, usedModel: true);
  }

  Future<String?> _readMemoryFile(String fileName) async {
    final file = File(path.join(memoryDirectory, fileName));
    if (!await file.exists()) {
      return null;
    }
    try {
      return await file.readAsString(encoding: utf8);
    } on Object {
      return null;
    }
  }

  /// 模型理解的 open-loop 候选转成条目载荷，与 episode 候选一起走
  /// 同一套提升闸门（合法性/禁提/去重/预算）。
  List<EpisodeEntry> _modelLoopCandidates(
    String date,
    DayUnderstanding? understanding,
  ) {
    if (understanding == null) {
      return const [];
    }
    final at = _endOfDayUtc(date);
    return [
      for (final (index, candidate) in understanding.loopCandidates.indexed)
        EpisodeEntry(
          id: 'finalize:$date:loop:$index',
          sessionId: 'finalization',
          requestId: 'finalization',
          summary: candidate.title,
          at: at,
          kind: episodeKindOpenLoopCandidate,
          due: candidate.due,
          proactive: candidate.proactive,
          note: candidate.note,
        ),
    ];
  }

  /// 模型理解的画像候选提示转成条目载荷，走 PersonaTree 同一套
  /// 建叶闸门；指针落在日文件上（条目号为理解块内的引用）。
  List<EpisodeEntry> _personaHintEntries(
    String date,
    DayUnderstanding? understanding,
  ) {
    if (understanding == null) {
      return const [];
    }
    final at = _endOfDayUtc(date);
    return [
      for (final (index, hint) in understanding.personaHints.indexed)
        EpisodeEntry(
          id: 'finalize:$date:persona:$index',
          sessionId: 'finalization',
          requestId: 'finalization',
          summary: hint.summary,
          at: at,
          personaBranch: hint.branch,
          personaNature: hint.nature,
        ),
    ];
  }

  DateTime _endOfDayUtc(String date) {
    final parsed = _parseDate(date);
    return DateTime(parsed.year, parsed.month, parsed.day, 23).toUtc();
  }

  /// 把状态包等派生文件的写入统一包成归档失败语义。
  Future<void> _writeStep(String date, Future<void> Function() step) async {
    try {
      await step();
    } on MemoryRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw MemoryRepositoryException(
        code: 'finalization_write_failed',
        message: '日终归档写入失败，将在下次启动或空闲时重试。',
        retryable: true,
        cause: error,
      );
    }
  }

  /// 当天摘要：只按时间顺序复述当天条目的既有概括，去重并限长。
  String _buildSummary(List<EpisodeEntry> entries) {
    final parts = <String>[];
    final seen = <String>{};
    for (final entry in entries) {
      final text = entry.summary.trim();
      final key = normalizeMemoryText(text);
      if (key.isEmpty || !seen.add(key)) {
        continue;
      }
      parts.add(text);
      if (parts.length >= _dailySummaryMaxEntries) {
        break;
      }
    }
    return clipRunes(parts.join('；'), dailySummaryMaxRunes);
  }

  /// 待跟进候选（固定顺序第 2 步，ticket 11）：
  /// 1. 提升当天 episode 中的 open-loop 候选与模型理解候选——只有字段
  ///    合法、未被禁提、不与既有事项重复且热层预算允许时才成为正式
  ///    Open-loop；
  /// 2. 模型理解的闭环判断即时生效（只认清单里已有的事项）；
  /// 3. 已闭环条目挪入归档（热层只留 active/paused）；
  /// 4. 过期清理：due 过期仍无下文的事项按「过期」归档。
  /// 各动作都幂等；open-loops.md 结构无法识别时整体保留不动。
  Future<void> _processFollowUpCandidates(
    String date,
    List<EpisodeEntry> entries,
    DayUnderstanding? understanding,
  ) async {
    final candidates = [
      ...entries.where(
        (entry) => entry.kind == episodeKindOpenLoopCandidate,
      ),
      ..._modelLoopCandidates(date, understanding),
    ];
    if (candidates.isNotEmpty) {
      await _openLoopStore.promoteCandidates(candidates);
    }
    if (understanding != null) {
      for (final closure in understanding.loopClosures) {
        await _openLoopStore.applyStatusChange(
          title: closure.title,
          status: 'closed',
          result: closure.result,
        );
      }
    }
    await _openLoopStore.archiveClosed(date);
    await _openLoopStore.expireStale(_clock());
  }

  /// 近日状态包：每天从近 7 天 episodes 从头重写，不接龙旧状态包。
  /// 方向单向：episodes → daily-state；窗口内有可读日却没有有效证据时
  /// 删除旧文件，绝不用过期内容或猜测填充。窗口内日文件全部不可读
  /// （损坏）时保留现存投影不动，交给恢复流程（ticket 21）处理。
  ///
  /// [mood] 是日终模型理解产出的情绪余波，投影为「近日气氛」节
  /// （每日状态包定稿 2026-08-16）；未配置模型或模型未输出时本节
  /// 留空（不渲染），绝不编造。
  Future<void> _rebuildDailyState(
    String date,
    List<String> dates, {
    String? mood,
  }) async {
    final cutoff = localSessionDate(
      _parseDate(date).subtract(Duration(days: recentStateWindowDays - 1)),
    );
    final perDay = <String, List<EpisodeEntry>>{};
    var readableDays = 0;
    for (final candidate in dates) {
      if (candidate.compareTo(cutoff) < 0 || candidate.compareTo(date) > 0) {
        continue;
      }
      final day = await episodePipeline.readDay(candidate);
      if (!day.readable) {
        continue;
      }
      readableDays += 1;
      final valid = validEpisodeEntries(day.entries);
      if (valid.isNotEmpty) {
        perDay[candidate] = valid;
      }
    }
    final file = _dailyStateFile;
    if (perDay.isEmpty) {
      if (readableDays > 0 && await file.exists()) {
        await file.delete();
      }
      return;
    }

    final openLoopTitles = await _openLoopTitles();
    final latestDate = perDay.keys.reduce(
      (left, right) => left.compareTo(right) >= 0 ? left : right,
    );
    // 「一事只进其一」：已进 open-loop 的条目不重复进 daily-state。
    bool excluded(EpisodeEntry entry) =>
        openLoopTitles.contains(normalizeMemoryText(entry.summary));

    final active = <String>[];
    for (final dayDate in perDay.keys.toList()..sort()) {
      if (dayDate == latestDate) {
        continue;
      }
      for (final entry in perDay[dayDate]!) {
        if (excluded(entry)) {
          continue;
        }
        active.add(
          '- (${dayDate.substring(5)}) '
          '${clipRunes(entry.summary.trim(), _dailyStateMaxItemRunes)}',
        );
        if (active.length >= _dailyStateMaxActiveItems) {
          break;
        }
      }
      if (active.length >= _dailyStateMaxActiveItems) {
        break;
      }
    }
    final recent = perDay[latestDate]!
        .where((entry) => !excluded(entry))
        .take(_dailyStateMaxRecentItems)
        .map((entry) => '- ${clipRunes(entry.summary.trim(), _dailyStateMaxItemRunes)}')
        .toList();

    final sections = StringBuffer()
      ..writeln('# daily-state')
      ..writeln()
      ..writeln('date: $date')
      ..writeln()
      ..writeln('## 时间感')
      ..writeln(_timeSense(_clock()));
    String renderSection(String title, List<String> items) {
      final body = StringBuffer()
        ..writeln()
        ..writeln('## $title');
      for (final item in items) {
        body.writeln(item);
      }
      return body.toString();
    }

    final trimmedMood = mood?.trim() ?? '';
    var moodSection = trimmedMood.isEmpty
        ? ''
        : renderSection(
            '近日气氛',
            [clipRunes(trimmedMood, understandingMoodMaxRunes)],
          );
    final recentSection = recent.isEmpty
        ? ''
        : renderSection('用户当前近况', recent);
    var activeSection = active.isEmpty
        ? ''
        : renderSection('近日活跃', active);
    var usedRunes = sections.toString().runes.length + moodSection.runes.length;
    // 预算关（T09 砍序：气氛描述是 daily-state 内的可牺牲项）：超限
    // 先整体砍掉近日气氛，再砍近日活跃（最旧优先）；当前近况是最新
    // 一天的事实，预算上永远放得下，不参与裁剪。
    if (usedRunes + activeSection.runes.length + recentSection.runes.length >
        dailyStateMaxRunes) {
      moodSection = '';
      usedRunes = sections.toString().runes.length;
    }
    while (usedRunes + activeSection.runes.length + recentSection.runes.length >
            dailyStateMaxRunes &&
        active.isNotEmpty) {
      active.removeAt(0);
      activeSection = active.isEmpty
          ? ''
          : renderSection('近日活跃', active);
    }
    final contents = '$sections$moodSection$activeSection$recentSection';
    await _atomicWriter.replace(file.path, contents);
  }

  Future<Set<String>> _openLoopTitles() async {
    final items = await _openLoopStore.readItems();
    if (items == null) {
      return const {};
    }
    return items
        .map((item) => normalizeLoopTitle(item.title))
        .where((title) => title.isNotEmpty)
        .toSet();
  }

  /// 日终归档内的索引步骤：从原始 episode 整体重建两级索引，日终路径
  /// 只收录已归档、有有效条目的日期。整体重建保证补跑幂等、失败不
  /// 残留半份索引。（召回修复是另一条重建路径：索引缺失或损坏时
  /// 收录全部可读日期，见 MemoryRecallService。）
  /// [includingDay] 是本次正在归档的日期：索引步骤先于 finalized 标记，
  /// 构建时把它视作已归档，避免当天永远缺席索引。
  Future<void> _rebuildIndexes({String? includingDay}) =>
      _indexStore.rebuild(includingDay: includingDay);

  String _timeSense(DateTime now) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final local = now.toLocal();
    final weekday = weekdays[local.weekday - 1];
    final hour = local.hour;
    final period = hour < 5
        ? '凌晨'
        : hour < 11
        ? '上午'
        : hour < 14
        ? '中午'
        : hour < 18
        ? '下午'
        : hour < 23
        ? '晚上'
        : '深夜';
    return '$weekday$period';
  }
}

DateTime _parseDate(String date) => DateTime(
  int.parse(date.substring(0, 4)),
  int.parse(date.substring(5, 7)),
  int.parse(date.substring(8, 10)),
);

