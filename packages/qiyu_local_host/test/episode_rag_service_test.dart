import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/src/embedding_gateway.dart';
import 'package:qiyu_local_host/src/episode_memory.dart';
import 'package:qiyu_local_host/src/episode_rag_index.dart';
import 'package:qiyu_local_host/src/episode_rag_service.dart';
import 'package:qiyu_local_host/src/model_gateway.dart' show ModelFailureKind;
import 'package:qiyu_local_host/src/open_loop_store.dart';
import 'package:qiyu_local_host/src/provider_config.dart';
import 'package:test/test.dart';

import 'support/scripted_embedding_client.dart';

void main() {
  group('启用与首次完整构建', () {
    test('未配置服务不能启用', () async {
      final harness = await _RagHarness.create(configured: false);
      addTearDown(harness.dispose);
      await expectLater(
        harness.service.enable(),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            contains('还没有保存记忆召回服务配置'),
          ),
        ),
      );
    });

    test('显式启用触发后台完整构建并发布就绪索引；只发送日期与脱敏摘要', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [
            _entry('s1:r1:0', '用户聊到旧书店的事', evidence: '原话证据绝不出现在请求里'),
          ],
          '2026-08-11': [_entry('s1:r2:0', '用户说他开始跑步了')],
        },
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
          '2026-08-11\n用户说他开始跑步了': [0.0, 1.0],
        },
      );
      addTearDown(harness.dispose);

      final status = await harness.service.enable();
      expect(status.state, EpisodeRagState.preparing);
      await harness.service.settlePendingWork();

      final done = await harness.service.status();
      expect(done.state, EpisodeRagState.ready);
      // 两次批次调用（每批最多 10 条，这里两条各成一批也可同批；脚本
      // 按批返回，两次调用都被记录）。
      final allInputs = [
        for (final batch in harness.embedding.calls) ...batch,
      ];
      expect(allInputs, hasLength(2));
      for (final input in allInputs) {
        expect(input, matches(RegExp(r'^\d{4}-\d{2}-\d{2}\n.+$', dotAll: true)));
        expect(input.contains('原话证据'), isFalse, reason: input);
        expect(input.contains('s1:r1:0'), isFalse, reason: input);
      }
      // 发布的索引可在盘上读回：身份与条目齐全。
      final index = await harness.indexStoreRead();
      expect(index, isNotNull);
      expect(index!.entries, hasLength(2));
      expect(index.identity.model, 'text-embedding-test');
      expect(index.identity.dimension, 2);
    });

    test('构建按每批最多 10 条切批', () async {
      final entries = <String, List<EpisodeEntry>>{};
      final vectors = <String, List<double>>{};
      for (var i = 0; i < 12; i++) {
        final date = '2026-08-${(10 + i).toString().padLeft(2, '0')}';
        final summary = '用户记事第 $i 条';
        entries[date] = [_entry('s:r$i:0', summary)];
        vectors['$date\n$summary'] = [i.toDouble(), 1.0];
      }
      final harness = await _RagHarness.create(
        episodes: entries,
        vectors: vectors,
      );
      addTearDown(harness.dispose);

      await harness.service.enable();
      await harness.service.settlePendingWork();

      expect(harness.embedding.calls.map((batch) => batch.length).toList(), [
        10,
        2,
      ]);
    });

    test('空库完整完成为零条就绪索引；查询不外发 embedding', () async {
      final harness = await _RagHarness.create();
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.ready);
      expect(harness.embedding.calls, isEmpty, reason: '空库无需 embedding');

      final result = await harness.service.locate('随便查点什么');
      expect(result, isA<RagCandidates>());
      expect((result as RagCandidates).hits, isEmpty);
      expect(harness.embedding.calls, isEmpty, reason: '零条索引不外发查询');
    });

    test('首批失败不发布部分索引，状态暂不可用并带人话原因；重建可恢复', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        failures: [const EmbeddingGatewayException(
          kind: ModelFailureKind.authentication,
          message: '还没有保存记忆召回服务的 API Key。',
        )],
      );
      addTearDown(harness.dispose);

      await harness.service.enable();
      await harness.service.settlePendingWork();

      final failed = await harness.service.status();
      expect(failed.state, EpisodeRagState.unavailable);
      expect(failed.reason, contains('API Key'));
      // 没有部分索引落盘。
      expect(
        File(
          '${harness.root.path}/$episodeRagIndexFileName',
        ).existsSync(),
        isFalse,
      );

      // 明确重试：同一服务恢复后重建成功。
      harness.embedding.failures.clear();
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      final recovered = await harness.service.status();
      expect(recovered.state, EpisodeRagState.ready);
    });

    test('批间维度不一致不发布，明确不可用', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
          '2026-08-11': [_entry('s:r2:0', '用户说他开始跑步了')],
        },
        batchResponses: [
          [
            [1.0, 0.0],
          ],
          [
            [0.0, 1.0, 2.0],
          ],
        ],
      );
      addTearDown(harness.dispose);

      await harness.service.enable();
      await harness.service.settlePendingWork();

      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.unavailable);
      expect(
        File(
          '${harness.root.path}/$episodeRagIndexFileName',
        ).existsSync(),
        isFalse,
      );
    });

    test('禁提条目不入索引（不发送 embedding）', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户说下周去医院检查')],
          '2026-08-11': [_entry('s:r2:0', '用户说他开始跑步了')],
        },
        vectors: {'2026-08-11\n用户说他开始跑步了': [0.0, 1.0]},
        banned: '医院检查',
      );
      addTearDown(harness.dispose);

      await harness.service.enable();
      await harness.service.settlePendingWork();

      final allInputs = [
        for (final batch in harness.embedding.calls) ...batch,
      ];
      expect(allInputs, hasLength(1));
      expect(allInputs.single.contains('医院检查'), isFalse);
      expect(allInputs.single.contains('跑步'), isTrue);
    });
  });

  group('索引身份与凭据作用域', () {
    test('同身份仅换 Key：重新启用直接就绪，不重算向量', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      expect(harness.embedding.calls, hasLength(1));

      // 同作用域换 Key：停用再启用（配置不变），缓存身份仍匹配。
      await harness.service.disable();
      harness.embedding.calls.clear();
      await harness.service.enable();
      await harness.service.settlePendingWork();

      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.ready);
      expect(harness.embedding.calls, isEmpty, reason: '同身份不重算');
    });

    test('换模型后旧索引停止查询，显示需重建', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      expect((await harness.service.status()).state, EpisodeRagState.ready);

      final previous = harness.repository.config!;
      harness.repository.config = EmbeddingConfig(
        baseUrl: previous.baseUrl,
        model: 'another-embedding-model',
        apiKey: previous.apiKey,
        enabled: previous.enabled,
      );

      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.rebuildNeeded);
      final result = await harness.service.locate('旧书店');
      expect(result, isA<RagUnavailable>());
    });

    test('明确停用回到旧路径；再启用且缓存有效时直接就绪', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      await harness.service.disable();
      expect(
        await harness.service.locate('旧书店'),
        isA<RagNotEnabled>(),
      );

      await harness.service.enable();
      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.ready);
      expect(harness.embedding.calls, hasLength(1), reason: '首轮构建一次');
    });

    test('索引文件损坏在加载时显示需重建，重建后恢复', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      // 模拟重启：新服务实例从磁盘加载，读到的缓存已损坏 → 需重建。
      File(
        '${harness.root.path}/$episodeRagIndexFileName',
      ).writeAsStringSync('这不是索引');
      final restarted = EpisodeRagService(
        memoryDirectory: harness.root.path,
        configRepository: harness.repository,
        embeddingClient: harness.embedding,
        episodePipeline: harness.pipeline,
        openLoopStore: OpenLoopStore(memoryDirectory: harness.root.path),
        diagnosticsSink: (_) {},
      );
      expect(
        (await restarted.status()).state,
        EpisodeRagState.rebuildNeeded,
      );

      await restarted.rebuild();
      await restarted.settlePendingWork();
      expect((await restarted.status()).state, EpisodeRagState.ready);
    });
  });

  group('查询与回读校验', () {
    test('命中回读当前摘要与摘录；查询只发送 query 一条输入', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [
            _entry('s:r1:0', '用户聊到旧书店的事', evidence: '他说那家店的猫很粘人'),
          ],
          '2026-08-11': [_entry('s:r2:0', '用户说他开始跑步了')],
        },
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
          '2026-08-11\n用户说他开始跑步了': [0.0, 1.0],
        },
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      harness.embedding.calls.clear();

      final result = await harness.service.locate('那家旧书店') as RagCandidates;

      expect(harness.embedding.calls.single, hasLength(1));
      expect(harness.embedding.calls.single.single, '那家旧书店');
      // 无阈值：最多 10 条当前有效候选都交组织调用判断，这里两条都在。
      expect(result.hits, hasLength(2));
      // 同分相同则按确定性排序，余弦更高（向量 [1,0] 与查询同向）的
      // 旧书店条目排第一。
      expect(result.hits.first.date, '2026-08-10');
      expect(result.hits.first.entry.summary, '用户聊到旧书店的事');
      expect(result.hits.first.entry.evidence, '他说那家店的猫很粘人');
    });

    test('查询向量维度与索引身份不符按不可用处理', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      final result = await harness.service.locate('旧书店');
      expect(result, isA<RagUnavailable>());
      // 一次查询失败不销毁仍有效的索引。
      expect((await harness.service.status()).state, EpisodeRagState.ready);
    });

    test('摘要编辑后旧向量立即不可用（来源 hash 失配）', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      // 用户编辑摘要：索引里的输入 hash 不再匹配当前来源。
      await harness.pipeline.synchronizedOnDayFiles(
        () => harness.pipeline.writeFinalization(
          '2026-08-10',
          entries: [_entry('s:r1:0', '用户聊到了新的旧书店')],
          finalized: true,
        ),
      );

      final result = await harness.service.locate('旧书店') as RagCandidates;
      expect(result.hits, isEmpty);
      expect(
        result.diagnostics.join('\n'),
        contains('reason=stale-source'),
      );
    });

    test('删除与禁提在回读前生效；摘录命中禁提丢摘录保摘要', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [
            _entry('s:r1:0', '用户说周末有安排', evidence: '周末顺便去医院检查，然后吃火锅'),
          ],
        },
        vectors: {'2026-08-10\n用户说周末有安排': [1.0, 0.0]},
        banned: '医院检查',
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      final result = await harness.service.locate('周末安排') as RagCandidates;
      expect(result.hits, hasLength(1));
      expect(result.hits.single.entry.summary, '用户说周末有安排');
      expect(result.hits.single.entry.evidence, isNull);
    });

    test('精确余弦最多取 10 条当前有效候选', () async {
      final entries = <String, List<EpisodeEntry>>{};
      final vectors = <String, List<double>>{};
      for (var i = 0; i < 15; i++) {
        final date = '2026-08-${(10 + i).toString().padLeft(2, '0')}';
        final summary = '用户记事第 $i 条';
        entries[date] = [_entry('s:r$i:0', summary)];
        vectors['$date\n$summary'] = [1.0, 0.0];
      }
      final harness = await _RagHarness.create(
        episodes: entries,
        vectors: vectors,
        queryVectors: {'找记事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      final result = await harness.service.locate('找记事') as RagCandidates;
      expect(result.hits, hasLength(episodeRagQueryLimit));
      // 同分确定性排序：日期升序在前。
      expect(result.hits.first.date, '2026-08-10');
    });

    test('查询 embedding 失败按不可用处理，不冒充没有候选', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryFailures: [
          const EmbeddingGatewayException(
            kind: ModelFailureKind.timeout,
            message: '连接记忆召回服务超时。',
          ),
        ],
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      final result = await harness.service.locate('旧书店');
      expect(result, isA<RagUnavailable>());
      expect((await harness.service.status()).state, EpisodeRagState.ready);
    });
  });

  group('维护暂停、排空与失效', () {
    test('维护暂停期间不启动新构建，明确落为需重建', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      harness.service.pauseBackgroundScheduling();

      await harness.service.enable();
      await harness.service.settlePendingWork();

      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.rebuildNeeded);
      expect(
        File(
          '${harness.root.path}/$episodeRagIndexFileName',
        ).existsSync(),
        isFalse,
      );

      harness.service.resumeBackgroundScheduling();
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      expect((await harness.service.status()).state, EpisodeRagState.ready);
    });

    test('维护完成后缓存失效并显示需重建', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      expect((await harness.service.status()).state, EpisodeRagState.ready);

      harness.service.onMaintenanceCompleted();

      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.rebuildNeeded);
      expect(await harness.service.locate('旧书店'), isA<RagUnavailable>());
    });

    test('在途构建在维护代数推进后不得发布旧来源结果', () async {
      final gate = Completer<void>();
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        batchGate: gate,
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      // 等第一批真的卡在网关上（模拟在途请求）。
      while (harness.embedding.calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // 维护在在途请求未完成时推进代数。
      harness.service.onMaintenanceCompleted();
      gate.complete();
      await harness.service.settlePendingWork();

      expect(
        (await harness.service.status()).state,
        isNot(EpisodeRagState.ready),
      );
      expect(
        File(
          '${harness.root.path}/$episodeRagIndexFileName',
        ).existsSync(),
        isFalse,
        reason: '维护后的在途结果不得发布',
      );
    });
  });
}

// ---------- 测试基架 ----------

final class _RagHarness {
  _RagHarness._(
    this.root,
    this.pipeline,
    this.repository,
    this.embedding,
  ) : service = EpisodeRagService(
       memoryDirectory: root.path,
       configRepository: repository,
       embeddingClient: embedding,
       episodePipeline: pipeline,
       openLoopStore: OpenLoopStore(memoryDirectory: root.path),
       diagnosticsSink: (_) {},
     );

  static Future<_RagHarness> create({
    Map<String, List<EpisodeEntry>> episodes = const {},
    Map<String, List<double>> vectors = const {},
    Map<String, List<double>> queryVectors = const {},
    List<List<List<double>>>? batchResponses,
    List<EmbeddingGatewayException>? failures,
    List<EmbeddingGatewayException>? queryFailures,
    String? banned,
    Completer<void>? batchGate,
    bool configured = true,
  }) async {
    final root = await Directory.systemTemp.createTemp('qiyu-rag-service-');
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: root.path,
      clock: () => DateTime(2026, 8, 16, 22),
    );
    for (final MapEntry(:key, :value) in episodes.entries) {
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
    if (banned != null) {
      File('${root.path}/memory-controls.md')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '# memory-controls\n## frozen\n## banned\n'
          '- [MC001] open-loop | $banned\n## deleted\n',
          encoding: utf8,
        );
    }
    final repository = _StaticEmbeddingRepository(
      configured
          ? EmbeddingConfig(
              baseUrl: 'https://api.example.com/v1',
              model: 'text-embedding-test',
              apiKey: 'sk-test',
            )
          : null,
    );
    final embedding = _ScriptedEmbedding(
      vectors: vectors,
      queryVectors: queryVectors,
      batchResponses: batchResponses,
      failures: failures ?? [],
      queryFailures: queryFailures ?? [],
      batchGate: batchGate,
    );
    final harness = _RagHarness._(root, pipeline, repository, embedding);
    return harness;
  }

  final Directory root;
  final EpisodeMemoryPipeline pipeline;
  final _StaticEmbeddingRepository repository;
  final _ScriptedEmbedding embedding;
  late final EpisodeRagService service;

  void dispose() => root.delete(recursive: true);
}

/// 从 harness 拿已发布的索引（走文件读回，供断言身份）。
extension _RagIndexProbe on _RagHarness {
  Future<EpisodeRagIndex?> indexStoreRead() =>
      EpisodeRagIndexStore(
        memoryDirectory: root.path,
        commits: pipeline.commits,
      ).read();
}

/// 播种一条可入库的有效记忆条目。
EpisodeEntry _entry(String id, String summary, {String? evidence}) =>
    EpisodeEntry(
      id: id,
      sessionId: id.split(':').first,
      requestId: id.split(':').elementAt(1),
      summary: summary,
      evidence: evidence,
      at: DateTime.utc(2026, 8, 10, 12),
    );

/// 静态 embedding 配置仓储：内存现值 + 事务直通（support 共享版）。
typedef _StaticEmbeddingRepository = StaticEmbeddingConfigRepository;

/// 脚本化 embedding 客户端（support 共享版）。
typedef _ScriptedEmbedding = ScriptedEmbeddingClient;
