import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'markdown_memory_repository.dart';

/// 增量整理窗口：每四到六轮取最保守的一侧。窗口内没有显著信号时，
/// checkpoint 照常前进，保证对话不会被重复整理。
const episodeWindowTurns = 4;

final class EpisodeEntry {
  const EpisodeEntry({
    required this.id,
    required this.sessionId,
    required this.requestId,
    required this.summary,
    this.evidence,
    required this.at,
  });

  factory EpisodeEntry.fromJson(Map<String, Object?> json) => EpisodeEntry(
    id: json['id']! as String,
    sessionId: json['sessionId']! as String,
    requestId: json['requestId']! as String,
    summary: json['summary']! as String,
    evidence: json['evidence'] as String?,
    at: DateTime.parse(json['at']! as String).toUtc(),
  );

  final String id;
  final String sessionId;
  final String requestId;
  final String summary;
  final String? evidence;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'requestId': requestId,
    'summary': summary,
    if (evidence != null) 'evidence': evidence,
    'at': at.toUtc().toIso8601String(),
  };
}

final class EpisodeDay {
  const EpisodeDay({
    required this.date,
    required this.entries,
    this.exists = false,
    this.readable = true,
  });

  final String date;
  final List<EpisodeEntry> entries;

  /// 当日文件是否已存在；存在但不可解析时绝不能被新内容覆盖。
  final bool exists;
  final bool readable;

  bool hasEntryId(String id) => entries.any((entry) => entry.id == id);
}

final class EpisodeCheckpoint {
  const EpisodeCheckpoint({
    required this.sessionId,
    required this.lastRequestId,
    required this.updatedAt,
    this.schemaVersion = 1,
  });

  factory EpisodeCheckpoint.fromJson(Map<String, Object?> json) =>
      EpisodeCheckpoint(
        schemaVersion: json['schemaVersion'] as int? ?? 1,
        sessionId: json['sessionId']! as String,
        lastRequestId: json['lastRequestId']! as String,
        updatedAt: DateTime.parse(json['updatedAt']! as String).toUtc(),
      );

  final int schemaVersion;
  final String sessionId;
  final String lastRequestId;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'sessionId': sessionId,
    'lastRequestId': lastRequestId,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

final class EpisodeUpdateResult {
  const EpisodeUpdateResult({
    required this.writtenEntries,
    required this.skippedDuplicates,
    required this.checkpointAdvanced,
    required this.pendingTurns,
    this.skippedCorruptDay = false,
  });

  final int writtenEntries;
  final int skippedDuplicates;
  final bool checkpointAdvanced;

  /// 当日 episode 文件存在但无法解析：本轮不写入、不前进，等待恢复。
  final bool skippedCorruptDay;

  /// 前进后仍留在窗口内、等待下一次整理判断的用户轮数。
  final int pendingTurns;
}

/// 伪 Agent 隐藏动作的记忆写入端。只接受白名单校验后的
/// [HiddenAction]，把 memory_signal 增量写入当天 episode，并维护
/// 可续跑的 checkpoint。模型从不直接写文件；这里的每一次写入都是
/// 原子替换，且 checkpoint 只在 episode 写入成功后才前进。
final class EpisodeMemoryPipeline {
  EpisodeMemoryPipeline({
    required this.memoryDirectory,
    Clock? clock,
    AtomicTextWriter? atomicWriter,
  }) : _clock = clock ?? DateTime.now,
       _atomicWriter = atomicWriter ?? const IoAtomicTextWriter();

  final String memoryDirectory;
  final Clock _clock;
  final AtomicTextWriter _atomicWriter;

  Directory get _episodesDirectory =>
      Directory(path.join(memoryDirectory, 'episodes'));

  Future<EpisodeDay> readToday() => _readDay(localSessionDate(_clock()));

  Future<EpisodeCheckpoint?> readCheckpoint() async {
    final file = _checkpointFile();
    if (!await file.exists()) {
      return null;
    }
    try {
      final metadata = _decodeMetadata(await file.readAsString(encoding: utf8));
      return EpisodeCheckpoint.fromJson(metadata);
    } on Object {
      return null;
    }
  }

  Future<EpisodeUpdateResult> processReply({
    required RawSession session,
    required String requestId,
    required List<HiddenAction> hiddenActions,
    bool consumeWindow = true,
  }) async {
    final checkpoint = await readCheckpoint();
    final pendingTurns = _pendingUserTurns(checkpoint, session);
    final date = localSessionDate(_clock());
    final day = await _readDay(date);
    if (day.exists && !day.readable) {
      // 当日文件存在但无法解析：不覆盖、不前进，交给恢复流程处理。
      return EpisodeUpdateResult(
        writtenEntries: 0,
        skippedDuplicates: 0,
        checkpointAdvanced: false,
        pendingTurns: pendingTurns,
        skippedCorruptDay: true,
      );
    }

    var written = 0;
    var skipped = 0;
    // TODO(ticket 13): memory_recall 动作在两级索引落地后接入后台检索；
    // 在那之前只消费 memory_signal，recall 经白名单校验后静默忽略。
    final signals = hiddenActions
        .where((action) => action.kind == HiddenActionKind.memorySignal)
        .toList();
    if (signals.isNotEmpty) {
      final additions = <EpisodeEntry>[];
      for (var index = 0; index < signals.length; index += 1) {
        final signal = signals[index];
        final entry = EpisodeEntry(
          id: '${session.id}:$requestId:$index',
          sessionId: session.id,
          requestId: requestId,
          summary: redactSessionText(signal.summary ?? '').trim(),
          evidence: signal.evidence == null
              ? null
              : redactSessionText(signal.evidence!).trim(),
          at: _clock().toUtc(),
        );
        if (entry.summary.isEmpty || day.hasEntryId(entry.id)) {
          skipped += 1;
          continue;
        }
        additions.add(entry);
      }
      if (additions.isNotEmpty) {
        await _writeDay(date, [...day.entries, ...additions]);
        written = additions.length;
      }
    }

    final shouldAdvance =
        written > 0 ||
        (consumeWindow && pendingTurns >= episodeWindowTurns);
    if (!shouldAdvance) {
      return EpisodeUpdateResult(
        writtenEntries: written,
        skippedDuplicates: skipped,
        checkpointAdvanced: false,
        pendingTurns: pendingTurns,
      );
    }
    final remainingTurns = written > 0 ? 0 : pendingTurns - episodeWindowTurns;
    await _writeCheckpoint(
      EpisodeCheckpoint(
        sessionId: session.id,
        lastRequestId: requestId,
        updatedAt: _clock().toUtc(),
      ),
    );
    return EpisodeUpdateResult(
      writtenEntries: written,
      skippedDuplicates: skipped,
      checkpointAdvanced: true,
      pendingTurns: remainingTurns < 0 ? 0 : remainingTurns,
    );
  }

  int _pendingUserTurns(EpisodeCheckpoint? checkpoint, RawSession session) {
    final userTurns = session.turns
        .where((turn) => turn.speaker == Speaker.user)
        .toList();
    if (checkpoint == null || checkpoint.sessionId != session.id) {
      return userTurns.length;
    }
    final markerIndex = userTurns.indexWhere(
      (turn) => turn.requestId == checkpoint.lastRequestId,
    );
    if (markerIndex < 0) {
      return userTurns.length;
    }
    return userTurns.length - markerIndex - 1;
  }

  Future<EpisodeDay> _readDay(String date) async {
    final file = _dayFile(date);
    if (!await file.exists()) {
      return EpisodeDay(date: date, entries: const []);
    }
    try {
      final contents = await file.readAsString(encoding: utf8);
      if (!RegExp(r'^<!-- qiyu-episode:', multiLine: true).hasMatch(contents)) {
        // 没有栖语元数据标记：可能是用户手改的普通 Markdown，绝不覆盖。
        return EpisodeDay(
          date: date,
          entries: const [],
          exists: true,
          readable: false,
        );
      }
      final entries = RegExp(
        r'^<!-- qiyu-episode-entry:([A-Za-z0-9_-]+) -->\r?$',
        multiLine: true,
      ).allMatches(contents).map((match) {
        return EpisodeEntry.fromJson(_decodeJson(match.group(1)!));
      }).toList();
      return EpisodeDay(date: date, entries: entries, exists: true);
    } on Object {
      // 文件存在但无法解析：返回损坏标记，调用方绝不覆盖它。
      return EpisodeDay(
        date: date,
        entries: const [],
        exists: true,
        readable: false,
      );
    }
  }

  Future<void> _writeDay(String date, List<EpisodeEntry> entries) async {
    final buffer = StringBuffer()
      ..writeln('# 栖语每日记录')
      ..writeln()
      ..writeln('<!-- qiyu-episode:${_encodeJson({
        'schemaVersion': 1,
        'date': date,
        'updatedAt': _clock().toUtc().toIso8601String(),
      })} -->')
      ..writeln();
    for (final entry in entries) {
      buffer
        ..writeln('<!-- qiyu-episode-entry:${_encodeJson(entry.toJson())} -->')
        ..writeln('## ${entry.at.toLocal().toIso8601String()} · ${entry.summary}')
        ..writeln();
      final evidence = entry.evidence;
      if (evidence != null && evidence.isNotEmpty) {
        buffer.writeln('> $evidence');
        buffer.writeln();
      }
    }
    try {
      await _atomicWriter.replace(_dayFile(date).path, buffer.toString());
    } on MemoryRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw MemoryRepositoryException(
        code: 'episode_write_failed',
        message: '无法保存今日记忆整理，对话不受影响。',
        retryable: true,
        cause: error,
      );
    }
  }

  File _dayFile(String date) => File(
    path.join(
      _episodesDirectory.path,
      date.substring(0, 4),
      date.substring(5, 7),
      '$date.md',
    ),
  );

  File _checkpointFile() =>
      File(path.join(_episodesDirectory.path, 'checkpoint.md'));

  Future<void> _writeCheckpoint(EpisodeCheckpoint checkpoint) async {
    final contents =
        '# 栖语整理检查点\n\n'
        '<!-- qiyu-checkpoint:${_encodeJson(checkpoint.toJson())} -->\n';
    try {
      await _atomicWriter.replace(_checkpointFile().path, contents);
    } on MemoryRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw MemoryRepositoryException(
        code: 'checkpoint_write_failed',
        message: '无法保存整理进度，对话不受影响。',
        retryable: true,
        cause: error,
      );
    }
  }

  Map<String, Object?> _decodeMetadata(String contents) {
    final match = RegExp(
      r'^<!-- qiyu-checkpoint:([A-Za-z0-9_-]+) -->\r?$',
      multiLine: true,
    ).firstMatch(contents);
    if (match == null) {
      throw const FormatException('Missing qiyu checkpoint metadata');
    }
    return _decodeJson(match.group(1)!);
  }
}

String _encodeJson(Map<String, Object?> value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

Map<String, Object?> _decodeJson(String value) {
  final padded = value.padRight(value.length + (4 - value.length % 4) % 4, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded)))
      as Map<String, Object?>;
}
