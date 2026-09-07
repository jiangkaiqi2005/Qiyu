import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

import 'support/dream_state_fixture.dart';
import 'support/failing_atomic_writer.dart';

void main() {
  group('记忆节奏', () {
    late Directory rootDirectory;
    late String memoryDirectory;
    late List<String> diagnostics;

    setUp(() async {
      rootDirectory = await Directory.systemTemp.createTemp(
        'qiyu-memory-cadence-test-',
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

    test(
      'startup chain finalizes before monthly compression and survives failures',
      () async {
        var failWrites = true;
        final failingWriter = FailingAtomicTextWriter(
          shouldFail: (_) => failWrites,
        );
        // 播种用正常写入器；节奏链用失败写入器（同目录先后使用，不并发）。
        final seedPipeline = EpisodeMemoryPipeline(
          memoryDirectory: memoryDirectory,
          clock: () => DateTime(2026, 8, 10, 22),
        );
        await _seedEpisodeDay(
          seedPipeline,
          '2026-08-10',
          summary: '用户完成了演讲',
          finalized: false,
        );
        await _seedEpisodeDay(
          seedPipeline,
          '2026-07-02',
          summary: '用户聊了搬家的计划',
          finalized: true,
        );
        final cadencePipeline = EpisodeMemoryPipeline(
          memoryDirectory: memoryDirectory,
          clock: () => DateTime(2026, 8, 12, 9),
          atomicWriter: failingWriter,
        );
        final cadence = MemoryCadence(
          dailyFinalization: DailyFinalizationService(
            memoryDirectory: memoryDirectory,
            episodePipeline: cadencePipeline,
            clock: () => DateTime(2026, 8, 12, 9),
            atomicWriter: failingWriter,
          ),
          monthlySummary: MonthlySummaryStore(
            memoryDirectory: memoryDirectory,
            episodePipeline: cadencePipeline,
            atomicWriter: failingWriter,
            diagnosticsSink: diagnostics.add,
          ),
          clock: () => DateTime(2026, 8, 12, 9),
          diagnosticsSink: diagnostics.add,
        );

        // 启动入口（组合根直调）：失败只记诊断，绝不外抛阻塞。
        cadence.initialize();
        await cadence.finalizePending();

        final startupIndex = diagnostics.indexWhere(
          (line) => line.contains('reason=startup'),
        );
        final monthlyIndex = diagnostics.indexWhere(
          (line) => line.contains('monthly compression deferred ['),
        );
        expect(startupIndex, isNonNegative, reason: '写入被拦时启动补扫记诊断');
        expect(monthlyIndex, isNonNegative, reason: '写入被拦时月压缩记诊断');
        // 先后顺序：补日终在月压缩之前（同一条串行链）。
        expect(startupIndex < monthlyIndex, isTrue);
        final reader = EpisodeMemoryPipeline(
          memoryDirectory: memoryDirectory,
          clock: () => DateTime(2026, 8, 12, 9),
        );
        expect((await reader.readDay('2026-08-10')).finalized, isFalse);

        // 放开写入器：下一个触发点把积压补齐——失败没有堵死链。
        failWrites = false;
        cadence.onDeliveryComplete(bedtime: false);
        await cadence.finalizePending();

        expect((await reader.readDay('2026-08-10')).finalized, isTrue);
        expect(
          MonthlySummaryStore(
            memoryDirectory: memoryDirectory,
            episodePipeline: reader,
          ).summaryFile('2026-07').existsSync(),
          isTrue,
        );
      },
    );

    test('bedtime hook marks dream pending and archives the day', () async {
      DateTime clock() => DateTime(2026, 8, 11, 22, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: clock,
      );
      await _seedEpisodeDay(
        pipeline,
        '2026-08-11',
        summary: '用户说今天很累',
        finalized: false,
      );
      final dream = DreamService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        clock: clock,
      );
      final cadence = MemoryCadence(
        dailyFinalization: DailyFinalizationService(
          memoryDirectory: memoryDirectory,
          episodePipeline: pipeline,
          clock: clock,
        ),
        dreamService: dream,
        clock: clock,
        diagnosticsSink: diagnostics.add,
      );

      cadence.onDeliveryComplete(bedtime: true);
      await cadence.finalizePending();

      // 晚安预登记落在链最前：进程随后退出也能由下次启动补跑兑现。
      expect((await dream.readState()).pending, isTrue);
      expect((await pipeline.readDay('2026-08-11')).finalized, isTrue);
      expect(diagnostics.where((line) => line.contains('deferred')), isEmpty);
    });

    test('date-change hook fires once per natural day', () async {
      var now = DateTime(2026, 8, 11, 23, 50);
      var failWrites = true;
      final failingWriter = FailingAtomicTextWriter(
        shouldFail: (_) => failWrites,
      );
      final seedPipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: () => DateTime(2026, 8, 10, 22),
      );
      await _seedEpisodeDay(
        seedPipeline,
        '2026-08-10',
        summary: '用户聊了周末的安排',
        finalized: false,
      );
      final cadencePipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: () => now,
        atomicWriter: failingWriter,
      );
      final cadence = MemoryCadence(
        dailyFinalization: DailyFinalizationService(
          memoryDirectory: memoryDirectory,
          episodePipeline: cadencePipeline,
          clock: () => now,
          atomicWriter: failingWriter,
        ),
        clock: () => now,
        diagnosticsSink: diagnostics.add,
      );

      cadence.onDeliveryComplete(bedtime: false);
      await cadence.finalizePending();
      // 同一天再交付：日期没变，不重复触发。
      cadence.onDeliveryComplete(bedtime: false);
      await cadence.finalizePending();
      expect(
        diagnostics.where((line) => line.contains('reason=date-change')),
        hasLength(1),
      );

      now = DateTime(2026, 8, 12, 8);
      cadence.onDeliveryComplete(bedtime: false);
      await cadence.finalizePending();
      expect(
        diagnostics.where((line) => line.contains('reason=date-change')),
        hasLength(2),
      );
    });

    test(
      'idle poll yields to busy delivery and accounts daily attempts',
      () async {
        var busy = false;
        var failWrites = true;
        final failingWriter = FailingAtomicTextWriter(
          shouldFail: (_) => failWrites,
        );
        final seedPipeline = EpisodeMemoryPipeline(
          memoryDirectory: memoryDirectory,
          clock: () => DateTime(2026, 7, 2, 22),
        );
        await _seedEpisodeDay(
          seedPipeline,
          '2026-07-02',
          summary: '用户完成了演讲',
          finalized: true,
        );
        final cadencePipeline = EpisodeMemoryPipeline(
          memoryDirectory: memoryDirectory,
          clock: () => DateTime(2026, 8, 12, 9),
          atomicWriter: failingWriter,
        );
        final summaryStore = MonthlySummaryStore(
          memoryDirectory: memoryDirectory,
          episodePipeline: cadencePipeline,
          atomicWriter: failingWriter,
          diagnosticsSink: diagnostics.add,
        );
        final cadence = MemoryCadence(
          providerPort: const _PreparedProviderPort(),
          dailyFinalization: DailyFinalizationService(
            memoryDirectory: memoryDirectory,
            episodePipeline: cadencePipeline,
            clock: () => DateTime(2026, 8, 12, 9),
            atomicWriter: failingWriter,
          ),
          monthlySummary: summaryStore,
          isDeliveryBusy: () => busy,
          clock: () => DateTime(2026, 8, 12, 9),
          diagnosticsSink: diagnostics.add,
        );

        // 在途交付：让路且不排程。
        busy = true;
        await cadence.pollTick();
        await cadence.finalizePending();
        expect(
          diagnostics.join('\n'),
          contains('idle catchup skipped reason=busy-delivery'),
        );
        expect(
          diagnostics.join('\n'),
          isNot(contains('idle catchup scheduled')),
        );
        busy = false;

        // 三次失败尝试后放开写入器：成功清零计数。
        for (var attempt = 0; attempt < 3; attempt += 1) {
          await cadence.pollTick();
          await cadence.finalizePending();
        }
        failWrites = false;
        await cadence.pollTick();
        await cadence.finalizePending();
        expect(
          diagnostics.join('\n'),
          contains('idle catchup done status=ok items=monthly-compression'),
        );
        expect(summaryStore.summaryFile('2026-07').existsSync(), isTrue);

        // 再次制造积压：清零后的配额允许完整再试 10 轮，第 11 轮闸住。
        failWrites = true;
        summaryStore.summaryFile('2026-07').deleteSync();
        for (var attempt = 0; attempt < 10; attempt += 1) {
          await cadence.pollTick();
          await cadence.finalizePending();
        }
        await cadence.pollTick();
        await cadence.finalizePending();
        final scheduled = diagnostics
            .where((line) => line.contains('idle catchup scheduled'))
            .length;
        // 3 次失败 + 1 次成功 + 10 次失败；若成功未清零则不足 14 次。
        expect(scheduled, 14);
        expect(
          diagnostics.join('\n'),
          contains(
            'idle catchup blocked item=monthly-compression reason=daily-limit',
          ),
        );
      },
    );

    test(
      'dream eligibility misses never consume the daily attempt budget',
      () async {
        DateTime clock() => DateTime(2026, 8, 11, 22, 30);
        final pipeline = EpisodeMemoryPipeline(
          memoryDirectory: memoryDirectory,
          clock: clock,
        );
        await _seedEpisodeDay(
          pipeline,
          '2026-08-05',
          summary: '用户说周末要去爬山',
          finalized: true,
        );
        await _seedPendingDream(
          memoryDirectory,
          lastSuccess: DateTime(2026, 8, 1),
        );
        // 未配置模型客户端：Dream 整体跳过（skippedNoProvider）。
        final cadence = MemoryCadence(
          providerPort: const _PreparedProviderPort(),
          dreamService: DreamService(
            memoryDirectory: memoryDirectory,
            episodePipeline: pipeline,
            clock: clock,
          ),
          clock: clock,
          diagnosticsSink: diagnostics.add,
        );

        for (var attempt = 0; attempt < 12; attempt += 1) {
          await cadence.pollTick();
          await cadence.finalizePending();
        }

        // 资格不符不是真正的补跑尝试：12 次轮询一次都不消耗每日上限。
        expect(
          diagnostics.join('\n'),
          contains('idle catchup scheduled items=dream'),
        );
        expect(diagnostics.join('\n'), isNot(contains('blocked item=dream')));
      },
    );

    test('idle poll stays silent when no model port is configured', () async {
      final seedPipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: () => DateTime(2026, 7, 2, 22),
      );
      await _seedEpisodeDay(
        seedPipeline,
        '2026-07-02',
        summary: '用户完成了演讲',
        finalized: true,
      );
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: () => DateTime(2026, 8, 12, 9),
      );
      final cadence = MemoryCadence(
        dailyFinalization: DailyFinalizationService(
          memoryDirectory: memoryDirectory,
          episodePipeline: pipeline,
          clock: () => DateTime(2026, 8, 12, 9),
        ),
        monthlySummary: MonthlySummaryStore(
          memoryDirectory: memoryDirectory,
          episodePipeline: pipeline,
        ),
        clock: () => DateTime(2026, 8, 12, 9),
        diagnosticsSink: diagnostics.add,
      );

      // 有积压但未配置模型服务：安静地什么都不做，绝不用本地规则补写。
      await cadence.pollTick();
      await cadence.finalizePending();

      expect(
        diagnostics.where((line) => line.contains('idle catchup')),
        isEmpty,
      );
    });
  });
}

/// 播种一份 episode 日文件。writeFinalization 契约要求调用方持有
/// episode 日文件写锁，测试也照做。
Future<void> _seedEpisodeDay(
  EpisodeMemoryPipeline pipeline,
  String date, {
  required String summary,
  required bool finalized,
}) {
  final finalizedAt = finalized
      ? DateTime.parse('${date}T23:00:00').toUtc()
      : null;
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
      finalized: finalized,
      finalizedAt: finalizedAt,
    ),
  );
}

/// 与 DreamService 内部编码同构的测试夹具（support/dream_state_fixture）：
/// 直接落一份待补跑的 dream/state.md。
Future<void> _seedPendingDream(
  String memoryDirectory, {
  DateTime? lastSuccess,
}) async {
  await Directory(
    '$memoryDirectory${Platform.pathSeparator}dream',
  ).create(recursive: true);
  File(
    '$memoryDirectory${Platform.pathSeparator}dream${Platform.pathSeparator}state.md',
  ).writeAsStringSync(
    encodedDreamState(lastSuccess: lastSuccess, pending: true),
  );
}

/// 永远就绪的端口替身：轮询只取「已配置模型服务」信号；月压缩全程
/// 零模型调用，打开流的句柄绝不会被使用。
final class _PreparedProviderPort implements ProviderChatPort {
  const _PreparedProviderPort();

  @override
  Future<PreparedProviderChatRequest?> prepareChatRequest() async =>
      PreparedProviderChatRequest(
        hardRulesAddendum: '',
        openStream: (messages, whenCancelled) async => null,
      );
}
