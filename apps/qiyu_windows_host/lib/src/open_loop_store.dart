import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'episode_memory.dart';
import 'markdown_memory_repository.dart';

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
DateTime? parseDueDate(String due) {
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
  final dueDate = parseDueDate(due);
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

/// Open-loop 生命周期存储：热层 `open-loops.md`、归档
/// `open-loops.archive.md` 与用户记忆控制 `memory-controls.md` 的读写。
///
/// 职责边界（ticket 11）：
/// - 日终：候选提升（校验未完性/禁提/去重/预算）、closed 归档、过期清理；
/// - 即时：状态变化与禁提在回复落盘后立刻生效，不等日终；
/// - 禁提写入 memory-controls.md 并移出手层，后续整理不得重新激活。
final class OpenLoopStore {
  OpenLoopStore({
    required this.memoryDirectory,
    AtomicTextWriter? atomicWriter,
  }) : _atomicWriter = atomicWriter ?? const IoAtomicTextWriter();

  final String memoryDirectory;
  final AtomicTextWriter _atomicWriter;
  Future<void> _lockTail = Future.value();

  File get _loopsFile => File(path.join(memoryDirectory, 'open-loops.md'));
  File get _archiveFile =>
      File(path.join(memoryDirectory, 'open-loops.archive.md'));
  File get _controlsFile => File(path.join(memoryDirectory, 'memory-controls.md'));

  /// 串行化全部 loop/controls 文件写操作：日终归档与对话中的即时
  /// 生效分属不同任务链，必须在此汇合。
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
  Future<Set<String>> bannedTitles() async {
    final file = _controlsFile;
    if (!await file.exists()) {
      return const {};
    }
    final titles = <String>{};
    var inBanned = false;
    for (final line in (await file.readAsString(encoding: utf8))
        .replaceAll('\r\n', '\n')
        .split('\n')) {
      final header = line.trim();
      if (header.startsWith('## ')) {
        inBanned = header == '## banned';
        continue;
      }
      if (!inBanned) {
        continue;
      }
      final match = RegExp(r'^- \[[^\]]+\]\s*[^|]*\|\s*(.+)$').firstMatch(line);
      if (match != null) {
        final normalized = normalizeLoopTitle(match.group(1)!);
        if (normalized.isNotEmpty) {
          titles.add(normalized);
        }
      }
    }
    return titles;
  }

  /// 主动跟进候选池：状态 active、允许主动、due 已到、关系阶段允许
  /// 且未被禁提的条目。只进入候选池，是否开口由模型按语境选择。
  Future<List<OpenLoopItem>> proactiveCandidates(
    DateTime now,
    RelationshipStage stage,
  ) async {
    final items = await readItems();
    if (items == null) {
      return const [];
    }
    final banned = await bannedTitles();
    return items
        .where(
          (item) =>
              item.status == OpenLoopStatus.active &&
              item.proactive != OpenLoopProactive.no &&
              loopDueArrived(item.due, now) &&
              stageAllowsProactive(stage) &&
              !banned.contains(normalizeLoopTitle(item.title)),
        )
        .toList();
  }

  // ---------- 日终 ----------

  /// 候选提升：只有字段合法、未被禁提、不与既有事项重复且预算允许时
  /// 才成为正式 Open-loop。返回提升数量；结构不可识别时整体跳过。
  Future<int> promoteCandidates(List<EpisodeEntry> candidates) =>
      _withLock(() async {
        final parsed = await _parseLoopsFile();
        if (parsed == null) {
          return 0;
        }
        final banned = await bannedTitles();
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
          if (normalized.isEmpty || banned.contains(normalized)) {
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
    final archiveLines = await _readArchiveLines();
    final seen = archiveLines.toSet();
    var moved = 0;
    for (final item in closed) {
      final line = _archiveLine(item.title, date, item.note ?? '已闭环');
      if (seen.add(line)) {
        archiveLines.add(line);
      }
      moved += 1;
    }
    await _atomicWriter.replace(
      _archiveFile.path,
      '${archiveLines.join('\n')}\n',
    );
    final kept = parsed.items
        .where((item) => item.status != OpenLoopStatus.closed)
        .map((item) => item.raw)
        .toList();
    await _replaceLoops(_composeLoopsFile(kept));
    return moved;
  });

  /// 过期清理：due 已过超过 [openLoopExpiryDays] 天仍未闭环的条目
  /// 按「过期」归档。无 due 的条目不自动过期。
  Future<int> expireStale(DateTime now) => _withLock(() async {
    final parsed = await _parseLoopsFile();
    if (parsed == null) {
      return 0;
    }
    final local = now.toLocal();
    final today = DateTime(local.year, local.month, local.day);
    final stale = parsed.items
        .where((item) => item.status != OpenLoopStatus.closed &&
            item.due != null &&
            _dueExpired(item.due!, today))
        .toList();
    if (stale.isEmpty) {
      return 0;
    }
    final date = localSessionDate(now);
    final archiveLines = await _readArchiveLines();
    final seen = archiveLines.toSet();
    for (final item in stale) {
      final line = _archiveLine(item.title, date, '过期');
      if (seen.add(line)) {
        archiveLines.add(line);
      }
    }
    await _atomicWriter.replace(
      _archiveFile.path,
      '${archiveLines.join('\n')}\n',
    );
    final staleTitles = stale
        .map((item) => normalizeLoopTitle(item.title))
        .toSet();
    final kept = parsed.items
        .where((item) => !staleTitles.contains(normalizeLoopTitle(item.title)))
        .map((item) => item.raw)
        .toList();
    await _replaceLoops(_composeLoopsFile(kept));
    return stale.length;
  });

  bool _dueExpired(String due, DateTime today) {
    final dueDate = parseDueDate(due);
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

  /// 禁提：写入 memory-controls.md 的 banned 区，并立即把事项移出手层。
  /// 幂等——同一事项重复禁提不产生重复控制记录。返回禁提是否已生效；
  /// controls 文件不可识别、禁提记录无法落盘时返回 false 且**不动热层**——
  /// 否则事项离了热层又没有控制记录，次日日终会被重新提升，留下可复活空洞。
  Future<bool> banTitle(String title) => _withLock(() async {
    final normalized = normalizeLoopTitle(title);
    if (normalized.isEmpty) {
      return false;
    }
    if (!(await bannedTitles()).contains(normalized)) {
      final controls = await _appendBannedControl(title);
      if (controls == null) {
        return false;
      }
      await _atomicWriter.replace(_controlsFile.path, controls);
    }
    final parsed = await _parseLoopsFile();
    if (parsed != null) {
      final kept = <String>[];
      var removed = false;
      for (final item in parsed.items) {
        if (normalizeLoopTitle(item.title) == normalized) {
          removed = true;
        } else {
          kept.add(item.raw);
        }
      }
      if (removed) {
        await _replaceLoops(_composeLoopsFile(kept));
      }
    }
    return true;
  });

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

  /// 追加 banned 控制记录；controls 文件结构不可识别时返回 null（不动）。
  Future<String?> _appendBannedControl(String title) async {
    final file = _controlsFile;
    String contents;
    if (await file.exists()) {
      contents = await file.readAsString(encoding: utf8);
      if (!contents.contains('# memory-controls')) {
        return null;
      }
    } else {
      contents = '# memory-controls\n'
          '## frozen\n'
          '## banned\n'
          '## deleted\n';
    }
    final maxId = RegExp(r'- \[MC(\d+)\]')
        .allMatches(contents)
        .map((match) => int.tryParse(match.group(1)!) ?? 0)
        .fold<int>(0, (max, value) => value > max ? value : max);
    final line =
        '- [MC${(maxId + 1).toString().padLeft(3, '0')}] open-loop | $title';
    final normalizedLines = contents.replaceAll('\r\n', '\n');
    final bannedHeader = RegExp(r'^## banned\s*$', multiLine: true);
    if (bannedHeader.hasMatch(normalizedLines)) {
      return normalizedLines.replaceFirstMapped(
        bannedHeader,
        (_) => '## banned\n$line',
      );
    }
    return '$normalizedLines\n## banned\n$line\n';
  }

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

  String _composeLoopsFile(List<String> itemRaws) {
    if (itemRaws.isEmpty) {
      return '# open-loops\n';
    }
    return '# open-loops\n\n${itemRaws.join('\n')}\n';
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

/// 标题规范化：折叠空白并统一大小写，用于去重、禁提与状态定位。
String normalizeLoopTitle(String value) => value
    .replaceAll(RegExp(r'\s+'), ' ')
    .toLowerCase()
    .trim();

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

/// 从 relationship.md 解析关系阶段；缺失或不可识别按初识处理。
RelationshipStage parseRelationshipStage(String? contents) {
  if (contents == null) {
    return RelationshipStage.stranger;
  }
  final match = RegExp(
    r'^\s*stage\s*[:：]\s*(.+)$',
    multiLine: true,
  ).firstMatch(contents);
  if (match == null) {
    return RelationshipStage.stranger;
  }
  final value = match.group(1)!.trim();
  for (final stage in RelationshipStage.values) {
    if (stage.wireName == value) {
      return stage;
    }
  }
  return RelationshipStage.stranger;
}
