import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'episode_memory.dart';
import 'markdown_memory_repository.dart';

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

  /// 当天文件存在但没有有效条目：只置 finalized，不写任何状态包。
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
    Clock? clock,
    AtomicTextWriter? atomicWriter,
  }) : _clock = clock ?? DateTime.now,
       _atomicWriter = atomicWriter ?? const IoAtomicTextWriter();

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final Clock _clock;
  final AtomicTextWriter _atomicWriter;

  File get _openLoopsFile => File(path.join(memoryDirectory, 'open-loops.md'));
  File get _openLoopsArchiveFile =>
      File(path.join(memoryDirectory, 'open-loops.archive.md'));
  File get _relationshipFile =>
      File(path.join(memoryDirectory, 'relationship.md'));
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
      // 只有系统错误或敏感信息的一天不会留下条目：只置 organized 标记
      // 防止反复重扫，绝不写任何状态包内容。
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
    await _writeStep(date, () => _archiveClosedOpenLoops(date));
    await _writeStep(date, () => _ensureRelationshipFile(dates));
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

  /// 待跟进候选：把 status: closed 的 open-loop 挪入归档文件。
  /// 热层只留 active/paused；归档文件不注入、不占热层预算。
  /// 结构无法识别时（例如用户手写内容）原样保留，绝不覆盖。
  Future<void> _archiveClosedOpenLoops(String date) async {
    final file = _openLoopsFile;
    if (!await file.exists()) {
      return;
    }
    final contents = await file.readAsString(encoding: utf8);
    final items = _splitOpenLoopItems(contents);
    if (items == null) {
      return;
    }
    final kept = <String>[];
    final archivedLines = <String>[];
    for (final item in items) {
      if (_isOpenLoopClosed(item)) {
        archivedLines.add(_archiveLineFor(item, date));
      } else {
        kept.add(item);
      }
    }
    if (archivedLines.isEmpty) {
      return;
    }
    // 整体重写归档文件（读-合并-去重-写），补跑不会重复追加。
    final existingLines = await _openLoopsArchiveFile.exists()
        ? (await _openLoopsArchiveFile.readAsString(encoding: utf8))
              .replaceAll('\r\n', '\n')
              .split('\n')
              .where((line) => line.trim().isNotEmpty)
              .toList()
        : <String>['# open-loops archive'];
    final seenLines = existingLines.toSet();
    for (final line in archivedLines) {
      if (seenLines.add(line)) {
        existingLines.add(line);
      }
    }
    await _atomicWriter.replace(
      _openLoopsArchiveFile.path,
      '${existingLines.join('\n')}\n',
    );
    final keptBody = kept.isEmpty ? '' : '\n${kept.join('\n')}\n';
    await _atomicWriter.replace(file.path, '# open-loops\n$keptBody');
  }

  /// 把 open-loops.md 拆成条目块；无法识别结构时返回 null（不得改动）。
  List<String>? _splitOpenLoopItems(String contents) {
    final lines = contents.replaceAll('\r\n', '\n').split('\n');
    final items = <String>[];
    final current = <String>[];
    var sawItem = false;
    for (final line in lines) {
      if (RegExp(r'^- \[').hasMatch(line)) {
        if (current.isNotEmpty) {
          items.add(_joinItem(current));
        }
        current
          ..clear()
          ..add(line);
        sawItem = true;
      } else if (sawItem) {
        current.add(line);
      } else if (line.trim().isNotEmpty && !line.startsWith('#')) {
        // 条目之外存在无法识别的正文：视为用户内容，整体不动。
        return null;
      }
    }
    if (current.isNotEmpty) {
      items.add(_joinItem(current));
    }
    return items;
  }

  String _joinItem(List<String> lines) {
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  bool _isOpenLoopClosed(String item) => RegExp(
    r'^\s*status\s*[:：]\s*closed\s*$',
    multiLine: true,
  ).hasMatch(item);

  String _archiveLineFor(String item, String date) {
    final titleMatch = RegExp(
      r'^- \[[^\]]+\]\s*(.*)$',
      multiLine: true,
    ).firstMatch(item);
    final title = (titleMatch?.group(1) ?? '').trim();
    final noteMatch = RegExp(
      r'^\s*note\s*[:：]\s*(.*)$',
      multiLine: true,
    ).firstMatch(item);
    final result = (noteMatch?.group(1) ?? '').trim();
    return '- ${title.isEmpty ? '未命名事项' : title} | 闭环: $date | '
        '${result.isEmpty ? '已闭环' : result}';
  }

  /// 关系证据：只负责确保 relationship.md 以初识起步存在；既有文件
  /// 一律不覆盖——阶段升降与温度变化归 ticket 12，记忆控制归 ticket 18。
  Future<void> _ensureRelationshipFile(List<String> dates) async {
    final file = _relationshipFile;
    if (await file.exists()) {
      return;
    }
    final since = dates.isEmpty ? localSessionDate(_clock()) : dates.first;
    final contents = '# relationship\n'
        '\n'
        'stage: 初识\n'
        'since: $since\n'
        '阶段描述: 初识阶段：以回应当前话题为主；不调侃、不翻旧账、'
        '不主动追问私事。\n';
    await _atomicWriter.replace(file.path, contents);
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
    final file = _openLoopsFile;
    if (!await file.exists()) {
      return const {};
    }
    final contents = await file.readAsString(encoding: utf8);
    final titles = <String>{};
    for (final match in RegExp(
      r'^- \[[^\]]+\]\s*(.*)$',
      multiLine: true,
    ).allMatches(contents)) {
      final title = _normalize(match.group(1) ?? '');
      if (title.isNotEmpty) {
        titles.add(title);
      }
    }
    return titles;
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

/// 只保留摘要非空的条目；摘要是日终全部投影的唯一内容来源。
List<EpisodeEntry> _validEntries(List<EpisodeEntry> entries) => entries
    .where((entry) => entry.summary.trim().isNotEmpty)
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
