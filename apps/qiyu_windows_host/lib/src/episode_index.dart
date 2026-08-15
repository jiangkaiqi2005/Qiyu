import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'episode_memory.dart';
import 'markdown_memory_repository.dart';

/// 每日索引行的关键词上限（日终归档定稿）。
const indexMaxDayKeywords = 4;

/// 月份索引行的关键词上限（日终归档定稿）。
const indexMaxMonthKeywords = 6;

/// 索引关键词长度上限（runes）。
const indexKeywordMaxRunes = 12;

/// 月份索引（`episodes/index.md`）的一行：月份 + 月关键词。
/// 路径不落数据类——本仓库 episodes 目录布局固定为
/// `episodes/YYYY/MM/`，路径由月份推导。
final class MonthIndexLine {
  const MonthIndexLine({required this.month, required this.keywords});

  final String month;
  final List<String> keywords;
}

/// 每日索引（`episodes/YYYY/MM/index.md`）的一行：日期 + 当天关键词。
final class DayIndexLine {
  const DayIndexLine({required this.date, required this.keywords});

  final String date;
  final List<String> keywords;
}

/// 只保留可参与投影的条目：摘要非空，且不是系统簿记条目。
/// open_loop_event（状态变化/禁提）与 relationship_signal（关系证据）
/// 只留在 episode 里做追溯：前者不得进摘要、状态包或索引（簿记文字
/// 含禁提标题，进状态包就会随注入绕回）；后者按定稿只投影到
/// relationship.md 的近期变化，不走通用投影。
List<EpisodeEntry> validEpisodeEntries(List<EpisodeEntry> entries) => entries
    .where(
      (entry) =>
          entry.summary.trim().isNotEmpty &&
          entry.kind != episodeKindOpenLoopEvent &&
          entry.kind != episodeKindRelationshipSignal,
    )
    .toList();

final _monthPattern = RegExp(r'^\d{4}-\d{2}$');
final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// 两级索引（月份索引 + 每日索引）的读取与重建。
///
/// 索引只负责定位文件，永远不是事实来源：行内只放关键词和路径，
/// 不放记忆正文；任何事实判断都必须回到索引指向的 daily episode
/// 原始证据（硬规则定稿）。
///
/// 重建是幂等的整体重写：从原始 episode 日文件推导全部索引内容，
/// 中途失败不会留下半份索引。日终归档（只收 finalized 日）与
/// 召回修复（收录全部可读日）共用同一套写入逻辑，仅收录范围不同。
final class EpisodeIndexStore {
  EpisodeIndexStore({
    required this.memoryDirectory,
    required this.episodePipeline,
    AtomicTextWriter? atomicWriter,
  }) : _atomicWriter = atomicWriter ?? const IoAtomicTextWriter();

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final AtomicTextWriter _atomicWriter;

  File get topIndexFile =>
      File(path.join(memoryDirectory, 'episodes', 'index.md'));

  File monthIndexFile(String month) => File(
    path.join(
      memoryDirectory,
      'episodes',
      month.substring(0, 4),
      month.substring(5, 7),
      'index.md',
    ),
  );

  /// 读取月份索引；文件不存在或无法解析出任何有效行时返回 null，
  /// 由调用方决定重建。
  Future<List<MonthIndexLine>?> readTopIndex() async {
    final lines = await _readIndexLines(topIndexFile);
    if (lines == null) {
      return null;
    }
    final result = <MonthIndexLine>[];
    for (final fields in lines) {
      if (fields.length < 2 || !_monthPattern.hasMatch(fields[0])) {
        continue;
      }
      result.add(
        MonthIndexLine(month: fields[0], keywords: _splitKeywords(fields[1])),
      );
    }
    return result.isEmpty ? null : result;
  }

  /// 读取某月每日索引；文件不存在或无法解析出任何有效行时返回 null。
  Future<List<DayIndexLine>?> readMonthIndex(String month) async {
    if (!_monthPattern.hasMatch(month)) {
      return null;
    }
    final lines = await _readIndexLines(monthIndexFile(month));
    if (lines == null) {
      return null;
    }
    final result = <DayIndexLine>[];
    for (final fields in lines) {
      if (fields.length < 2 ||
          !_datePattern.hasMatch(fields[0]) ||
          fields[0].substring(0, 7) != month) {
        continue;
      }
      result.add(
        DayIndexLine(date: fields[0], keywords: _splitKeywords(fields[1])),
      );
    }
    return result.isEmpty ? null : result;
  }

  /// 从原始 episode 日文件整体重建两级索引。
  ///
  /// 调用方必须已持有 [EpisodeMemoryPipeline.synchronizedOnDayFiles]
  /// 写锁（日终归档整体持锁；召回修复在检索侧自行加锁），锁不可重入。
  ///
  /// [includingDay] 在日终归档中使用：索引步骤先于 finalized 标记，
  /// 把正在归档的当天视作已归档，避免当天永远缺席索引。
  /// [includeUnfinalized] 供召回修复使用：索引缺失或损坏时，全部
  /// 可读且有有效条目的日期都参与重建，即使尚未日终归档。
  Future<void> rebuild({
    bool includeUnfinalized = false,
    String? includingDay,
  }) async {
    final dates = await episodePipeline.listEpisodeDates();
    final monthDayLines = <String, List<String>>{};
    final monthKeywords = <String, List<String>>{};
    for (final date in dates) {
      final day = await episodePipeline.readDay(date);
      if (!day.readable) {
        continue;
      }
      final countsAsFinalized =
          day.finalized ||
          date == includingDay ||
          includeUnfinalized;
      if (!countsAsFinalized) {
        continue;
      }
      final valid = validEpisodeEntries(day.entries);
      if (valid.isEmpty) {
        continue;
      }
      final keywords = _keywordsFor(valid);
      final month = date.substring(0, 7);
      (monthDayLines[month] ??= []).add(
        '- $date | ${keywords.join(', ')} | $date.md',
      );
      final monthList = monthKeywords[month] ??= [];
      for (final keyword in keywords) {
        final key = normalizeMemoryText(keyword);
        final exists = monthList.any(
          (existing) => normalizeMemoryText(existing) == key,
        );
        if (!exists) {
          monthList.add(keyword);
        }
      }
    }

    if (monthDayLines.isEmpty) {
      if (await topIndexFile.exists()) {
        await topIndexFile.delete();
      }
      return;
    }
    final topLines = <String>[];
    for (final month in monthDayLines.keys.toList()..sort()) {
      await _atomicWriter.replace(
        monthIndexFile(month).path,
        '# $month index\n\n${monthDayLines[month]!.join('\n')}\n',
      );
      final keywords = (monthKeywords[month] ?? [])
          .take(indexMaxMonthKeywords)
          .join(', ');
      topLines.add(
        '- $month | $keywords | episodes/${month.substring(0, 4)}/'
        '${month.substring(5, 7)}/index.md',
      );
    }
    await _atomicWriter.replace(
      topIndexFile.path,
      '# episodes index\n\n${topLines.join('\n')}\n',
    );
  }

  /// 从当天有效条目提取索引关键词：摘要截断后去重，最多四条。
  List<String> _keywordsFor(List<EpisodeEntry> entries) {
    final keywords = <String>[];
    final seen = <String>{};
    for (final entry in entries) {
      final keyword = clipRunes(entry.summary.trim(), indexKeywordMaxRunes);
      final key = normalizeMemoryText(keyword);
      if (key.isEmpty || !seen.add(key)) {
        continue;
      }
      keywords.add(keyword);
      if (keywords.length >= indexMaxDayKeywords) {
        break;
      }
    }
    return keywords;
  }

  /// 读取索引文件的列表行，按 ` | ` 切分字段；文件不存在或没有
  /// 列表行时返回 null（损坏与缺失同义，都交给重建）。
  Future<List<List<String>>?> _readIndexLines(File file) async {
    if (!await file.exists()) {
      return null;
    }
    String contents;
    try {
      contents = await file.readAsString(encoding: utf8);
    } on Object {
      return null;
    }
    final lines = <List<String>>[];
    for (final rawLine in contents.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith('- ')) {
        continue;
      }
      lines.add(
        line
            .substring(2)
            .split(' | ')
            .map((field) => field.trim())
            .where((field) => field.isNotEmpty)
            .toList(),
      );
    }
    return lines.isEmpty ? null : lines;
  }

  List<String> _splitKeywords(String value) => value
      .split(',')
      .map((keyword) => keyword.trim())
      .where((keyword) => keyword.isNotEmpty)
      .toList();
}

/// 规范化用于语义去重比较：折叠空白并统一大小写；不改变落盘原文。
String normalizeMemoryText(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').toLowerCase().trim();

/// 按 rune 截断文本，避免截断多字节字符。
String clipRunes(String value, int maxRunes) {
  final runes = value.runes;
  if (runes.length <= maxRunes) {
    return value;
  }
  return String.fromCharCodes(runes.take(maxRunes));
}
