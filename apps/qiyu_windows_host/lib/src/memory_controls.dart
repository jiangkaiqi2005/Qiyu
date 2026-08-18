import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'episode_index.dart';
import 'markdown_memory_repository.dart';

/// memory-controls.md 的一条控制记录：稳定 ID（删除后不复用）、
/// 原归属与安全摘要。删除记录存的是抽象防复活范围，绝不保留原内容。
final class MemoryControlEntry {
  const MemoryControlEntry({
    required this.id,
    required this.origin,
    required this.summary,
  });

  final int id;

  /// 控制触发渠道（chat / open-loop）。渠道语义即「原归属」本意
  /// （用户裁定 2026-08-18）：记录里不另写内容原归属层。
  final String origin;
  final String summary;
}

/// memory-controls.md 的一次解析快照。[readable] 为 false 表示文件
/// 存在但结构无法识别：一切写操作拒绝执行（绝不产出半生效状态），
/// 读取按已解析出的部分尽力返回（「无法恢复时继续使用其他有效记忆」）。
final class MemoryControls {
  const MemoryControls({
    required this.readable,
    this.frozen = const [],
    this.banned = const [],
    this.deleted = const [],
  });

  static const MemoryControls empty = MemoryControls(readable: true);

  final bool readable;
  final List<MemoryControlEntry> frozen;
  final List<MemoryControlEntry> banned;
  final List<MemoryControlEntry> deleted;

  Set<String> _normalized(List<MemoryControlEntry> entries) => {
    for (final entry in entries)
      normalizeMemoryText(entry.summary),
  }..remove('');

  /// 冻结摘要集合（规范化后）。
  Set<String> get frozenSummaries => _normalized(frozen);

  /// 禁提摘要集合（规范化后）。
  Set<String> get bannedSummaries => _normalized(banned);

  /// 删除范围集合（规范化后）。
  Set<String> get deletedSummaries => _normalized(deleted);

  /// 封禁集合 = 禁提 ∪ 删除：注入、检索与全部派生整理都按它过滤。
  Set<String> get blockedSummaries => {
    ...bannedSummaries,
    ...deletedSummaries,
  };
}

final _controlEntryPattern = RegExp(r'^- \[MC(\d+)\]\s*([^|]*?)\s*\|\s*(.+)$');
final _controlIdPattern = RegExp(r'- \[MC(\d+)\]');

/// 用户记忆控制（ticket 18 / T24 定稿）：`memory-controls.md` 的唯一
/// 读写者。三段结构 frozen / banned / deleted，ID 稳定且删除后不复用。
///
/// 写入纪律（Memory.md 定稿）：
/// - 冻结/禁提/删除先写控制记录，调用方再移出或清除派生内容；
/// - 解除先恢复内容（冻结/禁提不清原文，恢复即无操作），最后移除记录；
/// - 文件不可识别时拒绝一切写入，读取尽力而为；
/// - 全部写入走 temp+rename 原子替换，串行化执行，重复执行安全。
final class MemoryControlsStore {
  MemoryControlsStore({
    required this.memoryDirectory,
    AtomicTextWriter? atomicWriter,
    void Function(String message)? diagnosticsSink,
  }) : _atomicWriter = atomicWriter ?? const IoAtomicTextWriter(),
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final AtomicTextWriter _atomicWriter;
  final void Function(String) _diagnosticsSink;
  Future<void> _lockTail = Future.value();

  File get controlsFile =>
      File(path.join(memoryDirectory, 'memory-controls.md'));

  Future<T> _withLock<T>(Future<T> Function() body) {
    final result = _lockTail.then((_) => body());
    _lockTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 读取当前控制快照；文件不存在返回空的可写快照。
  Future<MemoryControls> load() async {
    final file = controlsFile;
    if (!await file.exists()) {
      return MemoryControls.empty;
    }
    String contents;
    try {
      contents = await file.readAsString(encoding: utf8);
    } on Object {
      return const MemoryControls(readable: false);
    }
    return parseMemoryControls(contents);
  }

  /// 禁提：写入 banned 区。已存在同摘要记录时幂等返回 true。
  /// 文件不可识别时返回 false，调用方必须保持现状等待重试。
  Future<bool> ban(String summary, {String origin = 'chat'}) =>
      _addRecord('## banned', summary, origin);

  /// 冻结：写入 frozen 区。语义同 [ban]。
  Future<bool> freeze(String summary, {String origin = 'chat'}) =>
      _addRecord('## frozen', summary, origin);

  /// 删除：写入 deleted 区（抽象防复活范围，不得保留原内容）。
  Future<bool> recordDelete(String summary, {String origin = 'chat'}) =>
      _addRecord('## deleted', summary, origin);

  /// 解除冻结：移除匹配的控制记录（内容从未被清除，无需恢复）。
  /// 返回移除条数；文件不可识别返回 null。
  Future<int?> unfreeze(String summary) => _removeRecords('## frozen', summary);

  /// 解除禁提：语义同 [unfreeze]。
  Future<int?> unban(String summary) => _removeRecords('## banned', summary);

  Future<bool> _addRecord(String section, String summary, String origin) =>
      _withLock(() async {
        final normalized = normalizeMemoryText(summary);
        if (normalized.isEmpty) {
          return false;
        }
        final controls = await load();
        if (!controls.readable) {
          return false;
        }
        final existing = switch (section) {
          '## frozen' => controls.frozenSummaries,
          '## banned' => controls.bannedSummaries,
          _ => controls.deletedSummaries,
        };
        if (existing.contains(normalized)) {
          return true;
        }
        final contents = await _readRawContents();
        final rendered = _appendRecord(contents, section, summary, origin);
        if (rendered == null) {
          return false;
        }
        try {
          await _atomicWriter.replace(controlsFile.path, rendered);
          return true;
        } on Object catch (error) {
          _diagnosticsSink('memory controls deferred [$error]');
          return false;
        }
      });

  Future<int?> _removeRecords(String section, String summary) =>
      _withLock(() async {
        final normalized = normalizeMemoryText(summary);
        if (normalized.isEmpty) {
          return 0;
        }
        final controls = await load();
        if (!controls.readable) {
          return null;
        }
        final contents = await _readRawContents();
        if (contents == null) {
          // 文件不存在：没有任何记录可解除。
          return 0;
        }
        var removed = 0;
        final buffer = StringBuffer();
        var current = '';
        for (final rawLine in contents.replaceAll('\r\n', '\n').split('\n')) {
          final trimmed = rawLine.trim();
          if (trimmed.startsWith('## ')) {
            current = trimmed;
            buffer.writeln(rawLine);
            continue;
          }
          if (current == section && _entryMatches(trimmed, normalized)) {
            removed += 1;
            continue;
          }
          buffer.writeln(rawLine);
        }
        if (removed == 0) {
          return 0;
        }
        try {
          await _atomicWriter.replace(
            controlsFile.path,
            _normalizeTrailing(buffer.toString()),
          );
          return removed;
        } on Object catch (error) {
          _diagnosticsSink('memory controls deferred [$error]');
          return null;
        }
      });

  /// 解除匹配只认精确相等（与写侧幂等检查对称）：过度屏蔽是保守，
  /// 过度解除不是——解除 A 连带解除 B 违背「只能由明确操作解除」。
  bool _entryMatches(String line, String normalizedSummary) {
    final match = _controlEntryPattern.firstMatch(line);
    if (match == null) {
      return false;
    }
    final entryNormalized = normalizeMemoryText(match.group(3)!);
    if (entryNormalized.isEmpty) {
      return false;
    }
    return entryNormalized == normalizedSummary;
  }

  /// 追加控制记录；结构不可识别时返回 null（不动文件）。
  String? _appendRecord(
    String? contents,
    String section,
    String summary,
    String origin,
  ) {
    String base;
    if (contents == null) {
      base = '# memory-controls\n'
          '## frozen\n'
          '## banned\n'
          '## deleted\n';
    } else if (!contents.contains('# memory-controls')) {
      return null;
    } else {
      base = contents.replaceAll('\r\n', '\n');
    }
    final maxId = _controlIdPattern
        .allMatches(base)
        .map((match) => int.tryParse(match.group(1)!) ?? 0)
        .fold<int>(0, (max, value) => value > max ? value : max);
    final line =
        '- [MC${(maxId + 1).toString().padLeft(3, '0')}] $origin | $summary';
    final header = RegExp('^${RegExp.escape(section)}\\s*\$', multiLine: true);
    if (header.hasMatch(base)) {
      return base.replaceFirstMapped(header, (_) => '$section\n$line');
    }
    return '${_normalizeTrailing(base)}$section\n$line\n';
  }

  Future<String?> _readRawContents() async {
    final file = controlsFile;
    if (!await file.exists()) {
      return null;
    }
    try {
      return await file.readAsString(encoding: utf8);
    } on Object {
      return null;
    }
  }

  String _normalizeTrailing(String contents) {
    final trimmed = contents.replaceAll(RegExp(r'\n{3,}$'), '\n\n');
    return trimmed.endsWith('\n') ? trimmed : '$trimmed\n';
  }
}

/// 解析 memory-controls.md：只认 `# memory-controls` 标题与三段
/// `## frozen` / `## banned` / `## deleted`；段内只允许空行与
/// `- [MCxxx] 原归属 | 安全摘要` 记录行，其余一律不可读。
MemoryControls parseMemoryControls(String contents) {
  if (!contents.contains('# memory-controls')) {
    return const MemoryControls(readable: false);
  }
  final frozen = <MemoryControlEntry>[];
  final banned = <MemoryControlEntry>[];
  final deleted = <MemoryControlEntry>[];
  List<MemoryControlEntry>? current;
  for (final rawLine in contents.replaceAll('\r\n', '\n').split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line == '# memory-controls') {
      continue;
    }
    if (line.startsWith('## ')) {
      current = switch (line) {
        '## frozen' => frozen,
        '## banned' => banned,
        '## deleted' => deleted,
        _ => null,
      };
      if (current == null) {
        return const MemoryControls(readable: false);
      }
      continue;
    }
    if (current == null) {
      return const MemoryControls(readable: false);
    }
    final match = _controlEntryPattern.firstMatch(line);
    if (match == null) {
      return const MemoryControls(readable: false);
    }
    current.add(
      MemoryControlEntry(
        id: int.tryParse(match.group(1)!) ?? 0,
        origin: match.group(2)!.trim(),
        summary: match.group(3)!.trim(),
      ),
    );
  }
  return MemoryControls(
    readable: true,
    frozen: frozen,
    banned: banned,
    deleted: deleted,
  );
}
