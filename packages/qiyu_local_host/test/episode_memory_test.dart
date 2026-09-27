import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';

void main() {
  test(
    'a validated memory signal writes today episode and advances checkpoint',
    () async {
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
          MemorySignalAction(summary: '用户明天有面试', evidence: '明天要面试，有点紧张'),
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
    },
  );

  test('带 BOM 的检查点与每日记录文件照常读出', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-bom-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );
    await pipeline.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [MemorySignalAction(summary: '用户明天有面试')],
    );

    // 手动编辑过的文件可能以 BOM 开头；解析层剥 BOM 再解析，检查点
    // 与当日记录照常读出，文件字节不动。
    final checkpointFile = File(
      '${temporaryDirectory.path}/episodes/checkpoint.md',
    );
    final dayFile = File(
      '${temporaryDirectory.path}/episodes/2026/08/2026-08-14.md',
    );
    Future<void> prependBom(File file) async {
      final bytes = await file.readAsBytes();
      await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...bytes]);
    }

    await prependBom(checkpointFile);
    await prependBom(dayFile);
    final checkpointBytes = await checkpointFile.readAsBytes();

    final checkpoint = await pipeline.readCheckpoint();
    expect(checkpoint!.sessionId, 'session-1');
    expect(checkpoint.lastRequestId, 'req-1');
    final day = await pipeline.readDay('2026-08-14');
    expect(day.entries, hasLength(1));
    expect(day.entries.single.summary, '用户明天有面试');
    expect(await checkpointFile.readAsBytes(), checkpointBytes);

    // 文件首 BOM 由 utf8 解码器丢弃后，重复 BOM 的第二个字符留在字
    // 符串层；解析层剥除后同样照常解析。
    await prependBom(checkpointFile);
    final reloaded = await pipeline.readCheckpoint();
    expect(reloaded!.sessionId, 'session-1');
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
    const signal = [MemorySignalAction(summary: '用户下周搬家')];

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
      atomicWriter: FailingAtomicTextWriter(shouldFail: (_) => true),
    );

    await expectLater(
      pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [MemorySignalAction(summary: '写不进去的记忆')],
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

  test(
    'the four-turn window stays pending without a memory decision',
    () async {
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
            ...[
              'req-1',
              'req-2',
              'req-3',
            ].sublist(0, ['req-1', 'req-2', 'req-3'].indexOf(requestId) + 1),
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

      expect(fourth.checkpointAdvanced, isFalse);
      expect(fourth.pendingTurns, 4);
      expect(await pipeline.readCheckpoint(), isNull);
      expect((await pipeline.readToday()).entries, isEmpty);
    },
  );

  test('an explicit no-action advances only a clean current turn', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-no-action-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );

    final result = await pipeline.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [NoAction()],
    );

    expect(result.checkpointAdvanced, isTrue);
    expect(result.pendingTurns, 0);
    expect((await pipeline.readCheckpoint())!.lastRequestId, 'req-1');
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

  test(
    'secrets never reach the episode file even if validation is bypassed',
    () async {
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
          MemorySignalAction(
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
    },
  );

  test('a keep-marked memory signal round-trips through the day file', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-keep-test-',
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
        MemorySignalAction(
          summary: '用户认定长期记忆只放长远的事',
          keep: memorySignalKeepMonth,
        ),
        MemorySignalAction(summary: '用户晚饭吃了小馄饨'),
      ],
    );

    final day = await pipeline.readToday();
    expect(day.entries, hasLength(2));
    expect(
      day.entries.firstWhere((entry) => entry.summary.contains('长远')).keep,
      memorySignalKeepMonth,
    );
    // 没标 keep 的条目按未标记落盘，月压缩不收。
    expect(
      day.entries.firstWhere((entry) => entry.summary.contains('小馄饨')).keep,
      isNull,
    );
  });

  test('keep marks ride the lifecycle action creation paths', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-keep-lifecycle-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );

    // 真实创建路径：聊天轮隐藏动作落当天条目。
    await pipeline.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [
        OpenLoopCandidateAction(
          title: '租房事宜',
          keep: memorySignalKeepMonth,
        ),
        RelationshipSignalAction(
          summary: '用户近期愿意聊到更深的家庭关系',
          signal: RelationshipSignal.deepTalk,
          keep: memorySignalKeepMonth,
        ),
      ],
    );
    await pipeline.processReply(
      session: _session('session-1', ['req-2']),
      requestId: 'req-2',
      hiddenActions: const [
        OpenLoopCandidateAction(title: '买牛奶'),
        RelationshipSignalAction(
          summary: '今晚话少',
          signal: RelationshipSignal.temperature,
        ),
      ],
    );

    final day = await pipeline.readToday();
    expect(day.entries, hasLength(4));
    final marked = day.entries.where((entry) => entry.keep != null).toList();
    expect(marked, hasLength(2));
    expect(
      marked.map((entry) => entry.summary),
      containsAll(['租房事宜', '用户近期愿意聊到更深的家庭关系']),
    );
    // 没标的两类条目按未标记落盘，月文件对应分区不收。
    expect(
      day.entries.where((entry) => entry.keep == null).map((e) => e.summary),
      containsAll(['买牛奶', '今晚话少']),
    );
  });

  test('a day file written before the keep field reads back unmarked', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-keep-legacy-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    // 旧日文件没有 keep 字段：必须照常读出，按未标记参与月压缩。
    final dayPath =
        '${temporaryDirectory.path}/episodes/2026/08/2026-08-14.md';
    File(dayPath).createSync(recursive: true);
    File(dayPath).writeAsStringSync(
      '# 栖语每日记录\n'
      '\n'
      '<!-- qiyu-episode:${encodeMarkerPayload({
        'schemaVersion': 1,
        'date': '2026-08-14',
        'updatedAt': '2026-08-14T22:30:00.000Z',
        'finalized': true,
        'finalizedAt': '2026-08-14T23:00:00.000Z',
      })} -->\n'
      '\n'
      '<!-- qiyu-episode-entry:${encodeMarkerPayload({
        'id': 'legacy:r1:0',
        'sessionId': 'legacy',
        'requestId': 'r1',
        'summary': '用户明天有面试',
        'at': '2026-08-14T22:30:00.000Z',
      })} -->\n'
      '\n'
      '## 2026-08-14T22:30:00.000 · 用户明天有面试\n',
      encoding: utf8,
    );

    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );
    final day = await pipeline.readDay('2026-08-14');

    expect(day.readable, isTrue);
    expect(day.entries, hasLength(1));
    expect(day.entries.single.summary, '用户明天有面试');
    expect(day.entries.single.keep, isNull);
  });

  test('the keep mark survives the entry JSON round trip and model copy', () {
    final entry = EpisodeEntry(
      id: 'session-1:req-1:0',
      sessionId: 'session-1',
      requestId: 'req-1',
      summary: '用户对芒果过敏',
      at: DateTime.utc(2026, 8, 14, 22, 30),
      keep: memorySignalKeepMonth,
    );
    expect(EpisodeEntry.fromJson(entry.toJson()).keep, memorySignalKeepMonth);
    expect(entry.redactedForModel().keep, memorySignalKeepMonth);
    // 未标记时 toJson 不写该键，旧读取端不受影响。
    final unmarked = EpisodeEntry(
      id: entry.id,
      sessionId: entry.sessionId,
      requestId: entry.requestId,
      summary: entry.summary,
      at: entry.at,
    );
    expect(EpisodeEntry.fromJson(unmarked.toJson()).keep, isNull);
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
    final dayPath = '${temporaryDirectory.path}/episodes/2026/08/2026-08-14.md';
    File(dayPath).createSync(recursive: true);
    File(dayPath).writeAsStringSync('# 用户手写的日记\n\n今天天气很好。\n', encoding: utf8);

    final result = await pipeline.processReply(
      session: _session('session-1', ['req-1', 'req-2', 'req-3', 'req-4']),
      requestId: 'req-4',
      hiddenActions: const [MemorySignalAction(summary: '新记忆')],
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

  test('a recovered turn never skips past backlogged turns', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-episode-pending-window-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 14, 22, 30),
    );

    // 本地降级期间积压了四轮：恢复后的整理只判断当前轮，
    // 不能顺带越过更早的轮次。
    final recovered = await pipeline.processReply(
      session: _session('session-1', [
        'req-1',
        'req-2',
        'req-3',
        'req-4',
        'req-5',
      ]),
      requestId: 'req-5',
      hiddenActions: const [NoAction()],
    );
    expect(recovered.checkpointAdvanced, isFalse);
    expect(recovered.pendingTurns, 5);
    expect(await pipeline.readCheckpoint(), isNull);
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
      hiddenActions: const [MemorySignalAction(summary: '已记录')],
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
      hiddenActions: const [MemorySignalAction(summary: '已记录')],
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
