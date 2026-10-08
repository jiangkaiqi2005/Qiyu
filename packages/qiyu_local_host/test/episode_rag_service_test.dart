import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_local_host/src/embedding_gateway.dart';
import 'package:qiyu_local_host/src/embedding_settings_service.dart';
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
      // 再启用采纳缓存并调度一次来源对账：排空它（同身份不重算）。
      await harness.service.settlePendingWork();
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

    test('查询返回维度与索引身份不符：落需重建，明确重建后恢复（票 06）', () async {
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
      // 实际维度是索引身份的组成成分：服务端维度漂移是确定性的身份
      // 失配（单次网络失败才保持 ready）——旧索引立即停止查询并显示
      // 需重建（票 06 验收：换实际维度使旧身份索引停止查询）。
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.rebuildNeeded,
      );

      // 明确重建以新维度发布新身份：不再卡死在旧维度上。
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      expect((await harness.service.status()).state, EpisodeRagState.ready);
      // 服务端恢复原维度后查询照常命中。
      harness.embedding.inner.queryVectors['旧书店'] = [1.0, 0.0];
      final recovered = await harness.service.locate('旧书店');
      expect(recovered, isA<RagCandidates>());
    });

    test('发往 embedding 的查询先脱敏：秘密不出仓，整句秘密不外发', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      harness.embedding.calls.clear();

      // 查询带着秘密：外发的是脱敏后的文本，绝不携带原值。
      final result =
          await harness.service.locate('旧书店 密码 {"password": "s3cret-9"}')
              as RagCandidates;
      final sent = harness.embedding.calls.single.single;
      expect(sent.contains('s3cret-9'), isFalse);
      expect(sent.contains('[已脱敏]'), isTrue);
      expect(sent.contains('旧书店'), isTrue);
      expect(result, isA<RagCandidates>());

      // 整句都是秘密：外发的文本同样只有脱敏形态，原值绝不出现。
      harness.embedding.calls.clear();
      final fullySecret =
          await harness.service.locate('{"password": "s3cret-9"}')
              as RagCandidates;
      expect(fullySecret, isA<RagCandidates>());
      final secretSent = harness.embedding.calls.single.single;
      expect(secretSent.contains('s3cret-9'), isFalse);
      expect(secretSent.contains('[已脱敏]'), isTrue);
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

    test('在途增量同步在维护代数推进后不得发布旧来源结果（票 05）', () async {
      final gate = Completer<void>();
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      // 新增条目触发增量同步，请求卡在网关上（模拟在途增量）。
      await harness.addEpisodes({
        '2026-08-12': [_entry('s:r2:0', '用户开始养猫了')],
      });
      harness.embedding.vectors['2026-08-12\n用户开始养猫了'] = [0.0, 1.0];
      harness.embedding.gate = gate;
      harness.service.scheduleIncrementalSync();
      await harness.embedding.entered.future;

      // 维护在增量嵌入未完成时推进代数：放行后不得发布旧来源结果。
      harness.service.onMaintenanceCompleted();
      gate.complete();
      await harness.service.settlePendingWork();

      final index = await harness.indexStoreRead();
      expect(
        index!.entries.map((record) => record.entryId),
        isNot(contains('s:r2:0')),
        reason: '维护后的在途增量结果不得发布',
      );
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.rebuildNeeded,
      );
      expect(
        await harness.service.locate('旧书店'),
        isA<RagUnavailable>(),
      );
    });

    test('首次启动索引缺失：不外发历史内容，明确重建后才入索引（票 05）', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      // 启用位已在（配置持久化过），但索引文件从未建成（缓存缺失）：
      // 模拟「清除缓存/缓存丢失后的首次启动」。
      harness.repository.config = harness.repository.config!.withEnabled(
        true,
      );
      final restarted = EpisodeRagService(
        memoryDirectory: harness.root.path,
        configRepository: harness.repository,
        embeddingClient: harness.embedding,
        episodePipeline: harness.pipeline,
        openLoopStore: OpenLoopStore(memoryDirectory: harness.root.path),
        diagnosticsSink: (_) {},
      );

      // 首启对齐状态：需重建，且绝不自动把历史摘要外发给 embedding。
      expect(
        (await restarted.status()).state,
        EpisodeRagState.rebuildNeeded,
      );
      expect(harness.embedding.calls, isEmpty, reason: '缺失缓存首启不外发');
      expect(
        await restarted.locate('旧书店'),
        isA<RagUnavailable>(),
      );
      expect(harness.embedding.calls, isEmpty, reason: '未就绪不外发查询');

      // 明确重建后按当前有效条目建索引。
      await restarted.rebuild();
      await restarted.settlePendingWork();
      expect((await restarted.status()).state, EpisodeRagState.ready);
      final hits = await restarted.locate('旧书店') as RagCandidates;
      expect(hits.hits.single.entry.summary, '用户聊到旧书店的事');
    });

    test('配置被清除后维护状态对齐为未启用，不擅自恢复（票 05）', () async {
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

      // 配置已清除（embedding 段不存在）：维护结束后按实际状态显示
      // 未启用，且不自动重建、不外发任何历史内容。
      harness.repository.config = null;
      harness.service.onMaintenanceCompleted();
      harness.embedding.calls.clear();

      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.disabled);
      expect(
        await harness.service.locate('旧书店'),
        isA<RagNotEnabled>(),
      );
      expect(harness.embedding.calls, isEmpty, reason: '未启用不外发');
    });
  });

  group('增量同步与来源对账（票 04）', () {
    test('新增 episode 后增量入索引：更新中显示待处理量，旧条目照常可查', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      harness.embedding.calls.clear();

      // 两个新条目入待处理队列：批量请求卡在闸门上时观察更新中状态。
      final gate = Completer<void>();
      harness.embedding.gate = gate;
      await harness.addEpisodes({
        '2026-08-12': [_entry('s:r3:0', '用户开始养猫了')],
        '2026-08-13': [_entry('s:r4:0', '用户换了一份新工作')],
      });
      harness.embedding.vectors['2026-08-12\n用户开始养猫了'] = [0.0, 1.0];
      harness.embedding.vectors['2026-08-13\n用户换了一份新工作'] = [0.5, 0.5];
      harness.service.scheduleIncrementalSync();
      await harness.embedding.entered.future;

      final updating = await harness.service.status();
      expect(updating.state, EpisodeRagState.updating);
      expect(updating.pendingCount, 2);
      // 更新中仍可查询：仍有效的旧条目照常命中。
      final during = await harness.service.locate('旧书店') as RagCandidates;
      expect(during.hits, hasLength(1));
      expect(during.hits.single.entry.summary, '用户聊到旧书店的事');

      gate.complete();
      await harness.service.settlePendingWork();
      final done = await harness.service.status();
      expect(done.state, EpisodeRagState.ready);
      expect(done.pendingCount, 0);
      final index = await harness.indexStoreRead();
      expect(index!.entries, hasLength(3));
      // 增量只发送了两个新条目（旧向量未重算）；期间还有一次更新中的
      // 查询请求，各自成批——批请求闸门放行后才记账，排在查询之后。
      expect(harness.embedding.calls, hasLength(2));
      expect(harness.embedding.calls.last, hasLength(2));
      expect(
        harness.embedding.calls.last,
        containsAll(<String>[
          '2026-08-12\n用户开始养猫了',
          '2026-08-13\n用户换了一份新工作',
        ]),
      );
    });

    test('摘要编辑重嵌入新向量；只改证据摘录不重嵌入且回读新摘录', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [
            _entry(
              's:r1:0',
              '用户聊到旧书店的事',
              evidence: '他说那家店的猫很粘人',
            ),
          ],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'书店': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      harness.embedding.calls.clear();

      // 摘要变化：旧 hash 失配 → 重嵌入。
      await harness.pipeline.synchronizedOnDayFiles(
        () => harness.pipeline.writeFinalization(
          '2026-08-10',
          entries: [
            _entry(
              's:r1:0',
              '用户聊到了新的书店天地',
              evidence: '他说那家店的猫很粘人',
            ),
          ],
          finalized: true,
        ),
      );
      harness.embedding.vectors['2026-08-10\n用户聊到了新的书店天地'] = [0.9, 0.1];
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      expect(harness.embedding.calls, hasLength(1));
      expect(harness.embedding.calls.single.single, '2026-08-10\n用户聊到了新的书店天地');
      expect(
        harness.embedding.calls.single.single.contains('猫很粘人'),
        isFalse,
        reason: '证据摘录不进入 embedding 输入',
      );
      final afterSummary = await harness.service.locate('书店') as RagCandidates;
      expect(afterSummary.hits.single.entry.summary, '用户聊到了新的书店天地');
      harness.embedding.calls.clear();

      // 只改证据摘录：输入 hash 不变 → 不重嵌入，回读得到当前摘录。
      await harness.pipeline.synchronizedOnDayFiles(
        () => harness.pipeline.writeFinalization(
          '2026-08-10',
          entries: [
            _entry(
              's:r1:0',
              '用户聊到了新的书店天地',
              evidence: '他提到店主养了三只橘猫',
            ),
          ],
          finalized: true,
        ),
      );
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      expect(harness.embedding.calls, isEmpty, reason: '证据变化不重嵌入');
      final afterEvidence =
          await harness.service.locate('书店') as RagCandidates;
      expect(afterEvidence.hits.single.entry.evidence, '他提到店主养了三只橘猫');
    });

    test('删除与禁提同步后出索引；解除禁提重新入索引', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户说下周去医院检查')],
          '2026-08-11': [_entry('s:r2:0', '用户说他开始跑步了')],
        },
        vectors: {
          '2026-08-10\n用户说下周去医院检查': [1.0, 0.0],
          '2026-08-11\n用户说他开始跑步了': [0.0, 1.0],
        },
        queryVectors: {'医院': [1.0, 0.0], '跑步': [0.0, 1.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      harness.embedding.calls.clear();

      // 删除医院条目（重写日文件）并禁提跑步条目：两者都退出索引。
      await harness.pipeline.synchronizedOnDayFiles(
        () => harness.pipeline.writeFinalization(
          '2026-08-10',
          entries: const [],
          finalized: true,
        ),
      );
      await harness.writeControls(banned: '跑步');
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      final index = await harness.indexStoreRead();
      expect(index!.entries, isEmpty, reason: '删除与禁提条目不再有效');
      expect(harness.embedding.calls, isEmpty, reason: '剔除不触发重嵌入');
      expect(
        (await harness.service.locate('跑步') as RagCandidates).hits,
        isEmpty,
      );

      // 解除禁提：按当前来源重新验证后重新嵌入入索引。
      await harness.writeControls();
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      final recovered = await harness.indexStoreRead();
      expect(recovered!.entries, hasLength(1));
      expect(recovered.entries.single.entryId, 's:r2:0');
      expect(harness.embedding.calls.single.single, contains('跑步'));
      final hits = await harness.service.locate('跑步') as RagCandidates;
      expect(hits.hits.single.entry.summary, '用户说他开始跑步了');
    });

    test('冻结条目随增量同步出索引；解除冻结重新入索引', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
          '2026-08-11': [_entry('s:r2:0', '用户说他开始跑步了')],
        },
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
          '2026-08-11\n用户说他开始跑步了': [0.0, 1.0],
        },
        queryVectors: {'跑步': [0.0, 1.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      harness.embedding.calls.clear();

      // 冻结跑步条目：与禁提同走受控集合，同步后退出索引。
      await harness.writeControls(frozen: '跑步');
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      final index = await harness.indexStoreRead();
      expect(
        index!.entries.map((record) => record.entryId),
        ['s:r1:0'],
        reason: '冻结条目不再有效，旧向量随同步剔除',
      );
      expect(harness.embedding.calls, isEmpty, reason: '剔除不触发重嵌入');
      final hits = await harness.service.locate('跑步') as RagCandidates;
      expect(hits.hits.map((hit) => hit.entry.id), ['s:r1:0']);
      expect(
        (await harness.service.status()).pendingCount,
        0,
        reason: '受控剔除是清理，不算待嵌入欠账',
      );

      // 解除冻结：按当前来源重新验证后重新嵌入入索引。
      harness.embedding.calls.clear();
      await harness.writeControls();
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      final recovered = await harness.indexStoreRead();
      expect(recovered!.entries, hasLength(2));
      expect(harness.embedding.calls.single.single, contains('跑步'));
      final unfrozen = await harness.service.locate('跑步') as RagCandidates;
      expect(
        unfrozen.hits.map((hit) => hit.entry.id),
        containsAll(['s:r1:0', 's:r2:0']),
      );
      expect(
        unfrozen.hits.singleWhere(
          (hit) => hit.entry.id == 's:r2:0',
        ).entry.summary,
        '用户说他开始跑步了',
      );
    });

    test('启动来源扫描：重启后手工外部编辑由对账发现', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'书店': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      // 手工改写摘要（不经 Host 写入回调），再模拟重启：新实例从盘上
      // 采纳缓存索引，来源扫描发现 hash 失配并重嵌入。
      await harness.pipeline.synchronizedOnDayFiles(
        () => harness.pipeline.writeFinalization(
          '2026-08-10',
          entries: [_entry('s:r1:0', '用户聊到了山脚的书摊')],
          finalized: true,
        ),
      );
      harness.embedding.vectors['2026-08-10\n用户聊到了山脚的书摊'] = [0.8, 0.2];
      final restarted = EpisodeRagService(
        memoryDirectory: harness.root.path,
        configRepository: harness.repository,
        embeddingClient: harness.embedding,
        episodePipeline: harness.pipeline,
        openLoopStore: OpenLoopStore(memoryDirectory: harness.root.path),
        diagnosticsSink: (_) {},
      );
      expect((await restarted.status()).state, EpisodeRagState.ready);
      await restarted.settlePendingWork();

      final index = await harness.indexStoreRead();
      expect(index!.entries, hasLength(1));
      expect(
        index.entries.single.inputSha256,
        episodeRagInputHash('2026-08-10\n用户聊到了山脚的书摊'),
      );
      final hits = await restarted.locate('书店') as RagCandidates;
      expect(hits.hits.single.entry.summary, '用户聊到了山脚的书摊');
    });

    test('在途竞争：嵌入窗口内删除待处理条目，旧结果不复活', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'书店': [1.0, 0.0], '养猫': [0.0, 1.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      final gate = Completer<void>();
      harness.embedding.gate = gate;
      await harness.addEpisodes({
        '2026-08-12': [_entry('s:r3:0', '用户开始养猫了')],
      });
      harness.embedding.vectors['2026-08-12\n用户开始养猫了'] = [0.0, 1.0];
      harness.service.scheduleIncrementalSync();
      await harness.embedding.entered.future;

      // 嵌入请求在途时删除待处理条目，再放行响应。
      await harness.pipeline.synchronizedOnDayFiles(
        () => harness.pipeline.writeFinalization(
          '2026-08-12',
          entries: const [],
          finalized: true,
        ),
      );
      gate.complete();
      await harness.service.settlePendingWork();

      final index = await harness.indexStoreRead();
      expect(
        index!.entries.map((record) => record.entryId),
        ['s:r1:0'],
        reason: '在途结果不得把已删除条目写回有效索引',
      );
      final hits = await harness.service.locate('养猫') as RagCandidates;
      expect(hits.hits.map((hit) => hit.entry.id), ['s:r1:0']);
      expect(hits.hits.single.entry.summary, '用户聊到旧书店的事');
    });

    test('更新失败保留待处理：旧索引可查，重试只补失败条', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
          '2026-08-11': [_entry('s:r2:0', '用户说他开始跑步了')],
        },
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
          '2026-08-11\n用户说他开始跑步了': [0.0, 1.0],
        },
        queryVectors: {'书店': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      harness.embedding.calls.clear();

      harness.embedding.vectors['2026-08-12\n用户开始养猫了'] = [0.0, 1.0];
      await harness.addEpisodes({
        '2026-08-12': [_entry('s:r3:0', '用户开始养猫了')],
      });
      harness.embedding.failures.add(
        const EmbeddingGatewayException(
          kind: ModelFailureKind.timeout,
          message: '连接记忆召回服务超时。',
        ),
      );
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      final failed = await harness.service.status();
      expect(failed.state, EpisodeRagState.ready, reason: '仍有效索引不破坏');
      expect(failed.pendingCount, 1);
      expect(failed.reason, isNotNull);
      final during = await harness.service.locate('书店') as RagCandidates;
      // 无阈值：旧索引里仍有效的两条都返回，失败条目不在其中。
      expect(during.hits.map((hit) => hit.entry.id), ['s:r1:0', 's:r2:0']);
      expect(during.hits.first.entry.summary, '用户聊到旧书店的事');

      // 显式重试（就绪态的重建入口走增量对账）：只补失败条，不整库重算。
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      final retried = await harness.service.status();
      expect(retried.state, EpisodeRagState.ready);
      expect(retried.pendingCount, 0);
      expect(retried.reason, isNull);
      // 期间一次失败批次、一次查询、一次重试批次；重试只补失败条。
      expect(harness.embedding.calls, hasLength(3));
      expect(harness.embedding.calls.last.single, contains('养猫'));
      final index = await harness.indexStoreRead();
      expect(index!.entries, hasLength(3));
    });

    test('零条就绪索引后首条新增：维度以实际向量补齐', () async {
      final harness = await _RagHarness.create();
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      expect(harness.embedding.calls, isEmpty);

      harness.embedding.vectors['2026-08-12\n用户开始养猫了'] = [0.0, 1.0];
      await harness.addEpisodes({
        '2026-08-12': [_entry('s:r3:0', '用户开始养猫了')],
      });
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      final index = await harness.indexStoreRead();
      expect(index!.entries, hasLength(1));
      expect(index.identity.dimension, 2);
      expect((await harness.service.status()).state, EpisodeRagState.ready);
      final hits =
          await harness.service.locate('养猫') as RagCandidates;
      expect(hits.hits.single.entry.summary, '用户开始养猫了');
    });

    test('维护暂停期间调度增量同步是空操作', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      harness.embedding.calls.clear();

      harness.service.pauseBackgroundScheduling();
      await harness.addEpisodes({
        '2026-08-12': [_entry('s:r3:0', '用户开始养猫了')],
      });
      harness.embedding.vectors['2026-08-12\n用户开始养猫了'] = [0.0, 1.0];
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      expect(harness.embedding.calls, isEmpty, reason: '暂停期间不嵌入');
      expect((await harness.service.status()).state, EpisodeRagState.ready);
    });
  });

  group('身份切换、凭据缺口与请求窗口（票 06）', () {
    test('同维度换模型：旧索引停止查询显示需重建，无历史外发；重建后恢复', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      final buildCalls = harness.embedding.calls.length;

      // 换成同维度（2 维）的另一模型：仅模型名变化即身份失配——
      // 同维度换模型也不能沿用旧向量空间（票 06 验收）。
      final previous = harness.repository.config!;
      harness.repository.config = EmbeddingConfig(
        baseUrl: previous.baseUrl,
        model: 'another-embedding-model',
        apiKey: previous.apiKey,
        enabled: previous.enabled,
      );

      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.rebuildNeeded);
      expect(
        harness.embedding.calls,
        hasLength(buildCalls),
        reason: '换模型只落状态，不外发历史',
      );
      expect(await harness.service.locate('旧书店'), isA<RagUnavailable>());

      // 明确重建后以新模型身份发布（同维度也重算，不沿用旧索引）。
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      final index = await harness.indexStoreRead();
      expect(index!.identity.model, 'another-embedding-model');
      expect(
        index.identity.dimension,
        2,
        reason: '同维度换模型仍经历完整重建',
      );
      expect((await harness.service.status()).state, EpisodeRagState.ready);
      expect(await harness.service.locate('旧书店'), isA<RagCandidates>());
    });

    test('换地址保存清 Key：启用状态如实暂不可用；补 Key 后需重建，重建恢复', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      // 换地址保存且未输入新 Key：地址作用域变化不带旧 Key，保存不改
      // 启用位（Spec：保存配置与启用分开）。
      final settings = EmbeddingSettingsService(
        harness.repository,
        harness.embedding,
      );
      final previousModel = harness.repository.config!.model;
      await settings.save(
        baseUrl: 'https://other.example.com/v1',
        model: previousModel,
      );
      expect(
        harness.repository.config!.apiKey,
        isNull,
        reason: '地址作用域变化不得带旧 Key',
      );
      expect(
        harness.repository.config!.enabled,
        isTrue,
        reason: '保存不改启用位',
      );

      // 启用状态下 Key 缺失：如实暂不可用，不自动停用掩盖，也不查询。
      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.unavailable);
      expect(status.reason, contains('API Key'));
      expect(await harness.service.locate('旧书店'), isA<RagUnavailable>());
      expect(
        harness.embedding.calls,
        hasLength(1),
        reason: '凭据缺口期间查询不外发',
      );

      // 补上新作用域的 Key：凭据缺口恢复，但地址身份已变——需重建。
      await settings.save(
        baseUrl: 'https://other.example.com/v1',
        model: previousModel,
        apiKey: 'sk-other',
      );
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.rebuildNeeded,
      );

      // 明确重建后以新地址恢复查询。
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      expect((await harness.service.status()).state, EpisodeRagState.ready);
      expect(await harness.service.locate('旧书店'), isA<RagCandidates>());
    });

    test('忘记 Key：启用状态暂不可用而非自动停用；同作用域补回即恢复，不重算', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();
      final buildCalls = harness.embedding.calls.length;

      final settings = EmbeddingSettingsService(
        harness.repository,
        harness.embedding,
      );
      await settings.forgetApiKey();
      expect(
        harness.repository.config!.enabled,
        isTrue,
        reason: '忘记 Key 不用自动停用掩盖故障',
      );

      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.unavailable);
      expect(status.reason, contains('API Key'));
      expect(await harness.service.locate('旧书店'), isA<RagUnavailable>());

      // 同作用域补回 Key：按缓存身份恢复就绪，不重算有效向量。
      final config = harness.repository.config!;
      await settings.save(
        baseUrl: config.baseUrl,
        model: config.model,
        apiKey: 'sk-test',
      );
      final recovered = await harness.service.status();
      expect(recovered.state, EpisodeRagState.ready);
      await harness.service.settlePendingWork();
      expect(
        harness.embedding.calls,
        hasLength(buildCalls),
        reason: '同作用域仅换 Key 不重算有效向量',
      );
      expect(await harness.service.locate('旧书店'), isA<RagCandidates>());
      expect(
        harness.embedding.calls,
        hasLength(buildCalls + 1),
        reason: '恢复后只多出一次查询请求',
      );
    });

    test('请求途中停用：结果发布前核对，不把旧请求结果当有效候选', () async {
      _RagHarness? box;
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
        onEmbed: () => box!.service.disable(),
      );
      box = harness;
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      final result = await harness.service.locate('旧书店');
      expect(
        result,
        isA<RagUnavailable>(),
        reason: '停用发生在请求窗口内：旧请求结果不发布',
      );
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.disabled,
      );
    });

    test('请求途中换模型：结果发布前核对身份，不把旧请求结果当新服务结果', () async {
      _RagHarness? box;
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
        queryVectors: {'旧书店': [1.0, 0.0]},
        onEmbed: () async {
          final previous = box!.repository.config!;
          box.repository.config = EmbeddingConfig(
            baseUrl: previous.baseUrl,
            model: 'midflight-model',
            apiKey: previous.apiKey,
            enabled: previous.enabled,
          );
        },
      );
      box = harness;
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      final result = await harness.service.locate('旧书店');
      expect(
        result,
        isA<RagUnavailable>(),
        reason: '配置在请求窗口内更换：旧请求结果不当新服务有效结果',
      );
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.rebuildNeeded,
        reason: '身份已漂移：旧索引停止查询',
      );
    });

    test('增量同步遇服务端维度漂移：落需重建而非卡死待处理；重建后恢复', () async {
      final harness = await _RagHarness.create(
        episodes: {
          '2026-08-10': [_entry('s:r1:0', '用户聊到旧书店的事')],
        },
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      addTearDown(harness.dispose);
      await harness.service.enable();
      await harness.service.settlePendingWork();

      // 新条目等待入索引，但服务端此时已整体换到 3 维输出。
      await harness.addEpisodes({
        '2026-08-12': [_entry('s:r3:0', '用户开始养猫了')],
      });
      harness.embedding.vectors['2026-08-12\n用户开始养猫了'] = [0.0, 1.0, 0.0];
      harness.service.scheduleIncrementalSync();
      await harness.service.settlePendingWork();

      // 不保留待处理记账死循环：旧索引身份失配，如实落需重建。
      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.rebuildNeeded);
      expect(status.reason, contains('维度'));

      // 服务端整体漂移后，明确重建以新维度恢复。
      harness.embedding.vectors['2026-08-10\n用户聊到旧书店的事'] = [
        1.0, 0.0, 0.0,
      ];
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      expect((await harness.service.status()).state, EpisodeRagState.ready);
      harness.embedding.inner.queryVectors['养猫'] = [0.0, 1.0, 0.0];
      expect(await harness.service.locate('养猫'), isA<RagCandidates>());
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
    EmbeddingClient serviceEmbedding,
  ) : service = EpisodeRagService(
       memoryDirectory: root.path,
       configRepository: repository,
       embeddingClient: serviceEmbedding,
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
    Future<void> Function()? onEmbed,
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
    final gated = GatedEmbeddingClient(
      _ScriptedEmbedding(
        vectors: Map<String, List<double>>.of(vectors),
        queryVectors: Map<String, List<double>>.of(queryVectors),
        batchResponses: batchResponses,
        failures: failures ?? [],
        queryFailures: queryFailures ?? [],
        batchGate: batchGate,
      ),
    );
    // 查询钩子（票 06）：仅查询请求在途时改配置或停用，制造「请求
    // 途中变化」的确定性竞态；无钩子时与既有用例完全同构。
    final serviceEmbedding = onEmbed == null
        ? gated
        : (
            _QueryHookEmbeddingClient(
              gated,
              buildInputs: vectors.keys.toSet(),
            )
              ..onEmbed = onEmbed
          );
    final harness = _RagHarness._(
      root,
      pipeline,
      repository,
      gated,
      serviceEmbedding,
    );
    return harness;
  }

  final Directory root;
  final EpisodeMemoryPipeline pipeline;
  final _StaticEmbeddingRepository repository;
  final GatedEmbeddingClient embedding;
  late final EpisodeRagService service;

  Future<void> dispose() async {
    // 先排空后台任务链：在途增量同步可能仍在写索引文件，直接删临时
    // 目录会在 Windows 上撞「目录不是空的」。
    await service.settlePendingWork();
    await root.delete(recursive: true);
  }

  /// 在既有日文件上追加条目（新增 episode 的增量用例）。
  Future<void> addEpisodes(Map<String, List<EpisodeEntry>> episodes) async {
    for (final MapEntry(:key, :value) in episodes.entries) {
      await pipeline.synchronizedOnDayFiles(() async {
        final day = await pipeline.readDay(key);
        return pipeline.writeFinalization(
          key,
          entries: [...day.entries, ...value],
          summary: day.summary,
          finalized: day.finalized,
          finalizedAt: day.finalizedAt,
        );
      });
    }
  }

  /// 重写 memory-controls.md 的冻结与禁提区（null = 清空对应区）。
  Future<void> writeControls({String? banned, String? frozen}) => File(
    '${root.path}/memory-controls.md',
  ).writeAsString(
    '# memory-controls\n## frozen\n'
    '${frozen == null ? '' : '- [MC001] open-loop | $frozen\n'}'
    '## banned\n'
    '${banned == null ? '' : '- [MC002] open-loop | $banned\n'}'
    '## deleted\n',
    encoding: utf8,
  );
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

/// 查询钩子包装（票 06）：查询请求（单条输入且不在构建向量表内，与
/// Scripted/Gated 同一启发）发出前执行 [onEmbed]——在 locate 已读过
/// 配置、请求在途的窗口内改配置或停用，验证结果发布前的核对。构建
/// 请求直通，不影响首次建索引。
final class _QueryHookEmbeddingClient implements EmbeddingClient {
  _QueryHookEmbeddingClient(this.inner, {required this.buildInputs});

  final EmbeddingClient inner;

  /// 构建输入（日期+换行+摘要）集合：命中即构建请求，hook 不触发。
  final Set<String> buildInputs;

  Future<void> Function()? onEmbed;

  @override
  Future<List<Float32List>> embed({
    required EmbeddingConfig config,
    required String? apiKey,
    required List<String> inputs,
    Duration? timeout,
  }) async {
    final isQuery =
        inputs.length == 1 && !buildInputs.contains(inputs.single);
    if (onEmbed != null && isQuery) {
      await onEmbed!();
    }
    return inner.embed(
      config: config,
      apiKey: apiKey,
      inputs: inputs,
      timeout: timeout,
    );
  }
}
