/// 记忆删除范围的统一检查（ticket 01）：删除预览、删除前定位与
/// 实际清除全部消费这同一份逐层扫描。事实标准是实际清除管线
/// （[MemoryActionService] 的 purgeDerivedScopes，含人格树禁删清扫
/// applyBan）能够触及的节点集合——凡是管线删不到的内容，扫描绝不
/// 报命中，预览、定位与落盘因此永远一致。
///
/// 匹配规则只存在于本模块：若把它删掉，规则会复制回预览与定位
/// 两处，这正是它存在的理由，不得降级成浅包装。文本包含规则本身
/// 仍归 [bannedMemoryText]（与注入侧同律），这里只定义「管线能触及
/// 哪些节点」。
library;

import 'dart:convert';
import 'dart:io';

import 'daily_understanding.dart';
import 'dream.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_controls.dart';
import 'monthly_summary.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'relationship_lifecycle.dart';

/// 控制范围（禁提 ∪ 删除）的统一文本谓词：先归一化再按包含规则
/// 匹配，删除预览、定位扫描与派生清除共用同一份，绝不各写一套。
bool Function(String) scopeTextHit(Set<String> scope) =>
    (candidate) => bannedMemoryText(candidate, scope);

/// episode 条目是否命中控制范围：簿记条目（open_loop_event，含受控
/// 标题文字）不参与匹配；摘要与原始摘录任一命中即算。清除管线
/// （purgeEntriesMatching）与逐层扫描共用同一谓词。
bool Function(EpisodeEntry) scopeEntryHit(bool Function(String) hitText) =>
    (entry) =>
        entry.kind != episodeKindOpenLoopEvent &&
        (hitText(entry.summary) ||
            (entry.evidence != null && hitText(entry.evidence!)));

/// 逐层扫描的命中计数：每个字段对应清除管线能触及的一类内容。
final class MemoryScopeHit {
  const MemoryScopeHit({
    required this.episodeEntries,
    required this.episodeDaySummaries,
    required this.episodeDayUnderstandings,
    required this.personaNodes,
    required this.longTermItems,
    required this.monthSummaryItems,
    required this.relationshipLines,
    required this.dailyStateLines,
    required this.openLoops,
  });

  /// 命中的 episode 条目数（簿记条目除外）。
  final int episodeEntries;

  /// 命中的当日小结数（清除管线以摘要探针清掉整段小结）。
  final int episodeDaySummaries;

  /// 命中的当日理解元数据天数：清除管线对每日落盘的理解元数据过一遍
  /// [DayUnderstanding.filterBanned]，命中即重写移除；这里统计有内容
  /// 被移除的天数（纯键序差异不算）。
  final int episodeDayUnderstandings;

  /// 命中的画像节点数：根断言、根下中间理解、独立中间理解与
  /// 未归类叶，与 applyBan 的实际清除范围对齐。
  final int personaNodes;
  final int longTermItems;

  /// 命中的月摘要条目与主题关键词总数（两者都会被清除管线移除）。
  final int monthSummaryItems;
  final int relationshipLines;
  final int dailyStateLines;
  final int openLoops;

  /// 任一层命中：删除前定位的唯一判据。
  bool get anyHit =>
      episodeEntries > 0 ||
      episodeDaySummaries > 0 ||
      episodeDayUnderstandings > 0 ||
      personaNodes > 0 ||
      longTermItems > 0 ||
      monthSummaryItems > 0 ||
      relationshipLines > 0 ||
      dailyStateLines > 0 ||
      openLoops > 0;
}

/// 删除范围的只读逐层扫描器。[scope] 为规范化后的受控文本集合
/// （与清除管线接收的集合同一形态）。
final class MemoryScopeScanner {
  MemoryScopeScanner({
    required this.memoryDirectory,
    required this.episodePipeline,
    required this.personaTree,
    required this.openLoopStore,
    required this.monthlySummary,
  });

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final PersonaTreeStore personaTree;
  final OpenLoopStore openLoopStore;
  final MonthlySummaryStore monthlySummary;

  File get _longMemoryFile => memoryFile(memoryDirectory, longMemoryFileName);
  File get _relationshipFile =>
      memoryFile(memoryDirectory, relationshipFileName);
  File get _dailyStateFile => memoryFile(memoryDirectory, dailyStateFileName);

  /// 按清除管线能触及的节点集合逐层统计命中。只读，绝不写盘。
  Future<MemoryScopeHit> scan(Set<String> scope) async {
    final hitText = scopeTextHit(scope);
    final hitEntry = scopeEntryHit(hitText);

    var episodeEntries = 0;
    var episodeDaySummaries = 0;
    var episodeDayUnderstandings = 0;
    final dates = await episodePipeline.listEpisodeDates();
    for (final date in dates) {
      final day = await episodePipeline.readDay(date);
      if (!day.readable) {
        continue;
      }
      episodeEntries += day.entries.where(hitEntry).length;
      final summary = day.summary;
      // 与 purgeEntriesMatching 的摘要探针一致：命中即清掉当日小结。
      if (summary != null && hitText(summary)) {
        episodeDaySummaries += 1;
      }
      // 当日理解元数据同样在清除管线触及范围：purgeDerivedScopes 把每日
      // 落盘的理解元数据过一遍 filterBanned，命中即重写移除。这里复用同一
      // 过滤，只统计确有内容被移除的天（两端都按规范化序列化比较，落盘
      // 键序漂移触发的无内容重写不算命中）。
      final rawUnderstanding = day.understanding;
      if (rawUnderstanding != null) {
        final understanding = DayUnderstanding.fromJson(rawUnderstanding);
        final filtered = understanding.filterBanned(scope);
        if (jsonEncode(filtered.toJson()) !=
            jsonEncode(understanding.toJson())) {
          episodeDayUnderstandings += 1;
        }
      }
    }

    // 画像节点集合 = applyBan 的清扫范围：根断言（命中连子树删）、
    // 根下中间理解、独立（未归根）中间理解、未归类叶。
    var personaNodes = 0;
    final snapshot = await personaTree.readSnapshot();
    for (final view in snapshot.branches.values) {
      if (!view.readable) {
        continue;
      }
      for (final root in view.roots) {
        if (hitText(root.claim)) {
          personaNodes += 1;
        }
        for (final middle in root.middles) {
          if (hitText(middle.claim)) {
            personaNodes += 1;
          }
        }
      }
      personaNodes += view.unrooted
          .where((middle) => hitText(middle.claim))
          .length;
      personaNodes += view.unclassified
          .where((leaf) => hitText(leaf.summary))
          .length;
    }

    var longTermItems = 0;
    final longMemory = await readFileIfExists(_longMemoryFile);
    if (longMemory != null && longMemory.trim().isNotEmpty) {
      final parsed = parseLongMemory(longMemory);
      if (parsed.readable) {
        longTermItems = parsed.allItems.where(hitText).length;
      }
    }

    // 月份集合与清除管线同一事实来源：按盘上已有摘要文件枚举，
    // episodes 已被删空的月份残留摘要同样算命中。
    var monthSummaryItems = 0;
    for (final month in await monthlySummary.summaryMonths()) {
      final summaryFile = await monthlySummary.readMonthSummary(month);
      if (summaryFile == null || !summaryFile.readable) {
        continue;
      }
      monthSummaryItems += summaryFile.items
          .where((item) => hitText(item.text))
          .length;
      monthSummaryItems += summaryFile.theme.where(hitText).length;
    }

    // 与 purgeBlockedTitles 逐字一致：只有受管结构的三个列表参与清除，
    // 手写文件（解析返回 null）管线动不了，扫描也不算命中；命中判断对
    // 整条列表行（含 "- " 前缀）走同一份归一化与包含谓词（解析器保证
    // 列表里只有带前缀的已修剪行，清除侧也没有额外前缀判断）。先剥
    // 前缀再匹配会在反向包含的边界场景让两侧结论漂移：预览报出清除
    // 管线实际删不掉的行，或漏报管线整行包含命中的行。
    var relationshipLines = 0;
    final relationship = await readFileIfExists(_relationshipFile);
    if (relationship != null) {
      final parsed = parseRelationshipFile(relationship);
      if (parsed != null) {
        relationshipLines =
            parsed.confirmed.where(hitText).length +
            parsed.probes.where(hitText).length +
            parsed.recentChanges.where(hitText).length;
      }
    }

    var dailyStateLines = 0;
    final dailyState = await readFileIfExists(_dailyStateFile);
    if (dailyState != null) {
      // 与 _purgeDailyStateLines 逐字一致：含 "- " 前缀的整行参与匹配。
      dailyStateLines = dailyState
          .split('\n')
          .where((line) => line.trim().startsWith('- ') && hitText(line.trim()))
          .length;
    }

    var openLoops = 0;
    final loops = await openLoopStore.readItems();
    if (loops != null) {
      openLoops = loops.where((item) => hitText(item.title)).length;
    }

    return MemoryScopeHit(
      episodeEntries: episodeEntries,
      episodeDaySummaries: episodeDaySummaries,
      episodeDayUnderstandings: episodeDayUnderstandings,
      personaNodes: personaNodes,
      longTermItems: longTermItems,
      monthSummaryItems: monthSummaryItems,
      relationshipLines: relationshipLines,
      dailyStateLines: dailyStateLines,
      openLoops: openLoops,
    );
  }
}
