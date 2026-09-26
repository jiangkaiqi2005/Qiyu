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
const memoryControlsFileName = 'memory-controls.md';

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
/// 返回 null，由调用方按「缺失与不可读同义」处理；读取成功的文本先
/// 剥 BOM（手动编辑过的文件可能带 BOM，解析层保证带 BOM 与无 BOM 一
/// 致）。记忆域各存储类共用同一份容错口径，不再各写一套。
Future<String?> readFileIfExists(File file) async {
  if (!await file.exists()) {
    return null;
  }
  try {
    return stripUtf8Bom(await file.readAsString(encoding: utf8));
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
    this.serviceError,
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
    ServiceErrorCategory? serviceError,
    SafetyKind? safety,
  }) => RawSessionTurn._(
    requestId: requestId,
    speaker: Speaker.qiyu,
    text: messages.join('\n'),
    messages: List.unmodifiable(messages),
    at: at.toUtc(),
    source: source,
    fallbackReason: fallbackReason,
    serviceError: serviceError,
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
      serviceError: json['serviceError'] == null
          ? null
          : ServiceErrorCategory.fromWireName(json['serviceError']! as String),
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
  final ServiceErrorCategory? serviceError;
  final String? mode;
  final SafetyKind? safety;

  RawSessionTurn redacted() {
    // 落盘前的回合脱敏走跨消息引擎：凭据拆在同轮多条 bubble 时逐条
    // 过滤各自不命中；无跨消息命中时与逐条脱敏逐字一致。
    final safeMessages = redactSessionMessages(messages);
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
      serviceError: serviceError,
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
    if (serviceError != null) 'serviceError': serviceError!.name,
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

RawSession _parseMarkdown(String rawMarkdown) {
  final markdown = stripUtf8Bom(rawMarkdown);
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

/// 既有原文规则共用的词表；新增 JSON 识别在解码后单独处理。
const String _sensitiveKeyNames =
    r'api[_ -]?key|api[_ -]?secret|secret[_ -]?key|access[_ -]?token|'
    r'refresh[_ -]?token|password|passwd|pwd|secret|token|'
    r'密码|口令|密钥|令牌';

final _sensitiveJsonKeyPattern = RegExp(
  '^(?:$_sensitiveKeyNames|client[_ -]?secret)\$',
  caseSensitive: false,
);
final _jsonCookieKeyPattern = RegExp(
  r'^(?:set[- ])?cookie$',
  caseSensitive: false,
);

/// 会话文本脱敏规则（每条消息、每段诊断都会过一遍，正则只编译一次）。
/// JSON 形态的敏感键值：字段名带引号，值段匹配到未转义的结束引号
/// （转义引号随值一并遮蔽），占位后 JSON 结构保持可读。JSON Cookie
/// 只遮蔽含「名字=值」的整个字符串，不吞掉相邻字段。Cookie 文本两段
/// 式：行内出现至少一个「名字=值」形态的项才整行遮蔽（多项串接与
/// 只带标志位的真实头都盖住），纯口吻提及不遮；裸值形态（冒号后
/// 直接跟一长串无空格令牌）单独遮值。PEM 私钥的类型词可缺省，覆盖
/// PKCS#8（BEGIN PRIVATE KEY）与 RSA/EC/OpenSSH/DSA/加密形态；类型
/// 段禁止连字符，防止跨标记误吃。
final _sessionTokenRedactPatterns = <RegExp>[
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
];
final _sessionKeyedRedactPatterns = <RegExp>[
  RegExp(
    r'("(?:' + _sensitiveKeyNames + r')"\s*:\s*")(?:[^"\\]|\\.)*',
    caseSensitive: false,
  ),
  RegExp(
    r'((?:set[- ])?cookie\s*[:=：]\s*'
    r'(?=[^\r\n]*[A-Za-z0-9_~-]+\s*=[^\s；;，,]))[^\r\n]+',
    caseSensitive: false,
  ),
  RegExp(
    r'((?:set[- ])?cookie\s*[:=：]\s*)[A-Za-z0-9._~+/=-]{10,}',
    caseSensitive: false,
  ),
  RegExp(
    r'((?:' + _sensitiveKeyNames + r')\s*[:=：]\s*)[^\s；;，,]+',
    caseSensitive: false,
  ),
];
final _sessionOtherRedactPatterns = <RegExp>[
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

final _sessionRedactPatterns = <RegExp>[
  ..._sessionTokenRedactPatterns,
  ..._sessionKeyedRedactPatterns,
  ..._sessionOtherRedactPatterns,
];
final _decodedValueRedactPatterns = <RegExp>[
  ..._sessionTokenRedactPatterns,
  ..._sessionOtherRedactPatterns,
];

/// 落盘脱敏表末位即私钥配对条目（清单被
/// secret_patterns_lockstep_test 逐字钉死，末位恒为该条目）。该
/// 条目的命中区间不直接跑 allMatches，改由 [_privateKeyPairRegions]
/// 有界配对：先定位 BEGIN/END 成对区间再替换，无 END 的 BEGIN 不
/// 进入跨整串惰性回溯，病态输入（重复 BEGIN 无 END）从平方级降为
/// 线性，命中结果与原正则逐字一致。
final _privateKeyPairRedactPattern = _sessionOtherRedactPatterns.last;

/// 与钉死清单里私钥条目逐字一致的 BEGIN/END 标记段及其字面量头。
/// 标记匹配必然以字面量开头，先扫字面量候选再用标记正则
/// matchAsPrefix 校验，语义与原正则在该起点的尝试完全一致；END
/// 候选必须这样重叠感知地收集——allMatches 的不重叠语义会漏掉与
/// 上一 END 尾部五连字线相接的合法候选，而惰性扫描是逐位尝试的。
final _privateKeyBeginHeadPattern = RegExp(
  '-----BEGIN ',
  caseSensitive: false,
);
final _privateKeyEndHeadPattern = RegExp('-----END ', caseSensitive: false);
final _privateKeyBeginMarkerPattern = RegExp(
  '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----',
  caseSensitive: false,
);
final _privateKeyEndMarkerPattern = RegExp(
  '-----END [A-Z0-9 ]*PRIVATE KEY-----',
  caseSensitive: false,
);

/// 私钥配对条目的命中区间：与原正则同款配对语义（每个 BEGIN 配其
/// 后第一个合法 END，成对区间吞并其间所有候选），按起点升序返回
/// 互不重叠的区间。扫描从上一个成对区间终点继续，与
/// replaceAllMapped 的消费方式一致；END 耗尽后余下 BEGIN 全部不成对。
List<({int start, int end})> _privateKeyPairRegions(String text) {
  final begins = <Match>[];
  for (final head in _privateKeyBeginHeadPattern.allMatches(text)) {
    final marker = _privateKeyBeginMarkerPattern.matchAsPrefix(
      text,
      head.start,
    );
    if (marker != null) begins.add(marker);
  }
  if (begins.isEmpty) return const [];
  final ends = <Match>[];
  for (final head in _privateKeyEndHeadPattern.allMatches(text)) {
    final marker = _privateKeyEndMarkerPattern.matchAsPrefix(text, head.start);
    if (marker != null) ends.add(marker);
  }
  final regions = <({int start, int end})>[];
  var endIndex = 0;
  var consumed = 0;
  for (final begin in begins) {
    if (begin.start < consumed) continue;
    while (endIndex < ends.length && ends[endIndex].start < begin.end) {
      endIndex += 1;
    }
    if (endIndex == ends.length) break;
    final end = ends[endIndex];
    regions.add((start: begin.start, end: end.end));
    consumed = end.end;
    endIndex += 1;
  }
  return regions;
}

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

/// 单条脱敏规则的命中区间（起点已越过保留前缀，替换从该处开始）。
/// 私钥配对条目走 [_privateKeyPairRegions] 的有界配对路径，其余
/// 条目保持 allMatches 的原始语义与遍历顺序。
List<({int start, int end})> _redactSpans(String text, RegExp pattern) {
  if (identical(pattern, _privateKeyPairRedactPattern)) {
    return _privateKeyPairRegions(text);
  }
  return [
    for (final match in pattern.allMatches(text))
      (
        start: match.groupCount > 0
            ? match.start + match.group(1)!.length
            : match.start,
        end: match.end,
      ),
  ];
}

// 新增 JSON 兜底仅处理无法解码的片段，不重新匹配已识别的键和值。
final _additionalJsonRedactPattern = RegExp(
  r'("(client[_ -]?secret|(?:set[- ])?cookie)"\s*:\s*")'
  r'((?:[^"\\]|\\.)*)',
  caseSensitive: false,
);
final _decodedTextCredentialPattern = credentialTextPattern(
  '$_sensitiveKeyNames|client[_ -]?secret|(?:set[- ])?cookie',
);
// 多项 Cookie 只在当前解码文本内遮蔽，不跨重新编码后的 JSON 值边界。
final _decodedCookieTextPattern = RegExp(
  r'((?:set[- ])?cookie\s*[:=：]\s*)([^\r\n]+)',
  caseSensitive: false,
);
final _decodedBareCookieTextPattern = RegExp(
  r'((?:set[- ])?cookie\s*[:=：]\s*)([A-Za-z0-9._~+/=-]{10,})',
  caseSensitive: false,
);

bool _jsonFieldContainsSecret(String key, String? value) {
  if (value != null && (value.trim().isEmpty || value == '[已脱敏]')) {
    return false;
  }
  if (_jsonCookieKeyPattern.hasMatch(key)) {
    return value != null && containsCookieEntry(value);
  }
  return _sensitiveJsonKeyPattern.hasMatch(key);
}

Iterable<JsonTextReplacement> _redactUnparsedJsonText(String text, bool decoded) {
  final replacements = <JsonTextReplacement>[];
  void replaceValue(Match match, int valueGroup) {
    replacements.add(JsonTextReplacement(
      match.end - match.group(valueGroup)!.length, match.end, '[已脱敏]',
    ));
  }
  for (final match in _additionalJsonRedactPattern.allMatches(text)) {
    final rawValue = match.group(3)!;
    String value;
    try {
      value = jsonDecode('"$rawValue"') as String;
    } on FormatException {
      value = rawValue;
    }
    if (_jsonFieldContainsSecret(match.group(2)!, value)) replaceValue(match, 3);
  }
  if (!decoded) {
    replacements.addAll(_rawTextRedactions(text));
  } else {
    // 解码后的文本只按实际凭据值判定，不搬入旧原文规则的空值/占位行为。
    for (final pattern in _decodedValueRedactPatterns) {
      for (final span in _redactSpans(text, pattern)) {
        replacements.add(JsonTextReplacement(
          span.start, span.end, '[已脱敏]',
        ));
      }
    }
    for (final match in _decodedCookieTextPattern.allMatches(text)) {
      final credential =
          _decodedTextCredentialPattern.matchAsPrefix(text, match.start);
      if (credential != null &&
          credentialTextValue(credential.group(3)!).start != 0) {
        // 完整引号值交给下方共享规则，后缀的 price=12 等不是 Cookie 内容。
        continue;
      }
      if (containsCookieEntry(match.group(2)!)) replaceValue(match, 2);
    }
    for (final match in _decodedBareCookieTextPattern.allMatches(text)) {
      replaceValue(match, 2);
    }
    for (final match in _decodedTextCredentialPattern.allMatches(text)) {
      final rawValue = match.group(3)!;
      final value = credentialTextValue(rawValue);
      final key = match.group(2)!;
      final quotedCookie = value.start != 0 && _jsonCookieKeyPattern.hasMatch(key);
      final secret = _jsonFieldContainsSecret(key, value.text) ||
          (quotedCookie && isBareCookieTextValue(value.text, quoted: true));
      if (secret) {
        final start = match.end - rawValue.length;
        replacements.add(JsonTextReplacement(
          start + value.start, start + value.end, '[已脱敏]',
          contextStart: match.start, contextEnd: match.end,
        ));
      }
      if (quotedCookie) {
        for (final part in cookieTextContinuationValues(text, match.end)) {
          replacements.add(JsonTextReplacement(
            part.start, part.end, '[已脱敏]',
            contextStart: match.start, contextEnd: part.end,
          ));
        }
      }
    }
  }
  // 同一凭据可能同时命中 Token 和键值规则；仅合并重叠的替换区间。
  replacements.sort((left, right) => left.start.compareTo(right.start));
  final merged = <JsonTextReplacement>[];
  for (final replacement in replacements) {
    if (merged.isNotEmpty && replacement.start < merged.last.end) {
      final previous = merged.removeLast();
      merged.add(JsonTextReplacement(
        previous.start,
        replacement.end > previous.end ? replacement.end : previous.end,
        '[已脱敏]',
        contextStart: previous.contextStart == null ? replacement.contextStart
            : replacement.contextStart == null ? previous.contextStart
            : previous.contextStart! < replacement.contextStart!
            ? previous.contextStart : replacement.contextStart,
        contextEnd: previous.contextEnd == null ? replacement.contextEnd
            : replacement.contextEnd == null ? previous.contextEnd
            : previous.contextEnd! > replacement.contextEnd!
            ? previous.contextEnd : replacement.contextEnd,
      ));
    } else {
      merged.add(replacement);
    }
  }
  return merged;
}

// 旧规则只检查尚未被 JSON 字符串占用的原文，所有区间仍指向该原文。
Iterable<JsonTextReplacement> _rawTextRedactions(String text) {
  final quoted = <({int start, int end, JsonTextReplacement replacement})>[];
  final replacements = <JsonTextReplacement>[];
  for (final match in _decodedTextCredentialPattern.allMatches(text)) {
    final rawValue = match.group(3)!;
    final value = credentialTextValue(rawValue);
    final key = match.group(2)!;
    if (value.start != 0 && _jsonCookieKeyPattern.hasMatch(key)) {
      for (final part in cookieTextContinuationValues(text, match.end)) {
        replacements.add(JsonTextReplacement(
          part.start, part.end, '[已脱敏]',
          contextStart: match.start, contextEnd: part.end,
        ));
      }
    }
    if (value.start == 0 ||
        (!_jsonFieldContainsSecret(key, value.text) &&
            !(_jsonCookieKeyPattern.hasMatch(key) &&
                isBareCookieTextValue(value.text, quoted: true)))) {
      continue;
    }
    final start = match.end - rawValue.length;
    quoted.add((
      start: match.start,
      end: match.end,
      replacement: JsonTextReplacement(
        start, match.end, '[已脱敏]',
        contextStart: match.start, contextEnd: match.end,
      ),
    ));
  }
  replacements.addAll(quoted.map((value) => value.replacement));
  for (final pattern in _sessionRedactPatterns) {
    var quotedIndex = 0;
    for (final span in _redactSpans(text, pattern)) {
      final start = span.start;
      while (quotedIndex < quoted.length && quoted[quotedIndex].end <= start) {
        quotedIndex += 1;
      }
      if (quotedIndex < quoted.length && quoted[quotedIndex].start <= start &&
          span.end <= quoted[quotedIndex].end) {
        continue;
      }
      replacements.add(JsonTextReplacement(start, span.end, '[已脱敏]'));
    }
  }
  return replacements;
}

String redactSessionText(String text) =>
    _rewriteSessionText(text, _redactUnparsedJsonText);

/// 按完整回复识别凭据，保留未落入替换区间的原消息边界。
List<String> redactSessionMessages(List<String> messages) =>
    _rewriteSessionMessages(messages, _redactUnparsedJsonText);

/// 逐条保形出口（提示词历史轮次等必须逐条装配的场景）的跨消息脱敏。
/// 与 [redactSessionMessages] 同一引擎与命中区间，但保持消息条数与
/// 边界：完全落在单条消息内的命中按原替换值写出（与单条脱敏逐字
/// 一致），跨消息命中的区间投影到每条相交消息、各相交段替换为
/// 「[已脱敏]」，不吞并相邻消息；无命中时逐字返回原文。
List<String> redactSessionTurnTexts(List<String> messages) {
  // 第一遍与 [_rewriteSessionMessages] 同源：键控规则在拼接文本上定位，
  // 命中带保留前缀，替换从值起点开始。
  final firstPass = _projectRedactions(messages, [
    for (final match in _sessionKeyedRedactPatterns.first.allMatches(
      messages.join('\n'),
    ))
      JsonTextReplacement(
        match.start + match.group(1)!.length, match.end, '[已脱敏]',
      ),
  ]);
  // 第二遍在第一遍的拼接结果上定位 JSON 字符串值替换，再投影回各条。
  return _projectRedactions(
    firstPass,
    jsonStringValueReplacements(
      firstPass.join('\n'),
      isSecret: _jsonFieldContainsSecret,
      rewriteText: _redactUnparsedJsonText,
    ),
  );
}

/// 把拼接文本坐标上的替换区间投影回各条消息：命中区间完全落在单条
/// 消息内时按原替换值写出（保留引号整值与零长插入语义，与单条脱敏
/// 逐字一致）；跨条区间拆到每条相交消息，各相交段替换为「[已脱敏]」。
/// 消息条数与未相交文本逐字保留。
List<String> _projectRedactions(
  List<String> messages,
  List<JsonTextReplacement> replacements,
) {
  if (messages.isEmpty || replacements.isEmpty) {
    return List.of(messages);
  }
  final merged = <JsonTextReplacement>[];
  final sorted = [...replacements]
    ..sort((left, right) => left.start.compareTo(right.start));
  for (final replacement in sorted) {
    if (merged.isNotEmpty && replacement.start < merged.last.end) {
      final previous = merged.removeLast();
      // 与引擎自身合并重叠区间的口径一致：合并后退回占位值。
      merged.add(
        JsonTextReplacement(
          previous.start,
          previous.end > replacement.end ? previous.end : replacement.end,
          '[已脱敏]',
        ),
      );
    } else {
      merged.add(replacement);
    }
  }
  final result = <String>[];
  var spanIndex = 0;
  var messageStart = 0;
  for (final message in messages) {
    final messageEnd = messageStart + message.length;
    final buffer = StringBuffer();
    var cursor = messageStart;
    while (spanIndex < merged.length && merged[spanIndex].end <= messageStart) {
      spanIndex += 1;
    }
    for (
      var index = spanIndex;
      index < merged.length && merged[index].start < messageEnd;
      index += 1
    ) {
      final replacement = merged[index];
      final start = replacement.start < messageStart
          ? messageStart
          : replacement.start;
      final end = messageEnd < replacement.end ? messageEnd : replacement.end;
      if (end < start) {
        continue;
      }
      buffer.write(
        message.substring(cursor - messageStart, start - messageStart),
      );
      // 零长区间（空敏感值插入）同样视为完全落在单条内。
      final contained = replacement.start >= messageStart &&
          replacement.end <= messageEnd;
      buffer.write(contained ? replacement.value : '[已脱敏]');
      cursor = end;
    }
    buffer.write(message.substring(cursor - messageStart));
    result.add(buffer.toString());
    messageStart = messageEnd + 1;
  }
  return result;
}

String _rewriteSessionText(
  String text,
  Iterable<JsonTextReplacement> Function(String text, bool decoded) rewriteText,
) => _rewriteSessionMessages([text], rewriteText).single;

List<String> _rewriteSessionMessages(
  List<String> messages,
  Iterable<JsonTextReplacement> Function(String text, bool decoded) rewriteText,
) {
  // 这条旧规则完整消费 JSON 转义字符串，保留直接空值等既有输出。
  final firstPass = _replaceSessionMessageRanges(messages, [
    for (final match in _sessionKeyedRedactPatterns.first.allMatches(
      messages.join('\n'),
    ))
      JsonTextReplacement(
        match.start + match.group(1)!.length, match.end, '[已脱敏]',
      ),
  ]);
  return _replaceSessionMessageRanges(
    firstPass,
    jsonStringValueReplacements(
      firstPass.join('\n'),
      isSecret: _jsonFieldContainsSecret,
      rewriteText: rewriteText,
    ),
  );
}

List<String> _replaceSessionMessageRanges(
  List<String> messages,
  Iterable<JsonTextReplacement> replacements,
) {
  if (messages.isEmpty) return const [];
  final text = messages.join('\n');
  final boundaries = <int>[];
  var offset = 0;
  for (final message in messages.take(messages.length - 1)) {
    offset += message.length;
    boundaries.add(offset);
    offset += 1;
  }
  final buffer = StringBuffer();
  final safeBoundaries = <int>[];
  var boundaryIndex = 0;
  var cursor = 0;
  for (final replacement in replacements) {
    while (boundaryIndex < boundaries.length &&
        boundaries[boundaryIndex] < replacement.start) {
      safeBoundaries.add(boundaries[boundaryIndex++] + buffer.length - cursor);
    }
    buffer.write(text.substring(cursor, replacement.start));
    buffer.write(replacement.value);
    // PEM 等跨消息替换会消费内部换行，只移除被实际遮蔽的边界。
    while (boundaryIndex < boundaries.length &&
        boundaries[boundaryIndex] < replacement.end) {
      boundaryIndex += 1;
    }
    cursor = replacement.end;
  }
  while (boundaryIndex < boundaries.length) {
    safeBoundaries.add(boundaries[boundaryIndex++] + buffer.length - cursor);
  }
  buffer.write(text.substring(cursor));
  final safeText = buffer.toString();
  final result = <String>[];
  var start = 0;
  for (final boundary in safeBoundaries) {
    result.add(safeText.substring(start, boundary));
    start = boundary + 1;
  }
  result.add(safeText.substring(start));
  return result;
}

String redactDiagnosticText(String text) => _applyRedactions(
  redactSessionText(text),
  _diagnosticRedactPatterns,
);

/// 标记载荷里的结构字段：标识、时刻、枚举与计数。这些值不是自由
/// 文本，导出脱敏不触碰（防止随机标识被令牌特征误改、时刻被误吃），
/// 其下挂载的列表与映射一并保留。其余值保留 JSON 键值语义，
/// 自由字符串按记忆文本脱敏，包括字符串里再次嵌入的合法标记。
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
  'serviceError',
  'safety',
  'personaBranch',
  'personaNature',
  'proactive',
  'signal',
  'userEdited',
  'compressedDates',
};

Object? _redactMarkerPayloadValue(String? key, Object? value) {
  if (key != null && _markerStructuralKeys.contains(key)) {
    return value;
  }
  if (key != null &&
      (value is String || value is num) &&
      _jsonFieldContainsSecret(key, value is String ? value : null)) {
    // 保留键值上下文交给现有 JSON 规则；Cookie 内的普通序列化对象
    // 等例外也由同一规则判断，不能仅凭键名遮掉整段内容。
    final field = jsonEncode({key: value});
    final redacted = redactMemoryMarkdown(field) ?? field;
    return (jsonDecode(redacted) as Map<String, Object?>)[key];
  }
  if (value is String) {
    return redactMemoryMarkdown(value) ?? value;
  }
  if (value is List<Object?>) {
    final owner = _jsonCookieKeyPattern.hasMatch(key ?? '') ? key : null;
    return [for (final item in value) _redactMarkerPayloadValue(owner, item)];
  }
  if (value is Map<String, Object?>) {
    final keys = {
      for (final key in value.keys)
        key: _markerStructuralKeys.contains(key)
            ? key
            : redactMemoryMarkdown(key) ?? key,
    };
    final unchangedKeys = {
      for (final MapEntry(:key, :value) in keys.entries)
        if (key == value) key,
    };
    final result = <String, Object?>{};
    var suffix = 2;
    for (final MapEntry(:key, :value) in value.entries) {
      final redactedKey = keys[key]!;
      var uniqueKey = redactedKey;
      // 正常键先保留；改名冲突仅附序号，不能覆盖任何一个普通值。
      while (result.containsKey(uniqueKey) ||
          (uniqueKey != key && unchangedKeys.contains(uniqueKey))) {
        uniqueKey = '$redactedKey (${suffix++})';
      }
      result[uniqueKey] = _redactMarkerPayloadValue(key, value);
    }
    return result;
  }
  return value;
}

String? _redactMarkerPayload(Match match) {
  try {
    final payload = _redactMarkerPayloadValue(
      null,
      decodeMarkerPayload(match.group(2)!),
    ) as Map<String, Object?>;
    final encoded = encodeMarkerPayload(payload);
    return encoded == match.group(2) ? null : encoded;
  } on Object {
    // 载荷解不开：保持原样（宁原样，不可损坏）。
    return null;
  }
}

Iterable<JsonTextReplacement> _redactMemoryText(String text, bool decoded) {
  final markers = memoryMarkerBlockPattern.allMatches(text).toList();
  if (markers.isEmpty) return _redactUnparsedJsonText(text, decoded);
  // 等长遮住编码体，普通规则仍看见完整凭据上下文，区间仍指向原串。
  final protected = text.replaceAllMapped(
    memoryMarkerBlockPattern,
    (match) => '\uE000' * (match.end - match.start),
  );
  final replacements = _redactUnparsedJsonText(protected, decoded).toList();
  for (final marker in markers) {
    if (replacements.any((replacement) =>
        replacement.start < marker.end && replacement.end > marker.start)) {
      continue;
    }
    final encoded = _redactMarkerPayload(marker);
    if (encoded != null) {
      // 只替换载荷，JSON 层已有的前缀/后缀转义也保持原样。
      replacements.add(JsonTextReplacement(
        marker.start + marker.group(1)!.length,
        marker.end - marker.group(3)!.length,
        encoded,
      ));
    }
  }
  return replacements..sort((left, right) => left.start.compareTo(right.start));
}

/// 记忆 Markdown 的返回视图脱敏（备份外发与主动揭示共用）：`qiyu-*`
/// 标记载荷先解码，自由文本字段递归脱敏后重编码，秘密藏进 base64url
/// 载荷也一并过滤；标记以外的可见文本直接套用同一规则。未发生任何
/// 替换时返回 null，调用方沿用原始字节，正常备份往返逐字节一致；
/// 解不开的载荷保持原样，绝不让脱敏损坏文件结构。
String? redactMemoryMarkdown(String markdown) {
  // 标记先以不含凭据语法的占位符参与完整文本判定，避免切断外层
  // JSON/Cookie 的值范围，也避免把合法 base64url 偶合字符当成令牌。
  final markers = <Match>[];
  // 原文中的占位起始字符先转义，恢复时一次消费，避免与用户文本碰撞。
  final protected = markdown
      .replaceAll('\uE000', '\uE000\uE000')
      .replaceAllMapped(memoryMarkerBlockPattern, (match) {
        markers.add(match);
        return '\uE000${markers.length - 1}\uE001';
      });
  final redacted = _rewriteSessionText(protected, _redactMemoryText);
  final result = redacted.replaceAllMapped(
    RegExp('\uE000(\uE000|([0-9]+)\uE001)'),
    (placeholder) {
      final index = placeholder.group(2);
      if (index == null) return '\uE000';
      final match = markers[int.parse(index)];
      final encoded = _redactMarkerPayload(match);
      return encoded == null
          ? match.group(0)!
          : '${match.group(1)}$encoded${match.group(3)}';
    },
  );
  return result == markdown ? null : result;
}
