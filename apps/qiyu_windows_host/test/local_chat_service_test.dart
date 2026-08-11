import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test(
    'retries an interrupted exchange without duplicating the user turn',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-local-chat-service-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final writer = _FailOnceAtomicWriter(failOnCall: 3);
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: () => DateTime.utc(2026, 8, 11, 22, 30),
        atomicWriter: writer,
      );
      final service = LocalChatService(
        repository,
        clock: () => DateTime.utc(2026, 8, 11, 22, 30),
      );
      final snapshot = await service.restore();

      await expectLater(
        service.send(
          requestId: 'retry-1',
          text: '今天有点累',
          sessionId: snapshot.session.id,
        ),
        throwsA(
          isA<MemoryRepositoryException>().having(
            (error) => error.code,
            'code',
            'session_write_failed',
          ),
        ),
      );

      final pending = await repository.openSession(
        sessionId: snapshot.session.id,
      );
      expect(pending.turns, hasLength(1));
      final completed = await service.send(
        requestId: 'retry-1',
        text: '今天有点累',
        sessionId: snapshot.session.id,
      );

      expect(completed.result.messages, ['咋了']);
      expect(completed.session.turns, hasLength(2));
      expect(completed.session.turns.map((turn) => turn.requestId), [
        'retry-1',
        'retry-1',
      ]);
    },
  );
}

final class _FailOnceAtomicWriter implements AtomicTextWriter {
  _FailOnceAtomicWriter({required this.failOnCall});

  final int failOnCall;
  final AtomicTextWriter _delegate = const IoAtomicTextWriter();
  var _calls = 0;

  @override
  Future<void> replace(String path, String contents) {
    _calls += 1;
    if (_calls == failOnCall) {
      throw const FileSystemException('mock interrupted write');
    }
    return _delegate.replace(path, contents);
  }
}
