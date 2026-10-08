import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/chat_memory_test_module.dart';
import 'support/scripted_chat_client.dart';
import 'support/scripted_embedding_client.dart';

/// 票 03 集成回归：Episode RAG 启用后的轮内召回接线、下一轮消费的
/// 来源重核、维护独占的缓存失效与向量缓存的备份/快照排除。
void main() {
  group('RAG 启用后的轮内召回', () {
    test('就绪时跳过目录选择：组织调用直接收到 RAG 命中的当前证据', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [
          _entry('seed:1:0', '用户聊到旧书店的事', evidence: '他说那家店的猫很粘人'),
        ],
      });
      addTearDown(() => root.delete(recursive: true));
      final (harness, pipeline) = await _ragHarness(
        root.path,
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
        },
        queryVectors: {
          '那家旧书店': [1.0, 0.0],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();

      // 组织调用一次即返回；选择调用绝不发生（RAG 替换目录选择）。
      final client = ScriptedChatClient([
        ModelCompletion.reply(_composeReply('想起那家店了。', entries: ['seed:1:0'])),
      ]);
      final orchestrator = _orchestrator(root.path, pipeline, client, harness.service);

      final result = await orchestrator.runTurnRecall(
        userText: '那家旧书店',
        recallActions: [MemoryRecallAction(query: '那家旧书店')],
      );

      expect(client.calls, hasLength(1), reason: '只有组织调用');
      expect(result.bubbleText, '想起那家店了。');
      // 组织调用的输入里有 RAG 回读的当前摘要与摘录。
      final composeInput = client.calls.single.last.content;
      expect(composeInput, contains('用户聊到旧书店的事'));
      expect(composeInput, contains('他说那家店的猫很粘人'));
      expect(composeInput, isNot(contains('月份索引')));
      // 明确使用且回执采信：下一轮临时材料只带用到的条目。
      final pending = await orchestrator.verifyAndRenderPending(
        result.pendingMaterial!,
      );
      expect(pending, contains('用户聊到旧书店的事'));
    });

    test('已启用但未就绪时明确不可用：不调模型、不回退旧目录', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (harness, pipeline) = await _ragHarness(root.path);
      // 直接写启用位、不建索引：模拟「启用后准备失败/缓存缺失」状态。
      harness.repository.config = harness.repository.config!.withEnabled(true);

      final client = ScriptedChatClient(const []);
      final orchestrator = _orchestrator(root.path, pipeline, client, harness.service);

      final result = await orchestrator.runTurnRecall(
        userText: '旧书店',
        recallActions: [MemoryRecallAction(query: '旧书店')],
      );

      expect(client.calls, isEmpty, reason: '明确不可用，不做任何模型调用');
      expect(result.bubbleText, isNull);
      expect(result.pendingMaterial, isNull);
      expect(result.diagnostics.join('\n'), contains('rag unavailable'));
    });

    test('未启用时继续旧目录定位：选择调用照常发生', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (harness, pipeline) = await _ragHarness(
        root.path,
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
        },
      );
      // 未启用（启用位 false）：RAG 不得拦截旧路径。
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          '<qiyu-actions>[{"action":"memory_recall","query":"旧书店",'
          '"dates":["2026-08-10"]}]</qiyu-actions>',
        ),
        ModelCompletion.reply('想起来了。'),
      ]);
      final orchestrator = _orchestrator(root.path, pipeline, client, harness.service);
      await pipeline.synchronizedOnDayFiles(
        () => orchestrator.indexStore.rebuild(includeUnfinalized: true),
      );

      final result = await orchestrator.runTurnRecall(
        userText: '旧书店',
        recallActions: [MemoryRecallAction(query: '旧书店')],
      );

      expect(client.calls, hasLength(2), reason: '选择 + 组织两次调用');
      expect(result.bubbleText, '想起来了。');
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.disabled,
      );
    });

    test('下一轮消费按当前来源重核：摘要编辑后 RAG 材料整条失效', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [
          _entry('seed:1:0', '用户聊到旧书店的事'),
          _entry('seed:1:1', '用户说他开始跑步了'),
        ],
      });
      addTearDown(() => root.delete(recursive: true));
      final (harness, pipeline) = await _ragHarness(
        root.path,
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
          '2026-08-10\n用户说他开始跑步了': [0.9, 0.1],
        },
        queryVectors: {
          '旧事': [1.0, 0.0],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();

      // 组织调用失败＝未完成判断：材料按既有规则整体留给下一轮
      //（票 01：回执缺失/不可信才收窄为空集，未判断保留全量）。
      final client = ScriptedChatClient([
        const ModelCompletion.failure(ModelFailureKind.network),
      ]);
      final orchestrator = _orchestrator(root.path, pipeline, client, harness.service);
      final result = await orchestrator.runTurnRecall(
        userText: '旧事',
        recallActions: [MemoryRecallAction(query: '旧事')],
      );
      expect(result.pendingMaterial, isNotNull);
      orchestrator.storePendingContext('session-1', result.pendingMaterial!);
      final before = await orchestrator.consumePendingContext('session-1');
      expect(before.context, contains('用户聊到旧书店的事'));
      expect(before.context, contains('用户说他开始跑步了'));

      // 用户编辑其中一条摘要：该条 hash 失配，消费时整条失效；
      // 另一条不受影响。
      await pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          '2026-08-10',
          entries: [
            _entry('seed:1:0', '用户聊到了新的书店天地'),
            _entry('seed:1:1', '用户说他开始跑步了'),
          ],
          finalized: true,
        ),
      );
      orchestrator.storePendingContext('session-1', result.pendingMaterial!);
      final diagnostics = <String>[];
      final after = await orchestrator.consumePendingContext(
        'session-1',
        onDiagnostic: diagnostics.add,
      );
      expect(after.context, isNot(contains('用户聊到旧书店的事')));
      expect(after.context, contains('用户说他开始跑步了'));
      expect(after.material, isNotNull);
      expect(after.material!.entries.single.entryId, 'seed:1:1');
      expect(diagnostics.join('\n'), contains('reason=stale-source'));
    });
  });

  group('维护独占与向量缓存隔离', () {
    test('改写来源的维护在结束后使缓存失效并显示需重建', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (harness, pipeline) = await _ragHarness(
        root.path,
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      expect((await harness.service.status()).state, EpisodeRagState.ready);

      final chatService = LocalChatService(
        MarkdownMemoryRepository(memoryDirectory: root.path),
        memory: buildChatMemoryModule(
          memoryDirectory: root.path,
          episodePipeline: pipeline,
          embeddingRagService: harness.service,
        ),
      );
      // 只读维护（一致性导出口径）：缓存不失效。
      await chatService.runExclusively(() async => 'export');
      expect((await harness.service.status()).state, EpisodeRagState.ready);
      // 改写来源的维护（导入/回滚/清除口径）：缓存失效并显示需重建。
      await chatService.runExclusively(
        () async => 'import',
        invalidatesDerivedCaches: true,
      );
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.rebuildNeeded,
      );
    });

    test('向量索引不进备份导出与本机快照', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (harness, pipeline) = await _ragHarness(
        root.path,
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      expect(
        File(
          '${root.path}/$episodeRagIndexFileName',
        ).existsSync(),
        isTrue,
      );

      final module = buildChatMemoryModule(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        embeddingRagService: harness.service,
      );
      final backup = MemoryBackupService(
        memoryDirectory: root.path,
        memoryControls: module.memoryControls,
        episodePipeline: pipeline,
        personaTree: module.personaTree,
        memoryActions: module.memoryActions,
      );
      final exported = await backup.exportBundle();
      final zipDirectory = ZipDirectory();
      zipDirectory.read(InputMemoryStream(exported.bytes));
      final names = [
        for (final header in zipDirectory.fileHeaders) header.filename,
      ];
      expect(
        names.any((name) => name.contains(episodeRagIndexFileName)),
        isFalse,
        reason: '向量缓存不进导出包',
      );

      final snapshotId = await backup.createSnapshot();
      final snapshotDir = Directory('${root.path}/backups/$snapshotId');
      expect(
        snapshotDir.existsSync() &&
            snapshotDir.listSync().any(
              (entity) => entity.path.endsWith(episodeRagIndexFileName),
            ),
        isFalse,
        reason: '向量缓存不进本机快照',
      );
    });
  });

  group('维护与恢复不复活旧候选（票 05）', () {
    test('回滚到旧快照后：需重建、旧 pending 消费判失效，重建只含当前条目', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (harness, pipeline) = await _ragHarness(
        root.path,
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
          '2026-08-12\n用户开始养猫了': [0.0, 1.0],
        },
        queryVectors: {
          '养的宠物': [0.0, 1.0],
        },
      );
      final module = buildChatMemoryModule(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        embeddingRagService: harness.service,
      );
      final backup = MemoryBackupService(
        memoryDirectory: root.path,
        memoryControls: module.memoryControls,
        episodePipeline: pipeline,
        personaTree: module.personaTree,
        memoryActions: module.memoryActions,
      );
      // 快照打在只有 08-10 的时候：回滚后 08-12 应当消失。
      final snapshotId = await backup.createSnapshot();
      await pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          '2026-08-12',
          entries: [_entry('seed:2:0', '用户开始养猫了')],
          summary: '用户开始养猫了',
          finalized: true,
          finalizedAt: DateTime(2026, 8, 12, 22),
        ),
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      final before = await harness.service.locate('养的宠物') as RagCandidates;
      expect(
        before.hits.map((hit) => hit.entry.summary),
        contains('用户开始养猫了'),
      );

      // 未完成判断的召回把两条候选都留给下一轮一次性消费。
      final client = ScriptedChatClient([
        const ModelCompletion.failure(ModelFailureKind.network),
      ]);
      final orchestrator = _orchestrator(root.path, pipeline, client, harness.service);
      final turn = await orchestrator.runTurnRecall(
        userText: '旧事',
        recallActions: [MemoryRecallAction(query: '养的宠物')],
      );
      expect(turn.pendingMaterial, isNotNull);
      orchestrator.storePendingContext('session-1', turn.pendingMaterial!);

      // 经维护独占入口回滚：08-12 随快照恢复消失。
      final chatService = LocalChatService(
        MarkdownMemoryRepository(memoryDirectory: root.path),
        memory: module,
      );
      await chatService.runExclusively(
        () => backup.rollbackTo(snapshotId),
        invalidatesDerivedCaches: true,
      );

      // 状态如实显示需重建，不冒充就绪。
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.rebuildNeeded,
      );
      // 旧 pending 消费前按当前来源判失效：消失的条目整条出局。
      final diagnostics = <String>[];
      final consumed = await orchestrator.consumePendingContext(
        'session-1',
        onDiagnostic: diagnostics.add,
      );
      expect(consumed.context, contains('用户聊到旧书店的事'));
      expect(consumed.context, isNot(contains('用户开始养猫了')));
      expect(consumed.material!.entries.single.entryId, 'seed:1:0');
      expect(diagnostics.join('\n'), contains('reason='));

      // 明确重建只纳入维护后的当前有效条目。
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      expect((await harness.service.status()).state, EpisodeRagState.ready);
      final after = await harness.service.locate('养的宠物') as RagCandidates;
      expect(
        after.hits.map((hit) => hit.entry.summary),
        isNot(contains('用户开始养猫了')),
      );
    });

    test('恢复扫描隔离损坏日后：失效来源不再成为候选，重建对账出索引', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
        '2026-08-12': [_entry('seed:2:0', '用户开始养猫了')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (harness, pipeline) = await _ragHarness(
        root.path,
        vectors: {
          '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
          '2026-08-12\n用户开始养猫了': [0.0, 1.0],
        },
        queryVectors: {
          '养的宠物': [0.0, 1.0],
        },
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();

      // 08-12 写成带栖语标记但元数据损坏的文件（日文件在 episodes/
      // YYYY/MM/ 两级目录下）：恢复扫描会隔离原件，当日来源消失。
      // 08-10 只追加一个截断的条目标记：完整条目可抢救，恢复按原内容
      // 重写当日文件。
      File(
        '${root.path}/episodes/2026/08/2026-08-12.md',
      ).writeAsStringSync('<!-- qiyu-episode:aGlz -->\n');
      File(
        '${root.path}/episodes/2026/08/2026-08-10.md',
      ).writeAsStringSync(
        '${File('${root.path}/episodes/2026/08/2026-08-10.md').readAsStringSync()}'
        '<!-- qiyu-episode-entry:broken',
      );
      final module = buildChatMemoryModule(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
      );
      final monthly = MonthlySummaryStore(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        openLoopStore: module.openLoopStore,
      );
      // 时钟固定在当月：月摘要策略跳过 2026-08，聚焦日文件隔离。
      final recovery = MemoryRecoveryService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        memoryControls: module.memoryControls,
        personaTree: module.personaTree,
        dreamService: DreamService(
          memoryDirectory: root.path,
          episodePipeline: pipeline,
          openLoopStore: module.openLoopStore,
          monthlySummary: monthly,
          personaTree: module.personaTree,
        ),
        monthlySummary: monthly,
        relationshipLifecycle: RelationshipLifecycle(memoryDirectory: root.path),
        memoryActions: module.memoryActions,
        clock: () => DateTime(2026, 8, 19, 21),
        diagnosticsSink: (_) {},
      );
      final report = await recovery.sweepAndRecover();
      final dayFindings = report.findings
          .where((finding) => finding.layerKey == 'episode-day')
          .toList();
      expect(
        dayFindings.map((finding) => finding.outcome),
        contains(MemoryRecoveryOutcome.pending),
        reason: '元数据损坏的日文件被隔离，当日来源消失',
      );
      expect(
        dayFindings.map((finding) => finding.outcome),
        contains(MemoryRecoveryOutcome.partial),
        reason: '截断日文件从完整条目抢救重写',
      );

      // 旧索引仍显示就绪：被隔离日的候选在回读时被来源核对拦下；
      // 抢救修复日按当前来源验证——内容未变，有效候选照常命中。
      expect((await harness.service.status()).state, EpisodeRagState.ready);
      final hits = await harness.service.locate('养的宠物') as RagCandidates;
      expect(
        hits.hits.map((hit) => hit.entry.summary),
        isNot(contains('用户开始养猫了')),
      );
      expect(
        hits.hits.map((hit) => hit.entry.summary),
        contains('用户聊到旧书店的事'),
        reason: '修复后的当前来源仍支持原候选，不因维护误伤有效条目',
      );

      // 明确重建按当前来源对账：损坏日出索引，有效条目保留。
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      expect((await harness.service.status()).state, EpisodeRagState.ready);
      final rebuilt = await EpisodeRagIndexStore(
        memoryDirectory: root.path,
        commits: pipeline.commits,
      ).read();
      expect(
        rebuilt!.entries.map((record) => record.entryId),
        ['seed:1:0'],
      );
    });

    test('清除产品数据后：索引随记忆目录删除，需重建且重建落零条就绪', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (harness, pipeline) = await _ragHarness(
        root.path,
        vectors: {'2026-08-10\n用户聊到旧书店的事': [1.0, 0.0]},
      );
      await harness.service.enable();
      await harness.service.settlePendingWork();
      expect(
        File('${root.path}/$episodeRagIndexFileName').existsSync(),
        isTrue,
      );

      final module = buildChatMemoryModule(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        embeddingRagService: harness.service,
      );
      final backup = MemoryBackupService(
        memoryDirectory: root.path,
        memoryControls: module.memoryControls,
        episodePipeline: pipeline,
        personaTree: module.personaTree,
        memoryActions: module.memoryActions,
      );
      final configRepository = _ClearTestProviderConfigRepository();
      final providerSettings = ProviderSettingsService(
        configRepository,
        _ClearTestSecretStore(),
        const _ClearTestUnusedGateway(),
        const ModelPromptBuilder(''),
      );
      // 运行时目录与记忆目录分开（与组合根同构）：引导状态在运行时侧。
      final runtime = await Directory.systemTemp.createTemp(
        'qiyu-rag-clear-runtime-',
      );
      addTearDown(() => runtime.delete(recursive: true));
      final localData = LocalDataService(
        memoryDirectory: root.path,
        repository: MarkdownMemoryRepository(memoryDirectory: root.path),
        backupService: backup,
        providerSettingsService: providerSettings,
        webSearchSettingsService: WebSearchSettingsService(configRepository),
        onboardingFilePath: '${runtime.path}/onboarding.json',
        episodePipeline: pipeline,
        memoryControls: module.memoryControls,
      );
      final chatService = LocalChatService(
        MarkdownMemoryRepository(memoryDirectory: root.path),
        memory: module,
      );
      await chatService.runExclusively(
        () => localData.clear(),
        invalidatesDerivedCaches: true,
      );

      // 向量缓存随记忆目录一并清除；状态按实际显示需重建（配置仍在）。
      expect(
        File('${root.path}/$episodeRagIndexFileName').existsSync(),
        isFalse,
      );
      expect(
        (await harness.service.status()).state,
        EpisodeRagState.rebuildNeeded,
      );
      expect(
        await harness.service.locate('旧书店'),
        isA<RagUnavailable>(),
      );

      // 明确重建后当前来源为空：零条就绪，查询不外发。
      harness.embedding.calls.clear();
      await harness.service.rebuild();
      await harness.service.settlePendingWork();
      final status = await harness.service.status();
      expect(status.state, EpisodeRagState.ready);
      expect(
        await harness.service.locate('旧书店'),
        isA<RagCandidates>(),
      );
      expect(harness.embedding.calls, isEmpty, reason: '空库查询不外发');
    });
  });

  group('来源变化触发增量同步（票 04）', () {
    test('聊天写入新 episode 后后台入索引：保存不等网络，公共召回命中新条', () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店的事')],
      });
      addTearDown(() => root.delete(recursive: true));
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: () => DateTime(2026, 8, 16, 22),
      );
      final repository = StaticEmbeddingConfigRepository(
        EmbeddingConfig(
          baseUrl: 'https://api.example.com/v1',
          model: 'text-embedding-test',
          apiKey: 'sk-test',
        ),
      );
      final vectors = <String, List<double>>{
        '2026-08-10\n用户聊到旧书店的事': [1.0, 0.0],
      };
      final embedding = GatedEmbeddingClient(
        ScriptedEmbeddingClient(
          vectors: vectors,
          queryVectors: {'养的宠物': [1.0, 0.0]},
        ),
      );
      final service = EpisodeRagService(
        memoryDirectory: root.path,
        configRepository: repository,
        embeddingClient: embedding,
        episodePipeline: pipeline,
        openLoopStore: OpenLoopStore(memoryDirectory: root.path),
        diagnosticsSink: (_) {},
      );
      await service.enable();
      await service.settlePendingWork();
      embedding.calls.clear();

      // 聊天链路（hidden_action_executor.applyActions 在回复接受后运行）
      // 成功写入新 episode，即调度召回索引的增量同步。
      vectors['2026-08-16\n用户开始养猫了'] = [0.0, 1.0];
      final gate = Completer<void>();
      embedding.gate = gate;
      final module = buildChatMemoryModule(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        embeddingRagService: service,
      );
      final executor = HiddenActionExecutor(
        memory: module,
        diagnosticsSink: (_) {},
      );
      final session = RawSession(
        id: 's1',
        date: '2026-08-16',
        segment: 1,
        createdAt: DateTime.utc(2026, 8, 16, 21),
        updatedAt: DateTime.utc(2026, 8, 16, 22),
        turns: [
          RawSessionTurn.user(
            requestId: 'r9',
            text: '我开始养猫了，猫粮刚到',
            at: DateTime.utc(2026, 8, 16, 21, 59),
          ),
          RawSessionTurn.qiyu(
            requestId: 'r9',
            messages: const ['恭喜呀，记得拍张照给我看。'],
            at: DateTime.utc(2026, 8, 16, 22),
            source: ReplySource.llm,
            mode: 'text',
          ),
        ],
      );
      await executor.applyActions(session, 'r9', [
        const MemorySignalAction(summary: '用户开始养猫了', evidence: '猫粮刚到'),
      ]);
      // 保存已完成；等同步任务推进到在途嵌入，证明保存没有等网络。
      await embedding.entered.future.timeout(const Duration(seconds: 2));
      expect(gate.isCompleted, isFalse, reason: 'episode 保存不等 embedding 响应');

      gate.complete();
      await service.settlePendingWork();
      final index = await EpisodeRagIndexStore(
        memoryDirectory: root.path,
        commits: pipeline.commits,
      ).read();
      expect(
        index!.entries.map((record) => record.entryId),
        containsAll(['seed:1:0', 's1:r9:0']),
        reason: '新条目已入索引',
      );

      // 公共召回入口命中新条：组织调用收到当前摘要与摘录。
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          _composeReply('恭喜呀。', entries: ['s1:r9:0']),
        ),
      ]);
      final orchestrator = RecallOrchestrator(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        openLoopStore: OpenLoopStore(memoryDirectory: root.path),
        modelClient: client,
        episodeRag: service,
      );
      final result = await orchestrator.runTurnRecall(
        userText: '我最近养的宠物',
        recallActions: [MemoryRecallAction(query: '养的宠物')],
      );
      expect(result.bubbleText, '恭喜呀。');
      final composeInput = client.calls.single.last.content;
      expect(composeInput, contains('用户开始养猫了'));
      expect(composeInput, contains('猫粮刚到'));
    });
  });
}

// ---------- 基架 ----------

final class _RagHarness {
  _RagHarness._(this.root, this.pipeline, this.repository, this.embedding)
    : service = EpisodeRagService(
        memoryDirectory: root.path,
        configRepository: repository,
        embeddingClient: embedding,
        episodePipeline: pipeline,
        openLoopStore: OpenLoopStore(memoryDirectory: root.path),
        diagnosticsSink: (_) {},
      );

  final Directory root;
  final EpisodeMemoryPipeline pipeline;
  final StaticEmbeddingConfigRepository repository;
  final ScriptedEmbeddingClient embedding;
  late final EpisodeRagService service;
}

Future<(_RagHarness, EpisodeMemoryPipeline)> _ragHarness(
  String memoryDirectory, {
  Map<String, List<double>> vectors = const {},
  Map<String, List<double>> queryVectors = const {},
}) async {
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: memoryDirectory,
    clock: () => DateTime(2026, 8, 16, 22),
  );
  final repository = StaticEmbeddingConfigRepository(
    EmbeddingConfig(
      baseUrl: 'https://api.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'sk-test',
    ),
  );
  final embedding = ScriptedEmbeddingClient(
    vectors: vectors,
    queryVectors: queryVectors,
  );
  return (
    _RagHarness._(
      Directory(memoryDirectory),
      pipeline,
      repository,
      embedding,
    ),
    pipeline,
  );
}

RecallOrchestrator _orchestrator(
  String memoryDirectory,
  EpisodeMemoryPipeline pipeline,
  ProviderChatClient client,
  EpisodeRagService rag,
) => RecallOrchestrator(
  memoryDirectory: memoryDirectory,
  episodePipeline: pipeline,
  openLoopStore: OpenLoopStore(memoryDirectory: memoryDirectory),
  modelClient: client,
  episodeRag: rag,
);

Future<Directory> _seedEpisodes(
  Map<String, List<EpisodeEntry>> entriesByDate,
) async {
  final root = await Directory.systemTemp.createTemp('qiyu-rag-recall-');
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: root.path,
    clock: () => DateTime(2026, 8, 16, 22),
  );
  for (final MapEntry(:key, :value) in entriesByDate.entries) {
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
  return root;
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

String _composeReply(String bubble, {List<String> entries = const []}) {
  if (entries.isEmpty) {
    return bubble;
  }
  final entriesJson = entries.map((entry) => '"$entry"').join(',');
  return '$bubble\n<qiyu-actions>[{"action":"memory_recall","query":"测试查找",'
      '"entries":[$entriesJson]}]</qiyu-actions>';
}

/// 清除产品数据用例的内存 Provider 配置仓储（local_data_service_test 同律）。
final class _ClearTestProviderConfigRepository
    implements ProviderConfigRepository, WebSearchConfigRepository {
  @override
  Future<ProviderConfig?> load() async => null;

  @override
  Future<void> save(ProviderConfig config) async {}

  @override
  Future<WebSearchConfig?> loadWebSearch() async => null;

  @override
  Future<void> saveWebSearch(WebSearchConfig? config) async {}

  @override
  Future<T> runTransaction<T>(Future<T> Function() action) => action();
}

final class _ClearTestSecretStore implements SecretStore {
  @override
  Future<void> deleteApiKey(String scope) async {}

  @override
  Future<String?> readApiKey(String scope) async => null;
}

final class _ClearTestUnusedGateway implements ModelGateway {
  const _ClearTestUnusedGateway();

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) {
    throw UnsupportedError('clear tests never call the model');
  }
}
