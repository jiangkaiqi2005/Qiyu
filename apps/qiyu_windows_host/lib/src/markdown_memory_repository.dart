import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

const maxRawSessionTurns = 80;
const activeSessionHistoryWindow = Duration(days: 180);

typedef Clock = DateTime Function();

abstract interface class AtomicTextWriter {
  Future<void> replace(String path, String contents);
}

final class IoAtomicTextWriter implements AtomicTextWriter {
  const IoAtomicTextWriter();

  @override
  Future<void> replace(String targetPath, String contents) async {
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final temporary = File(
      '$targetPath.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(contents, encoding: utf8, flush: true);
      await temporary.rename(targetPath);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}

final class MemoryRepositoryException implements Exception {
  const MemoryRepositoryException({
    required this.code,
    required this.message,
    required this.retryable,
    this.cause,
  });

  final String code;
  final String message;
  final bool retryable;
  final Object? cause;

  @override
  String toString() => message;
}

final class RawSessionTurn {
  RawSessionTurn._({
    required this.requestId,
    required this.speaker,
    required this.text,
    required this.messages,
    required this.at,
    required this.source,
    required this.fallbackReason,
    required this.mode,
    required this.safety,
  });

  factory RawSessionTurn.user({
    required String requestId,
    required String text,
    required DateTime at,
  }) => RawSessionTurn._(
    requestId: requestId,
    speaker: Speaker.user,
    text: text,
    messages: const [],
    at: at.toUtc(),
    source: null,
    fallbackReason: null,
    mode: null,
    safety: null,
  );

  factory RawSessionTurn.qiyu({
    required String requestId,
    required List<String> messages,
    required DateTime at,
    required ReplySource source,
    required String mode,
    FallbackReason? fallbackReason,
    SafetyKind? safety,
  }) => RawSessionTurn._(
    requestId: requestId,
    speaker: Speaker.qiyu,
    text: messages.join('\n'),
    messages: List.unmodifiable(messages),
    at: at.toUtc(),
    source: source,
    fallbackReason: fallbackReason,
    mode: mode,
    safety: safety,
  );

  factory RawSessionTurn.fromJson(Map<String, Object?> json) {
    final speaker = Speaker.values.byName(json['speaker']! as String);
    final sourceName = json['source'] as String?;
    final fallbackName = json['fallbackReason'] as String?;
    final safetyName = json['safety'] as String?;
    final rawMessages = json['messages'] as List<Object?>?;
    return RawSessionTurn._(
      requestId: json['requestId']! as String,
      speaker: speaker,
      text: json['text']! as String,
      messages: List.unmodifiable(rawMessages?.cast<String>() ?? const []),
      at: DateTime.parse(json['at']! as String).toUtc(),
      source: sourceName == null ? null : ReplySource.values.byName(sourceName),
      fallbackReason: fallbackName == null
          ? null
          : FallbackReason.fromWireName(fallbackName),
      mode: json['mode'] as String?,
      safety: safetyName == null ? null : SafetyKind.values.byName(safetyName),
    );
  }

  final String requestId;
  final Speaker speaker;
  final String text;
  final List<String> messages;
  final DateTime at;
  final ReplySource? source;
  final FallbackReason? fallbackReason;
  final String? mode;
  final SafetyKind? safety;

  RawSessionTurn redacted() {
    final safeMessages = messages.map(redactSessionText).toList();
    return RawSessionTurn._(
      requestId: requestId,
      speaker: speaker,
      text: speaker == Speaker.qiyu
          ? safeMessages.join('\n')
          : redactSessionText(text),
      messages: List.unmodifiable(safeMessages),
      at: at,
      source: source,
      fallbackReason: fallbackReason,
      mode: mode,
      safety: safety,
    );
  }

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'speaker': speaker.name,
    'text': text,
    if (messages.isNotEmpty) 'messages': messages,
    'at': at.toUtc().toIso8601String(),
    if (source != null) 'source': source!.name,
    if (fallbackReason != null) 'fallbackReason': fallbackReason!.wireName,
    if (mode != null) 'mode': mode,
    if (safety != null) 'safety': safety!.name,
  };
}

final class RawSession {
  RawSession({
    required this.id,
    required this.date,
    required this.segment,
    required this.createdAt,
    required this.updatedAt,
    required List<RawSessionTurn> turns,
  }) : turns = List.unmodifiable(turns);

  factory RawSession.fromJson(
    Map<String, Object?> json,
    List<RawSessionTurn> turns,
  ) => RawSession(
    id: json['id']! as String,
    date: json['date']! as String,
    segment: json['segment']! as int,
    createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
    updatedAt: DateTime.parse(json['updatedAt']! as String).toUtc(),
    turns: turns,
  );

  final String id;
  final String date;
  final int segment;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<RawSessionTurn> turns;

  RawSession append(RawSessionTurn turn) => RawSession(
    id: id,
    date: date,
    segment: segment,
    createdAt: createdAt,
    updatedAt: turn.at,
    turns: [...turns, turn],
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'date': date,
    'segment': segment,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

final class UnavailableSessionFile {
  const UnavailableSessionFile({
    required this.name,
    required this.message,
    this.date,
    this.segment,
  });

  final String name;
  final String message;
  final String? date;
  final int? segment;
}

final class HistoryListing {
  const HistoryListing({required this.sessions, required this.unavailable});

  final List<RawSession> sessions;
  final List<UnavailableSessionFile> unavailable;
}

abstract interface class MemoryRepository {
  Future<void> initialize();

  Future<RawSession> openSession({String? sessionId});

  Future<RawSession> createSession();

  Future<RawSession> appendTurn(RawSession session, RawSessionTurn turn);

  Future<HistoryListing> readHistory();

  Future<void> deleteSession(String sessionId);
}

final class MarkdownMemoryRepository implements MemoryRepository {
  MarkdownMemoryRepository({
    required this.memoryDirectory,
    Clock? clock,
    AtomicTextWriter? atomicWriter,
  }) : _clock = clock ?? DateTime.now,
       _atomicWriter = atomicWriter ?? const IoAtomicTextWriter();

  final String memoryDirectory;
  final Clock _clock;
  final AtomicTextWriter _atomicWriter;

  Directory get _sessionsDirectory =>
      Directory(path.join(memoryDirectory, 'sessions'));

  @override
  Future<void> initialize() async {
    try {
      await _sessionsDirectory.create(recursive: true);
    } on FileSystemException catch (error) {
      throw MemoryRepositoryException(
        code: 'storage_init_failed',
        message: '无法初始化本地聊天存储，请检查目录权限。',
        retryable: true,
        cause: error,
      );
    }
  }

  @override
  Future<RawSession> openSession({String? sessionId}) async {
    await initialize();
    final records = await _readSessionRecords();
    final sessions = _validSessions(records);
    final currentTime = _clock();
    final now = currentTime.toUtc();
    final today = localSessionDate(currentTime);
    RawSession? requested;
    if (sessionId != null) {
      requested = sessions
          .where((session) => session.id == sessionId)
          .firstOrNull;
      if (requested == null) {
        throw const MemoryRepositoryException(
          code: 'session_not_found',
          message: '找不到这段本地会话，请刷新后重试。',
          retryable: false,
        );
      }
    }
    if (requested != null) {
      return requested;
    }
    final latest = _latestSession(sessions);
    if (latest != null &&
        now.difference(latest.updatedAt) <= activeSessionHistoryWindow) {
      return latest;
    }

    return _createSession(records, now, today);
  }

  @override
  Future<RawSession> createSession() async {
    await initialize();
    final records = await _readSessionRecords();
    final currentTime = _clock();
    final now = currentTime.toUtc();
    return _createSession(records, now, localSessionDate(currentTime));
  }

  @override
  Future<HistoryListing> readHistory() async {
    await initialize();
    final records = await _readSessionRecords();
    final sessions = _validSessions(records)
      ..sort((left, right) {
        final byDate = right.date.compareTo(left.date);
        if (byDate != 0) {
          return byDate;
        }
        return left.segment.compareTo(right.segment);
      });
    final unavailable = records
        .map((record) => record.unavailable)
        .whereType<UnavailableSessionFile>()
        .toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    return HistoryListing(sessions: sessions, unavailable: unavailable);
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    await initialize();
    final records = await _readSessionRecords();
    for (final record in records) {
      final session = record.session;
      if (session == null || session.id != sessionId) {
        continue;
      }
      try {
        await record.file.delete();
      } on FileSystemException catch (error) {
        throw MemoryRepositoryException(
          code: 'session_delete_failed',
          message: '无法删除这段本地会话，请检查目录权限后重试。',
          retryable: true,
          cause: error,
        );
      }
      return;
    }
    throw const MemoryRepositoryException(
      code: 'session_not_found',
      message: '没有找到这段本地会话，可能已经被删除。',
      retryable: false,
    );
  }

  Future<RawSession> _createSession(
    List<_SessionRecord> records,
    DateTime now,
    String today,
  ) async {
    var maxSegment = 0;
    for (final record in records) {
      final session = record.session;
      if (session != null) {
        if (session.date == today && session.segment > maxSegment) {
          maxSegment = session.segment;
        }
        continue;
      }
      final unavailable = record.unavailable;
      final segment = unavailable?.segment;
      if (unavailable != null &&
          unavailable.date == today &&
          segment != null &&
          segment > maxSegment) {
        maxSegment = segment;
      }
    }
    final created = RawSession(
      id: _newOpaqueId(),
      date: today,
      segment: maxSegment + 1,
      createdAt: now,
      updatedAt: now,
      turns: const [],
    );
    await _writeSession(created);
    return created;
  }

  @override
  Future<RawSession> appendTurn(RawSession session, RawSessionTurn turn) async {
    if (session.turns.length >= maxRawSessionTurns) {
      throw const MemoryRepositoryException(
        code: 'session_full',
        message: '当前会话段已满，请开启新段后重试。',
        retryable: true,
      );
    }
    final updated = session.append(turn.redacted());
    await _writeSession(updated);
    return updated;
  }

  Future<void> _writeSession(RawSession session) async {
    final targetPath = _sessionPath(session);
    try {
      await _atomicWriter.replace(targetPath, _toMarkdown(session));
    } on MemoryRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw MemoryRepositoryException(
        code: 'session_write_failed',
        message: '无法保存本地聊天记录，请检查磁盘空间和目录权限。',
        retryable: true,
        cause: error,
      );
    }
  }

  Future<List<_SessionRecord>> _readSessionRecords() async {
    final files = await _sessionsDirectory
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File && entity.path.endsWith('.md'))
        .cast<File>()
        .toList();
    final records = <_SessionRecord>[];
    for (final file in files) {
      try {
        final session = _parseMarkdown(await file.readAsString(encoding: utf8));
        records.add(_SessionRecord(file: file, session: session));
      } on Object {
        records.add(_SessionRecord(file: file, unavailable: _unavailableFor(file)));
      }
    }
    return records;
  }

  UnavailableSessionFile _unavailableFor(File file) {
    final name = path.basename(file.path);
    final match = RegExp(
      r'^(\d{4}-\d{2}-\d{2})-(\d{3})\.md$',
    ).firstMatch(name);
    return UnavailableSessionFile(
      name: name,
      message: '这个会话文件暂时无法读取，不影响其他历史记录。',
      date: match?.group(1),
      segment: match == null ? null : int.parse(match.group(2)!),
    );
  }

  String _sessionPath(RawSession session) => path.join(
    memoryDirectory,
    'sessions',
    session.date.substring(0, 4),
    session.date.substring(5, 7),
    '${session.date}-${session.segment.toString().padLeft(3, '0')}.md',
  );
}

final class _SessionRecord {
  const _SessionRecord({required this.file, this.session, this.unavailable});

  final File file;
  final RawSession? session;
  final UnavailableSessionFile? unavailable;
}

List<RawSession> _validSessions(List<_SessionRecord> records) => records
    .map((record) => record.session)
    .whereType<RawSession>()
    .toList();

RawSession? _latestSession(List<RawSession> sessions) {
  if (sessions.isEmpty) {
    return null;
  }
  return sessions.reduce(
    (left, right) => left.updatedAt.isAfter(right.updatedAt) ? left : right,
  );
}

String _toMarkdown(RawSession session) {
  final buffer = StringBuffer()
    ..writeln('# 栖语原始会话')
    ..writeln()
    ..writeln('<!-- qiyu-session:${_encodeJson(session.toJson())} -->')
    ..writeln();
  for (final turn in session.turns) {
    final speaker = turn.speaker == Speaker.user ? '用户' : '栖语';
    buffer
      ..writeln('<!-- qiyu-turn:${_encodeJson(turn.toJson())} -->')
      ..writeln('## $speaker · ${turn.at.toLocal().toIso8601String()}')
      ..writeln();
    for (final line in turn.text.replaceAll('\r\n', '\n').split('\n')) {
      buffer.writeln('> $line');
    }
    buffer.writeln();
  }
  return buffer.toString();
}

RawSession _parseMarkdown(String markdown) {
  final metadataMatch = RegExp(
    r'^<!-- qiyu-session:([A-Za-z0-9_-]+) -->\r?$',
    multiLine: true,
  ).firstMatch(markdown);
  if (metadataMatch == null) {
    throw const FormatException('Missing qiyu session metadata');
  }
  final metadata = _decodeJson(metadataMatch.group(1)!);
  final turnMatches = RegExp(
    r'^<!-- qiyu-turn:([A-Za-z0-9_-]+) -->\r?$',
    multiLine: true,
  ).allMatches(markdown);
  final turns = turnMatches
      .map((match) => RawSessionTurn.fromJson(_decodeJson(match.group(1)!)))
      .toList();
  return RawSession.fromJson(metadata, turns);
}

String _encodeJson(Map<String, Object?> value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

Map<String, Object?> _decodeJson(String value) {
  final padded = value.padRight(value.length + (4 - value.length % 4) % 4, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded)))
      as Map<String, Object?>;
}

String localSessionDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String _newOpaqueId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

String redactSessionText(String text) {
  var result = text;
  final patterns = <RegExp>[
    RegExp(r'sk-[A-Za-z0-9_-]{16,}', caseSensitive: false),
    RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
    RegExp(
      r'((?:api[_ -]?key|token|cookie|password|密码|口令)\s*[:=：]\s*)[^\s；;，,]+',
      caseSensitive: false,
    ),
    RegExp(
      r'((?:验证码|otp|verification code)\s*[:=：]?\s*)\d{4,8}',
      caseSensitive: false,
    ),
    RegExp(r'((?:身份证(?:号)?|证件号)\s*[:=：]?\s*)\d{17}[\dXx]'),
    RegExp(r'((?:银行卡(?:号)?|卡号)\s*[:=：]?\s*)(?:\d[ -]?){15,18}\d'),
    RegExp(r'(?<!\d)\d{17}[\dXx](?!\d)'),
    RegExp(r'(?<!\d)(?:\d[ -]?){15,18}\d(?!\d)'),
    RegExp(
      r'-----BEGIN [^-]+ PRIVATE KEY-----[\s\S]*?-----END [^-]+ PRIVATE KEY-----',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    result = result.replaceAllMapped(pattern, (match) {
      final prefix = match.groupCount > 0 ? match.group(1) : null;
      return '${prefix ?? ''}[已脱敏]';
    });
  }
  return result;
}

String redactDiagnosticText(String text) {
  var result = redactSessionText(text);
  final patterns = <RegExp>[
    RegExp(
      r'((?:authorization|proxy-authorization)\s*[:=]\s*)[^\r\n,;]+',
      caseSensitive: false,
    ),
    RegExp(r'(cookie\s*[:=]\s*)[^\r\n]+', caseSensitive: false),
    RegExp(
      r'((?:用户输入|完整输入|user input|prompt)\s*[:=：]\s*)[^\r\n]+',
      caseSensitive: false,
    ),
    RegExp(r'[A-Za-z]:\\(?:[^\\\r\n\s]+\\)*[^\\\r\n\s]+'),
    RegExp(r'/(?:Users|home)/[^\r\n\s]+', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    result = result.replaceAllMapped(pattern, (match) {
      final prefix = match.groupCount > 0 ? match.group(1) : null;
      return '${prefix ?? ''}[已脱敏]';
    });
  }
  return result;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
