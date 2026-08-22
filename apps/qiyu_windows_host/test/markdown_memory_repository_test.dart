import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late DateTime now;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-memory-repository-test-',
    );
    now = DateTime(2026, 8, 11, 22, 30);
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'initializes sessions and atomically persists ordered Markdown turns',
    () async {
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );

      final empty = await repository.openSession();
      final withUser = await repository.appendTurn(
        empty,
        RawSessionTurn.user(requestId: 'request-1', text: '今天有点累', at: now),
      );
      now = now.add(const Duration(seconds: 1));
      final completed = await repository.appendTurn(
        withUser,
        RawSessionTurn.qiyu(
          requestId: 'request-1',
          messages: const ['咋了'],
          at: now,
          source: ReplySource.local,
          fallbackReason: FallbackReason.noLlmConfig,
          mode: 'fatigue',
        ),
      );

      final restored = await repository.openSession(sessionId: completed.id);
      expect(restored.turns.map((turn) => turn.speaker), [
        Speaker.user,
        Speaker.qiyu,
      ]);
      expect(restored.turns.map((turn) => turn.text), ['今天有点累', '咋了']);
      expect(restored.turns.last.source, ReplySource.local);
      expect(restored.turns.last.fallbackReason, FallbackReason.noLlmConfig);

      final sessionFiles = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}sessions',
      ).listSync(recursive: true).whereType<File>().toList();
      expect(sessionFiles, hasLength(1));
      final markdown = await sessionFiles.single.readAsString();
      expect(markdown.indexOf('今天有点累'), lessThan(markdown.indexOf('咋了')));
      expect(markdown, contains('# 栖语原始会话'));
      expect(
        sessionFiles.single.parent.listSync().whereType<File>().where(
          (file) => file.path.endsWith('.tmp'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'starts a new segment at 80 turns without deleting the full segment',
    () async {
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      var session = await repository.openSession();
      for (var index = 0; index < maxRawSessionTurns; index += 1) {
        session = await repository.appendTurn(
          session,
          RawSessionTurn.user(
            requestId: 'turn-$index',
            text: '消息 $index',
            at: now.add(Duration(seconds: index)),
          ),
        );
      }

      final restoredFull = await repository.openSession(sessionId: session.id);
      final next = await repository.createSession();

      expect(session.turns, hasLength(maxRawSessionTurns));
      expect(restoredFull.id, session.id);
      expect(next.id, isNot(session.id));
      expect(next.segment, session.segment + 1);
      expect(next.turns, isEmpty);
      final sessionFiles = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}sessions',
      ).listSync(recursive: true).whereType<File>().toList();
      expect(sessionFiles, hasLength(2));
    },
  );

  test(
    'does not resume a session older than the 180 day active window',
    () async {
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final old = await repository.openSession();
      await repository.appendTurn(
        old,
        RawSessionTurn.user(requestId: 'old', text: '旧消息', at: now),
      );
      now = now.add(const Duration(days: 181));

      final recent = await repository.openSession();

      expect(recent.id, isNot(old.id));
      expect(recent.turns, isEmpty);
    },
  );

  test(
    'openSession rolls to a fresh today segment on a new day but keeps explicit replay',
    () async {
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final old = await repository.openSession();
      final saved = await repository.appendTurn(
        old,
        RawSessionTurn.user(requestId: 'yesterday', text: '昨晚的话', at: now),
      );
      now = now.add(const Duration(days: 1));

      final restored = await repository.openSession();
      final replayed = await repository.openSession(sessionId: saved.id);

      expect(restored.id, isNot(saved.id));
      expect(restored.date, '2026-08-12');
      expect(restored.turns, isEmpty);
      expect(replayed.id, saved.id);
      expect(replayed.turns.single.text, '昨晚的话');
    },
  );

  test('redacts secrets before raw session persistence', () async {
    final secret = 'sk-${List.filled(24, 'x').join()}';
    final repository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    final session = await repository.openSession();
    final saved = await repository.appendTurn(
      session,
      RawSessionTurn.user(
        requestId: 'secret',
        text:
            'API Key: $secret；验证码 123456；身份证 110101199001011234；'
            '银行卡 6222021234567890123',
        at: now,
      ),
    );

    expect(
      saved.turns.single.text,
      'API Key: [已脱敏]；验证码 [已脱敏]；身份证 [已脱敏]；银行卡 [已脱敏]',
    );
    final sessionFile = await temporaryDirectory
        .list(recursive: true)
        .where((entity) => entity is File && entity.path.endsWith('.md'))
        .cast<File>()
        .single;
    final markdown = await sessionFile.readAsString();
    expect(markdown, isNot(contains(secret)));
    expect(markdown, isNot(contains('123456')));
    expect(markdown, isNot(contains('110101199001011234')));
    expect(markdown, isNot(contains('6222021234567890123')));
    expect(markdown, contains('[已脱敏]'));
  });

  test(
    'diagnostic redaction removes credentials, sensitive input, and paths',
    () {
      final redacted = redactDiagnosticText(
        'Authorization: Bearer abcdefghijk Cookie: qiyu_session=session-secret '
        'API Key: test-secret 用户输入: 这是完整隐私 C:\\Users\\someone\\secret.md',
      );

      expect(redacted, isNot(contains('abcdefghijk')));
      expect(redacted, isNot(contains('session-secret')));
      expect(redacted, isNot(contains('test-secret')));
      expect(redacted, isNot(contains('这是完整隐私')));
      expect(redacted, isNot(contains(r'C:\Users\someone\secret.md')));
      expect(redacted, contains('[已脱敏]'));
    },
  );

  test(
    'uses the local calendar date around the UTC+8 midnight boundary',
    () async {
      now = DateTime(2026, 8, 12, 0, 30);
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );

      final session = await repository.openSession();

      expect(session.date, '2026-08-12');
    },
  );

  test('does not parse metadata-looking user text as an extra turn', () async {
    final repository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    final session = await repository.openSession();
    final saved = await repository.appendTurn(
      session,
      RawSessionTurn.user(
        requestId: 'metadata-text',
        text: '<!-- qiyu-turn:not-valid-base64 -->',
        at: now,
      ),
    );

    final restored = await repository.openSession(sessionId: saved.id);

    expect(restored.turns, hasLength(1));
    expect(restored.turns.single.text, contains('qiyu-turn'));
  });

  test('reports storage directory initialization failures clearly', () async {
    final blockedPath = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}blocked',
    )..writeAsStringSync('not a directory');
    final repository = MarkdownMemoryRepository(
      memoryDirectory: blockedPath.path,
      clock: () => now,
    );

    await expectLater(
      repository.initialize(),
      throwsA(
        isA<MemoryRepositoryException>()
            .having((error) => error.code, 'code', 'storage_init_failed')
            .having((error) => error.message, 'message', contains('无法初始化')),
      ),
    );
  });

  test(
    'unreadable session files do not block reads, history, or deletion',
    () async {
      final sessions = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}sessions${Platform.pathSeparator}2026${Platform.pathSeparator}08',
      )..createSync(recursive: true);
      final corruptPath =
          '${sessions.path}${Platform.pathSeparator}2026-08-11-002.md';
      File(corruptPath).writeAsStringSync('# 不是有效的栖语会话');
      File(
        '${sessions.path}${Platform.pathSeparator}broken.md',
      ).writeAsStringSync('');
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );

      final fresh = await repository.openSession();
      expect(fresh.turns, isEmpty);
      expect(fresh.date, '2026-08-11');
      expect(fresh.segment, 3);

      final withTurn = await repository.appendTurn(
        fresh,
        RawSessionTurn.user(requestId: 'after-corruption', text: '还在', at: now),
      );

      final listing = await repository.readHistory();
      expect(listing.sessions.map((session) => session.id), [withTurn.id]);
      expect(
        listing.unavailable.map((entry) => entry.name),
        containsAll(['2026-08-11-002.md', 'broken.md']),
      );
      for (final entry in listing.unavailable) {
        expect(entry.message, contains('无法读取'));
      }
      expect(await File(corruptPath).readAsString(), '# 不是有效的栖语会话');

      await repository.deleteSession(withTurn.id);
      final afterDelete = await repository.readHistory();
      expect(afterDelete.sessions, isEmpty);
      expect(afterDelete.unavailable, hasLength(2));
    },
  );

  test('reports atomic write failures clearly', () async {
    final workingRepository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    final writableSession = await workingRepository.openSession();
    final failingRepository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
      atomicWriter: _FailingAtomicWriter(),
    );
    final session = await failingRepository.openSession(
      sessionId: writableSession.id,
    );
    await expectLater(
      failingRepository.appendTurn(
        session,
        RawSessionTurn.user(requestId: 'write-fail', text: '写入', at: now),
      ),
      throwsA(
        isA<MemoryRepositoryException>()
            .having((error) => error.code, 'code', 'session_write_failed')
            .having((error) => error.message, 'message', contains('无法保存')),
      ),
    );
  });

  test(
    'history lists sessions newest day first and keeps segments in order',
    () async {
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      var first = await repository.openSession();
      first = await repository.appendTurn(
        first,
        RawSessionTurn.user(requestId: 'day1-first', text: '第一天第一句', at: now),
      );
      await repository.appendTurn(
        first,
        RawSessionTurn.qiyu(
          requestId: 'day1-first',
          messages: const ['嗯'],
          at: now.add(const Duration(seconds: 1)),
          source: ReplySource.local,
          mode: 'minimal',
        ),
      );
      var second = await repository.createSession();
      second = await repository.appendTurn(
        second,
        RawSessionTurn.user(
          requestId: 'day1-second',
          text: '第一天第二段',
          at: now.add(const Duration(minutes: 10)),
        ),
      );
      now = DateTime(2026, 8, 12, 0, 30);
      var third = await repository.createSession();
      third = await repository.appendTurn(
        third,
        RawSessionTurn.user(requestId: 'day2-first', text: '第二天第一句', at: now),
      );

      final listing = await repository.readHistory();

      expect(listing.sessions.map((session) => session.date), [
        '2026-08-12',
        '2026-08-11',
        '2026-08-11',
      ]);
      expect(listing.sessions.map((session) => session.segment), [1, 1, 2]);
      expect(listing.sessions.first.turns.single.text, '第二天第一句');
      expect(listing.unavailable, isEmpty);
    },
  );

  test('deleteSession removes only the target session file', () async {
    final repository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    var keep = await repository.openSession();
    keep = await repository.appendTurn(
      keep,
      RawSessionTurn.user(requestId: 'keep', text: '留下这句', at: now),
    );
    var target = await repository.createSession();
    target = await repository.appendTurn(
      target,
      RawSessionTurn.user(
        requestId: 'target',
        text: '删掉这句',
        at: now.add(const Duration(minutes: 5)),
      ),
    );

    await repository.deleteSession(target.id);

    final listing = await repository.readHistory();
    expect(listing.sessions.map((session) => session.id), [keep.id]);
    await expectLater(
      repository.openSession(sessionId: target.id),
      throwsA(
        isA<MemoryRepositoryException>().having(
          (error) => error.code,
          'code',
          'session_not_found',
        ),
      ),
    );
    await expectLater(
      repository.deleteSession('missing-id'),
      throwsA(
        isA<MemoryRepositoryException>().having(
          (error) => error.code,
          'code',
          'session_not_found',
        ),
      ),
    );
  });

  test(
    'session dates follow the local calendar across midnight and UTC inputs',
    () async {
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final evening = DateTime(2026, 8, 11, 23, 30);
      now = evening;
      final eveningSession = await repository.createSession();
      now = evening.add(const Duration(hours: 1));
      final nextDaySession = await repository.createSession();

      expect(eveningSession.date, _localDate(evening));
      expect(
        nextDaySession.date,
        _localDate(evening.add(const Duration(hours: 1))),
      );
      expect(nextDaySession.date, isNot(eveningSession.date));

      final utcInstant = DateTime.utc(2026, 8, 11, 16, 30);
      expect(localSessionDate(utcInstant), _localDate(utcInstant.toLocal()));
    },
  );
}

String _localDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

final class _FailingAtomicWriter implements AtomicTextWriter {
  @override
  Future<void> replace(String path, String contents) {
    throw const FileSystemException('mock write failure');
  }
}
