import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'memory_marker_codec.dart';

const maxRawSessionTurns = 80;
const activeSessionHistoryWindow = Duration(days: 180);

/// 记忆目录内固定文件名的单一出处：读取端 getter 与各写入端共用，
/// 防止文件名字符串在多文件间漂移。
const longMemoryFileName = 'long-memory.md';
const relationshipFileName = 'relationship.md';
const dailyStateFileName = 'daily-state.md';
const personaFileName = 'persona.md';

/// 记忆目录内文件句柄的统一拼装（`File(path.join(directory, name))`）。
File memoryFile(String directory, String name) =>
    File(path.join(directory, name));

/// 跨 0 点回放窗口：睡前对话跨过午夜后短时间内（继续聊或刷新）仍
/// 回放昨晚的段，窗口外按新的一天开新段。只影响回放，不影响写入分段
/// 与按自然日的日终归档。
const activeSessionResumeWindow = Duration(hours: 6);

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
      // Windows 上目标文件仍被并发读取句柄占用时 rename 抛共享冲突；
      // 冲突是瞬态的，短重试越过即可，不必为此把所有读取改成阻塞式
      // 同步 IO。重试窗口要盖过杀毒/索引服务对文件的实时扫描（实测
      // 外部进程可持锁数百毫秒），1 秒级窗口换保存的稳定。
      for (var attempt = 0; ; attempt += 1) {
        try {
          await temporary.rename(targetPath);
          break;
        } on FileSystemException catch (error) {
          if (attempt >= 20 || !_isTransientWindowsConflict(error)) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  /// ERROR_SHARING_VIOLATION (32) / ERROR_LOCK_VIOLATION (33)：
  /// 目标暂被其他句柄占用，稍后重试有意义；其余错误立即抛出。
  bool _isTransientWindowsConflict(FileSystemException error) {
    final code = error.osError?.errorCode;
    // 32/33（共享/锁冲突）：目标被并发句柄占用。5（拒绝访问）：rename
    // 要求目标的 DELETE 访问权，与其他进程已打开的读句柄（杀毒/索引
    // 实时扫描）冲突时 Windows 同样报 5——两者都是瞬态，重试有意义；
    // 权限真正缺失时重试 20 次后仍会如实失败。
    return code == 32 || code == 33 || code == 5;
  }
}

/// Host 内部诊断默认出口：只写本机 stderr，内容先过允许列表脱敏。
/// 诊断绝不展示给用户，也不透出正文、密钥或本机路径。
void stderrDiagnostics(String message) {
  stderr.writeln('[qiyu] ${redactDiagnosticText(message)}');
}

/// 安全读取文本文件：不存在或读取失败（权限、占用、损坏等）一律
/// 返回 null，由调用方按「缺失与不可读同义」处理。记忆域各存储类
/// 共用同一份容错口径，不再各写一套。
Future<String?> readFileIfExists(File file) async {
  if (!await file.exists()) {
    return null;
  }
  try {
    return await file.readAsString(encoding: utf8);
  } on Object {
    return null;
  }
}

/// 记忆域写入的统一异常壳：原子替换失败时 [MemoryRepositoryException]
/// 原样上抛（已是写入语义），其余异常一律包成调用方指定的 code 与
/// message（retryable 固定 true）。会话、episode 日文件与检查点三处
/// 写入端共用，异常口径不再各写一套。
Future<void> atomicReplace(
  AtomicTextWriter writer,
  String path,
  String contents, {
  required String code,
  required String message,
}) async {
  try {
    await writer.replace(path, contents);
  } on MemoryRepositoryException {
    rethrow;
  } on Object catch (error) {
    throw MemoryRepositoryException(
      code: code,
      message: message,
      retryable: true,
      cause: error,
    );
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
    // 自动恢复按凌晨 4 点逻辑日分界；只有跨逻辑日时才检查六小时窗口。
    // 会话自身日期仍按自然日保存。文件时间超前于当前时钟（时钟回拨）
    // 不算窗口内，保守开新段。
    final latest = _latestSession(sessions);
    if (latest != null) {
      final age = now.difference(latest.updatedAt);
      if (age >= Duration.zero &&
          (_logicalSessionDate(latest.updatedAt) ==
                  _logicalSessionDate(currentTime) ||
              age <= activeSessionResumeWindow)) {
        return latest;
      }
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
    final unavailable =
        records
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
      id: newOpaqueId(),
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

  Future<void> _writeSession(RawSession session) => atomicReplace(
    _atomicWriter,
    _sessionPath(session),
    renderSessionMarkdown(session),
    code: 'session_write_failed',
    message: '无法保存本地聊天记录，请检查磁盘空间和目录权限。',
  );

  Future<List<_SessionRecord>> _readSessionRecords() async {
    final files = await _sessionsDirectory
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File && entity.path.endsWith('.md'))
        .cast<File>()
        .toList();
    final records = <_SessionRecord>[];
    for (final file in files) {
      try {
        // 保持异步读取：同步读会在日终补扫循环里反复阻塞事件循环，
        // 卡住正在流式交付的聊天。与原子替换的瞬时句柄冲突由
        // IoAtomicTextWriter 的短重试处理。
        final session = _parseMarkdown(
          await file.readAsString(encoding: utf8),
        );
        records.add(_SessionRecord(file: file, session: session));
      } on Object {
        records.add(
          _SessionRecord(file: file, unavailable: _unavailableFor(file)),
        );
      }
    }
    return records;
  }

  UnavailableSessionFile _unavailableFor(File file) {
    final name = path.basename(file.path);
    final match = _sessionFileNamePattern.firstMatch(name);
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

/// 会话文件名形态（日期-段号.md）：不可读文件据此提取日期与段号。
final _sessionFileNamePattern = RegExp(r'^(\d{4}-\d{2}-\d{2})-(\d{3})\.md$');

// 会话文件的元数据与轮次标记（读取端）统一取自 memory_marker_codec.dart
//（唯一权威，禁止另写变体副本）。

final class _SessionRecord {
  const _SessionRecord({required this.file, this.session, this.unavailable});

  final File file;
  final RawSession? session;
  final UnavailableSessionFile? unavailable;
}

List<RawSession> _validSessions(List<_SessionRecord> records) =>
    records.map((record) => record.session).whereType<RawSession>().toList();

RawSession? _latestSession(List<RawSession> sessions) {
  if (sessions.isEmpty) {
    return null;
  }
  return sessions.reduce(
    (left, right) => left.updatedAt.isAfter(right.updatedAt) ? left : right,
  );
}

/// 会话文件的规范 Markdown 渲染（写入与 ticket 21 抢救重写共用）。
String renderSessionMarkdown(RawSession session) {
  final buffer = StringBuffer()
    ..writeln('# 栖语原始会话')
    ..writeln()
    ..writeln('<!-- qiyu-session:${encodeMarkerPayload(session.toJson())} -->')
    ..writeln();
  for (final turn in session.turns) {
    final speaker = turn.speaker == Speaker.user ? '用户' : '栖语';
    buffer
      ..writeln('<!-- qiyu-turn:${encodeMarkerPayload(turn.toJson())} -->')
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
  final metadataMatch = sessionMetaMarkerPattern.firstMatch(markdown);
  if (metadataMatch == null) {
    throw const FormatException('Missing qiyu session metadata');
  }
  final metadata = decodeMarkerPayload(metadataMatch.group(1)!);
  final turnMatches = sessionTurnMarkerPattern.allMatches(markdown);
  final turns = turnMatches
      .map((match) => RawSessionTurn.fromJson(decodeMarkerPayload(match.group(1)!)))
      .toList();
  return RawSession.fromJson(metadata, turns);
}

String localSessionDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// 解析 `YYYY-MM-DD` 日历日期为本地零时 [DateTime]；格式不符时抛
/// FormatException。与 [localSessionDate] 同一份日期串格式：会话、
/// episode 与日终归档的日期解析共用这一份实现。
DateTime parseLocalSessionDate(String date) => DateTime(
  int.parse(date.substring(0, 4)),
  int.parse(date.substring(5, 7)),
  int.parse(date.substring(8, 10)),
);

String _logicalSessionDate(DateTime value) =>
    localSessionDate(value.subtract(const Duration(hours: 4)));

/// 会话、episode 等记忆域记录的不透明 ID：Random.secure 生成 18 字节
/// 后 base64Url 去填充。单一出处，记忆中心注册表共用。
String newOpaqueId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 会话文本脱敏规则（每条消息、每段诊断都会过一遍，正则只编译一次）。
/// JSON 形态的敏感键值：字段名带引号、值是双引号字符串，值替换到结束
/// 引号之前，占位后 JSON 结构保持可读。整行 Cookie：多项分号串接只遮
/// 第一项等于没遮，值段吃到行尾。PEM 私钥的类型词可缺省，覆盖
/// PKCS#8（BEGIN PRIVATE KEY）与 RSA/EC/OpenSSH/DSA/加密形态；类型段
/// 禁止连字符，防止跨标记误吃。
final _sessionRedactPatterns = <RegExp>[
  RegExp(r'as_sk_[A-Za-z0-9_-]{8,}', caseSensitive: false),
  RegExp(
    r'(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}(?![A-Za-z0-9_])',
    caseSensitive: false,
  ),
  RegExp(
    r'(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{20,}(?![A-Za-z0-9_])',
    caseSensitive: false,
  ),
  RegExp(
    r'(?<![A-Za-z0-9_-])glpat-[A-Za-z0-9_-]{10,}(?![A-Za-z0-9_-])',
    caseSensitive: false,
  ),
  RegExp(
    r'(?<![A-Za-z0-9-])xox[a-z]-[A-Za-z0-9-]{10,}(?![A-Za-z0-9-])',
    caseSensitive: false,
  ),
  RegExp(r'(?<![A-Z0-9])AKIA[A-Z0-9]{16}(?![A-Z0-9])'),
  RegExp(r'(?<![A-Za-z0-9_-])AIza[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])'),
  RegExp(
    r'(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.'
    r'[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])',
  ),
  RegExp(r'sk-[A-Za-z0-9_-]{16,}', caseSensitive: false),
  RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
  RegExp(
    r'("(?:api[_ -]?key|api[_ -]?secret|secret[_ -]?key|access[_ -]?token|'
    r'refresh[_ -]?token|password|passwd|pwd|secret|token|cookie|'
    r'密码|口令|密钥|令牌)"\s*:\s*")[^"]*',
    caseSensitive: false,
  ),
  RegExp(
    r'((?:set[- ])?cookie\s*[:=：]\s*)[^\r\n]+',
    caseSensitive: false,
  ),
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
    r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?'
    r'-----END [A-Z0-9 ]*PRIVATE KEY-----',
    caseSensitive: false,
  ),
];

/// 诊断文本在会话脱敏之外的追加规则：授权头、Cookie、完整输入与本机路径。
final _diagnosticRedactPatterns = <RegExp>[
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

/// 依次套用脱敏规则：命中捕获组时保留组 1 前缀，其余替换为
/// 「[已脱敏]」。会话与诊断两套规则共用同一替换体。
String _applyRedactions(String text, List<RegExp> patterns) {
  var result = text;
  for (final pattern in patterns) {
    result = result.replaceAllMapped(pattern, (match) {
      final prefix = match.groupCount > 0 ? match.group(1) : null;
      return '${prefix ?? ''}[已脱敏]';
    });
  }
  return result;
}

String redactSessionText(String text) =>
    _applyRedactions(text, _sessionRedactPatterns);

String redactDiagnosticText(String text) => _applyRedactions(
  _applyRedactions(text, _sessionRedactPatterns),
  _diagnosticRedactPatterns,
);

/// 标记载荷里的结构字段：标识、时刻、枚举与计数。这些值不是自由
/// 文本，导出脱敏不触碰（防止随机标识被令牌特征误改、时刻被误吃），
/// 其下挂载的列表与映射一并保留。载荷里其余字符串值一律按会话
/// 脱敏规则处理：宁可多遮一层，不可漏掉秘密。
const _markerStructuralKeys = {
  'schemaVersion',
  'date',
  'month',
  'at',
  'createdAt',
  'updatedAt',
  'finalized',
  'finalizedAt',
  'generatedAt',
  'lastSuccess',
  'pending',
  'id',
  'sessionId',
  'requestId',
  'lastRequestId',
  'lastEntryId',
  'coveredRequestIds',
  'entryCount',
  'fileCount',
  'kind',
  'layer',
  'layerKey',
  'outcome',
  'quarantined',
  'quarantinedFiles',
  'status',
  'source',
  'mode',
  'speaker',
  'fallbackReason',
  'safety',
  'personaBranch',
  'personaNature',
  'proactive',
  'signal',
  'userEdited',
  'compressedDates',
};

Object? _redactMarkerPayloadValue(String key, Object? value) {
  if (_markerStructuralKeys.contains(key)) {
    return value;
  }
  if (value is String) {
    return redactSessionText(value);
  }
  if (value is List<Object?>) {
    return [for (final item in value) _redactMarkerPayloadValue('', item)];
  }
  if (value is Map<String, Object?>) {
    return {
      for (final MapEntry(:key, :value) in value.entries)
        key: _redactMarkerPayloadValue(key, value),
    };
  }
  return value;
}

/// 记忆 Markdown 的导出侧脱敏（备份外发共用）：`qiyu-*` 标记载荷先
/// 解码，自由文本字段按会话脱敏规则处理后重编码，秘密藏进 base64url
/// 载荷也一并过滤；标记以外的可见文本直接套用同一规则。未发生任何
/// 替换时返回 null，调用方沿用原始字节，正常备份往返逐字节一致；
/// 解不开的载荷保持原样，绝不让脱敏损坏文件结构。
String? redactMemoryMarkdown(String markdown) {
  final buffer = StringBuffer();
  var cursor = 0;
  for (final match in memoryMarkerBlockPattern.allMatches(markdown)) {
    buffer.write(redactSessionText(markdown.substring(cursor, match.start)));
    final original = match.group(0)!;
    var replacement = original;
    try {
      final payload = _redactMarkerPayloadValue(
        '',
        decodeMarkerPayload(match.group(2)!),
      ) as Map<String, Object?>;
      final encoded = encodeMarkerPayload(payload);
      if (encoded != match.group(2)) {
        replacement = '${match.group(1)}$encoded${match.group(3)}';
      }
    } on Object {
      // 载荷解不开：保持原样（宁原样，不可损坏）。
    }
    buffer.write(replacement);
    cursor = match.end;
  }
  buffer.write(redactSessionText(markdown.substring(cursor)));
  final result = buffer.toString();
  return result == markdown ? null : result;
}
