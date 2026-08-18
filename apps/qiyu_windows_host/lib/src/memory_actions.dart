import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'daily_understanding.dart';
import 'dream.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_center.dart';
import 'memory_controls.dart';
import 'monthly_summary.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'relationship_lifecycle.dart';

/// 记忆动作结果三态（ticket 20 验收）：成功、部分失败（控制已生效，
/// 个别派生清理推迟，旧有效数据不受影响）与可恢复失败（什么都没
/// 改变，可重试）。
enum MemoryActionStatus {
  success,
  partial,
  failed;

  String get wireName => name;
}

final class MemoryActionResult {
  const MemoryActionResult({
    required this.status,
    required this.message,
    this.retryable = false,
    this.code,
    this.deferred = const [],
    this.revealedText,
  });

  final MemoryActionStatus status;

  /// 面向用户的结果说明。
  final String message;

  /// 可恢复失败是否值得重试。
  final bool retryable;

  /// 机器可读错误码（memory_item_not_found / memory_action_not_allowed /
  /// memory_item_not_masked 等），路由据此选择 HTTP 状态码。
  final String? code;

  /// 部分失败时尚未完成的清理步骤（用户语言）。
  final List<String> deferred;

  /// 揭示动作返回的原文；只在 reveal 成功时出现，服务端不缓存、
  /// 不写日志。
  final String? revealedText;

  Map<String, Object?> toJson() => {
    'status': status.wireName,
    'message': message,
    if (retryable) 'retryable': true,
    if (code != null) 'code': code,
    if (deferred.isNotEmpty) 'deferred': deferred,
    if (revealedText != null) 'text': revealedText,
  };
}

/// 删除影响范围（删除前展示，ticket 20 验收）：每一项都是准确计数，
/// 不使用含糊的全部删除表述。
final class MemoryDeleteImpact {
  const MemoryDeleteImpact({
    required this.targetText,
    required this.targetMasked,
    required this.episodeEntries,
    required this.episodeDaySummaries,
    required this.personaNodes,
    required this.longTermItems,
    required this.monthSummaryItems,
    required this.relationshipLines,
    required this.dailyStateLines,
    required this.openLoops,
  });

  /// 删除目标的用户可见文本；敏感时为 null，界面用占位说明。
  final String? targetText;
  final bool targetMasked;

  final int episodeEntries;
  final int episodeDaySummaries;

  /// 会被清除的画像内容：根、根下与未归根的中间理解、未归类叶，
  /// 与 applyBan 的实际清除范围对齐。
  final int personaNodes;
  final int longTermItems;
  final int monthSummaryItems;
  final int relationshipLines;
  final int dailyStateLines;
  final int openLoops;

  /// 两级索引与当日理解元数据是否需要重建/过滤（有 episode 派生
  /// 内容被清除时必然发生）。
  bool get rebuildsIndex => episodeEntries > 0 || episodeDaySummaries > 0;

  /// 用户语言的准确影响清单。
  List<String> get lines {
    final lines = <String>[
      targetMasked ? '将删除一条涉及私密信息的记忆。' : '将删除这条记忆：${targetText ?? ''}',
    ];
    if (episodeEntries > 0) {
      lines.add('近期整理记录：清除 $episodeEntries 条。');
    }
    if (episodeDaySummaries > 0) {
      lines.add('当日小结：清除 $episodeDaySummaries 处。');
    }
    if (personaNodes > 0) {
      lines.add('关于你的画像：清除 $personaNodes 处（根、理解与证据叶）。');
    }
    if (longTermItems > 0) {
      lines.add('长期印象：清除 $longTermItems 条。');
    }
    if (monthSummaryItems > 0) {
      lines.add('月份摘要：清除 $monthSummaryItems 条。');
    }
    if (relationshipLines > 0) {
      lines.add('关系记录：清除 $relationshipLines 行。');
    }
    if (dailyStateLines > 0) {
      lines.add('近日状态：清除 $dailyStateLines 行。');
    }
    if (openLoops > 0) {
      lines.add('未闭环事项：清除 $openLoops 项。');
    }
    if (rebuildsIndex) {
      lines.add('两级索引将重建，当日理解元数据会同步过滤。');
    }
    lines.add('原始对话记录保留，但不会再从那里重新整理出这条内容。');
    return lines;
  }

  Map<String, Object?> toJson() => {
    if (targetText != null) 'targetText': targetText,
    'targetMasked': targetMasked,
    'episodeEntries': episodeEntries,
    'episodeDaySummaries': episodeDaySummaries,
    'personaNodes': personaNodes,
    'longTermItems': longTermItems,
    'monthSummaryItems': monthSummaryItems,
    'relationshipLines': relationshipLines,
    'dailyStateLines': dailyStateLines,
    'openLoops': openLoops,
    'rebuildsIndex': rebuildsIndex,
    'sessionsKept': true,
    'lines': lines,
  };
}

/// episode 条目编辑后的摘要上限（runes）：与召回呈现同宽。
const memoryEditEntryMaxRunes = 120;

/// 记忆中心动作执行端（ticket 20）：编辑、冻结/解除、禁提/解除、
/// 删除（含影响范围预览）与敏感临时揭示。全部动作都以记忆中心的
/// opaque 引用为目标，写入纪律沿用 T24 定稿：
///
/// - 控制先写 memory-controls.md，再清派生内容；controls 写不进时
///   绝不动任何派生层（可恢复失败，旧数据保持可用）。
/// - 删除只清派生内容与索引，sessions 原样保留；重复执行安全。
/// - 编辑把修正保存为用户声明：episode 条目移除原始摘录并标记
///   用户修正，long-memory 直接改写条目行；原始会话永不被改写。
/// - 揭示只返回一次原文，不落盘、不进日志。
final class MemoryActionService {
  MemoryActionService({
    required this.memoryDirectory,
    required this.episodePipeline,
    required this.personaTree,
    required this.memoryControls,
    required this.openLoopStore,
    required this.monthlySummary,
    required this.relationshipLifecycle,
    AtomicTextWriter? atomicWriter,
    void Function(String message)? diagnosticsSink,
  }) : _atomicWriter = atomicWriter ?? const IoAtomicTextWriter(),
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final PersonaTreeStore personaTree;
  final MemoryControlsStore memoryControls;
  final OpenLoopStore openLoopStore;
  final MonthlySummaryStore monthlySummary;
  final RelationshipLifecycle relationshipLifecycle;
  final AtomicTextWriter _atomicWriter;
  final void Function(String) _diagnosticsSink;

  File get _longMemoryFile =>
      File(path.join(memoryDirectory, 'long-memory.md'));
  File get _relationshipFile =>
      File(path.join(memoryDirectory, 'relationship.md'));
  File get _dailyStateFile =>
      File(path.join(memoryDirectory, 'daily-state.md'));

  static const _notFound = MemoryActionResult(
    status: MemoryActionStatus.failed,
    message: '这条记忆不存在或已经变化，请返回后刷新。',
    code: 'memory_item_not_found',
  );

  static const MemoryActionResult _controlNotWritable = MemoryActionResult(
    status: MemoryActionStatus.failed,
    message: '控制记录暂时写不进去，这次没有生效，原有内容保持不变，可稍后重试。',
    retryable: true,
    code: 'memory_controls_not_writable',
  );

  MemoryActionResult _notAllowed(String message) => MemoryActionResult(
    status: MemoryActionStatus.failed,
    message: message,
    code: 'memory_action_not_allowed',
  );

  // ---------- 控制动作 ----------

  Future<MemoryActionResult> freeze(MemoryItemRef ref) async {
    final text = await _itemText(ref);
    if (text == null) {
      return _notFound;
    }
    final denied = _denyStatePackControl(ref);
    if (denied != null) {
      return denied;
    }
    if (!await memoryControls.freeze(text, origin: 'memory-center')) {
      return _controlNotWritable;
    }
    return const MemoryActionResult(
      status: MemoryActionStatus.success,
      message: '已暂停使用这条记忆，解除前不会出现在对话和整理里。',
    );
  }

  Future<MemoryActionResult> unfreeze(MemoryItemRef ref) async {
    final text = await _itemText(ref);
    if (text == null) {
      return _notFound;
    }
    final removed = await memoryControls.unfreeze(text);
    if (removed == null) {
      return _controlNotWritable;
    }
    return const MemoryActionResult(
      status: MemoryActionStatus.success,
      message: '已恢复使用这条记忆。',
    );
  }

  Future<MemoryActionResult> ban(MemoryItemRef ref) async {
    final text = await _itemText(ref);
    if (text == null) {
      return _notFound;
    }
    final denied = _denyStatePackControl(ref);
    if (denied != null) {
      return denied;
    }
    if (!await memoryControls.ban(text, origin: 'memory-center')) {
      return _controlNotWritable;
    }
    final deferred = <String>[];
    final scope = {normalizeMemoryText(text)};
    try {
      await openLoopStore.removeLoopsMatching(scope);
    } on Object catch (error) {
      deferred.add('未闭环事项的移出');
      _diagnosticsSink('ban loop purge deferred [$error]');
    }
    try {
      await personaTree.applyBan(text);
    } on Object catch (error) {
      deferred.add('画像的清理');
      _diagnosticsSink('ban persona purge deferred [$error]');
    }
    if (deferred.isNotEmpty) {
      return MemoryActionResult(
        status: MemoryActionStatus.partial,
        message: '已不再提起这条记忆；${deferred.join('、')}没有一次完成，稍后会自动补上。',
        deferred: deferred,
      );
    }
    return const MemoryActionResult(
      status: MemoryActionStatus.success,
      message: '已不再提起这条记忆。',
    );
  }

  Future<MemoryActionResult> unban(MemoryItemRef ref) async {
    final text = await _itemText(ref);
    if (text == null) {
      return _notFound;
    }
    final removed = await memoryControls.unban(text);
    if (removed == null) {
      return _controlNotWritable;
    }
    return const MemoryActionResult(
      status: MemoryActionStatus.success,
      message: '已解除禁提。',
    );
  }

  /// 状态包各行（相处方式/试探/近期变化）不是控制对象（T24 定稿）：
  /// 只有 long-memory「共同过往」允许全部条目动作。
  MemoryActionResult? _denyStatePackControl(MemoryItemRef ref) {
    if (ref is MemoryRelationshipRef && ref.list != 'sharedPast') {
      return _notAllowed('关系状态记录不支持这项操作。');
    }
    if (ref is MemoryDayRef) {
      return _notAllowed('这一天的记录不支持这项操作。');
    }
    return null;
  }

  // ---------- 编辑 ----------

  Future<MemoryActionResult> edit(MemoryItemRef ref, String newText) async {
    final replacement = redactSessionText(newText).trim();
    if (replacement.isEmpty) {
      return _notAllowed('修正内容不能为空。');
    }
    switch (ref) {
      case MemoryEntryRef():
        return _editEntry(ref, replacement);
      case MemoryLongTermRef():
        return _editLongTerm(ref, replacement);
      case MemoryRelationshipRef() when ref.list == 'sharedPast':
        return _editLongTerm(MemoryLongTermRef('共同过往', ref.text), replacement);
      case MemoryRelationshipRef():
        return _notAllowed('关系状态记录不支持编辑。');
      case MemoryRootRef():
      case MemoryMiddleRef():
        return _notAllowed('画像只能通过对话纠正，不支持直接编辑。');
      case MemoryDayRef():
        return _notAllowed('这一天的记录不支持编辑。');
    }
  }

  /// episode 条目编辑：摘要按用户声明保存，原始摘录移除（修正不
  /// 伪装原始会话证据）；当日理解元数据过滤旧文本后与索引一并
  /// 重建，指向该条目的画像叶同步摘要，身份自述触发既有的在线撤根。
  Future<MemoryActionResult> _editEntry(
    MemoryEntryRef ref,
    String replacement,
  ) async {
    if (replacement.runes.length > memoryEditEntryMaxRunes) {
      return _notAllowed('修正内容太长了，请浓缩成一句。');
    }
    var unreadable = false;
    var missing = false;
    final deferred = <String>[];
    try {
      await episodePipeline.synchronizedOnDayFiles(() async {
        final day = await episodePipeline.readDay(ref.date);
        if (!day.readable) {
          unreadable = true;
          return;
        }
        final index = day.entries.indexWhere(
          (candidate) => candidate.id == ref.entryId,
        );
        if (index < 0) {
          missing = true;
          return;
        }
        final original = day.entries[index];
        final corrected = EpisodeEntry(
          id: original.id,
          sessionId: original.sessionId,
          requestId: original.requestId,
          summary: replacement,
          evidence: null,
          at: original.at,
          kind: original.kind,
          personaBranch: original.personaBranch,
          personaNature: original.personaNature,
          due: original.due,
          proactive: original.proactive,
          note: original.note,
          signal: original.signal,
          userEdited: true,
        );
        final entries = List<EpisodeEntry>.of(day.entries)..[index] = corrected;
        final oldScope = {normalizeMemoryText(original.summary)};
        Map<String, Object?>? understanding = day.understanding;
        if (understanding != null) {
          understanding = DayUnderstanding.fromJson(
            understanding,
          ).filterBanned(oldScope).toJson();
        }
        await episodePipeline.writeFinalization(
          ref.date,
          entries: entries,
          summary: day.summary,
          finalized: day.finalized,
          finalizedAt: day.finalizedAt,
          understanding: understanding,
        );
        final indexStore = EpisodeIndexStore(
          memoryDirectory: episodePipeline.memoryDirectory,
          episodePipeline: episodePipeline,
        );
        await indexStore.rebuild(includeUnfinalized: true);
        // 派生画像同步（失败只推迟，不回滚已确认落盘的修正）。
        try {
          await personaTree.resyncLeafSummaries(original.id, replacement);
          if (corrected.personaBranch == 'identity' &&
              corrected.personaNature == 'self_report') {
            await personaTree.revokeCorrectedIdentityRoots([corrected]);
          }
        } on Object catch (error) {
          deferred.add('画像证据的同步');
          _diagnosticsSink('edit persona resync deferred [$error]');
        }
      });
    } on Object catch (error) {
      _diagnosticsSink('memory edit failed [$error]');
      return const MemoryActionResult(
        status: MemoryActionStatus.failed,
        message: '修正没有保存成功，原内容保持不变，可稍后重试。',
        retryable: true,
      );
    }
    if (unreadable) {
      return const MemoryActionResult(
        status: MemoryActionStatus.failed,
        message: '这一天的记录暂时读不出来，修正没有生效，可稍后重试。',
        retryable: true,
      );
    }
    if (missing) {
      return _notFound;
    }
    if (deferred.isNotEmpty) {
      return MemoryActionResult(
        status: MemoryActionStatus.partial,
        message:
            '已按你的说法修正这条记录；'
            '${deferred.join('、')}没有一次完成，稍后会自动补上。',
        deferred: deferred,
      );
    }
    return const MemoryActionResult(
      status: MemoryActionStatus.success,
      message: '已按你的说法修正这条记录。',
    );
  }

  /// long-memory 条目编辑：分区内按原文定位后整行替换（含「共同
  /// 过往」）。结构不可识别时拒绝写入。
  Future<MemoryActionResult> _editLongTerm(
    MemoryLongTermRef ref,
    String replacement,
  ) async {
    if (replacement.runes.length > longMemoryItemMaxRunes) {
      return _notAllowed('修正内容太长了，请浓缩成一句。');
    }
    if (!longMemorySections.contains(ref.section)) {
      return _notFound;
    }
    final contents = await _readIfExists(_longMemoryFile);
    final trimmed = contents?.trim() ?? '';
    if (trimmed.isEmpty) {
      return _notFound;
    }
    final parsed = parseLongMemory(trimmed);
    if (!parsed.readable) {
      return const MemoryActionResult(
        status: MemoryActionStatus.failed,
        message: '长期印象暂时读不出来，修正没有生效，可稍后重试。',
        retryable: true,
      );
    }
    final items = parsed.sections[ref.section] ?? const <String>[];
    final normalizedTarget = normalizeMemoryText(ref.text);
    final normalizedReplacement = normalizeMemoryText(replacement);
    final rebuilt = <String>[];
    var found = false;
    var inserted = false;
    for (final item in items) {
      final normalized = normalizeMemoryText(item);
      if (normalized == normalizedTarget) {
        found = true;
      }
      if (normalized == normalizedReplacement) {
        // 分区里已有同文条目：保留原句作为替换落点，不重复写入。
        if (!inserted) {
          rebuilt.add(item);
          inserted = true;
        }
        continue;
      }
      if (normalized == normalizedTarget) {
        if (!inserted) {
          rebuilt.add(replacement);
          inserted = true;
        }
        continue;
      }
      rebuilt.add(item);
    }
    if (!found) {
      return _notFound;
    }
    final sections = {
      for (final section in longMemorySections)
        section: section == ref.section
            ? rebuilt
            : List<String>.of(parsed.sections[section] ?? const []),
    };
    try {
      await _atomicWriter.replace(
        _longMemoryFile.path,
        renderLongMemory(sections),
      );
    } on Object catch (error) {
      _diagnosticsSink('long-memory edit failed [$error]');
      return const MemoryActionResult(
        status: MemoryActionStatus.failed,
        message: '修正没有保存成功，原内容保持不变，可稍后重试。',
        retryable: true,
      );
    }
    return const MemoryActionResult(
      status: MemoryActionStatus.success,
      message: '已按你的说法修正这条长期印象。',
    );
  }

  // ---------- 删除 ----------

  /// 删除影响范围预览（只读）；引用指向的内容已不存在时返回 null。
  Future<MemoryDeleteImpact?> deletePreview(MemoryItemRef ref) async {
    final text = await _itemText(ref);
    if (text == null) {
      return null;
    }
    if (ref is MemoryRelationshipRef && ref.list != 'sharedPast') {
      return null;
    }
    final scope = {normalizeMemoryText(text)};
    bool hitText(String candidate) =>
        bannedTitleMatches(normalizeMemoryText(candidate), scope);

    var entries = 0;
    var daySummaries = 0;
    for (final date in await episodePipeline.listEpisodeDates()) {
      final day = await episodePipeline.readDay(date);
      if (!day.readable) {
        continue;
      }
      entries += day.entries
          .where(
            (entry) =>
                entry.kind != episodeKindOpenLoopEvent &&
                (hitText(entry.summary) ||
                    (entry.evidence != null && hitText(entry.evidence!))),
          )
          .length;
      final summary = day.summary;
      if (summary != null && hitText(summary)) {
        daySummaries += 1;
      }
    }

    // 与 applyBan 的实际清除范围对齐：根、根下与未归根的中间理解、
    // 未归类叶（命中即删，根命中连子树删）。
    var personaNodes = 0;
    final snapshot = await personaTree.readSnapshot();
    for (final view in snapshot.branches.values) {
      if (!view.readable) {
        continue;
      }
      personaNodes += view.roots.where((root) => hitText(root.claim)).length;
      for (final root in view.roots) {
        personaNodes += root.middles
            .where((middle) => hitText(middle.claim))
            .length;
      }
      personaNodes += view.unrooted
          .where((middle) => hitText(middle.claim))
          .length;
      personaNodes += view.unclassified
          .where((leaf) => hitText(leaf.summary))
          .length;
    }

    var longTermItems = 0;
    final longMemory = await _readIfExists(_longMemoryFile);
    if (longMemory != null && longMemory.trim().isNotEmpty) {
      final parsed = parseLongMemory(longMemory);
      if (parsed.readable) {
        longTermItems = parsed.allItems.where(hitText).length;
      }
    }

    var monthSummaryItems = 0;
    final months = <String>{
      for (final date in await episodePipeline.listEpisodeDates())
        date.substring(0, 7),
    };
    for (final month in months) {
      final summaryFile = await monthlySummary.readMonthSummary(month);
      if (summaryFile == null || !summaryFile.readable) {
        continue;
      }
      monthSummaryItems += summaryFile.items
          .where((item) => hitText(item.text))
          .length;
    }

    var relationshipLines = 0;
    final relationship = await _readIfExists(_relationshipFile);
    if (relationship != null) {
      final parsed = parseRelationshipFile(relationship);
      if (parsed != null) {
        bool hitLine(String line) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('- ')) {
            return false;
          }
          return hitText(trimmed.substring(2).trim());
        }

        relationshipLines =
            parsed.confirmed.where(hitLine).length +
            parsed.probes.where(hitLine).length +
            parsed.recentChanges.where(hitLine).length;
      }
    }

    var dailyStateLines = 0;
    final dailyState = await _readIfExists(_dailyStateFile);
    if (dailyState != null) {
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

    return MemoryDeleteImpact(
      targetText: isSensitiveMemoryText(text) ? null : text,
      targetMasked: isSensitiveMemoryText(text),
      episodeEntries: entries,
      episodeDaySummaries: daySummaries,
      personaNodes: personaNodes,
      longTermItems: longTermItems,
      monthSummaryItems: monthSummaryItems,
      relationshipLines: relationshipLines,
      dailyStateLines: dailyStateLines,
      openLoops: openLoops,
    );
  }

  /// 执行删除：先写 deleted 抽象防复活范围，再清除全部派生内容与
  /// 索引；sessions 保留。控制记录写不进时绝不清除（可恢复失败）。
  Future<MemoryActionResult> delete(MemoryItemRef ref) async {
    final text = await _itemText(ref);
    if (text == null) {
      return _notFound;
    }
    final denied = _denyStatePackControl(ref);
    if (denied != null) {
      return denied;
    }
    return _executeDelete(text, origin: 'memory-center');
  }

  /// 聊天隐藏动作的删除入口（ticket 18 既有路径）：目标来自模型
  /// 摘要而非具体条目，先做只读定位扫描——任一记忆层命中才执行，
  /// 绝不让宽泛范围变成永久封禁；定位后与 [delete] 走同一清除管线。
  Future<MemoryActionResult> deleteByScope(
    String summary, {
    String origin = 'chat',
    String? requestId,
  }) async {
    final normalized = normalizeMemoryText(summary);
    if (normalized.isEmpty) {
      return const MemoryActionResult(
        status: MemoryActionStatus.failed,
        message: '没有可定位的删除目标。',
        code: 'memory_delete_no_target',
      );
    }
    if (!await _locate(normalized)) {
      _diagnosticsSink(
        'memory delete skipped [no target] request=${requestId ?? '-'}',
      );
      return const MemoryActionResult(
        status: MemoryActionStatus.failed,
        message: '没有可定位的删除目标。',
        code: 'memory_delete_no_target',
      );
    }
    return _executeDelete(summary, origin: origin);
  }

  /// 定位扫描（只读）：episodes、长期印象、画像、未闭环事项、关系
  /// 记录、近日状态、月摘要任一层命中即返回 true。
  Future<bool> _locate(String normalized) async {
    final scope = {normalized};
    bool hitText(String candidate) =>
        bannedTitleMatches(normalizeMemoryText(candidate), scope);
    bool hitEntry(EpisodeEntry entry) =>
        entry.kind != episodeKindOpenLoopEvent &&
        (hitText(entry.summary) ||
            (entry.evidence != null && hitText(entry.evidence!)));

    for (final date in await episodePipeline.listEpisodeDates()) {
      final day = await episodePipeline.readDay(date);
      if (!day.readable) {
        continue;
      }
      if (day.entries.any(hitEntry) ||
          (day.summary != null && hitText(day.summary!))) {
        return true;
      }
    }
    final longMemory = await _readIfExists(_longMemoryFile);
    if (longMemory != null && longMemory.trim().isNotEmpty) {
      final parsed = parseLongMemory(longMemory);
      if (parsed.readable && parsed.allItems.any(hitText)) {
        return true;
      }
    }
    final snapshot = await personaTree.readSnapshot();
    for (final view in snapshot.branches.values) {
      if (!view.readable) {
        continue;
      }
      final claims = [
        for (final root in view.roots) root.claim,
        for (final middle in view.unrooted) middle.claim,
        for (final leaf in view.unclassified) leaf.summary,
      ];
      if (claims.any(hitText)) {
        return true;
      }
    }
    final items = await openLoopStore.readItems();
    if (items != null && items.any((item) => hitText(item.title))) {
      return true;
    }
    final relationship = await _readIfExists(_relationshipFile);
    if (relationship != null &&
        relationship
            .split('\n')
            .any((line) => line.trim().startsWith('- ') && hitText(line))) {
      return true;
    }
    final dailyState = await _readIfExists(_dailyStateFile);
    if (dailyState != null &&
        dailyState
            .split('\n')
            .any((line) => line.trim().startsWith('- ') && hitText(line))) {
      return true;
    }
    final months = <String>{
      for (final date in await episodePipeline.listEpisodeDates())
        date.substring(0, 7),
    };
    for (final month in months) {
      final summaryFile = await monthlySummary.readMonthSummary(month);
      if (summaryFile == null || !summaryFile.readable) {
        continue;
      }
      if (summaryFile.items.any((item) => hitText(item.text))) {
        return true;
      }
    }
    return false;
  }

  Future<MemoryActionResult> _executeDelete(
    String text, {
    required String origin,
  }) async {
    final scope = {normalizeMemoryText(text)};

    if (!await memoryControls.recordDelete(text, origin: origin)) {
      return const MemoryActionResult(
        status: MemoryActionStatus.failed,
        message: '删除没有生效：控制记录写不进去，原有内容保持不变，可稍后重试。',
        retryable: true,
        code: 'memory_controls_not_writable',
      );
    }

    // 每步独立幂等，单步失败只记诊断并进入部分失败清单；控制记录
    // 已挡住注入与检索，剩余派生内容等待下次触发或日终补齐。
    final deferred = await purgeDerivedScopes(scope, text: text);

    if (deferred.isNotEmpty) {
      return MemoryActionResult(
        status: MemoryActionStatus.partial,
        message:
            '删除已生效，这条内容不会再出现；'
            '${deferred.join('、')}没有一次完成，稍后会自动补上。',
        deferred: deferred,
      );
    }
    return const MemoryActionResult(
      status: MemoryActionStatus.success,
      message: '已删除。原始对话记录还在，但不会再从那里整理出这条内容。',
    );
  }

  /// 清除命中封禁范围的全部派生内容与索引（删除管线与 ticket 21
  /// 恢复共用）：每步独立幂等，单步失败只记诊断并进入返回的部分
  /// 失败清单。本方法绝不写控制记录——控制记录归调用方（删除先写
  /// deleted 记录；恢复先重建控制文件），避免复活或重复 tombstone。
  Future<List<String>> purgeDerivedScopes(
    Set<String> scope, {
    required String text,
  }) async {
    bool hitText(String candidate) =>
        bannedTitleMatches(normalizeMemoryText(candidate), scope);
    bool hitEntry(EpisodeEntry entry) =>
        entry.kind != episodeKindOpenLoopEvent &&
        (hitText(entry.summary) ||
            (entry.evidence != null && hitText(entry.evidence!)));

    final deferred = <String>[];
    try {
      await personaTree.applyBan(text);
    } on Object catch (error) {
      deferred.add('画像的清理');
      _diagnosticsSink('delete persona purge deferred [$error]');
    }
    try {
      await episodePipeline.synchronizedOnDayFiles(() async {
        await episodePipeline.purgeEntriesMatching(hitEntry);
        for (final date in await episodePipeline.listEpisodeDates()) {
          final day = await episodePipeline.readDay(date);
          if (!day.readable || day.understanding == null) {
            continue;
          }
          final filteredJson = DayUnderstanding.fromJson(
            day.understanding!,
          ).filterBanned(scope).toJson();
          if (jsonEncode(filteredJson) == jsonEncode(day.understanding)) {
            continue;
          }
          await episodePipeline.writeFinalization(
            date,
            entries: day.entries,
            summary: day.summary,
            finalized: day.finalized,
            finalizedAt: day.finalizedAt,
            understanding: filteredJson,
          );
        }
        final indexStore = EpisodeIndexStore(
          memoryDirectory: episodePipeline.memoryDirectory,
          episodePipeline: episodePipeline,
        );
        await indexStore.rebuild(includeUnfinalized: true);
      });
    } on Object catch (error) {
      deferred.add('整理记录与索引的清理');
      _diagnosticsSink('delete episode purge deferred [$error]');
    }
    try {
      await _purgeLongMemory(scope);
    } on Object catch (error) {
      deferred.add('长期印象的清理');
      _diagnosticsSink('delete long-memory purge deferred [$error]');
    }
    try {
      await monthlySummary.purgeBlocked(scope);
    } on Object catch (error) {
      deferred.add('月份摘要的清理');
      _diagnosticsSink('delete month summary purge deferred [$error]');
    }
    try {
      await relationshipLifecycle.purgeBlockedTitles(scope);
    } on Object catch (error) {
      deferred.add('关系记录的清理');
      _diagnosticsSink('delete relationship purge deferred [$error]');
    }
    try {
      await _purgeDailyStateLines(scope);
    } on Object catch (error) {
      deferred.add('近日状态的清理');
      _diagnosticsSink('delete daily-state purge deferred [$error]');
    }
    try {
      await openLoopStore.removeLoopsMatching(scope);
    } on Object catch (error) {
      deferred.add('未闭环事项的清理');
      _diagnosticsSink('delete loop purge deferred [$error]');
    }
    return deferred;
  }

  /// 删除清除长期印象里的命中条目：解析 → 过滤 → 原子重写。
  /// 结构不可识别时不动（等待恢复流程）。
  Future<void> _purgeLongMemory(Set<String> scope) async {
    if (!await _longMemoryFile.exists()) {
      return;
    }
    final parsed = parseLongMemory(
      await _longMemoryFile.readAsString(encoding: utf8),
    );
    if (!parsed.readable) {
      return;
    }
    var changed = false;
    final sections = <String, List<String>>{};
    for (final section in longMemorySections) {
      final items = parsed.sections[section] ?? const <String>[];
      final kept = items
          .where(
            (item) => !bannedTitleMatches(normalizeMemoryText(item), scope),
          )
          .toList();
      if (kept.length != items.length) {
        changed = true;
      }
      sections[section] = kept;
    }
    if (changed) {
      await _atomicWriter.replace(
        _longMemoryFile.path,
        renderLongMemory(sections),
      );
    }
  }

  /// 删除清除 daily-state.md 里命中的列表行；其余结构原样保留。
  Future<void> _purgeDailyStateLines(Set<String> scope) async {
    if (!await _dailyStateFile.exists()) {
      return;
    }
    final contents = await _dailyStateFile.readAsString(encoding: utf8);
    final kept = <String>[];
    var changed = false;
    for (final line in contents.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('- ') &&
          bannedTitleMatches(normalizeMemoryText(trimmed), scope)) {
        changed = true;
        continue;
      }
      kept.add(line);
    }
    if (changed) {
      await _atomicWriter.replace(_dailyStateFile.path, kept.join('\n'));
    }
  }

  // ---------- 揭示 ----------

  /// 敏感证据的临时揭示（ticket 20）：只返回一次原文，不缓存、
  /// 不写日志；非敏感内容没有可揭示的东西。
  Future<MemoryActionResult> reveal(MemoryItemRef ref, String field) async {
    final text = await _fieldText(ref, field);
    if (text == null) {
      return _notFound;
    }
    if (!isSensitiveMemoryText(text)) {
      return const MemoryActionResult(
        status: MemoryActionStatus.failed,
        message: '这条内容不需要揭示。',
        code: 'memory_item_not_masked',
      );
    }
    return MemoryActionResult(
      status: MemoryActionStatus.success,
      message: '仅本次展示，离开页面或稍后会自动重新遮罩。',
      revealedText: text,
    );
  }

  /// 引用指向条目的原文（未遮罩）；内容已不存在或引用不可用时返回
  /// null。簿记条目不进记忆中心，也不可作为动作目标。
  ///
  /// [field] 只对 episode 条目（'content' 摘要 / 'evidence' 原摘录）
  /// 与某一天（'summary'）有意义，其余引用忽略；动作目标取
  /// 'content'，天引用不作为控制对象。
  Future<String?> _fieldText(MemoryItemRef ref, String field) async {
    switch (ref) {
      case MemoryEntryRef():
        final day = await episodePipeline.readDay(ref.date);
        if (!day.readable) {
          return null;
        }
        final entry = day.entries
            .where((candidate) => candidate.id == ref.entryId)
            .firstOrNull;
        if (entry == null) {
          return null;
        }
        return _presentable(
          field == 'evidence' ? entry.evidence : entry.summary,
        );
      case MemoryDayRef():
        if (field != 'summary') {
          return null;
        }
        final day = await episodePipeline.readDay(ref.date);
        return day.readable ? _presentable(day.summary) : null;
      case MemoryRootRef():
        final snapshot = await personaTree.readSnapshot();
        final view = snapshot.branches[ref.branchWire];
        if (view == null || !view.readable) {
          return null;
        }
        final root = view.roots
            .where((candidate) => candidate.id == ref.rootId)
            .firstOrNull;
        return _presentable(root?.claim);
      case MemoryMiddleRef():
        final snapshot = await personaTree.readSnapshot();
        final view = snapshot.branches[ref.branchWire];
        if (view == null || !view.readable) {
          return null;
        }
        for (final root in view.roots) {
          final hit = root.middles
              .where((candidate) => candidate.id == ref.middleId)
              .firstOrNull;
          if (hit != null) {
            return _presentable(hit.claim);
          }
        }
        final middle = view.unrooted
            .where((candidate) => candidate.id == ref.middleId)
            .firstOrNull;
        return _presentable(middle?.claim);
      case MemoryLongTermRef():
        return _longTermItemText(ref.section, ref.text);
      case MemoryRelationshipRef():
        if (ref.list == 'sharedPast') {
          return _longTermItemText('共同过往', ref.text);
        }
        return _relationshipLineText(ref.list, ref.text);
    }
  }

  Future<String?> _itemText(MemoryItemRef ref) => _fieldText(ref, 'content');

  Future<String?> _longTermItemText(String section, String text) async {
    if (!longMemorySections.contains(section)) {
      return null;
    }
    final contents = await _readIfExists(_longMemoryFile);
    final trimmed = contents?.trim() ?? '';
    if (trimmed.isEmpty) {
      return null;
    }
    final parsed = parseLongMemory(trimmed);
    if (!parsed.readable) {
      return null;
    }
    final normalized = normalizeMemoryText(text);
    for (final item in parsed.sections[section] ?? const <String>[]) {
      if (normalizeMemoryText(item) == normalized) {
        return item;
      }
    }
    return null;
  }

  Future<String?> _relationshipLineText(String list, String text) async {
    final contents = await _readIfExists(_relationshipFile);
    if (contents == null) {
      return null;
    }
    final parsed = parseRelationshipFile(contents);
    if (parsed == null) {
      return null;
    }
    final lines = switch (list) {
      'confirmed' => parsed.confirmed,
      'probes' => parsed.probes,
      'recentChanges' => parsed.recentChanges,
      _ => const <String>[],
    };
    final normalized = normalizeMemoryText(text);
    for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('- ')) {
        continue;
      }
      final value = trimmed.substring(2).trim();
      if (value.isNotEmpty && normalizeMemoryText(value) == normalized) {
        return value;
      }
    }
    return null;
  }

  String? _presentable(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<String?> _readIfExists(File file) async {
    if (!await file.exists()) {
      return null;
    }
    try {
      return await file.readAsString(encoding: utf8);
    } on Object {
      return null;
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
