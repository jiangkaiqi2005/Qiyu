import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_controls.dart';
import 'memory_marker_codec.dart';
import 'open_loop_store.dart';

/// 月 summary 不注入、不占热层预算，体量控制在 800 字内（T07 定稿）。
const monthSummaryMaxRunes = 800;

/// 单条摘要条目的截断上限（runes）：摘要只留线索，细节回日文件。
const monthSummaryItemMaxRunes = 40;

/// 分区条目上限：先保线索数量，发生过的事情体量最大最先被裁。
const _maxHappenedItems = 14;
const _maxOpenLoopItems = 6;
const _maxRelationshipItems = 6;
const _maxUncertainItems = 6;

/// 月摘要分区标题（ticket 15 验收：区分发生过的事情、仍未解决的线索、
/// 关系变化和不确定内容）。
const sectionHappened = '发生过的事情';
const sectionOpenLoops = '仍未解决的线索';
const sectionRelationship = '关系变化';
const sectionUncertain = '不确定内容';

/// 跳过原因：未完成日终 / 文件损坏，都等待后续补做或恢复流程。
const skipReasonUnfinalized = 'unfinalized';
const skipReasonUnreadable = 'unreadable';

/// 不确定内容识别：用户当时就没说定的事。只做保守的词面归类，
/// 不改写原文、不推断新的不确定性。
final _uncertaintyPattern = RegExp(
  r'可能|也许|或许|大概|还不确定|还没定|还没确定|再说吧|看情况|待定|说不准|不确定',
);

final _summaryItemPattern = RegExp(r'^- (\d{4}-\d{2}-\d{2}) · (.+)$');

/// purgeBlocked 扫描 episodes 目录时的年/月目录段校验。
final _yearSegmentPattern = RegExp(r'^\d{4}$');
final _monthSegmentPattern = RegExp(r'^\d{2}$');

/// 月摘要中的一条证据条目：摘要文本 + 可回溯的证据引用
/// （日期、episode 路径与条目号）。
final class MonthSummaryItem {
  const MonthSummaryItem({
    required this.section,
    required this.date,
    required this.text,
    required this.episodePath,
    required this.entryRef,
  });

  final String section;
  final String date;
  final String text;
  final String episodePath;
  final String entryRef;

  String get pointer => '$episodePath [$entryRef]';
}

/// 解析后的月摘要。[readable] 为 false 表示文件存在但无法识别：
/// 与其他记忆文件一致，绝不覆盖，等待恢复流程。
final class MonthSummary {
  const MonthSummary({
    required this.month,
    required this.readable,
    this.theme = const [],
    this.items = const [],
    this.compressedDates = const [],
    this.skipped = const {},
  });

  final String month;
  final bool readable;
  final List<String> theme;
  final List<MonthSummaryItem> items;

  /// 本次压缩实际收录的日期。
  final List<String> compressedDates;

  /// 被跳过的日期与原因（unfinalized / unreadable）。为空说明当月
  /// 已完整覆盖，重跑不再重新生成。
  final Map<String, String> skipped;
}

/// 月压缩（五段节奏第四动作，ticket 15 / T07 定稿）。
///
/// 时机：进入新月的第一次对话、跨年或启动补做时，压缩当前月之前
/// 的月份；当天所在月份永不压缩。只收已经 finalized 的日期，未完成
/// 或损坏的日期明确跳过并记入元数据等待补做——之后若有被跳过的
/// 日期完成归档，整体重新生成并原子替换；已完整覆盖的月份绝不重复
/// 生成，不会产生相互冲突的摘要。
///
/// 确定性提炼（当前管线无模型参与）：按条目来源分区——记忆条目进
/// 「发生过的事情」（带不确定措辞的进「不确定内容」）、当月提升且
/// 至今未闭环的 open-loop 候选进「仍未解决的线索」、关系证据进
/// 「关系变化」。每条保留日期与 episode 指针；禁提内容先过滤；
/// 全部条目脱敏后再落盘，不改写、不新增原文不存在的结论。
///
/// 月 summary 不注入、不占热层预算（T07）；查找优先级
/// daily > 月 summary > long-memory 由召回侧遵守。
final class MonthlySummaryStore {
  MonthlySummaryStore({
    required this.memoryDirectory,
    required this.episodePipeline,
    this.openLoopStore,
    EpisodeIndexStore? indexStore,
    AtomicTextWriter? atomicWriter,
    void Function(String message)? diagnosticsSink,
  }) : _indexStore = indexStore ??
           EpisodeIndexStore(
             memoryDirectory: memoryDirectory,
             episodePipeline: episodePipeline,
           ),
       _atomicWriter = atomicWriter ?? const IoAtomicTextWriter(),
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final OpenLoopStore? openLoopStore;
  final EpisodeIndexStore _indexStore;
  final AtomicTextWriter _atomicWriter;
  final void Function(String message) _diagnosticsSink;

  File summaryFile(String month) => File(
    path.join(
      memoryDirectory,
      'episodes',
      month.substring(0, 4),
      month.substring(5, 7),
      'summary.md',
    ),
  );

  /// 读取某月摘要；文件不存在返回 null，存在但无法识别返回
  /// readable=false 的结果。
  Future<MonthSummary?> readMonthSummary(String month) async {
    final file = summaryFile(month);
    if (!await file.exists()) {
      return null;
    }
    String contents;
    try {
      contents = await file.readAsString(encoding: utf8);
    } on Object {
      return MonthSummary(month: month, readable: false);
    }
    return _parse(month, contents);
  }

  /// 压缩 [beforeMonth] 之前的全部月份（幂等）。当月与未来月份
  /// 永不触碰。
  Future<void> compressBefore(String beforeMonth) async {
    final dates = await episodePipeline.listEpisodeDates();
    final months = <String>{for (final date in dates) date.substring(0, 7)};
    for (final month in months.toList()..sort()) {
      if (month.compareTo(beforeMonth) >= 0) {
        continue;
      }
      try {
        await compressMonth(month, episodeDates: dates);
      } on Object catch (error) {
        // 单月失败不阻断其余月份；旧摘要原子写保护下保持可用。
        _diagnosticsSink('monthly compression deferred [$error] month=$month');
      }
    }
  }

  /// 压缩单个月份。
  ///
  /// 幂等规则：已完整覆盖（无跳过日期）的月份绝不重写；有跳过日期
  /// 的月份在跳过项仍未解决时保持原摘要，任一被跳过日期变为可用时
  /// 整体重建并原子替换。写入失败抛出异常，由调用方记诊断，
  /// 原摘要不受影响。
  Future<void> compressMonth(
    String month, {
    List<String>? episodeDates,
  }) async {
    final existing = await readMonthSummary(month);
    if (existing != null && !existing.readable) {
      _diagnosticsSink(
        'monthly compression skipped reason=$month-summary-unreadable',
      );
      return;
    }
    if (existing != null && existing.skipped.isEmpty) {
      // 已完整覆盖：重复执行不产生新摘要。
      return;
    }

    final dates = episodeDates ?? await episodePipeline.listEpisodeDates();
    final monthDates = dates
        .where((date) => date.substring(0, 7) == month)
        .toList();
    final compressedDates = <String>[];
    final skipped = <String, String>{};
    final days = <String, EpisodeDay>{};
    for (final date in monthDates) {
      final day = await episodePipeline.readDay(date);
      if (!day.readable) {
        skipped[date] = skipReasonUnreadable;
        _diagnosticsSink('monthly compression skipped date=$date reason=unreadable');
        continue;
      }
      if (!day.finalized) {
        skipped[date] = skipReasonUnfinalized;
        _diagnosticsSink('monthly compression skipped date=$date reason=unfinalized');
        continue;
      }
      compressedDates.add(date);
      days[date] = day;
    }

    if (compressedDates.isEmpty) {
      // 没有任何可压缩的日期：不写摘要（已有的旧摘要保持可用）。
      return;
    }
    if (existing != null &&
        existing.skipped.isNotEmpty &&
        skipped.length == existing.skipped.length &&
        skipped.keys.every(
          (date) => existing.skipped.containsKey(date),
        ) &&
        existing.compressedDates.length == compressedDates.length &&
        compressedDates.every(existing.compressedDates.contains)) {
      // 被跳过的日期一个都没解锁、收录范围也没变：重建只会得到同样
      // 内容，不重写。
      return;
    }

    final contents = await _buildContents(month, compressedDates, skipped, days);
    final file = summaryFile(month);
    if (await file.exists() &&
        await file.readAsString(encoding: utf8) == contents) {
      return;
    }
    await _atomicWriter.replace(file.path, contents);
  }

  Future<String> _buildContents(
    String month,
    List<String> compressedDates,
    Map<String, String> skipped,
    Map<String, EpisodeDay> days,
  ) async {
    final banned = await _controlledTitles();
    final loopTitles = await _activeLoopTitles();

    final happened = <MonthSummaryItem>[];
    final openLoops = <MonthSummaryItem>[];
    final relationship = <MonthSummaryItem>[];
    final uncertain = <MonthSummaryItem>[];
    final seen = <String>{};

    for (final date in compressedDates) {
      for (final entry in days[date]!.entries) {
        final text = redactSessionText(entry.summary).trim();
        if (text.isEmpty) {
          continue;
        }
        final key = normalizeMemoryText(text);
        if (!seen.add(key)) {
          continue;
        }
        if (bannedTitleMatches(key, banned)) {
          _diagnosticsSink(
            'monthly compression entry skipped reason=blocked date=$date',
          );
          continue;
        }
        MonthSummaryItem itemFor(String section) => MonthSummaryItem(
          section: section,
          date: date,
          text: clipRunes(text, monthSummaryItemMaxRunes),
          episodePath: episodeDayRelativePath(date),
          entryRef: entry.id,
        );
        switch (entry.kind) {
          case episodeKindOpenLoopCandidate:
            // 只有当月提升且至今仍未闭环的候选才算「仍未解决」。
            if (loopTitles.contains(normalizeLoopTitle(text))) {
              openLoops.add(itemFor(sectionOpenLoops));
            }
          case episodeKindRelationshipSignal:
            relationship.add(itemFor(sectionRelationship));
          case episodeKindOpenLoopEvent:
            // 簿记条目不进摘要。
            break;
          default:
            if (_uncertaintyPattern.hasMatch(text)) {
              uncertain.add(itemFor(sectionUncertain));
            } else {
              happened.add(itemFor(sectionHappened));
            }
        }
      }
    }

    // 主题关键词来自索引（索引本身不过滤受控内容），落盘前同样过滤，
    // 与条目侧的控制纪律保持一致。
    final theme = (await _monthTheme(month))
        .where((keyword) => !bannedMemoryText(keyword, banned))
        .toList();
    final sections = <String, List<MonthSummaryItem>>{
      sectionHappened: happened.take(_maxHappenedItems).toList(),
      sectionOpenLoops: openLoops.take(_maxOpenLoopItems).toList(),
      sectionRelationship: relationship.take(_maxRelationshipItems).toList(),
      sectionUncertain: uncertain.take(_maxUncertainItems).toList(),
    };
    _fitBudget(sections, theme);

    return _renderSummary(
      month: month,
      theme: theme,
      sections: sections,
      compressedDates: compressedDates,
      skipped: skipped,
    );
  }

  /// 删除清除（定稿：月摘要是派生内容，删除必须清掉引用）：扫描已有
  /// 月摘要，移除命中封禁集合的条目与主题关键词，原子重写有变化的
  /// 月份。已完整覆盖的月份平时绝不重新生成，所以删除必须在这里
  /// 显式清理。返回移除的条目与关键词总数。
  Future<int> purgeBlocked(Set<String> blocked) async {
    if (blocked.isEmpty) {
      return 0;
    }
    var removed = 0;
    // 按文件系统扫描已有摘要：即使某月的 episodes 已被删空，
    // 残留的摘要文件也必须清理。
    final months = <String>{};
    final episodesRoot = Directory(path.join(memoryDirectory, 'episodes'));
    if (await episodesRoot.exists()) {
      await for (final entity in episodesRoot.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && path.basename(entity.path) == 'summary.md') {
          final relative = path.relative(entity.path, from: episodesRoot.path);
          final parts = path.split(relative);
          if (parts.length == 3 &&
              _yearSegmentPattern.hasMatch(parts[0]) &&
              _monthSegmentPattern.hasMatch(parts[1])) {
            months.add('${parts[0]}-${parts[1]}');
          }
        }
      }
    }
    for (final month in months.toList()..sort()) {
      final summary = await readMonthSummary(month);
      if (summary == null || !summary.readable) {
        continue;
      }
      bool hit(String text) => bannedMemoryText(text, blocked);
      final keptItems = summary.items.where((item) => !hit(item.text)).toList();
      final keptTheme = summary.theme.where((keyword) => !hit(keyword)).toList();
      final removedHere =
          (summary.items.length - keptItems.length) +
          (summary.theme.length - keptTheme.length);
      if (removedHere == 0) {
        continue;
      }
      removed += removedHere;
      final sections = <String, List<MonthSummaryItem>>{
        for (final name in const [
          sectionHappened,
          sectionOpenLoops,
          sectionRelationship,
          sectionUncertain,
        ])
          name: keptItems.where((item) => item.section == name).toList(),
      };
      final contents = _renderSummary(
        month: month,
        theme: keptTheme,
        sections: sections,
        compressedDates: summary.compressedDates,
        skipped: summary.skipped,
      );
      await _atomicWriter.replace(summaryFile(month).path, contents);
      _diagnosticsSink(
        'monthly summary purged month=$month removed=$removedHere',
      );
    }
    return removed;
  }

  /// 月摘要渲染（压缩生成与删除清除共用）：元数据 + 当月主题 +
  /// 四分区条目。
  String _renderSummary({
    required String month,
    required List<String> theme,
    required Map<String, List<MonthSummaryItem>> sections,
    required List<String> compressedDates,
    required Map<String, String> skipped,
  }) {
    final metadata = encodeMarkerPayload({
      'schemaVersion': 1,
      'month': month,
      'compressedDates': compressedDates,
      if (skipped.isNotEmpty) 'skipped': skipped,
    });
    final buffer = StringBuffer()
      ..writeln('# $month 月度摘要')
      ..writeln()
      ..writeln('<!-- qiyu-month-summary:$metadata -->');
    if (theme.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 当月主题')
        ..writeln(theme.join('、'));
    }
    for (final MapEntry(:key, :value) in sections.entries) {
      if (value.isEmpty) {
        continue;
      }
      buffer
        ..writeln()
        ..writeln('## $key');
      for (final item in value) {
        buffer.writeln('- ${item.date} · ${item.text} | ${item.pointer}');
      }
    }
    return buffer.toString();
  }

  /// 超预算时按「先裁发生过的事情，再裁不确定内容、关系变化」的
  /// 顺序从尾部丢弃：线索分区最小也最常被跨月提起，留到最后。
  void _fitBudget(Map<String, List<MonthSummaryItem>> sections, List<String> theme) {
    var total = _totalRunes(sections, theme);
    for (final name in [
      sectionHappened,
      sectionUncertain,
      sectionRelationship,
      sectionOpenLoops,
    ]) {
      final items = sections[name]!;
      while (total > monthSummaryMaxRunes && items.isNotEmpty) {
        total -= items.removeLast().lineRunes;
      }
      if (total <= monthSummaryMaxRunes) {
        return;
      }
    }
  }

  int _totalRunes(Map<String, List<MonthSummaryItem>> sections, List<String> theme) {
    // 标题行少计的 8 runes 恰与元数据占位（不计入可见正文）相抵；
    // 主题区存在时其标题行须计入，否则满载月份会微超 800 字上限。
    var total = '# 月度摘要\n\n<!-- -->'.runes.length;
    if (theme.isNotEmpty) {
      total += '\n\n## 当月主题'.runes.length + theme.join('、').runes.length;
    }
    for (final MapEntry(:key, :value) in sections.entries) {
      total += '\n\n## $key'.runes.length;
      for (final item in value) {
        total += item.lineRunes;
      }
    }
    return total;
  }

  Future<List<String>> _monthTheme(String month) async {
    final topIndex = await _indexStore.readTopIndex();
    if (topIndex == null) {
      return const [];
    }
    for (final line in topIndex) {
      if (line.month == month) {
        return line.keywords;
      }
    }
    return const [];
  }

  /// 月压缩的受控集合 = 封禁（禁提 ∪ 删除）∪ 冻结：冻结停止整理，
  /// 封禁内容不得进摘要。
  Future<Set<String>> _controlledTitles() async {
    final store = openLoopStore;
    if (store == null) {
      return const {};
    }
    final controls = await store.memoryControls.load();
    return controls.controlledSummaries;
  }

  /// 当前仍未闭环（active/paused）的 open-loop 标题集合。
  Future<Set<String>> _activeLoopTitles() async {
    final store = openLoopStore;
    if (store == null) {
      return const {};
    }
    final items = await store.readItems();
    if (items == null) {
      return const {};
    }
    return items
        .where(
          (item) =>
              item.status == OpenLoopStatus.active ||
              item.status == OpenLoopStatus.paused,
        )
        .map((item) => normalizeLoopTitle(item.title))
        .where((title) => title.isNotEmpty)
        .toSet();
  }

  MonthSummary _parse(String month, String contents) {
    final metadataMatch = RegExp(
      r'^<!-- qiyu-month-summary:([A-Za-z0-9_-]+) -->\r?$',
      multiLine: true,
    ).firstMatch(contents);
    if (metadataMatch == null) {
      return MonthSummary(month: month, readable: false);
    }
    Map<String, Object?> metadata;
    try {
      metadata = decodeMarkerPayload(metadataMatch.group(1)!);
    } on Object {
      return MonthSummary(month: month, readable: false);
    }
    if (metadata['month'] != month) {
      return MonthSummary(month: month, readable: false);
    }
    final compressedDates = (metadata['compressedDates'] as List<Object?>?)
        ?.whereType<String>()
        .toList() ??
        const [];
    final skippedRaw = metadata['skipped'];
    final skipped = <String, String>{};
    if (skippedRaw is Map<String, Object?>) {
      for (final MapEntry(:key, :value) in skippedRaw.entries) {
        if (value is String) {
          skipped[key] = value;
        }
      }
    }
    final theme = <String>[];
    final items = <MonthSummaryItem>[];
    var section = '';
    for (final rawLine in contents.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (line.startsWith('## ')) {
        final title = line.substring(3).trim();
        section = switch (title) {
          '当月主题' => 'theme',
          sectionHappened ||
          sectionOpenLoops ||
          sectionRelationship ||
          sectionUncertain => title,
          _ => '',
        };
        continue;
      }
      if (section == 'theme') {
        theme.addAll(
          line
              .split('、')
              .map((part) => part.trim())
              .where((part) => part.isNotEmpty),
        );
        continue;
      }
      if (section.isEmpty) {
        continue;
      }
      final match = _summaryItemPattern.firstMatch(line);
      if (match == null) {
        return MonthSummary(month: month, readable: false);
      }
      final rest = match.group(2)!;
      final separator = rest.lastIndexOf(' | episodes/');
      if (separator < 0) {
        return MonthSummary(month: month, readable: false);
      }
      final pointer = rest.substring(separator + 3);
      final bracket = pointer.lastIndexOf(' [');
      if (bracket < 0 || !pointer.endsWith(']')) {
        return MonthSummary(month: month, readable: false);
      }
      items.add(
        MonthSummaryItem(
          section: section,
          date: match.group(1)!,
          text: rest.substring(0, separator),
          episodePath: pointer.substring(0, bracket),
          entryRef: pointer.substring(bracket + 2, pointer.length - 1),
        ),
      );
    }
    return MonthSummary(
      month: month,
      readable: true,
      theme: theme,
      items: items,
      compressedDates: compressedDates,
      skipped: skipped,
    );
  }
}

extension on MonthSummaryItem {
  int get lineRunes => '\n- $date · $text | $pointer'.runes.length;
}
