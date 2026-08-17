import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'markdown_memory_repository.dart';

/// 增量整理窗口：每四到六轮取最保守的一侧。窗口内没有显著信号时，
/// checkpoint 照常前进，保证对话不会被重复整理。
const episodeWindowTurns = 4;

/// episode 条目的来源类型。旧文件没有该字段，按 [episodeKindMemory] 解析。
const episodeKindMemory = 'memory';
const episodeKindOpenLoopCandidate = 'open_loop_candidate';
const episodeKindOpenLoopEvent = 'open_loop_event';
const episodeKindRelationshipSignal = 'relationship_signal';

final class EpisodeEntry {
  const EpisodeEntry({
    required this.id,
    required this.sessionId,
    required this.requestId,
    required this.summary,
    this.evidence,
    required this.at,
    this.kind = episodeKindMemory,
    this.personaBranch,
    this.personaNature,
    this.due,
    this.proactive,
    this.note,
    this.signal,
  });

  factory EpisodeEntry.fromJson(Map<String, Object?> json) => EpisodeEntry(
    id: json['id']! as String,
    sessionId: json['sessionId']! as String,
    requestId: json['requestId']! as String,
    summary: json['summary']! as String,
    evidence: json['evidence'] as String?,
    at: DateTime.parse(json['at']! as String).toUtc(),
    kind: json['kind'] as String? ?? episodeKindMemory,
    personaBranch: json['personaBranch'] as String?,
    personaNature: json['personaNature'] as String?,
    due: json['due'] as String?,
    proactive: json['proactive'] as String?,
    note: json['note'] as String?,
    signal: json['signal'] as String?,
  );

  final String id;
  final String sessionId;
  final String requestId;
  final String summary;
  final String? evidence;
  final DateTime at;

  /// 条目来源：普通记忆信号、Open-loop 日终候选、Open-loop 状态事件
  /// 或关系证据信号。
  final String kind;

  /// 画像提示（ticket 14）：本条信号所属的 PersonaTree 分支线名
  /// （identity/expression/values/preferences/boundaries）与来源性质
  /// （self_report/behavior）。白名单校验在隐藏动作层完成；两者同时
  /// 存在才建叶指针，缺任一个都只当普通记忆条目。
  final String? personaBranch;
  final String? personaNature;

  /// Open-loop 候选的四字段载荷，日终提升时原样带入 open-loops.md。
  final String? due;
  final String? proactive;
  final String? note;

  /// 关系证据的信号类型（deep_talk / temperature / boundary_open /
  /// boundary_close），日终据此更新 relationship.md 的阶段与温度。
  final String? signal;

  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'requestId': requestId,
    'summary': summary,
    if (evidence != null) 'evidence': evidence,
    'at': at.toUtc().toIso8601String(),
    if (kind != episodeKindMemory) 'kind': kind,
    if (personaBranch != null) 'personaBranch': personaBranch,
    if (personaNature != null) 'personaNature': personaNature,
    if (due != null) 'due': due,
    if (proactive != null) 'proactive': proactive,
    if (note != null) 'note': note,
    if (signal != null) 'signal': signal,
  };
}

final class EpisodeDay {
  const EpisodeDay({
    required this.date,
    required this.entries,
    this.exists = false,
    this.readable = true,
    this.summary,
    this.finalized = false,
    this.finalizedAt,
    this.understanding,
  });

  final String date;
  final List<EpisodeEntry> entries;

  /// 当日文件是否已存在；存在但不可解析时绝不能被新内容覆盖。
  final bool exists;
  final bool readable;

  /// 日终归档写入的当天摘要；未归档时为空。
  final String? summary;

  /// 日终归档是否已完成。只在当天全部必要写入成功后才为 true；
  /// 归档后若当天再次产生新条目，写入会把该标记重置为 false 等待补归档。
  final bool finalized;
  final DateTime? finalizedAt;

  /// 日终一次模型理解调用的白名单校验结果（Memory.md 日终归档定稿
  /// 2026-08-16）。持久化在日文件元数据里供重跑复用与索引取词；
  /// 未经过模型理解的日期为 null。
  final Map<String, Object?>? understanding;

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
    this.addedEntries = const [],
  });

  final int writtenEntries;
  final int skippedDuplicates;
  final bool checkpointAdvanced;

  /// 当日 episode 文件存在但无法解析：本轮不写入、不前进，等待恢复。
  final bool skippedCorruptDay;

  /// 前进后仍留在窗口内、等待下一次整理判断的用户轮数。
  final int pendingTurns;

  /// 本轮实际写入的条目，供后续整理（如 PersonaTree 建叶）复用，
  /// 避免重复推导。
  final List<EpisodeEntry> addedEntries;
}

/// 伪 Agent 隐藏动作的记忆写入端。只接受白名单校验后的
/// [HiddenAction]，把 memory_signal 增量写入当天 episode，并维护
/// 可续跑的 checkpoint。模型从不直接写文件；这里的每一次写入都是
/// 原子替换，且 checkpoint 只在 episode 写入成功后才前进。
///
/// 日终归档（ticket 10）与对话中的增量整理共用同一批 episode 文件；
/// [synchronizedOnDayFiles] 是两者之间的唯一写锁，保证晚安归档与
/// 紧随其后的新对话不会互相覆盖。
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
  Future<void> _dayFileTail = Future.value();

  Directory get _episodesDirectory =>
      Directory(path.join(memoryDirectory, 'episodes'));

  Future<EpisodeDay> readToday() => _readDay(localSessionDate(_clock()));

  /// 读取指定日期的 episode 日文件；文件不存在时返回空 [EpisodeDay]。
  Future<EpisodeDay> readDay(String date) => _readDay(date);

  /// 串行化所有 episode 日文件与 checkpoint 的写操作。日终归档流程
  /// 整体在此锁内执行；对话增量整理（[processReply]）同样在锁内。
  /// 锁内是本机小文件原子写：单日归档毫秒级；启用日终模型理解调用
  /// 时该调用也在锁内（归档日文件读写之间），耗时计入后台任务链，
  /// 绝不阻塞可见回应（所有归档触发都在回复交付之后或后台任务链上，
  /// 对话增量整理只排在后台等待）。启动补扫按日逐个串行执行并复用
  /// 日期列表，长积压分摊到多次归档。
  Future<T> synchronizedOnDayFiles<T>(Future<T> Function() body) {
    final result = _dayFileTail.then((_) => body());
    _dayFileTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 扫描 episodes 目录，返回全部日文件日期（升序）。
  /// 只认文件名形如 `YYYY-MM-DD.md` 的日文件；内容是否有效由读取方判断。
  Future<List<String>> listEpisodeDates() async {
    final root = _episodesDirectory;
    if (!await root.exists()) {
      return const [];
    }
    final dates = <String>{};
    final dayFileName = RegExp(r'^\d{4}-\d{2}-\d{2}\.md$');
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = path.basename(entity.path);
      if (dayFileName.hasMatch(name)) {
        dates.add(name.substring(0, 10));
      }
    }
    return dates.toList()..sort();
  }

  /// 日终归档写入：带摘要与 finalized 标记重写当日文件。
  /// [understanding] 是日终模型理解调用的白名单校验结果，随元数据
  /// 持久化供重跑复用与索引取词；null 表示当天没有模型理解。
  /// 调用方必须已持有 [synchronizedOnDayFiles] 锁（日终流程整体持锁）。
  Future<void> writeFinalization(
    String date, {
    required List<EpisodeEntry> entries,
    String? summary,
    required bool finalized,
    DateTime? finalizedAt,
    Map<String, Object?>? understanding,
  }) => _writeDayFile(
    date,
    entries,
    summary: summary,
    finalized: finalized,
    finalizedAt: finalizedAt,
    understanding: understanding,
  );

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
  }) => synchronizedOnDayFiles(
    () => _processReplyLocked(
      session: session,
      requestId: requestId,
      hiddenActions: hiddenActions,
      consumeWindow: consumeWindow,
    ),
  );

  Future<EpisodeUpdateResult> _processReplyLocked({
    required RawSession session,
    required String requestId,
    required List<HiddenAction> hiddenActions,
    required bool consumeWindow,
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
    final additions = <EpisodeEntry>[];
    // memory_recall 不产生 episode 条目：它由 LocalChatService 转交
    // RecallOrchestrator 走轮内查找循环，这里只消费记忆与
    // Open-loop 生活动作。
    final consumable = hiddenActions
        .where(
          (action) =>
              action.kind == HiddenActionKind.memorySignal ||
              action.kind == HiddenActionKind.openLoopCandidate ||
              action.kind == HiddenActionKind.openLoopStatus ||
              action.kind == HiddenActionKind.memoryBan ||
              action.kind == HiddenActionKind.relationshipSignal,
        )
        .toList();
    if (consumable.isNotEmpty) {
      for (var index = 0; index < consumable.length; index += 1) {
        final entry = _entryForAction(
          consumable[index],
          session: session,
          requestId: requestId,
          index: index,
        );
        if (entry == null || entry.summary.isEmpty || day.hasEntryId(entry.id)) {
          skipped += 1;
          continue;
        }
        additions.add(entry);
      }
      if (additions.isNotEmpty) {
        // 新条目使当天重新处于未归档状态：摘要与 finalized 标记失效，
        // 等待下一次晚安/跨日/启动补扫重新日终归档。
        await _writeDayFile(date, [...day.entries, ...additions]);
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
      addedEntries: additions,
    );
  }

  /// 把已通过白名单校验的隐藏动作落成当天 episode 条目。
  /// 候选保留四字段载荷供日终提升；状态变化与禁提作为事件条目留痕。
  EpisodeEntry? _entryForAction(
    HiddenAction action, {
    required RawSession session,
    required String requestId,
    required int index,
  }) {
    String? redacted(String? value) =>
        value == null ? null : redactSessionText(value).trim();
    final id = '${session.id}:$requestId:$index';
    switch (action.kind) {
      case HiddenActionKind.memorySignal:
        return EpisodeEntry(
          id: id,
          sessionId: session.id,
          requestId: requestId,
          summary: redactSessionText(action.summary ?? '').trim(),
          evidence: redacted(action.evidence),
          at: _clock().toUtc(),
          personaBranch: action.branch,
          personaNature: action.nature,
        );
      case HiddenActionKind.openLoopCandidate:
        return EpisodeEntry(
          id: id,
          sessionId: session.id,
          requestId: requestId,
          summary: redactSessionText(action.summary ?? '').trim(),
          evidence: redacted(action.evidence),
          at: _clock().toUtc(),
          kind: episodeKindOpenLoopCandidate,
          due: action.due,
          proactive: action.proactive,
          note: redacted(action.note),
        );
      case HiddenActionKind.openLoopStatus:
        return EpisodeEntry(
          id: id,
          sessionId: session.id,
          requestId: requestId,
          summary: 'Open-loop 状态: '
              '${redactSessionText(action.summary ?? '').trim()} → '
              '${action.status}',
          evidence: redacted(action.result),
          at: _clock().toUtc(),
          kind: episodeKindOpenLoopEvent,
        );
      case HiddenActionKind.memoryBan:
        return EpisodeEntry(
          id: id,
          sessionId: session.id,
          requestId: requestId,
          summary: '禁提: ${redactSessionText(action.summary ?? '').trim()}',
          at: _clock().toUtc(),
          kind: episodeKindOpenLoopEvent,
        );
      case HiddenActionKind.relationshipSignal:
        // 摘要本身就是自然、抽象的状态描述（白名单已校验），
        // 原话细节只留在 evidence 供追溯，不进任何注入投影。
        return EpisodeEntry(
          id: id,
          sessionId: session.id,
          requestId: requestId,
          summary: redactSessionText(action.summary ?? '').trim(),
          evidence: redacted(action.evidence),
          at: _clock().toUtc(),
          kind: episodeKindRelationshipSignal,
          signal: action.signal,
        );
      case HiddenActionKind.memoryRecall:
      case HiddenActionKind.noAction:
        return null;
    }
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
      final metadata = _decodeDayMetadata(contents);
      final finalizedAt = metadata['finalizedAt'] as String?;
      final understanding = metadata['understanding'];
      return EpisodeDay(
        date: date,
        entries: entries,
        exists: true,
        summary: metadata['summary'] as String?,
        finalized: metadata['finalized'] as bool? ?? false,
        finalizedAt: finalizedAt == null
            ? null
            : DateTime.parse(finalizedAt).toUtc(),
        understanding: understanding is Map<String, Object?>
            ? understanding
            : null,
      );
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

  Future<void> _writeDayFile(
    String date,
    List<EpisodeEntry> entries, {
    String? summary,
    bool finalized = false,
    DateTime? finalizedAt,
    Map<String, Object?>? understanding,
  }) async {
    final trimmedSummary = summary?.trim();
    final buffer = StringBuffer()
      ..writeln('# 栖语每日记录')
      ..writeln()
      ..writeln('<!-- qiyu-episode:${_encodeJson({
        'schemaVersion': 1,
        'date': date,
        'updatedAt': _clock().toUtc().toIso8601String(),
        if (trimmedSummary != null && trimmedSummary.isNotEmpty)
          'summary': trimmedSummary,
        'finalized': finalized,
        if (finalizedAt != null)
          'finalizedAt': finalizedAt.toUtc().toIso8601String(),
        'understanding': ?understanding,
      })} -->')
      ..writeln();
    if (trimmedSummary != null && trimmedSummary.isNotEmpty) {
      buffer
        ..writeln('## summary')
        ..writeln(trimmedSummary)
        ..writeln();
    }
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

  Map<String, Object?> _decodeDayMetadata(String contents) {
    final match = RegExp(
      r'^<!-- qiyu-episode:([A-Za-z0-9_-]+) -->\r?$',
      multiLine: true,
    ).firstMatch(contents);
    if (match == null) {
      throw const FormatException('Missing qiyu episode metadata');
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
