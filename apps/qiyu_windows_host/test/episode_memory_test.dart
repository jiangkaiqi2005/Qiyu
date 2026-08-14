import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

void main() {
  test('a validated memory signal writes today episode and advances checkpoint', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-signal-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );

    final result = await pipeline.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [
        HiddenAction(
          kind: HiddenActionKind.memorySignal,
          summary: '用户明天有面试',
          evidence: '明天要面试，有点紧张',
        ),
      ],
    );

    expect(result.writtenEntries, 1);
    expect(result.checkpointAdvanced, isTrue);
    final day = await pipeline.readToday();
    expect(day.entries, hasLength(1));
    expect(day.entries.single.summary, '用户明天有面试');
    expect(day.entries.single.evidence, '明天要面试，有点紧张');
    final checkpoint = await pipeline.readCheckpoint();
    expect(checkpoint!.sessionId, 'session-1');
    expect(checkpoint.lastRequestId, 'req-1');
  });

  test('duplicate signals for the same turn are idempotent', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-duplicate-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );
    final session = _session('session-1', ['req-1']);
    const signal = [
      HiddenAction(
        kind: HiddenActionKind.memorySignal,
        summary: '用户下周搬家',
      ),
    ];

    await pipeline.processReply(
      session: session,
      requestId: 'req-1',
      hiddenActions: signal,
    );
    final replay = await pipeline.processReply(
      session: session,
      requestId: 'req-1',
      hiddenActions: signal,
    );

    expect(replay.writtenEntries, 0);
    expect(replay.skippedDuplicates, 1);
    expect((await pipeline.readToday()).entries, hasLength(1));
  });

  test('episode write failure keeps the checkpoint where it was', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-failure-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
      atomicWriter: const _AlwaysFailingWriter(),
    );

    await expectLater(
      pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [
          HiddenAction(
            kind: HiddenActionKind.memorySignal,
            summary: '写不进去的记忆',
          ),
        ],
      ),
      throwsA(
        isA<MemoryRepositoryException>().having(
          (error) => error.code,
          'code',
          'episode_write_failed',
        ),
      ),
    );
    expect(await pipeline.readCheckpoint(), isNull);
  });

  test('the four-turn window advances the checkpoint without a signal', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-window-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );

    for (final requestId in ['req-1', 'req-2', 'req-3']) {
      final result = await pipeline.processReply(
        session: _session('session-1', [
          ...['req-1', 'req-2', 'req-3'].sublist(
            0,
            ['req-1', 'req-2', 'req-3'].indexOf(requestId) + 1,
          ),
        ]),
        requestId: requestId,
        hiddenActions: const [],
      );
      expect(result.checkpointAdvanced, isFalse, reason: requestId);
    }
    final fourth = await pipeline.processReply(
      session: _session('session-1', ['req-1', 'req-2', 'req-3', 'req-4']),
      requestId: 'req-4',
      hiddenActions: const [],
    );

    expect(fourth.checkpointAdvanced, isTrue);
    expect(fourth.pendingTurns, 0);
    expect((await pipeline.readCheckpoint())!.lastRequestId, 'req-4');
    expect((await pipeline.readToday()).entries, isEmpty);
  });

  test('a new session restarts the window from scratch', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-session-switch-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );
    await pipeline.processReply(
      session: _session('session-1', ['req-1', 'req-2']),
      requestId: 'req-2',
      hiddenActions: const [],
    );

    final switched = await pipeline.processReply(
      session: _session('session-2', ['req-3']),
      requestId: 'req-3',
      hiddenActions: const [],
    );

    expect(switched.checkpointAdvanced, isFalse);
    expect(switched.pendingTurns, 1);
  });

  test('secrets never reach the episode file even if validation is bypassed', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-secrets-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );

    await pipeline.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [
        HiddenAction(
          kind: HiddenActionKind.memorySignal,
          summary: '密码: hunter2abc',
          evidence: '身份证 11010519491231002X',
        ),
      ],
    );

    final episodeFile = File(
      '${temporaryDirectory.path}/episodes/2026/08/2026-08-14.md',
    );
    final contents = await episodeFile.readAsString(encoding: utf8);
    expect(contents, isNot(contains('hunter2abc')));
    expect(contents, isNot(contains('11010519491231002X')));
    expect(contents, contains('[已脱敏]'));
  });

  test('a corrupted or foreign day file is never overwritten', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-corrupt-day-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );
    final dayPath =
        '${temporaryDirectory.path}/episodes/2026/08/2026-08-14.md';
    File(dayPath).createSync(recursive: true);
    File(dayPath).writeAsStringSync(
      '# 用户手写的日记\n\n今天天气很好。\n',
      encoding: utf8,
    );

    final result = await pipeline.processReply(
      session: _session('session-1', ['req-1', 'req-2', 'req-3', 'req-4']),
      requestId: 'req-4',
      hiddenActions: const [
        HiddenAction(kind: HiddenActionKind.memorySignal, summary: '新记忆'),
      ],
    );

    expect(result.skippedCorruptDay, isTrue);
    expect(result.writtenEntries, 0);
    expect(result.checkpointAdvanced, isFalse);
    expect(
      File(dayPath).readAsStringSync(encoding: utf8),
      '# 用户手写的日记\n\n今天天气很好。\n',
    );
    expect(await pipeline.readCheckpoint(), isNull);
  });

  test('local fallback turns keep the window pending', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-pending-window-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );

    final result = await pipeline.processReply(
      session: _session('session-1', ['req-1', 'req-2', 'req-3', 'req-4']),
      requestId: 'req-4',
      hiddenActions: const [],
      consumeWindow: false,
    );

    expect(result.checkpointAdvanced, isFalse);
    expect(result.pendingTurns, 4);
    expect(await pipeline.readCheckpoint(), isNull);

    // Provider 恢复后的 LLM 轮一次性补跑窗口。
    final recovered = await pipeline.processReply(
      session: _session('session-1', [
        'req-1',
        'req-2',
        'req-3',
        'req-4',
        'req-5',
      ]),
      requestId: 'req-5',
      hiddenActions: const [],
      consumeWindow: true,
    );
    expect(recovered.checkpointAdvanced, isTrue);
  });

  test('a fresh pipeline resumes from the persisted checkpoint', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-resume-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final first = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );
    await first.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [
        HiddenAction(kind: HiddenActionKind.memorySignal, summary: '已记录'),
      ],
    );

    // 模拟 Host 重启后的新管线实例。
    final second = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 45),
    );
    final resumed = await second.processReply(
      session: _session('session-1', ['req-1', 'req-2']),
      requestId: 'req-2',
      hiddenActions: const [],
    );

    expect(resumed.pendingTurns, 1);
    expect(resumed.checkpointAdvanced, isFalse);
    // 重启后重复提交同一动作仍然幂等。
    final replay = await second.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [
        HiddenAction(kind: HiddenActionKind.memorySignal, summary: '已记录'),
      ],
    );
    expect(replay.writtenEntries, 0);
    expect(replay.skippedDuplicates, 1);
  });
}

RawSession _session(String id, List<String> requestIds) {
  final base = DateTime(2026, 8, 14, 22);
  final turns = <RawSessionTurn>[];
  for (var index = 0; index < requestIds.length; index += 1) {
    turns.add(
      RawSessionTurn.user(
        requestId: requestIds[index],
        text: '第 ${index + 1} 轮',
        at: base.add(Duration(minutes: index)),
      ),
    );
  }
  return RawSession(
    id: id,
    date: '2026-08-14',
    segment: 1,
    createdAt: base.toUtc(),
    updatedAt: base.toUtc(),
    turns: turns,
  );
}

final class _AlwaysFailingWriter implements AtomicTextWriter {
  const _AlwaysFailingWriter();

  @override
  Future<void> replace(String path, String contents) async {
    throw const FileSystemException('mock interrupted write');
  }
}
