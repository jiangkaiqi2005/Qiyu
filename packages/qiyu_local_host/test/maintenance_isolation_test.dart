import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/in_process_chat_host.dart';

void main() {
  group('维护独占边界（Host 端到端）', () {
    DateTime clock() => DateTime(2026, 8, 11, 22, 30);

    /// 起一个脚本化 Provider 的 Host：第一轮回复不分段（无停顿），
    /// 第二轮回复足够长、必然停在两段之间。返回的 [pauseReached] 在
    /// 交付真正停进分段停顿时置位（NDJSON 响应整体缓冲，客户端看不到
    /// 中途事件，只能用服务端接缝定位时机），此时栖语回复尚未落盘；
    /// [gate] 放行让交付走完。
    Future<(InProcessChatHost, Completer<void>, Completer<void>)>
    startGatedHost() async {
      final gate = Completer<void>();
      final pauseReached = Completer<void>();
      final gateway = ScriptedModelGateway(
        streamScript: const [
          ScriptedStreamReply('早些休息。'),
          ScriptedStreamReply('这周末的安排听起来不错，慢慢来就好。'),
        ],
      );
      final harness = await InProcessChatHost.start(
        modelGateway: gateway,
        clock: clock,
        deliveryPause: (_) {
          if (!pauseReached.isCompleted) {
            pauseReached.complete();
          }
          return gate.future;
        },
      );
      addTearDown(harness.dispose);
      return (harness, gate, pauseReached);
    }

    /// 红灯与绿灯共用的时序钉子：红灯下维护请求立即完成（先写盘，再
    /// 放行半途聊天，写入顺序被钉死）；绿灯下维护排在交付后面、在门
    /// 放开前不可能完成，超时兜底先放行交付再等维护。
    Future<T> releaseGateAfterMaintenanceSettles<T>(
      Completer<void> gate,
      Future<T> maintenancePending,
    ) async {
      final result = await maintenancePending.timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          gate.complete();
          return maintenancePending;
        },
      );
      if (!gate.isCompleted) {
        gate.complete();
      }
      return result;
    }

    test('导入等待在途聊天落盘完成，恢复结果不被旧会话写回', () async {
      final (harness, gate, pauseReached) = await startGatedHost();

      // 第一轮完整交付：会话文件里只有第一轮的两条记录。
      final first = await harness.sendChat(requestId: 'r0', text: '今天有点累');
      expect(first.statusCode, HttpStatus.ok);
      final sessionId = first.sessionId;

      // 第一轮落定后导出备份：包内会话同样只有第一轮。
      final (exportStatus, bundle) = await harness.getBytes(
        '/api/backup/export',
      );
      expect(exportStatus, HttpStatus.ok);

      // 第二轮交付停在分段停顿半途：栖语回复还没落盘。
      final second = harness.openChat(
        requestId: 'r1',
        text: '周末想去爬山',
        sessionId: sessionId,
      );
      await pauseReached.future;

      final importPending = harness.postJson('/api/backup/import', {
        'dataBase64': base64.encode(bundle),
      });
      await releaseGateAfterMaintenanceSettles(gate, importPending);
      await second.done;
      final imported = await importPending;
      expect(imported.statusCode, HttpStatus.ok);
      final importJson = jsonDecode(imported.body) as Map<String, Object?>;

      // 导入必须在半途聊天完整落盘之后才执行：导入自带的导入前快照
      // 捕到的会话必须包含栖语回复。红灯下导入不等在途交付，快照里
      // 只有半途状态。
      final snapshotId = importJson['snapshotId']! as String;
      final snapshotSession = File(
        '${harness.memoryDirectory}${Platform.pathSeparator}backups'
        '${Platform.pathSeparator}$snapshotId${Platform.pathSeparator}sessions'
        '${Platform.pathSeparator}2026${Platform.pathSeparator}08'
        '${Platform.pathSeparator}2026-08-11-001.md',
      );
      expect(snapshotSession.readAsStringSync(), contains('慢慢来就好'));

      // 会话冲突策略保持不变：同名原始会话两边内容不同时保留本机版本。
      final session = await harness.storedSession(sessionId);
      expect(session.turns.map((turn) => turn.requestId), [
        'r0',
        'r0',
        'r1',
        'r1',
      ]);
    });

    test('回滚等待在途聊天落盘完成，恢复结果不被半途回复覆盖', () async {
      final (harness, gate, pauseReached) = await startGatedHost();

      // 先产生会话并导出导入一次：导入会在写入前创建可回滚快照。
      final first = await harness.sendChat(requestId: 'r0', text: '今天有点累');
      expect(first.statusCode, HttpStatus.ok);
      final sessionId = first.sessionId;
      final (exportStatus, bundle) = await harness.getBytes(
        '/api/backup/export',
      );
      expect(exportStatus, HttpStatus.ok);
      final seeded = await harness.postJson('/api/backup/import', {
        'dataBase64': base64.encode(bundle),
      });
      expect(seeded.statusCode, HttpStatus.ok);

      // 第二轮交付停在半途，然后回滚到导入前的快照（同样只有第一轮）。
      final second = harness.openChat(
        requestId: 'r1',
        text: '周末想去爬山',
        sessionId: sessionId,
      );
      await pauseReached.future;

      final rollbackPending = harness.postJson('/api/backup/rollback', {});
      await releaseGateAfterMaintenanceSettles(gate, rollbackPending);
      await second.done;
      final rolledBack = await rollbackPending;
      expect(rolledBack.statusCode, HttpStatus.ok);

      // 回滚是最后写入者：半途交付不允许把快照里已删掉的轮次带回来。
      final session = await harness.storedSession(sessionId);
      expect(session.turns.map((turn) => turn.requestId), ['r0', 'r0']);
    });

    test('一致性导出等待在途聊天完成，备份不混入半途交付', () async {
      final (harness, gate, pauseReached) = await startGatedHost();

      final first = await harness.sendChat(requestId: 'r0', text: '今天有点累');
      expect(first.statusCode, HttpStatus.ok);
      final sessionId = first.sessionId;

      final second = harness.openChat(
        requestId: 'r1',
        text: '周末想去爬山',
        sessionId: sessionId,
      );
      await pauseReached.future;

      final exportPending = harness.getBytes('/api/backup/export');
      await releaseGateAfterMaintenanceSettles(gate, exportPending);
      await second.done;
      final (status, bytes) = await exportPending;
      expect(status, HttpStatus.ok);

      // 导出在聊天落盘之后进行：包内会话包含完整的第二轮回复。
      final archive = ZipDecoder().decodeBytes(bytes);
      final sessionEntry = archive.files.singleWhere(
        (file) => file.name.endsWith('sessions/2026/08/2026-08-11-001.md'),
      );
      expect(utf8.decode(sessionEntry.content as List<int>), contains('慢慢来就好'));
    });
  });

  group('维护独占边界（服务公共接口）', () {
    late Directory rootDirectory;
    late String memoryDirectory;
    late List<String> diagnostics;

    setUp(() async {
      rootDirectory = await Directory.systemTemp.createTemp(
        'qiyu-maintenance-isolation-test-',
      );
      memoryDirectory =
          '${rootDirectory.path}${Platform.pathSeparator}memories';
      await Directory(memoryDirectory).create(recursive: true);
      diagnostics = [];
      addTearDown(() {
        if (rootDirectory.existsSync()) {
          rootDirectory.deleteSync(recursive: true);
        }
      });
    });

    DateTime clock() => DateTime(2026, 8, 12, 9);

    Future<void> seedUnfinalizedDay(String date, String summary) {
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: () => DateTime.parse('${date}T22:00:00'),
      );
      return pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          date,
          entries: [
            EpisodeEntry(
              id: 'seed:1:0',
              sessionId: 'seed',
              requestId: 'seed',
              summary: summary,
              at: DateTime.parse('${date}T21:00:00').toUtc(),
            ),
          ],
          summary: summary,
          finalized: false,
        ),
      );
    }

    test('维护独占期间空闲补办不插队，恢复调度后未完成整理可补办', () async {
      await seedUnfinalizedDay('2026-08-10', '用户聊了周末的安排');
      final fixture = await _BoundaryFixture.build(
        memoryDirectory: memoryDirectory,
        clock: clock,
        diagnostics: diagnostics,
      );

      final opEntered = Completer<void>();
      final releaseOp = Completer<void>();
      final exclusive = fixture.service.runExclusively(() async {
        opEntered.complete();
        await releaseOp.future;
      });
      await opEntered.future;

      // 维护独占期间拨 tick：积压补办必须让路，不得插到维护前面执行。
      await fixture.cadence.pollTick();
      await fixture.cadence.finalizePending();
      final reader = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: clock,
      );
      expect((await reader.readDay('2026-08-10')).finalized, isFalse);

      releaseOp.complete();
      await exclusive;

      // 恢复调度：维护期间跳过的当次补办在下一次 tick 补齐，不丢。
      await fixture.cadence.pollTick();
      await fixture.cadence.finalizePending();
      expect((await reader.readDay('2026-08-10')).finalized, isTrue);
    });

    test('维护抛异常后释放独占状态，后续维护与空闲补办恢复正常', () async {
      await seedUnfinalizedDay('2026-08-10', '用户聊了周末的安排');
      final fixture = await _BoundaryFixture.build(
        memoryDirectory: memoryDirectory,
        clock: clock,
        diagnostics: diagnostics,
      );

      await expectLater(
        fixture.service.runExclusively(() async => throw StateError('维护失败')),
        throwsStateError,
      );

      // 失败不卡死调度：空闲补办重新排程，积压整理照常补齐。
      await fixture.cadence.pollTick();
      await fixture.cadence.finalizePending();
      final reader = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: clock,
      );
      expect((await reader.readDay('2026-08-10')).finalized, isTrue);

      // 后续维护请求可正常进入独占槽。
      var ran = false;
      await fixture.service.runExclusively(() async {
        ran = true;
      });
      expect(ran, isTrue);
    });

    test('维护期间新聊天排队等待，维护结束后正常交付', () async {
      final fixture = await _BoundaryFixture.build(
        memoryDirectory: memoryDirectory,
        clock: clock,
        diagnostics: diagnostics,
      );

      final opEntered = Completer<void>();
      final releaseOp = Completer<void>();
      final exclusive = fixture.service.runExclusively(() async {
        opEntered.complete();
        await releaseOp.future;
      });
      await opEntered.future;

      final received = <ChatDeliveryEvent>[];
      final deliveryDone = fixture.service
          .deliver(requestId: 'during-1', text: '在吗')
          .listen(received.add)
          .asFuture<void>();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // 维护独占期间新聊天排队：不产生任何交付事件，也不写会话。
      expect(received, isEmpty);

      releaseOp.complete();
      await exclusive;
      await deliveryDone;
      expect(
        received.map((event) => event.kind),
        contains(ChatDeliveryEventKind.done),
      );

      final session = await fixture.service.history();
      expect(session, isNotNull);
      final stored = await MarkdownMemoryRepository(
        memoryDirectory: memoryDirectory,
        clock: clock,
      ).openSession();
      expect(stored.turns.map((turn) => turn.speaker), [
        Speaker.user,
        Speaker.qiyu,
      ]);
    });

    test('并发维护请求串行排队，不互相覆盖', () async {
      final fixture = await _BoundaryFixture.build(
        memoryDirectory: memoryDirectory,
        clock: clock,
        diagnostics: diagnostics,
      );

      final log = <String>[];
      final release = Completer<void>();
      final first = fixture.service.runExclusively(() async {
        log.add('first-start');
        await release.future;
        log.add('first-end');
      });
      final second = fixture.service.runExclusively(() async {
        log.add('second');
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(log, ['first-start']);

      release.complete();
      await first;
      await second;
      expect(log, ['first-start', 'first-end', 'second']);
    });
  });
}

/// 服务级夹具：真实聊天服务与记忆节奏接在同一条交付串行链与空闲补办
/// 轮询信号上，与组合根装配同构。
final class _BoundaryFixture {
  _BoundaryFixture(this.service, this.cadence);

  final LocalChatService service;
  final MemoryCadence cadence;

  static Future<_BoundaryFixture> build({
    required String memoryDirectory,
    required DateTime Function() clock,
    required List<String> diagnostics,
  }) async {
    LocalChatService? wiredService;
    final cadence = MemoryCadence(
      providerPort: const _PreparedProviderPort(),
      dailyFinalization: DailyFinalizationService(
        memoryDirectory: memoryDirectory,
        episodePipeline: EpisodeMemoryPipeline(
          memoryDirectory: memoryDirectory,
          clock: clock,
        ),
        clock: clock,
      ),
      isDeliveryBusy: () => wiredService?.hasActiveDeliveries ?? false,
      clock: clock,
      diagnosticsSink: diagnostics.add,
    );
    final service = LocalChatService(
      MarkdownMemoryRepository(memoryDirectory: memoryDirectory, clock: clock),
      memoryCadence: cadence,
      clock: clock,
      deliveryPause: (_) async {},
      diagnosticsSink: diagnostics.add,
    );
    wiredService = service;
    await service.initialize();
    return _BoundaryFixture(service, cadence);
  }
}

/// 轮询 tick 的 Provider 端假件：让待办检测照常进行，与
/// memory_cadence_test 的同名假件同构。
final class _PreparedProviderPort implements ProviderChatPort {
  const _PreparedProviderPort();

  @override
  Future<PreparedProviderChatRequest?> prepareChatRequest() async =>
      PreparedProviderChatRequest(
        hardRulesAddendum: '',
        openStream: (messages, whenCancelled) async => null,
      );
}
