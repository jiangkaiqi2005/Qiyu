import 'dart:io';

import 'package:path/path.dart' as path;

import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'open_loop_store.dart';
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
const _indexMaxDayKeywords = 4;
const _indexMaxMonthKeywords = 6;
const _indexKeywordMaxRunes = 12;

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
  });

  final String date;
  final FinalizationStatus status;

  /// 失败时的诊断细节（错误码或异常摘要），只进本机诊断。
  final String? detail;
}

final class FinalizationReport {
  const FinalizationReport({required this.outcomes});

  final List<FinalizationOutcome> outcomes;
}

/// 日终归档（五段节奏第三动作）。触发点：晚安、日期切换、启动补扫。
///
/// 固定顺序：当天摘要 → 待跟进候选 → 关系证据 → 近日状态包 → 索引 →
/// 标记 finalized。finalized 只在全部必要写入成功后设置；任一步失败
/// 保持 false，下一次触发从同一 checkpoint 幂等重试，不产生重复条目。
///
/// 晚安只触发日终归档；Dream 是五段节奏中独立的第五动作（ticket 16），
/// 本服务绝不调用它。
///
/// 本阶段归档全部为确定性投影（episodes → 摘要/状态包/索引），
/// 不依赖 Provider；未配置模型时也完整可用。语义判定类步骤
/// （open-loop 提升、关系阶段升降、PersonaTree 中间理解）分别归
/// ticket 11/12/14，此处只维护它们的落盘机制。
final class DailyFinalizationService {
  DailyFinalizationService({
    required this.memoryDirectory,
    required this.episodePipeline,
    OpenLoopStore? openLoopStore,
    RelationshipLifecycle? relationshipLifecycle,
    Clock? clock,
    AtomicTextWriter? atomicWriter,
  }) : _clock = clock ?? DateTime.now,
       _atomicWriter = atomicWriter ?? const IoAtomicTextWriter(),
       _openLoopStore = openLoopStore ??
           OpenLoopStore(
             memoryDirectory: memoryDirectory,
             atomicWriter: atomicWriter ?? const IoAtomicTextWriter(),
           ),
       _relationshipLifecycle = relationshipLifecycle ??
           RelationshipLifecycle(
             memoryDirectory: memoryDirectory,
             atomicWriter: atomicWriter ?? const IoAtomicTextWriter(),
             clock: clock ?? DateTime.now,
           );

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final OpenLoopStore _openLoopStore;
  final RelationshipLifecycle _relationshipLifecycle;
  final Clock _clock;
  final AtomicTextWriter _atomicWriter;

  File get _dailyStateFile => File(path.join(memoryDirectory, 'daily-state.md'));
  File get _topIndexFile =>
      File(path.join(memoryDirectory, 'episodes', 'index.md'));

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
  Future<FinalizationReport> catchUpUnfinalized({required String before}) async {
    final outcomes = <FinalizationOutcome>[];
    final dates = await episodePipeline.listEpisodeDates();
    for (final date in dates) {
      if (date.compareTo(before) >= 0) {
        continue;
      }
      try {
        outcomes.add(await finalizeDay(date, episodeDates: dates));
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
  /// 复用已扫描的日期列表；缺省时自行扫描。
  Future<FinalizationOutcome> finalizeDay(
    String date, {
    List<String>? episodeDates,
  }) => episodePipeline.synchronizedOnDayFiles(
    () => _finalizeDayLocked(date, episodeDates),
  );

  Future<FinalizationOutcome> _finalizeDayLocked(
    String date,
    List<String>? episodeDates,
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
    final entries = _validEntries(day.entries);
    if (entries.isEmpty) {
      // 只有系统错误、敏感信息或纯簿记条目的一天没有可投影内容：
      // 不写 daily-state。但热层的闭环归档与过期清理是 store 级动作，
      // 与当天条目无关，仍要执行，否则 closed 条目永远进不了归档；
      // 关系证据同理——只有深谈信号的一天也是真实互动，relationship
      // 更新必须照跑。
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

    // 固定顺序，任一步失败则 finalized 保持 false，下次整体重跑：
    // 1. 当天摘要；2. 待跟进候选；3. 关系证据；4. 近日状态包；5. 索引。
    // TODO(ticket 14): PersonaTree 中间理解的建立、挂载与整理也归日终。
    final summary = _buildSummary(entries);
    await _writeStep(date, () => episodePipeline.writeFinalization(
      date,
      entries: day.entries,
      summary: summary,
      finalized: false,
    ));
    await _writeStep(date, () => _processFollowUpCandidates(date, day.entries));
    await _writeStep(
      date,
      () => _relationshipLifecycle.updateAtEndOfDay(date, episodePipeline, dates),
    );
    await _writeStep(date, () => _rebuildDailyState(date, dates));
    await _writeStep(date, () => _rebuildIndexes(dates, includingDay: date));
    await episodePipeline.writeFinalization(
      date,
      entries: day.entries,
      summary: summary,
      finalized: true,
      finalizedAt: _clock().toUtc(),
    );
    return FinalizationOutcome(date: date, status: FinalizationStatus.finalized);
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
      final key = _normalize(text);
      if (key.isEmpty || !seen.add(key)) {
        continue;
      }
      parts.add(text);
      if (parts.length >= _dailySummaryMaxEntries) {
        break;
      }
    }
    return _clip(parts.join('；'), dailySummaryMaxRunes);
  }

  /// 待跟进候选（固定顺序第 2 步，ticket 11）：
  /// 1. 提升当天 episode 中的 open-loop 候选——只有字段合法、未被禁提、
  ///    不与既有事项重复且热层预算允许时才成为正式 Open-loop；
  /// 2. 已闭环条目挪入归档（热层只留 active/paused）；
  /// 3. 过期清理：due 过期仍无下文的事项按「过期」归档。
  /// 三个动作都幂等；open-loops.md 结构无法识别时整体保留不动。
  Future<void> _processFollowUpCandidates(
    String date,
    List<EpisodeEntry> entries,
  ) async {
    final candidates = entries
        .where((entry) => entry.kind == episodeKindOpenLoopCandidate)
        .toList();
    if (candidates.isNotEmpty) {
      await _openLoopStore.promoteCandidates(candidates);
    }
    await _openLoopStore.archiveClosed(date);
    await _openLoopStore.expireStale(_clock());
  }

  /// 近日状态包：每天从近 7 天 episodes 从头重写，不接龙旧状态包。
  /// 方向单向：episodes → daily-state；窗口内有可读日却没有有效证据时
  /// 删除旧文件，绝不用过期内容或猜测填充。窗口内日文件全部不可读
  /// （损坏）时保留现存投影不动，交给恢复流程（ticket 21）处理。
  Future<void> _rebuildDailyState(String date, List<String> dates) async {
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
      final valid = _validEntries(day.entries);
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
        openLoopTitles.contains(_normalize(entry.summary));

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
          '${_clip(entry.summary.trim(), _dailyStateMaxItemRunes)}',
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
        .map((entry) => '- ${_clip(entry.summary.trim(), _dailyStateMaxItemRunes)}')
        .toList();

    final sections = StringBuffer()
      ..writeln('# daily-state')
      ..writeln()
      ..writeln('date: $date')
      ..writeln()
      ..writeln('## 时间感')
      ..writeln(_timeSense(_clock()));
    var usedRunes = sections.toString().runes.length;
    String renderSection(String title, List<String> items) {
      final body = StringBuffer()
        ..writeln()
        ..writeln('## $title');
      for (final item in items) {
        body.writeln(item);
      }
      return body.toString();
    }

    final recentSection = recent.isEmpty
        ? ''
        : renderSection('用户当前近况', recent);
    var activeSection = active.isEmpty
        ? ''
        : renderSection('近日活跃', active);
    // 预算关：超限时先砍近日活跃（最旧优先）；当前近况是最新一天的
    // 事实，预算上永远放得下，不参与裁剪。
    while (usedRunes + activeSection.runes.length + recentSection.runes.length >
            dailyStateMaxRunes &&
        active.isNotEmpty) {
      active.removeAt(0);
      activeSection = active.isEmpty
          ? ''
          : renderSection('近日活跃', active);
    }
    final contents = '$sections$activeSection$recentSection';
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

  /// 两级索引（月份索引 + 每日索引）只在日终更新，且只收录已归档、
  /// 有有效条目的日期。整体重建保证补跑幂等、失败不残留半份索引。
  /// [includingDay] 是本次正在归档的日期：索引步骤先于 finalized 标记，
  /// 构建时把它视作已归档，避免当天永远缺席索引。
  Future<void> _rebuildIndexes(
    List<String> dates, {
    String? includingDay,
  }) async {
    final monthDayLines = <String, List<String>>{};
    final monthKeywords = <String, List<String>>{};
    for (final date in dates) {
      final day = await episodePipeline.readDay(date);
      if (!day.readable) {
        continue;
      }
      if (!day.finalized && date != includingDay) {
        continue;
      }
      final valid = _validEntries(day.entries);
      if (valid.isEmpty) {
        continue;
      }
      final keywords = <String>[];
      final seen = <String>{};
      for (final entry in valid) {
        final keyword = _clip(entry.summary.trim(), _indexKeywordMaxRunes);
        final key = _normalize(keyword);
        if (key.isEmpty || !seen.add(key)) {
          continue;
        }
        keywords.add(keyword);
        if (keywords.length >= _indexMaxDayKeywords) {
          break;
        }
      }
      final month = date.substring(0, 7);
      (monthDayLines[month] ??= []).add(
        '- $date | ${keywords.join(', ')} | $date.md',
      );
      final monthList = monthKeywords[month] ??= [];
      for (final keyword in keywords) {
        final key = _normalize(keyword);
        final exists = monthList.any(
          (existing) => _normalize(existing) == key,
        );
        if (!exists) {
          monthList.add(keyword);
        }
      }
    }

    if (monthDayLines.isEmpty) {
      if (await _topIndexFile.exists()) {
        await _topIndexFile.delete();
      }
      return;
    }
    final topLines = <String>[];
    for (final month in monthDayLines.keys.toList()..sort()) {
      final monthPath = path.join(
        memoryDirectory,
        'episodes',
        month.substring(0, 4),
        month.substring(5, 7),
        'index.md',
      );
      await _atomicWriter.replace(
        monthPath,
        '# $month index\n\n${monthDayLines[month]!.join('\n')}\n',
      );
      final keywords = (monthKeywords[month] ?? [])
          .take(_indexMaxMonthKeywords)
          .join(', ');
      topLines.add(
        '- $month | $keywords | episodes/${month.substring(0, 4)}/'
        '${month.substring(5, 7)}/index.md',
      );
    }
    await _atomicWriter.replace(
      _topIndexFile.path,
      '# episodes index\n\n${topLines.join('\n')}\n',
    );
  }

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

/// 只保留可参与投影的条目：摘要非空，且不是系统簿记条目。
/// open_loop_event（状态变化/禁提）与 relationship_signal（关系证据）
/// 只留在 episode 里做追溯：前者不得进摘要、状态包或索引（簿记文字
/// 含禁提标题，进状态包就会随注入绕回）；后者按定稿只投影到
/// relationship.md 的近期变化，不走通用投影。
List<EpisodeEntry> _validEntries(List<EpisodeEntry> entries) => entries
    .where(
      (entry) =>
          entry.summary.trim().isNotEmpty &&
          entry.kind != episodeKindOpenLoopEvent &&
          entry.kind != episodeKindRelationshipSignal,
    )
    .toList();

DateTime _parseDate(String date) => DateTime(
  int.parse(date.substring(0, 4)),
  int.parse(date.substring(5, 7)),
  int.parse(date.substring(8, 10)),
);

/// 规范化用于语义去重比较：折叠空白并统一大小写；不改变落盘原文。
String _normalize(String value) => value
    .replaceAll(RegExp(r'\s+'), ' ')
    .toLowerCase()
    .trim();

String _clip(String value, int maxRunes) {
  final runes = value.runes;
  if (runes.length <= maxRunes) {
    return value;
  }
  return String.fromCharCodes(runes.take(maxRunes));
}
