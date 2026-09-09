import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_controls.dart';
import 'memory_text_primitives.dart';

/// 设计定稿分块预算：open-loops.md 100-250 tokens。
/// 保守按 1 rune ≈ 1 token 估算，rune 上限即 token 上限。
const openLoopsMaxRunes = 250;

/// 过期规则：due 已过超过该天数仍未闭环、用户也未再提起的 loop，
/// 日终整理时按「过期」归档。无 due 的 loop 不自动过期。
const openLoopExpiryDays = 14;

enum OpenLoopProactive { no, once, yes }

enum OpenLoopStatus { active, paused, closed }

/// open-loops.md 中的一个条目块。raw 保留原文，未变更条目按原样写回，
/// 不丢失未知字段或用户手写注释。
final class OpenLoopItem {
  const OpenLoopItem({
    required this.raw,
    required this.id,
    required this.title,
    required this.status,
    required this.proactive,
    required this.due,
    this.note,
  });

  final String raw;
  final String id;
  final String title;
  final OpenLoopStatus status;
  final OpenLoopProactive proactive;
  final String? due;
  final String? note;

  /// 仅改写 status 行，其余原文保留；缺失 status 行时补一行。
  /// 闭环时若带有结果（用户回复的追溯说明），用它替换 note——事项既已
  /// 闭环不会再被问起，归档行以该结果为准。
  OpenLoopItem withStatus(OpenLoopStatus next, {String? closedResult}) {
    final statusLine = RegExp(
      r'^(\s*status\s*[:：]\s*)(active|paused|closed)(\s*)$',
      multiLine: true,
    );
    var updated = statusLine.hasMatch(raw)
        ? raw.replaceFirstMapped(
            statusLine,
            (match) => '${match.group(1)}${next.name}${match.group(3)}',
          )
        : '$raw\n  status: ${next.name}';
    var nextNote = note;
    final trimmedResult = closedResult?.trim();
    if (next == OpenLoopStatus.closed &&
        trimmedResult != null &&
        trimmedResult.isNotEmpty) {
      final noteLine = RegExp(r'^\s*note\s*[:：]\s*.*$', multiLine: true);
      updated = noteLine.hasMatch(updated)
          ? updated.replaceFirstMapped(
              noteLine,
              (_) => '  note: $trimmedResult',
            )
          : '$updated\n  note: $trimmedResult';
      nextNote = trimmedResult;
    }
    return OpenLoopItem(
      raw: updated,
      id: id,
      title: title,
      status: next,
      proactive: proactive,
      due: due,
      note: nextNote,
    );
  }
}

/// 解析 due 开头的 `YYYY-MM-DD` 日期段；格式不合法返回 null。
/// 仅本文件消费（判定入口是 [loopDueArrived]）。
DateTime? _parseDueDate(String due) {
  final text = due.trim();
  if (text.runes.length < 10) {
    return null;
  }
  final year = int.tryParse(text.substring(0, 4));
  final month = int.tryParse(text.substring(5, 7));
  final day = int.tryParse(text.substring(8, 10));
  if (year == null || month == null || day == null) {
    return null;
  }
  return DateTime(year, month, day);
}

/// 判定规则中 Host 可确定性计算的部分：状态、权限与时间。
/// 「用户当前没有明确任务」与「语境自然」由模型在生成时判断。
bool loopDueArrived(String? due, DateTime now) {
  if (due == null) {
    return true;
  }
  final dueDate = _parseDueDate(due);
  if (dueDate == null) {
    return false;
  }
  final local = now.toLocal();
  final today = DateTime(local.year, local.month, local.day);
  if (dueDate.isBefore(today)) {
    return true;
  }
  if (dueDate.isAfter(today)) {
    return false;
  }
  final text = due.trim();
  final period = text.length > 10 ? text.substring(10).trim() : '';
  final hour = local.hour;
  return switch (period) {
    '早晨' || 'morning' => hour >= 6,
    '上午' => hour >= 9,
    '中午' => hour >= 11,
    '下午' || 'afternoon' => hour >= 13,
    '晚上' || 'evening' => hour >= 18,
    '深夜' || 'night' => hour >= 21,
    _ => true,
  };
}

/// 关系阶段门禁：产品灵魂阶段表——初识「不追问、倾听为主」，
/// 熟悉起才「开始记住并自然提起用户说过的事」。
bool stageAllowsProactive(RelationshipStage stage) =>
    stage != RelationshipStage.stranger;

/// Open-loop 生命周期存储：热层 `open-loops.md` 与归档
/// `open-loops.archive.md` 的读写。用户记忆控制记录统一由
/// [MemoryControlsStore] 管理（ticket 18），本类只做读取代理与
/// 禁提/删除时的热层移出。
///
/// 职责边界（ticket 11）：
/// - 日终：候选提升（校验未完性/控制/去重/预算）、closed 归档、过期清理；
/// - 即时：状态变化与禁提在回复落盘后立刻生效，不等日终；
/// - 禁提写入 memory-controls.md 并移出手层，后续整理不得重新激活。
final class OpenLoopStore {
  OpenLoopStore({
    required this.memoryDirectory,
    AtomicTextWriter? atomicWriter,
    MemoryControlsStore? memoryControls,
  }) : _atomicWriter = atomicWriter ?? const IoAtomicTextWriter(),
       memoryControls = memoryControls ??
           MemoryControlsStore(memoryDirectory: memoryDirectory);

  final String memoryDirectory;
  final AtomicTextWriter _atomicWriter;

  /// 记忆控制记录的唯一读写者；禁提/冻结/删除的过滤集合都从这里取。
  final MemoryControlsStore memoryControls;
  Future<void> _lockTail = Future.value();

  File get _loopsFile => File(path.join(memoryDirectory, 'open-loops.md'));
  File get _archiveFile =>
      File(path.join(memoryDirectory, 'open-loops.archive.md'));

  /// 串行化全部 loop 文件写操作：日终归档与对话中的即时生效分属
  /// 不同任务链，必须在此汇合。controls 文件有独立的串行锁。
  Future<T> _withLock<T>(Future<T> Function() body) {
    final result = _lockTail.then((_) => body());
    _lockTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  // ---------- 读取 ----------

  /// 解析热层条目；结构无法识别（用户手写内容）时返回 null，
  /// 一切写操作都必须原样保留该文件。
  Future<List<OpenLoopItem>?> readItems() async {
    final file = _loopsFile;
    if (!await file.exists()) {
      return const [];
    }
    return parseOpenLoopItems(await file.readAsString(encoding: utf8));
  }

  /// memory-controls.md 的 banned 摘要集合（规范化后），用于阻止
  /// 禁提事项被重新提升或注入。
  Future<Set<String>> bannedTitles() async =>
      (await memoryControls.load()).bannedSummaries;

  /// 封禁集合 = 禁提 ∪ 删除（规范化后）：两类内容都不得再被提升、
  /// 注入、检索或整理。
  Future<Set<String>> blockedTitles() async =>
      (await memoryControls.load()).blockedSummaries;

  /// 冻结摘要集合（规范化后）：冻结停止注入、检索与自动整理，
  /// 与封禁同样参与各管线过滤。
  Future<Set<String>> frozenTitles() async =>
      (await memoryControls.load()).frozenSummaries;

  /// 受控集合 = 封禁（禁提 ∪ 删除）∪ 冻结：冻结同样停止注入、检索
  /// 与自动整理，封禁内容不得被提升、注入或召回。各管线过滤的受控
  /// 集合统一从这里取，不另写「封禁∪冻结」的重复换算。
  Future<Set<String>> controlledTitles() async =>
      (await memoryControls.load()).controlledSummaries;

  /// 主动跟进候选池：状态 active、允许主动、due 已到、关系阶段允许
  /// 且未被封禁（禁提/删除）或冻结的条目。只进入候选池，是否开口
  /// 由模型按语境选择。控制匹配按包含关系（与其余管线同律），
  /// 绝不让受控事项经主动跟进绕回。
  Future<List<OpenLoopItem>> proactiveCandidates(
    DateTime now,
    RelationshipStage stage,
  ) async {
    final items = await readItems();
    if (items == null) {
      return const [];
    }
    final controls = await memoryControls.load();
    final controlled = controls.controlledSummaries;
    return items
        .where(
          (item) =>
              item.status == OpenLoopStatus.active &&
              item.proactive != OpenLoopProactive.no &&
              loopDueArrived(item.due, now) &&
              stageAllowsProactive(stage) &&
              !bannedTitleMatches(normalizeLoopTitle(item.title), controlled),
        )
        .toList();
  }

  // ---------- 日终 ----------

  /// 候选提升：只有字段合法、未被封禁（禁提/删除）或冻结、不与既有
  /// 事项重复且预算允许时才成为正式 Open-loop。控制匹配按包含关系
  /// （与其余管线同律）。返回提升数量；结构不可识别时整体跳过。
  Future<int> promoteCandidates(List<EpisodeEntry> candidates) =>
      _withLock(() async {
        final parsed = await _parseLoopsFile();
        if (parsed == null) {
          return 0;
        }
        final controls = await memoryControls.load();
        final controlled = controls.controlledSummaries;
        var nextId = _nextLoopNumber(parsed);
        final contents = parsed.contents;
        var promoted = 0;
        final additions = StringBuffer();
        final promotedTitles = <String>{};
        for (final candidate in candidates) {
          if (candidate.kind != episodeKindOpenLoopCandidate) {
            continue;
          }
          final title = candidate.summary.trim();
          final normalized = normalizeLoopTitle(title);
          if (normalized.isEmpty ||
              bannedTitleMatches(normalized, controlled)) {
            continue;
          }
          final exists = parsed.items.any(
            (item) => normalizeLoopTitle(item.title) == normalized,
          );
          if (exists || !promotedTitles.add(normalized)) {
            continue;
          }
          final block = _renderLoopBlock(
            id: 'o$nextId',
            title: title,
            due: candidate.due,
            proactive: _parseProactive(candidate.proactive),
            note: candidate.note,
          );
          if ((contents.runes.length +
                  additions.toString().runes.length +
                  block.runes.length) >
              openLoopsMaxRunes) {
            continue;
          }
          additions.write(block);
          nextId += 1;
          promoted += 1;
        }
        if (promoted > 0) {
          await _replaceLoops('$contents$additions');
        }
        return promoted;
      });

  /// closed 条目挪入归档：每条一行（事项、闭环日期、结果），
  /// 热层只留 active/paused。重复归档行去重。
  Future<int> archiveClosed(String date) => _withLock(() async {
    final parsed = await _parseLoopsFile();
    if (parsed == null) {
      return 0;
    }
    final closed = parsed.items
        .where((item) => item.status == OpenLoopStatus.closed)
        .toList();
    if (closed.isEmpty) {
      return 0;
    }
    return _archiveAndRewrite(
      selected: closed,
      archiveLineFor: (item) =>
          _archiveLine(item.title, date, item.note ?? '已闭环'),
      kept: parsed.items
          .where((item) => item.status != OpenLoopStatus.closed)
          .map((item) => item.raw)
          .toList(),
    );
  });

  /// 过期清理：due 已过超过 [openLoopExpiryDays] 天仍未闭环的条目
  /// 按「过期」归档。无 due 的条目不自动过期。冻结条目停止自动修改：
  /// 过期整理跳过它们，原地保留到用户解除。
  Future<int> expireStale(DateTime now) => _withLock(() async {
    final parsed = await _parseLoopsFile();
    if (parsed == null) {
      return 0;
    }
    final frozen = await frozenTitles();
    final local = now.toLocal();
    final today = DateTime(local.year, local.month, local.day);
    final stale = parsed.items
        .where((item) => item.status != OpenLoopStatus.closed &&
            item.due != null &&
            _dueExpired(item.due!, today) &&
            !bannedTitleMatches(normalizeLoopTitle(item.title), frozen))
        .toList();
    if (stale.isEmpty) {
      return 0;
    }
    final date = localSessionDate(now);
    final staleTitles = stale
        .map((item) => normalizeLoopTitle(item.title))
        .toSet();
    return _archiveAndRewrite(
      selected: stale,
      archiveLineFor: (item) => _archiveLine(item.title, date, '过期'),
      kept: parsed.items
          .where((item) => !staleTitles.contains(normalizeLoopTitle(item.title)))
          .map((item) => item.raw)
          .toList(),
    );
  });

  /// 归档追加 + 热层重写的共享骨架：[selected] 为本次要归档的条目，
  /// [archiveLineFor] 产出各自格式的归档行（重复行去重）；[kept] 是
  /// 重写后的热层条目原文。返回归档条数（= [selected] 长度）。
  Future<int> _archiveAndRewrite({
    required List<OpenLoopItem> selected,
    required String Function(OpenLoopItem item) archiveLineFor,
    required List<String> kept,
  }) async {
    final archiveLines = await _readArchiveLines();
    final seen = archiveLines.toSet();
    for (final item in selected) {
      final line = archiveLineFor(item);
      if (seen.add(line)) {
        archiveLines.add(line);
      }
    }
    await _atomicWriter.replace(
      _archiveFile.path,
      '${archiveLines.join('\n')}\n',
    );
    await _replaceLoops(_composeLoopsFile(kept));
    return selected.length;
  }

  bool _dueExpired(String due, DateTime today) {
    final dueDate = _parseDueDate(due);
    if (dueDate == null) {
      return false;
    }
    return today.difference(dueDate).inDays > openLoopExpiryDays;
  }

  // ---------- 即时生效 ----------

  /// 状态变化（闭环/暂缓/重新活跃）：找到事项即改写热层，回复落盘后
  /// 立刻生效，不等日终。闭环时若带 [result]（用户回复的追溯说明），
  /// 一并持久化，供日终归档行记录。找不到对应事项时静默跳过。
  Future<bool> applyStatusChange({
    required String title,
    required String status,
    String? result,
  }) => _withLock(() async {
    final next = switch (status) {
      'closed' => OpenLoopStatus.closed,
      'paused' => OpenLoopStatus.paused,
      'active' => OpenLoopStatus.active,
      _ => null,
    };
    if (next == null) {
      return false;
    }
    final parsed = await _parseLoopsFile();
    if (parsed == null) {
      return false;
    }
    final normalized = normalizeLoopTitle(title);
    var changed = false;
    final kept = <String>[];
    for (final item in parsed.items) {
      if (!changed && normalizeLoopTitle(item.title) == normalized) {
        kept.add(item.withStatus(next, closedResult: result).raw);
        changed = true;
      } else {
        kept.add(item.raw);
      }
    }
    if (changed) {
      await _replaceLoops(_composeLoopsFile(kept));
    }
    return changed;
  });

  /// 禁提：先写 memory-controls.md 的 banned 区，再把事项移出手层
  /// （定稿写入顺序：先控制记录后清派生）。幂等——同一事项重复禁提
  /// 不产生重复控制记录。返回禁提是否已生效；controls 文件不可识别、
  /// 禁提记录无法落盘时返回 false 且**不动热层**——否则事项离了热层
  /// 又没有控制记录，次日日终会被重新提升，留下可复活空洞。
  Future<bool> banTitle(String title, {String origin = 'open-loop'}) =>
      _withLock(() async {
        final normalized = normalizeLoopTitle(title);
        if (normalized.isEmpty) {
          return false;
        }
        if (!await memoryControls.ban(title, origin: origin)) {
          return false;
        }
        await _removeLoopsWhere(
          (item) => bannedTitleMatches(
            normalizeLoopTitle(item.title),
            {normalized},
          ),
        );
        return true;
      });

  /// 删除即时生效的一部分：把命中控制范围的条目永久移出手层
  /// （删除清除派生内容，与禁提的移出同一条路径）。返回移出条数。
  Future<int> removeLoopsMatching(Set<String> titles) => _withLock(() async {
    if (titles.isEmpty) {
      return 0;
    }
    return _removeLoopsWhere(
      (item) =>
          bannedTitleMatches(normalizeLoopTitle(item.title), titles),
    );
  });

  Future<int> _removeLoopsWhere(bool Function(OpenLoopItem item) test) async {
    final parsed = await _parseLoopsFile();
    if (parsed == null) {
      return 0;
    }
    final kept = <String>[];
    var removed = 0;
    for (final item in parsed.items) {
      if (test(item)) {
        removed += 1;
      } else {
        kept.add(item.raw);
      }
    }
    if (removed > 0) {
      await _replaceLoops(_composeLoopsFile(kept));
    }
    return removed;
  }

  // ---------- 内部 ----------

  Future<_ParsedLoops?> _parseLoopsFile() async {
    final file = _loopsFile;
    if (!await file.exists()) {
      return const _ParsedLoops(contents: '# open-loops\n\n', items: []);
    }
    final contents = await file.readAsString(encoding: utf8);
    final items = parseOpenLoopItems(contents);
    if (items == null) {
      return null;
    }
    return _ParsedLoops(contents: contents, items: items);
  }

  Future<void> _replaceLoops(String contents) async {
    try {
      await _atomicWriter.replace(_loopsFile.path, contents);
    } on MemoryRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw MemoryRepositoryException(
        code: 'open_loop_write_failed',
        message: '无法保存未闭环事项，对话不受影响。',
        retryable: true,
        cause: error,
      );
    }
  }

  Future<List<String>> _readArchiveLines() async {
    final file = _archiveFile;
    if (!await file.exists()) {
      return ['# open-loops archive'];
    }
    final lines = (await file.readAsString(encoding: utf8))
        .replaceAll('\r\n', '\n')
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    return lines.isEmpty ? ['# open-loops archive'] : lines;
  }

  String _archiveLine(String title, String date, String result) =>
      '- $title | 闭环: $date | $result';

  int _nextLoopNumber(_ParsedLoops parsed) {
    var max = 0;
    for (final item in parsed.items) {
      final match = RegExp(r'^o(\d+)$').firstMatch(item.id);
      final value = match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
      if (value > max) {
        max = value;
      }
    }
    return max + 1;
  }

  String _renderLoopBlock({
    required String id,
    required String title,
    required String? due,
    required OpenLoopProactive proactive,
    required String? note,
  }) {
    final buffer = StringBuffer()
      ..writeln('- [$id] $title');
    if (due != null && due.trim().isNotEmpty) {
      buffer.writeln('  due: ${due.trim()}');
    }
    buffer.writeln('  proactive: ${proactive.name}');
    buffer.writeln('  status: active');
    final trimmedNote = note?.trim();
    if (trimmedNote != null && trimmedNote.isNotEmpty) {
      buffer.writeln('  note: $trimmedNote');
    }
    return buffer.toString();
  }
}

/// proactive 字段白名单映射：只认 no/yes，其余一律按 once（定稿默认）。
/// 候选提升与热层解析共用同一份映射，避免两处漂移。
OpenLoopProactive _parseProactive(String? value) => switch (value) {
  'no' => OpenLoopProactive.no,
  'yes' => OpenLoopProactive.yes,
  _ => OpenLoopProactive.once,
};

final class _ParsedLoops {
  const _ParsedLoops({required this.contents, required this.items});

  final String contents;
  final List<OpenLoopItem> items;
}

/// 标题规范化：与 [normalizeMemoryText] 同一规则（折叠空白并统一
/// 大小写），用于去重、禁提与状态定位。
String normalizeLoopTitle(String value) => normalizeMemoryText(value);

/// open-loops.md 的规范文本（存储类与受控过滤共用同一份重渲染格式）。
String _composeLoopsFile(List<String> itemRaws) {
  if (itemRaws.isEmpty) {
    return '# open-loops\n';
  }
  return '# open-loops\n\n${itemRaws.join('\n')}\n';
}

/// open-loops.md 的条目级受控过滤：文件缺失返回 null；结构不可识别
/// 原样返回；有条目标题命中 [controlled] 时重渲染为只含未命中条目的
/// 完整文件文本。日终整理与 Dream 输入共用同一份重渲染格式。
String? filterOpenLoopContents(
  String? contents,
  bool Function(String title) controlled,
) {
  if (contents == null) {
    return null;
  }
  final items = parseOpenLoopItems(contents);
  if (items == null) {
    return contents;
  }
  final kept = items
      .where((item) => !controlled(item.title))
      .map((item) => item.raw)
      .toList();
  if (kept.length == items.length) {
    return contents;
  }
  return _composeLoopsFile(kept);
}

/// 把 open-loops.md 拆成条目块并解析四字段；无法识别的结构返回 null。
List<OpenLoopItem>? parseOpenLoopItems(String contents) {
  final lines = contents.replaceAll('\r\n', '\n').split('\n');
  final items = <OpenLoopItem>[];
  final current = <String>[];
  var sawItem = false;
  void flush() {
    if (current.isEmpty) {
      return;
    }
    while (current.isNotEmpty && current.last.trim().isEmpty) {
      current.removeLast();
    }
    final item = _parseItemBlock(current);
    if (item != null) {
      items.add(item);
    }
    current.clear();
  }

  for (final line in lines) {
    if (RegExp(r'^- \[[^\]]+\]').hasMatch(line)) {
      flush();
      current.add(line);
      sawItem = true;
    } else if (sawItem) {
      current.add(line);
    } else if (line.trim().isNotEmpty && !line.startsWith('#')) {
      return null;
    }
  }
  flush();
  if (items.isEmpty && sawItem) {
    return null;
  }
  return items;
}

OpenLoopItem? _parseItemBlock(List<String> blockLines) {
  final header = RegExp(r'^- \[([^\]]+)\]\s*(.*)$').firstMatch(blockLines.first);
  if (header == null) {
    return null;
  }
  final title = header.group(2)!.trim();
  if (title.isEmpty) {
    return null;
  }
  String? field(String name) {
    for (final line in blockLines.skip(1)) {
      final match = RegExp('^\\s*$name\\s*[:：]\\s*(.*)\$').firstMatch(line);
      if (match != null) {
        final value = match.group(1)!.trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  final status = switch (field('status')) {
    'paused' => OpenLoopStatus.paused,
    'closed' => OpenLoopStatus.closed,
    _ => OpenLoopStatus.active,
  };
  final proactive = _parseProactive(field('proactive'));
  return OpenLoopItem(
    raw: blockLines.join('\n'),
    id: header.group(1)!.trim(),
    title: title,
    status: status,
    proactive: proactive,
    due: field('due'),
    note: field('note'),
  );
}
