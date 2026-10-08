import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/chat_memory_test_module.dart';
import 'support/scripted_chat_client.dart';
import 'support/scripted_embedding_client.dart';

/// 票 07 集成回归：共享 RAG 实例下实时查找的三态结果——有候选、无当前
/// 有效候选与暂不可用不互相冒充；未启用继续旧目录定位；文字组织调用
/// 与实时工具回填两个入口定位同一有效 episode，交付各按既有节奏。
void main() {
  group('实时查找三态（票 07）', () {
    test('就绪时返回候选上下文：候选来自当前来源回读', () async {
      final (harness, pipeline) = await _ragHarness(
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'那家旧书店': [1.0, 0.0]},
        seed: {
          '2026-08-10': [
            _entry('seed:1:0', '用户聊到旧书店的事', evidence: '他说那家店的猫很粘人'),
          ],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      final module = buildChatMemoryModule(
        memoryDirectory: harness.root.path,
        episodePipeline: pipeline,
        embeddingRagService: harness.service,
      );

      final result = await module.memoryRecall.lookupForRealtime(
        query: '那家旧书店',
        userText: '我以前说过的那家旧书店怎么样了',
      );

      final found = result;
      expect(found, isA<RealtimeRecallFound>());
      final context = (found as RealtimeRecallFound).context;
      expect(context, contains('2026-08-10'));
      expect(context, contains('用户聊到旧书店的事'));
      expect(context, contains('他说那家店的猫很粘人'));
      // 共享实例出网：查询打在注入的同一 embedding 客户端上。
      expect(harness.embedding.calls, contains(equals(['那家旧书店'])));
    });

    test('RAG 查找不依赖文字选择小调用的模型客户端', () async {
      final (harness, pipeline) = await _ragHarness(
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
        seed: {
          '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      // recallModelClient 不接（缺省 null）：旧目录定位无法进行，但
      // 已启用的 RAG 语义定位不依赖它。
      final module = buildChatMemoryModule(
        memoryDirectory: harness.root.path,
        episodePipeline: pipeline,
        embeddingRagService: harness.service,
      );

      final result = await module.memoryRecall.lookupForRealtime(
        query: '旧书店',
        userText: '旧书店',
      );

      expect(result, isA<RealtimeRecallFound>());
    });

    test('未启用时继续旧目录定位：选择小调用照常发生', () async {
      final (harness, pipeline) = await _ragHarness(
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        seed: {
          '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
        },
      );
      // 未启用（启用位缺省 false）：RAG 不得拦截旧路径。
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          '<qiyu-actions>[{"action":"memory_recall","query":"旧书店",'
          '"dates":["2026-08-10"]}]</qiyu-actions>',
        ),
      ]);
      final module = buildChatMemoryModule(
        memoryDirectory: harness.root.path,
        episodePipeline: pipeline,
        recallModelClient: client,
        embeddingRagService: harness.service,
      );
      await pipeline.synchronizedOnDayFiles(
        () => module.memoryRecall.indexStore.rebuild(includeUnfinalized: true),
      );

      final result = await module.memoryRecall.lookupForRealtime(
        query: '旧书店',
        userText: '旧书店',
      );

      expect(client.calls, hasLength(1), reason: '旧目录定位的选择小调用');
      final found = result;
      expect(found, isA<RealtimeRecallFound>());
      expect(
        (found as RealtimeRecallFound).context,
        contains('用户聊到旧书店的事'),
      );
    });

    test('查询失败返回暂不可用：不冒充没有候选', () async {
      final (harness, pipeline) = await _ragHarness(
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
        queryFailures: [
          const EmbeddingGatewayException(
            kind: ModelFailureKind.timeout,
            message: '记忆召回服务请求超时。',
          ),
        ],
        seed: {
          '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      final module = buildChatMemoryModule(
        memoryDirectory: harness.root.path,
        episodePipeline: pipeline,
        embeddingRagService: harness.service,
      );

      final result = await module.memoryRecall.lookupForRealtime(
        query: '旧书店',
        userText: '旧书店',
      );

      expect(result, isA<RealtimeRecallUnavailable>());
      expect(
        result.diagnostics.join('\n'),
        contains('rag query deferred kind=timeout'),
      );
    });

    test('维护后需重建返回暂不可用：不回退旧目录', () async {
      final (harness, pipeline) = await _ragHarness(
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
        seed: {
          '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      // 维护（导入/回滚/清除）完成后的缓存失效：需重建。
      harness.service.onMaintenanceCompleted();
      final client = ScriptedChatClient(const []);
      final module = buildChatMemoryModule(
        memoryDirectory: harness.root.path,
        episodePipeline: pipeline,
        recallModelClient: client,
        embeddingRagService: harness.service,
      );

      final result = await module.memoryRecall.lookupForRealtime(
        query: '旧书店',
        userText: '旧书店',
      );

      expect(result, isA<RealtimeRecallUnavailable>());
      expect(client.calls, isEmpty, reason: '明确不可用，不回退旧目录定位');
      expect(
        result.diagnostics.join('\n'),
        contains('rag unavailable'),
      );
    });

    test('空库零条就绪返回 empty：查询不外发', () async {
      final (harness, pipeline) = await _ragHarness();
      await harness.service.enable();
      await harness.service.settlePendingWork();
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.ready,
      );
      final module = buildChatMemoryModule(
        memoryDirectory: harness.root.path,
        episodePipeline: pipeline,
        embeddingRagService: harness.service,
      );

      final result = await module.memoryRecall.lookupForRealtime(
        query: '旧书店',
        userText: '旧书店',
      );

      expect(result, isA<RealtimeRecallEmpty>());
      expect(harness.embedding.calls, isEmpty, reason: '空库查询不外发');
    });

    test('来源失效返回 empty：查询确实外发过，是回读核对拦下的', () async {
      final (harness, pipeline) = await _ragHarness(
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
        seed: {
          '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      // 手工编辑当日摘要：旧输入 hash 失配。
      await pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          '2026-08-10',
          entries: [_entry('seed:1:0', '用户聊到了新的书店天地')],
          summary: '用户聊到了新的书店天地',
          finalized: true,
          finalizedAt: DateTime(2026, 8, 10, 22),
        ),
      );
      final module = buildChatMemoryModule(
        memoryDirectory: harness.root.path,
        episodePipeline: pipeline,
        embeddingRagService: harness.service,
      );

      final result = await module.memoryRecall.lookupForRealtime(
        query: '旧书店',
        userText: '旧书店',
      );

      expect(result, isA<RealtimeRecallEmpty>());
      expect(
        harness.embedding.calls,
        contains(equals(['旧书店'])),
        reason: '查询外发过，无候选是回读核对的结果，不是没查',
      );
    });

    test('两个入口定位同一有效 episode：文字组气泡，实时回填上下文', () async {
      final (harness, pipeline) = await _ragHarness(
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'那家旧书店': [1.0, 0.0]},
        seed: {
          '2026-08-10': [
            _entry('seed:1:0', '用户聊到旧书店的事', evidence: '他说那家店的猫很粘人'),
          ],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          '想起那家店了。\n<qiyu-actions>[{"action":"memory_recall",'
          '"query":"测试查找","entries":["seed:1:0"]}]</qiyu-actions>',
        ),
      ]);
      final module = buildChatMemoryModule(
        memoryDirectory: harness.root.path,
        episodePipeline: pipeline,
        recallModelClient: client,
        embeddingRagService: harness.service,
      );

      // 文字入口：组织调用收到 RAG 回读的当前证据，组出 bubble 2。
      final turn = await module.memoryRecall.runTurnRecall(
        userText: '那家旧书店',
        recallActions: [MemoryRecallAction(query: '那家旧书店')],
      );
      // 实时入口：同一查找返回压缩上下文，交回答模型取舍。
      final realtime = await module.memoryRecall.lookupForRealtime(
        query: '那家旧书店',
        userText: '那家旧书店',
      );

      expect(turn.bubbleText, '想起那家店了。');
      expect(client.calls, hasLength(1), reason: '文字入口只有组织调用');
      expect(
        client.calls.single.last.content,
        contains('用户聊到旧书店的事'),
        reason: '组织调用的输入来自 RAG 回读',
      );
      final found = realtime;
      expect(found, isA<RealtimeRecallFound>());
      final context = (found as RealtimeRecallFound).context;
      expect(context, contains('2026-08-10'));
      expect(context, contains('用户聊到旧书店的事'));
      expect(context, contains('他说那家店的猫很粘人'));
    });
  });
}

// ---------- 基架 ----------

final class _RealtimeRagHarness {
  _RealtimeRagHarness._(this.root, this.pipeline, this.embedding)
    : service = EpisodeRagService(
        memoryDirectory: root.path,
        configRepository: StaticEmbeddingConfigRepository(
          EmbeddingConfig(
            baseUrl: 'https://api.example.com/v1',
            model: 'text-embedding-test',
            apiKey: 'sk-test',
          ),
        ),
        embeddingClient: embedding,
        episodePipeline: pipeline,
        openLoopStore: OpenLoopStore(memoryDirectory: root.path),
        diagnosticsSink: (_) {},
      );

  final Directory root;
  final EpisodeMemoryPipeline pipeline;
  final ScriptedEmbeddingClient embedding;
  late final EpisodeRagService service;
}

Future<(_RealtimeRagHarness, EpisodeMemoryPipeline)> _ragHarness({
  Map<String, List<double>> vectors = const {},
  Map<String, List<double>> queryVectors = const {},
  List<EmbeddingGatewayException> queryFailures = const [],
  Map<String, List<EpisodeEntry>> seed = const {},
}) async {
  final root = await Directory.systemTemp.createTemp('qiyu-rag-realtime-');
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: root.path,
    clock: () => DateTime(2026, 8, 16, 22),
  );
  for (final MapEntry(:key, :value) in seed.entries) {
    await pipeline.synchronizedOnDayFiles(
      () => pipeline.writeFinalization(
        key,
        entries: value,
        summary: value.first.summary,
        finalized: true,
        finalizedAt: DateTime(2026, 8, 15, 22),
      ),
    );
  }
  final embedding = ScriptedEmbeddingClient(
    vectors: vectors,
    queryVectors: queryVectors,
    queryFailures: queryFailures,
  );
  return (_RealtimeRagHarness._(root, pipeline, embedding), pipeline);
}

EpisodeEntry _entry(String id, String summary, {String? evidence}) =>
    EpisodeEntry(
      id: id,
      sessionId: id.split(':').first,
      requestId: id.split(':').elementAt(1),
      summary: summary,
      evidence: evidence,
      at: DateTime.utc(2026, 8, 10, 12),
    );
