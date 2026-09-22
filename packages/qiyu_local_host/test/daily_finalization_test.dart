import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';

void main() {
  test(
    'finalizes a day in fixed order: summary, state pack, indexes, flag',
    () async {
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture('qiyu-finalization-test-', clock: clock);
      await pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [
          MemorySignalAction(summary: '用户明天有面试', evidence: '明天要面试，有点紧张'),
        ],
      );

      final outcome = await service.finalizeDay('2026-08-14');

      expect(outcome.status, FinalizationStatus.finalized);
      final day = await pipeline.readDay('2026-08-14');
      expect(day.finalized, isTrue);
      expect(day.finalizedAt, isNotNull);
      expect(day.summary, '用户明天有面试');
      expect(day.entries, hasLength(1));

      final dailyState = await File(
        '${temporaryDirectory.path}/daily-state.md',
      ).readAsString(encoding: utf8);
      expect(dailyState, contains('date: 2026-08-14'));
      expect(dailyState, contains('## 时间感'));
      expect(dailyState, contains('用户明天有面试'));

      final relationship = await File(
        '${temporaryDirectory.path}/relationship.md',
      ).readAsString(encoding: utf8);
      expect(relationship, contains('stage: 初识'));
      expect(relationship, contains('since: 2026-08-14'));

      final monthIndex = await File(
        '${temporaryDirectory.path}/episodes/2026/08/index.md',
      ).readAsString(encoding: utf8);
      expect(monthIndex, contains('- 2026-08-14 |'));
      expect(monthIndex, contains('2026-08-14.md'));
      final topIndex = await File(
        '${temporaryDirectory.path}/episodes/index.md',
      ).readAsString(encoding: utf8);
      expect(topIndex, contains('- 2026-08 |'));
      expect(topIndex, contains('episodes/2026/08/index.md'));
    },
  );

  test('repeated finalization is an idempotent no-op', () async {
    DateTime clock() => DateTime(2026, 8, 14, 23, 30);
    final (:temporaryDirectory, :pipeline, :service) =
        await _finalizationFixture('qiyu-finalization-repeat-test-', clock: clock);
    await pipeline.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [MemorySignalAction(summary: '用户下周搬家')],
    );
    await service.finalizeDay('2026-08-14');
    final before = _snapshotStateFiles(temporaryDirectory.path);

    final replay = await service.finalizeDay('2026-08-14');

    expect(replay.status, FinalizationStatus.alreadyFinalized);
    expect(_snapshotStateFiles(temporaryDirectory.path), before);
    expect((await pipeline.readDay('2026-08-14')).entries, hasLength(1));
  });

  test(
    'bedtime finalizes today and catches up earlier unfinalized days',
    () async {
      var now = DateTime(2026, 8, 13, 22);
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-bedtime-test-',
            clock: () => now,
          );
      await pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [MemorySignalAction(summary: '前天聊了旅行计划')],
      );
      now = DateTime(2026, 8, 14, 23, 30);
      await pipeline.processReply(
        session: _session('session-2', ['req-2']),
        requestId: 'req-2',
        hiddenActions: const [MemorySignalAction(summary: '今天讨论了面试')],
      );

      final report = await service.finalizeForBedtime(date: '2026-08-14');

      expect(
        report.outcomes.map((outcome) => outcome.status),
        containsAll([
          FinalizationStatus.finalized,
          FinalizationStatus.finalized,
        ]),
      );
      expect((await pipeline.readDay('2026-08-14')).finalized, isTrue);
      expect((await pipeline.readDay('2026-08-13')).finalized, isTrue);
      // 近日状态包含两天证据，且当天条目落在「用户当前近况」。
      final dailyState = await File(
        '${temporaryDirectory.path}/daily-state.md',
      ).readAsString(encoding: utf8);
      expect(dailyState, contains('今天讨论了面试'));
      expect(dailyState, contains('前天聊了旅行计划'));
    },
  );

  test(
    'bedtime backfills a session-only day in the existing understanding call',
    () async {
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final client = _RecordingUnderstandingClient(
        jsonEncode({
          'episode_entries': [
            {
              'request_id': 'small-1',
              'summary': '用户晚饭吃了小馄饨，老板多送了两个',
              'evidence': '晚饭吃了小馄饨，老板多送了两个。',
            },
          ],
          'covered_request_ids': ['small-1'],
          'summary': '用户晚饭吃了小馄饨，老板多送了两个',
          'index_keywords': ['晚饭', '小馄饨'],
        }),
      );
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-session-backfill-test-',
            clock: clock,
            modelClient: client,
          );
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: clock,
      );
      var session = await repository.createSession();
      session = await repository.appendTurn(
        session,
        RawSessionTurn.user(
          requestId: 'small-1',
          text: '晚饭吃了小馄饨，老板多送了两个。晚安。',
          at: clock(),
        ),
      );
      final report = await service.finalizeForBedtime(date: '2026-08-14');

      expect(client.calls, 1);
      expect(
        client.lastMessages!
            .singleWhere((message) => message.role == ModelMessageRole.system)
            .content,
        contains('从已有 sessions 补建缺失的 episode'),
      );
      expect(
        client.lastMessages!
            .singleWhere((message) => message.role == ModelMessageRole.user)
            .content,
        contains('晚饭吃了小馄饨，老板多送了两个。晚安。'),
      );
      expect(report.outcomes.single.status, FinalizationStatus.finalized);
      final day = await pipeline.readDay('2026-08-14');
      expect(day.finalized, isTrue);
      expect(day.entries, hasLength(1));
      expect(day.entries.single.requestId, 'small-1');
      expect(day.entries.single.summary, '用户晚饭吃了小馄饨，老板多送了两个');
    },
  );

  test('a backfilled episode entry carries the model keep mark', () async {
    DateTime clock() => DateTime(2026, 8, 14, 23, 30);
    final client = _RecordingUnderstandingClient(
      jsonEncode({
        'episode_entries': [
          {
            'request_id': 'keep-1',
            'summary': '用户认定长期记忆只放长远的事',
            'keep': 'month',
          },
          {
            'request_id': 'keep-2',
            'summary': '用户晚饭吃了小馄饨',
          },
        ],
        'covered_request_ids': ['keep-1', 'keep-2'],
        'summary': '用户聊了记忆偏好，晚饭吃了小馄饨',
        'index_keywords': ['记忆偏好'],
      }),
    );
    final (:temporaryDirectory, :pipeline, :service) =
        await _finalizationFixture(
          'qiyu-finalization-backfill-keep-test-',
          clock: clock,
          modelClient: client,
        );
    final repository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: clock,
    );
    var session = await repository.createSession();
    session = await repository.appendTurn(
      session,
      RawSessionTurn.user(
        requestId: 'keep-1',
        text: '长期记忆只放真正重要的事吧',
        at: clock(),
      ),
    );
    session = await repository.appendTurn(
      session,
      RawSessionTurn.user(
        requestId: 'keep-2',
        text: '晚饭吃了小馄饨',
        at: clock(),
      ),
    );
    final report = await service.finalizeForBedtime(date: '2026-08-14');

    expect(report.outcomes.single.status, FinalizationStatus.finalized);
    final day = await pipeline.readDay('2026-08-14');
    expect(day.entries, hasLength(2));
    expect(
      day.entries.firstWhere((entry) => entry.requestId == 'keep-1').keep,
      memorySignalKeepMonth,
    );
    expect(
      day.entries.firstWhere((entry) => entry.requestId == 'keep-2').keep,
      isNull,
    );
  });

  test('pure bedtime farewells stay out of the backfill scope', () async {
    DateTime clock() => DateTime(2026, 8, 22, 23, 50);
    final client = _RecordingUnderstandingClient(
      jsonEncode({
        'episode_entries': [
          {
            'request_id': 'tired-1',
            'summary': '用户实训第一天很累',
            'evidence': '今天实训第一天，累瘫了',
          },
        ],
        'covered_request_ids': ['tired-1'],
        'summary': '用户实训第一天很累，早早道了晚安',
        'index_keywords': ['实训', '晚安'],
      }),
    );
    final (:temporaryDirectory, :pipeline, :service) =
        await _finalizationFixture(
          'qiyu-finalization-pure-bedtime-test-',
          clock: clock,
          modelClient: client,
        );
    final repository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: clock,
    );
    var session = await repository.createSession();
    session = await repository.appendTurn(
      session,
      RawSessionTurn.user(
        requestId: 'tired-1',
        text: '今天实训第一天，累瘫了',
        at: clock(),
      ),
    );
    // 整轮只是道别：不产生记忆条目，也不进待补范围。
    session = await repository.appendTurn(
      session,
      RawSessionTurn.user(requestId: 'tired-2', text: '该睡了', at: clock()),
    );
    final report = await service.finalizeForBedtime(date: '2026-08-22');

    final userMessage = client.lastMessages!
        .singleWhere((message) => message.role == ModelMessageRole.user)
        .content;
    expect(userMessage, contains('今天实训第一天，累瘫了'));
    expect(userMessage, isNot(contains('该睡了')));
    // 待补清单只含实质轮次，纯道别轮不要求模型覆盖。
    expect(userMessage, isNot(contains('- tired-2')));
    expect(report.outcomes.single.status, FinalizationStatus.finalized);
    final day = await pipeline.readDay('2026-08-22');
    expect(day.entries, hasLength(1));
    expect(day.entries.single.requestId, 'tired-1');
  });

  test(
    'a turn that sanitizes to nothing never blocks the backfill gate',
    () async {
      DateTime clock() => DateTime(2026, 8, 22, 23, 50);
      final client = _RecordingUnderstandingClient(
        jsonEncode({
          'episode_entries': [
            {
              'request_id': 'real-1',
              'summary': '用户项目原型跑通',
              'evidence': '项目原型今天跑通了',
            },
          ],
          'covered_request_ids': ['real-1'],
          'summary': '用户项目原型跑通',
          'index_keywords': ['项目原型'],
        }),
      );
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-empty-sanitize-test-',
            clock: clock,
            modelClient: client,
          );
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: clock,
      );
      var session = await repository.createSession();
      session = await repository.appendTurn(
        session,
        RawSessionTurn.user(
          requestId: 'real-1',
          text: '项目原型今天跑通了',
          at: clock(),
        ),
      );
      // 纯控制字符的消息清洗后为空：消息侧不会发给模型，
      // pending 侧也绝不能把它算作待补，否则覆盖校验永久通不过。
      session = await repository.appendTurn(
        session,
        RawSessionTurn.user(
          requestId: 'junk-1',
          text: '\u0000',
          at: clock(),
        ),
      );
      final report = await service.finalizeForBedtime(date: '2026-08-22');

      expect(report.outcomes.single.status, FinalizationStatus.finalized);
      final day = await pipeline.readDay('2026-08-22');
      expect(day.entries, hasLength(1));
      expect(day.entries.single.requestId, 'real-1');
    },
  );

  test(
    'session backfill never sends controlled memory text to the model',
    () async {
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final client = _RecordingUnderstandingClient(
        jsonEncode({
          'covered_request_ids': ['controlled-1'],
        }),
      );
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-session-control-test-',
            clock: clock,
            modelClient: client,
          );
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: clock,
      );
      var session = await repository.createSession();
      session = await repository.appendTurn(
        session,
        RawSessionTurn.user(
          requestId: 'controlled-1',
          text: '医院检查',
          at: clock(),
        ),
      );
      await MemoryBanExecution(
        openLoopStore: OpenLoopStore(memoryDirectory: temporaryDirectory.path),
      ).execute('医院检查', origin: 'open-loop');
      final report = await service.finalizeForBedtime(date: '2026-08-14');

      final prompt = client.lastMessages!
          .map((message) => message.content)
          .join();
      expect(prompt, isNot(contains('医院检查')));
      expect(prompt, contains('[受记忆控制内容已隐藏]'));
      expect(report.outcomes.single.status, FinalizationStatus.finalizedEmpty);
      expect((await pipeline.readDay('2026-08-14')).entries, isEmpty);
    },
  );

  test(
    'incomplete session coverage stays pending for a later backfill',
    () async {
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final client = _RecordingUnderstandingClient(
        jsonEncode({
          'covered_request_ids': ['coverage-1'],
        }),
      );
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-session-coverage-test-',
            clock: clock,
            modelClient: client,
          );
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: clock,
      );
      var session = await repository.createSession();
      for (final (requestId, text) in [
        ('coverage-1', '午饭吃了米线。'),
        ('coverage-2', '回家路上买了葡萄。'),
      ]) {
        session = await repository.appendTurn(
          session,
          RawSessionTurn.user(requestId: requestId, text: text, at: clock()),
        );
      }
      final report = await service.finalizeForBedtime(date: '2026-08-14');

      expect(report.outcomes.single.status, FinalizationStatus.failed);
      expect((await pipeline.readDay('2026-08-14')).finalized, isFalse);
      expect(await pipeline.readCheckpoint(), isNull);
    },
  );

  test('extra hallucinated coverage ids no longer fail the backfill', () async {
    DateTime clock() => DateTime(2026, 8, 14, 23, 30);
    final droppedDiagnostics = <String>[];
    // 模型覆盖了全部真实轮次，但额外编造了一个不存在的 requestId。
    final client = _RecordingUnderstandingClient(
      jsonEncode({
        'episode_entries': [
          {'request_id': 'real-1', 'summary': '用户午饭吃了米线'},
          {'request_id': 'hallucinated-x', 'summary': '模型编造的内容'},
        ],
        'covered_request_ids': ['real-1', 'real-2', 'hallucinated-x'],
      }),
    );
    final (:temporaryDirectory, :pipeline, :service) =
        await _finalizationFixture(
          'qiyu-finalization-session-extra-test-',
          clock: clock,
          diagnosticsSink: droppedDiagnostics.add,
          modelClient: client,
        );
    final repository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: clock,
    );
    var session = await repository.createSession();
    for (final (requestId, text) in [
      ('real-1', '午饭吃了米线。'),
      ('real-2', '回家路上买了葡萄。'),
    ]) {
      session = await repository.appendTurn(
        session,
        RawSessionTurn.user(requestId: requestId, text: text, at: clock()),
      );
    }

    final report = await service.finalizeForBedtime(date: '2026-08-14');

    // 多报项只被丢弃，不再整体作废重试：归档照常完成，且只为真实
    // 轮次建条目。
    expect(report.outcomes.single.status, FinalizationStatus.finalized);
    expect(
      droppedDiagnostics.where((message) => message.contains('hallucinated-x')),
      isNotEmpty,
    );
    final day = await pipeline.readDay('2026-08-14');
    expect(day.finalized, isTrue);
    expect(
      day.entries.map((entry) => entry.requestId),
      unorderedEquals(['real-1']),
    );
  });

  test(
    'incremental backfill of an archived day keeps the old understanding',
    () async {
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final firstResponse = jsonEncode({
        'episode_entries': [
          {'request_id': 'day-1', 'summary': '用户开始养绿萝'},
        ],
        'covered_request_ids': ['day-1'],
        'summary': '第一天完整理解',
        'index_keywords': ['绿萝'],
        'active_items': ['第一次调用判断仍活跃的事'],
      });
      final secondResponse = jsonEncode({
        'episode_entries': [
          {'request_id': 'day-2', 'summary': '用户晚饭吃了米线'},
        ],
        'covered_request_ids': ['day-2'],
        // 增量调用即使返回了不同的整体字段，也不得覆盖已归档结论。
        'summary': '增量调用不应覆盖这个',
        'active_items': ['增量调用不应覆盖这个'],
      });
      final client = _RecordingUnderstandingClient(
        firstResponse,
        scriptedReplies: [firstResponse, secondResponse],
      );
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-incremental-backfill-test-',
            clock: clock,
            modelClient: client,
          );
      final repository = MarkdownMemoryRepository(
        memoryDirectory: temporaryDirectory.path,
        clock: clock,
      );
      var session = await repository.createSession();
      session = await repository.appendTurn(
        session,
        RawSessionTurn.user(requestId: 'day-1', text: '开始养绿萝了。', at: clock()),
      );

      // 第一次晚安：当天完整理解并归档。
      final firstReport = await service.finalizeForBedtime(date: '2026-08-14');
      expect(firstReport.outcomes.single.status, FinalizationStatus.finalized);

      // 归档后又聊了一轮，再次晚安触发增量补建。
      session = await repository.appendTurn(
        session,
        RawSessionTurn.user(requestId: 'day-2', text: '晚饭吃了米线。', at: clock()),
      );
      final secondReport = await service.finalizeForBedtime(date: '2026-08-14');
      expect(secondReport.outcomes.single.status, FinalizationStatus.finalized);
      expect(client.calls, 2);

      final day = await pipeline.readDay('2026-08-14');
      expect(day.finalized, isTrue);
      expect(day.entries.map((entry) => entry.requestId).toSet(), {
        'day-1',
        'day-2',
      });
      final understanding = day.understanding!;
      // 整体结论保留第一次归档的；覆盖清单合并两批。
      expect(understanding['summary'], '第一天完整理解');
      expect(understanding['activeItems'], ['第一次调用判断仍活跃的事']);
      expect((understanding['coveredRequestIds'] as List<Object?>).toSet(), {
        'day-1',
        'day-2',
      });
    },
  );

  test('catch-up never finalizes the still-active current day', () async {
    var now = DateTime(2026, 8, 13, 22);
    final (:temporaryDirectory, :pipeline, :service) =
        await _finalizationFixture(
          'qiyu-finalization-catchup-test-',
          clock: () => now,
        );
    await pipeline.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [MemorySignalAction(summary: '昨天的事')],
    );
    now = DateTime(2026, 8, 14, 9);
    await pipeline.processReply(
      session: _session('session-2', ['req-2']),
      requestId: 'req-2',
      hiddenActions: const [MemorySignalAction(summary: '今天的事')],
    );

    await service.catchUpUnfinalized(before: '2026-08-14');

    expect((await pipeline.readDay('2026-08-13')).finalized, isTrue);
    expect((await pipeline.readDay('2026-08-14')).finalized, isFalse);
  });

  test('startup catch-up includes session-only dates before today', () async {
    DateTime sessionClock() => DateTime(2026, 8, 14, 22, 30);
    final client = _RecordingUnderstandingClient(
      jsonEncode({
        'episode_entries': [
          {
            'request_id': 'yesterday-1',
            'summary': '用户看到楼下新开了一家花店',
            'evidence': '路过楼下时看到新开了一家花店。',
          },
        ],
        'covered_request_ids': ['yesterday-1'],
        'summary': '用户看到楼下新开了一家花店',
        'index_keywords': ['楼下', '花店'],
      }),
    );
    final (:temporaryDirectory, :pipeline, :service) =
        await _finalizationFixture(
          'qiyu-finalization-startup-session-test-',
          clock: () => DateTime(2026, 8, 15, 9),
          modelClient: client,
        );
    final repository = MarkdownMemoryRepository(
      memoryDirectory: temporaryDirectory.path,
      clock: sessionClock,
    );
    var session = await repository.createSession();
    session = await repository.appendTurn(
      session,
      RawSessionTurn.user(
        requestId: 'yesterday-1',
        text: '路过楼下时看到新开了一家花店。',
        at: sessionClock(),
      ),
    );

    final report = await service.catchUpUnfinalized(before: '2026-08-15');

    expect(client.calls, 1);
    expect(report.outcomes.single.status, FinalizationStatus.finalized);
    final day = await pipeline.readDay('2026-08-14');
    expect(day.finalized, isTrue);
    expect(day.entries.single.summary, '用户看到楼下新开了一家花店');
  });

  test(
    'catchUpUnfinalized preserves daily-state on the latest finalized date when earlier days are caught up',
    () async {
      var now = DateTime(2026, 8, 10, 22);
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-catchup-rebuild-test-',
            clock: () => now,
          );
      // Day 1: 2026-08-10 有条目，未定稿
      await pipeline.processReply(
        session: _session('session-10', ['req-10']),
        requestId: 'req-10',
        hiddenActions: const [MemorySignalAction(summary: '08-10 买了一束百合花')],
      );

      // Day 2: 2026-08-12 有条目，正常定稿
      now = DateTime(2026, 8, 12, 23);
      await pipeline.processReply(
        session: _session('session-12', ['req-12']),
        requestId: 'req-12',
        hiddenActions: const [MemorySignalAction(summary: '08-12 开始看一本书')],
      );
      final outcome12 = await service.finalizeDay('2026-08-12');
      expect(outcome12.status, FinalizationStatus.finalized);

      // 此时 daily-state.md 在 2026-08-12
      var dailyState = await File(
        '${temporaryDirectory.path}/daily-state.md',
      ).readAsString(encoding: utf8);
      expect(dailyState, contains('date: 2026-08-12'));

      // 启动补扫在 2026-08-13 触发
      now = DateTime(2026, 8, 13, 10);
      final report = await service.catchUpUnfinalized(before: '2026-08-13');
      expect(
        report.outcomes.firstWhere((o) => o.date == '2026-08-10').status,
        FinalizationStatus.finalized,
      );

      // daily-state.md 必须保持重建在最新定稿日 2026-08-12，绝不能倒退到 2026-08-10
      dailyState = await File(
        '${temporaryDirectory.path}/daily-state.md',
      ).readAsString(encoding: utf8);
      expect(dailyState, contains('date: 2026-08-12'));
      expect(dailyState, isNot(contains('date: 2026-08-10')));
    },
  );

  test(
    'a failed step keeps finalized false; retry completes without duplicates',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-finalization-failure-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: temporaryDirectory.path,
        clock: clock,
      );
      await pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [MemorySignalAction(summary: '用户在健身')],
      );
      final failingService = DailyFinalizationService(
        memoryDirectory: temporaryDirectory.path,
        episodePipeline: pipeline,
        clock: clock,
        atomicWriter: FailingAtomicTextWriter(
          shouldFail: (path) => path.contains('daily-state'),
        ),
      );

      await expectLater(
        failingService.finalizeDay('2026-08-14'),
        throwsA(
          isA<MemoryRepositoryException>().having(
            (error) => error.code,
            'code',
            'finalization_write_failed',
          ),
        ),
      );
      expect((await pipeline.readDay('2026-08-14')).finalized, isFalse);
      expect(
        File('${temporaryDirectory.path}/episodes/index.md').existsSync(),
        isFalse,
        reason: '索引是最后一步，失败前不得落盘',
      );

      final retryService = DailyFinalizationService(
        memoryDirectory: temporaryDirectory.path,
        episodePipeline: pipeline,
        clock: clock,
      );
      final retry = await retryService.finalizeDay('2026-08-14');

      expect(retry.status, FinalizationStatus.finalized);
      final day = await pipeline.readDay('2026-08-14');
      expect(day.finalized, isTrue);
      expect(day.entries, hasLength(1), reason: '补跑不得重复写入条目');
      expect(
        File('${temporaryDirectory.path}/episodes/index.md').existsSync(),
        isTrue,
      );
    },
  );

  test('a day without valid content never fabricates state pack files', () async {
    DateTime clock() => DateTime(2026, 8, 14, 23, 30);
    final (:temporaryDirectory, :pipeline, :service) =
        await _finalizationFixture(
          'qiyu-finalization-empty-test-',
          clock: clock,
        );

    // 没有 episode 文件的日期：归档直接跳过，不落任何文件。
    final missing = await service.finalizeDay('2026-08-14');
    expect(missing.status, FinalizationStatus.skippedMissing);
    expect(
      File('${temporaryDirectory.path}/daily-state.md').existsSync(),
      isFalse,
    );
    expect(
      File('${temporaryDirectory.path}/relationship.md').existsSync(),
      isFalse,
    );

    // 有日文件但没有效条目（例如全部动作都被敏感过滤）：只置标记，
    // 不写任何状态包，也不进索引。
    final dayPath = '${temporaryDirectory.path}/episodes/2026/08/2026-08-14.md';
    await File(dayPath).create(recursive: true);
    await File(dayPath).writeAsString(
      '# 栖语每日记录\n\n'
      '<!-- qiyu-episode:${base64Url.encode(utf8.encode(jsonEncode({'schemaVersion': 1, 'date': '2026-08-14', 'updatedAt': clock().toUtc().toIso8601String(), 'finalized': false}))).replaceAll('=', '')} -->\n',
      encoding: utf8,
    );

    final empty = await service.finalizeDay('2026-08-14');

    expect(empty.status, FinalizationStatus.finalizedEmpty);
    expect((await pipeline.readDay('2026-08-14')).finalized, isTrue);
    expect(
      File('${temporaryDirectory.path}/daily-state.md').existsSync(),
      isFalse,
    );
    expect(
      File('${temporaryDirectory.path}/episodes/index.md').existsSync(),
      isFalse,
    );
  });

  test(
    'closed open-loops are archived; active entries stay idempotently',
    () async {
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-openloops-test-',
            clock: clock,
          );
      await pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [MemorySignalAction(summary: '今天随便聊聊')],
      );
      File('${temporaryDirectory.path}/open-loops.md').writeAsStringSync(
        '# open-loops\n\n'
        '- [o1] 人生第一次演讲\n'
        '  due: 2026-08-13 evening\n'
        '  proactive: once\n'
        '  status: closed\n'
        '  note: 用户说演讲顺利结束\n'
        '- [o2] 医院检查\n'
        '  due: 2026-08-20\n'
        '  proactive: no\n'
        '  status: active\n'
        '  note: 用户主动提到时再接\n',
        encoding: utf8,
      );

      await service.finalizeDay('2026-08-14');

      final hotLayer = await File(
        '${temporaryDirectory.path}/open-loops.md',
      ).readAsString(encoding: utf8);
      expect(hotLayer, isNot(contains('人生第一次演讲')));
      expect(hotLayer, contains('- [o2] 医院检查'));
      final archive = await File(
        '${temporaryDirectory.path}/open-loops.archive.md',
      ).readAsString(encoding: utf8);
      expect(archive, contains('人生第一次演讲'));
      expect(archive, contains('闭环: 2026-08-14'));
      expect(archive, contains('用户说演讲顺利结束'));

      // 重复归档不得追加重复行。
      File(
        '${temporaryDirectory.path}/episodes/2026/08/2026-08-14.md',
      ).deleteSync();
      await pipeline.processReply(
        session: _session('session-1', ['req-2']),
        requestId: 'req-2',
        hiddenActions: const [MemorySignalAction(summary: '又过了一天')],
      );
      await service.finalizeDay('2026-08-14');
      final archiveAgain = await File(
        '${temporaryDirectory.path}/open-loops.archive.md',
      ).readAsString(encoding: utf8);
      expect('人生第一次演讲'.allMatches(archiveAgain).length, 1);
    },
  );

  test('an existing relationship file is never overwritten', () async {
    DateTime clock() => DateTime(2026, 8, 14, 23, 30);
    final (:temporaryDirectory, :pipeline, :service) =
        await _finalizationFixture(
          'qiyu-finalization-relationship-test-',
          clock: clock,
        );
    await pipeline.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [MemorySignalAction(summary: '聊了咖啡')],
    );
    const custom = '# relationship\n\nstage: 朋友\nsince: 2026-01-01\n';
    File(
      '${temporaryDirectory.path}/relationship.md',
    ).writeAsStringSync(custom, encoding: utf8);

    await service.finalizeDay('2026-08-14');

    expect(
      File(
        '${temporaryDirectory.path}/relationship.md',
      ).readAsStringSync(encoding: utf8),
      custom,
    );
  });

  test('daily-state respects the budget and the seven-day window', () async {
    var now = DateTime(2026, 8, 7, 22);
    final (:temporaryDirectory, :pipeline, :service) =
        await _finalizationFixture(
          'qiyu-finalization-budget-test-',
          clock: () => now,
        );
    // 窗口外的一天（8 天前）+ 窗口内 7 天，每天多条长摘要。
    await pipeline.processReply(
      session: _session('session-old', ['req-old']),
      requestId: 'req-old',
      hiddenActions: const [MemorySignalAction(summary: '窗口外不应出现的很旧很旧的事情')],
    );
    for (var dayOffset = 0; dayOffset < 7; dayOffset += 1) {
      now = DateTime(2026, 8, 8 + dayOffset, 22);
      await pipeline.processReply(
        session: _session('session-$dayOffset', ['req-$dayOffset']),
        requestId: 'req-$dayOffset',
        hiddenActions: [
          MemorySignalAction(
            summary:
                '第$dayOffset天发生的一件需要很长描述才能说清楚的事情，'
                '这里继续补充更多细节以撑大体积',
          ),
        ],
      );
    }

    await service.finalizeDay('2026-08-14');

    final dailyState = await File(
      '${temporaryDirectory.path}/daily-state.md',
    ).readAsString(encoding: utf8);
    expect(dailyState.runes.length, lessThanOrEqualTo(dailyStateMaxRunes));
    expect(dailyState, isNot(contains('窗口外不应出现')));
    expect(dailyState, contains('date: 2026-08-14'));
  });

  test(
    'a foreign day file is skipped untouched and does not block other days',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-finalization-foreign-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: temporaryDirectory.path,
        clock: clock,
      );
      const foreign = '# 用户手写的日记\n\n今天天气很好。\n';
      final foreignFile = File(
        '${temporaryDirectory.path}/episodes/2026/08/2026-08-13.md',
      );
      await foreignFile.create(recursive: true);
      await foreignFile.writeAsString(foreign, encoding: utf8);
      await pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [MemorySignalAction(summary: '正常的一天')],
      );
      final service = DailyFinalizationService(
        memoryDirectory: temporaryDirectory.path,
        episodePipeline: pipeline,
        clock: () => DateTime(2026, 8, 15, 8),
      );

      final report = await service.catchUpUnfinalized(before: '2026-08-15');

      expect(
        report.outcomes
            .firstWhere((outcome) => outcome.date == '2026-08-13')
            .status,
        FinalizationStatus.skippedUnreadable,
      );
      expect(
        await foreignFile.readAsString(encoding: utf8),
        foreign,
        reason: '无法识别的日文件绝不覆盖',
      );
      expect((await pipeline.readDay('2026-08-14')).finalized, isTrue);
    },
  );

  test(
    'indexes only list finalized days and survive re-finalization',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-finalization-index-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      var now = DateTime(2026, 7, 31, 22);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      await pipeline.processReply(
        session: _session('session-july', ['req-july']),
        requestId: 'req-july',
        hiddenActions: const [MemorySignalAction(summary: '七月最后一天')],
      );
      now = DateTime(2026, 8, 1, 22);
      await pipeline.processReply(
        session: _session('session-aug', ['req-aug']),
        requestId: 'req-aug',
        hiddenActions: const [MemorySignalAction(summary: '八月第一天')],
      );
      final service = DailyFinalizationService(
        memoryDirectory: temporaryDirectory.path,
        episodePipeline: pipeline,
        clock: () => DateTime(2026, 8, 2, 8),
      );

      // 只归档七月的天；八月的天保持未归档，不得进入索引。
      await service.finalizeDay('2026-07-31');

      final topIndex = await File(
        '${temporaryDirectory.path}/episodes/index.md',
      ).readAsString(encoding: utf8);
      expect(topIndex, contains('- 2026-07 |'));
      expect(topIndex, isNot(contains('2026-08')));
      final julyIndex = await File(
        '${temporaryDirectory.path}/episodes/2026/07/index.md',
      ).readAsString(encoding: utf8);
      expect(julyIndex, contains('七月最后一天'));

      await service.finalizeDay('2026-08-01');
      final rebuiltTop = await File(
        '${temporaryDirectory.path}/episodes/index.md',
      ).readAsString(encoding: utf8);
      expect(rebuiltTop, contains('- 2026-07 |'));
      expect(rebuiltTop, contains('- 2026-08 |'));
    },
  );

  test(
    'a new entry after bedtime reopens the day for re-finalization',
    () async {
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-reopen-test-',
            clock: clock,
          );
      await pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [MemorySignalAction(summary: '说了晚安')],
      );
      await service.finalizeDay('2026-08-14');
      expect((await pipeline.readDay('2026-08-14')).finalized, isTrue);

      // 用户说完晚安又回来补了一句：新条目使当天重新开放。
      await pipeline.processReply(
        session: _session('session-1', ['req-1', 'req-2']),
        requestId: 'req-2',
        hiddenActions: const [MemorySignalAction(summary: '又睡不着了')],
      );
      final reopened = await pipeline.readDay('2026-08-14');
      expect(reopened.finalized, isFalse);
      expect(reopened.entries, hasLength(2));

      final again = await service.finalizeDay('2026-08-14');
      expect(again.status, FinalizationStatus.finalized);
      final day = await pipeline.readDay('2026-08-14');
      expect(day.summary, contains('说了晚安'));
      expect(day.summary, contains('又睡不着了'));
    },
  );

  test(
    'end-of-day promotes candidates and repeated runs never duplicate',
    () async {
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture('qiyu-finalization-promote-test-', clock: clock);
      await pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [
          OpenLoopCandidateAction(
            title: '人生第一次演讲',
            due: '2026-08-20 晚上',
            evidence: '下周三是人生第一次演讲',
          ),
        ],
      );

      final outcome = await service.finalizeDay('2026-08-14');

      expect(outcome.status, FinalizationStatus.finalized);
      final loopsFile = File('${temporaryDirectory.path}/open-loops.md');
      var contents = await loopsFile.readAsString(encoding: utf8);
      expect(contents, contains('- [o1] 人生第一次演讲'));
      expect(contents, contains('due: 2026-08-20 晚上'));
      expect(contents, contains('proactive: once'));
      expect(contents, contains('status: active'));
      // 证据本体留在 episode：候选条目带类型与载荷。
      final day = await pipeline.readDay('2026-08-14');
      expect(day.entries.single.kind, episodeKindOpenLoopCandidate);
      expect(day.entries.single.evidence, '下周三是人生第一次演讲');

      // 晚安后用户又回来：同一候选重复日终不得重复提升。
      await pipeline.processReply(
        session: _session('session-1', ['req-1', 'req-2']),
        requestId: 'req-2',
        hiddenActions: const [OpenLoopCandidateAction(title: '人生第一次演讲')],
      );
      await service.finalizeDay('2026-08-14');
      contents = await loopsFile.readAsString(encoding: utf8);
      expect('人生第一次演讲'.allMatches(contents).length, 1);
    },
  );

  test(
    'end-of-day relationship step promotes once and replays stay stable',
    () async {
      var now = DateTime(2026, 8, 1, 22);
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture(
            'qiyu-finalization-relationship-test-',
            clock: () => now,
          );
      // 三个活跃日 + 一次深谈：证据够到熟悉。
      for (var day = 1; day <= 3; day += 1) {
        now = DateTime(2026, 8, day, 22);
        await pipeline.processReply(
          session: _session('session-$day', ['req-$day']),
          requestId: 'req-$day',
          hiddenActions: [
            const MemorySignalAction(summary: '聊了日常'),
            if (day == 2)
              const RelationshipSignalAction(
                signal: RelationshipSignal.deepTalk,
                summary: '用户愿意聊到更深的工作困扰',
              ),
          ],
        );
      }
      now = DateTime(2026, 8, 3, 22);
      final relationshipFile = File(
        '${temporaryDirectory.path}/relationship.md',
      );

      // 补扫三个旧日都在同一自然日执行：只允许升级一次。
      await service.finalizeDay('2026-08-01');
      await service.finalizeDay('2026-08-02');
      await service.finalizeDay('2026-08-03');
      var contents = await relationshipFile.readAsString(encoding: utf8);
      expect(contents, contains('stage: 熟悉'));
      expect(contents, contains('用户愿意聊到更深的工作困扰'));

      // 重复日终：阶段不回退也不重复升级。
      await service.finalizeDay('2026-08-03');
      contents = await relationshipFile.readAsString(encoding: utf8);
      expect(contents, contains('stage: 熟悉'));
    },
  );

  test(
    'banned matters are never re-promoted by later end-of-day runs',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-finalization-ban-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      var now = DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
      final service = DailyFinalizationService(
        memoryDirectory: temporaryDirectory.path,
        episodePipeline: pipeline,
        openLoopStore: store,
        clock: () => now,
      );
      await pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [
          OpenLoopCandidateAction(title: '医院检查', proactive: LoopProactive.no),
        ],
      );
      await service.finalizeDay('2026-08-14');
      expect(await store.readItems(), hasLength(1));

      // 用户要求不再提：立即禁提并移出手层。
      await MemoryBanExecution(openLoopStore: store)
          .execute('医院检查', origin: 'open-loop');
      expect(await store.readItems(), isEmpty);

      // 次日模型再次提出同一事项：日终不得重新激活。
      now = DateTime(2026, 8, 15, 22);
      await pipeline.processReply(
        session: _session('session-2', ['req-2']),
        requestId: 'req-2',
        hiddenActions: const [OpenLoopCandidateAction(title: '医院检查')],
      );
      await service.finalizeDay('2026-08-15');
      expect(await store.readItems(), isEmpty);
      final controls = await File(
        '${temporaryDirectory.path}/memory-controls.md',
      ).readAsString(encoding: utf8);
      expect(controls, contains('医院检查'));
    },
  );

  test(
    'end-of-day archives loops that expired without any follow-up',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-finalization-expiry-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final now = DateTime(2026, 8, 16, 22);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
      await store.promoteCandidates([
        EpisodeEntry(
          id: 'seed:1:0',
          sessionId: 'seed',
          requestId: 'seed',
          summary: '早已过期的大事',
          at: DateTime(2026, 7, 1).toUtc(),
          kind: episodeKindOpenLoopCandidate,
          due: '2026-07-01',
        ),
      ]);
      await pipeline.processReply(
        session: _session('session-1', ['req-1']),
        requestId: 'req-1',
        hiddenActions: const [MemorySignalAction(summary: '普通的一天')],
      );
      final service = DailyFinalizationService(
        memoryDirectory: temporaryDirectory.path,
        episodePipeline: pipeline,
        openLoopStore: store,
        clock: () => now,
      );

      await service.finalizeDay('2026-08-16');

      expect(await store.readItems(), isEmpty);
      final archive = await File(
        '${temporaryDirectory.path}/open-loops.archive.md',
      ).readAsString(encoding: utf8);
      expect(archive, contains('- 早已过期的大事 | 闭环: 2026-08-16 | 过期'));
    },
  );

  test(
    'system bookkeeping entries stay out of summaries, state pack and indexes',
    () async {
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final (:temporaryDirectory, :pipeline, :service) =
          await _finalizationFixture('qiyu-finalization-bookkeeping-test-', clock: clock);
      await pipeline.processReply(
        session: _session('session-1', ['req-1', 'req-2']),
        requestId: 'req-1',
        hiddenActions: const [
          MemorySignalAction(summary: '聊了周末的安排'),
          OpenLoopStatusAction(
            title: '人生第一次演讲',
            status: LoopStatus.closed,
            result: '用户说演讲很顺利',
          ),
        ],
      );
      await pipeline.processReply(
        session: _session('session-1', ['req-1', 'req-2']),
        requestId: 'req-2',
        hiddenActions: const [
          MemoryBanAction(title: '医院检查'),
          RelationshipSignalAction(
            signal: RelationshipSignal.deepTalk,
            summary: '用户愿意聊到更深的家庭关系',
          ),
        ],
      );

      final outcome = await service.finalizeDay('2026-08-14');

      expect(outcome.status, FinalizationStatus.finalized);
      final day = await pipeline.readDay('2026-08-14');
      // 簿记条目仍留在 episode 里供追溯。
      expect(
        day.entries.where((entry) => entry.kind == episodeKindOpenLoopEvent),
        hasLength(2),
      );
      expect(
        day.entries.where(
          (entry) => entry.kind == episodeKindRelationshipSignal,
        ),
        hasLength(1),
      );
      // 但摘要只复述真实记忆条目。
      expect(day.summary, contains('聊了周末的安排'));
      expect(day.summary, isNot(contains('Open-loop 状态')));
      expect(day.summary, isNot(contains('禁提')));
      // 近日状态包与索引同样不得带回簿记文字（含禁提标题）。
      final dailyState = await File(
        '${temporaryDirectory.path}/daily-state.md',
      ).readAsString(encoding: utf8);
      expect(dailyState, contains('聊了周末的安排'));
      expect(dailyState, isNot(contains('Open-loop 状态')));
      expect(dailyState, isNot(contains('禁提')));
      final monthIndex = await File(
        '${temporaryDirectory.path}/episodes/2026/08/index.md',
      ).readAsString(encoding: utf8);
      expect(monthIndex, contains('聊了周末的安排'));
      expect(monthIndex, isNot(contains('Open-loop 状态')));
      expect(monthIndex, isNot(contains('禁提')));
      // 关系证据也不走通用投影。
      expect(day.summary, isNot(contains('家庭关系')));
      expect(dailyState, isNot(contains('家庭关系')));
      expect(monthIndex, isNot(contains('家庭关系')));
      // 它唯一的去处是 relationship.md 的近期变化。
      final relationship = await File(
        '${temporaryDirectory.path}/relationship.md',
      ).readAsString(encoding: utf8);
      expect(relationship, contains('用户愿意聊到更深的家庭关系'));
    },
  );
}

/// 建临时目录并装配 episode 管线与日终服务：成员沿用用例原变量名。
/// 装配形态不同的用例（双时钟、双服务、外部 openLoopStore）不迁移。
Future<({
  Directory temporaryDirectory,
  EpisodeMemoryPipeline pipeline,
  DailyFinalizationService service,
})> _finalizationFixture(
  String tempPrefix, {
  required DateTime Function() clock,
  ProviderChatClient? modelClient,
  void Function(String message)? diagnosticsSink,
}) async {
  final temporaryDirectory = await Directory.systemTemp.createTemp(tempPrefix);
  addTearDown(() => temporaryDirectory.delete(recursive: true));
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: temporaryDirectory.path,
    clock: clock,
  );
  final service = DailyFinalizationService(
    memoryDirectory: temporaryDirectory.path,
    episodePipeline: pipeline,
    modelClient: modelClient,
    diagnosticsSink: diagnosticsSink,
    clock: clock,
  );
  return (
    temporaryDirectory: temporaryDirectory,
    pipeline: pipeline,
    service: service,
  );
}

Map<String, String> _snapshotStateFiles(String root) {
  final snapshot = <String, String>{};
  for (final relative in [
    'daily-state.md',
    'relationship.md',
    'open-loops.md',
    'open-loops.archive.md',
    'episodes/index.md',
    'episodes/2026/08/index.md',
    'episodes/2026/08/2026-08-14.md',
  ]) {
    final file = File('$root/$relative');
    if (file.existsSync()) {
      snapshot[relative] = file.readAsStringSync(encoding: utf8);
    }
  }
  return snapshot;
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

final class _RecordingUnderstandingClient implements ProviderChatClient {
  _RecordingUnderstandingClient(this.reply, {List<String>? scriptedReplies})
    : _scriptedReplies = scriptedReplies ?? const [];

  final String reply;
  final List<String> _scriptedReplies;
  int calls = 0;
  List<ModelMessage>? lastMessages;

  @override
  Future<ModelCompletion?> complete(
    List<ModelMessage> messages, {
    int? maxTokens,
  }) async {
    calls += 1;
    lastMessages = messages;
    if (_scriptedReplies.isNotEmpty) {
      return ModelCompletion.reply(_scriptedReplies.removeAt(0));
    }
    return ModelCompletion.reply(reply);
  }
}
