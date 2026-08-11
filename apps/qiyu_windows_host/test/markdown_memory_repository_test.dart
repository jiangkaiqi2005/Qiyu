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
    'restores a recent prior-day session but starts today explicitly',
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
      final today = await repository.createSession();

      expect(restored.id, saved.id);
      expect(restored.turns.single.text, '昨晚的话');
      expect(today.id, isNot(saved.id));
      expect(today.date, '2026-08-12');
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

  test('reports corrupt Markdown and atomic write failures clearly', () async {
    final sessions = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}sessions${Platform.pathSeparator}2026${Platform.pathSeparator}08',
    )..createSync(recursive: true);
    File(
      '${sessions.path}${Platform.pathSeparator}broken.md',
    ).writeAsStringSync('# 不是有效的栖语会话');
    final corruptRepository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );

    await expectLater(
      corruptRepository.openSession(),
      throwsA(
        isA<MemoryRepositoryException>()
            .having((error) => error.code, 'code', 'session_parse_failed')
            .having((error) => error.message, 'message', contains('会话文件损坏')),
      ),
    );

    await sessions.delete(recursive: true);
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
}

final class _FailingAtomicWriter implements AtomicTextWriter {
  @override
  Future<void> replace(String path, String contents) {
    throw const FileSystemException('mock write failure');
  }
}
