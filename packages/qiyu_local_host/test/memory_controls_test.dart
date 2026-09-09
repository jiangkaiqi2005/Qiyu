import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/in_process_chat_host.dart';
import 'support/scripted_chat_client.dart';

void main() {
  group('memory-controls store', () {
    test(
      'writes frozen/banned/deleted sections with stable ids, idempotently',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'qiyu-memory-controls-store-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = MemoryControlsStore(memoryDirectory: directory.path);

        expect(await store.ban('前任'), isTrue);
        expect(await store.freeze('加班'), isTrue);
        expect(await store.recordDelete('搬家'), isTrue);
        // 幂等：重复控制不产生重复记录。
        expect(await store.ban('前任'), isTrue);

        final controls = await store.load();
        expect(controls.readable, isTrue);
        expect(controls.bannedSummaries, {'前任'});
        expect(controls.frozenSummaries, {'加班'});
        expect(controls.deletedSummaries, {'搬家'});
        expect(controls.blockedSummaries, {'前任', '搬家'});

        final contents = File(
          '${directory.path}/memory-controls.md',
        ).readAsStringSync();
        expect(contents, contains('# memory-controls'));
        expect(contents, contains('## frozen'));
        expect(contents, contains('## banned'));
        expect(contents, contains('## deleted'));
        expect(contents, contains('- [MC001] chat | 前任'));
        expect(contents, contains('- [MC002] chat | 加班'));
        expect(contents, contains('- [MC003] chat | 搬家'));

        // 跨重启保持：新实例从文件读回同样的控制。
        final reopened = MemoryControlsStore(memoryDirectory: directory.path);
        final reopenedControls = await reopened.load();
        expect(reopenedControls.bannedSummaries, {'前任'});
        expect(reopenedControls.frozenSummaries, {'加班'});
        expect(reopenedControls.deletedSummaries, {'搬家'});
      },
    );

    test('unfreeze and unban remove records; deleted records stay', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-memory-controls-release-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = MemoryControlsStore(memoryDirectory: directory.path);
      expect(await store.ban('前任'), isTrue);
      expect(await store.freeze('加班'), isTrue);
      expect(await store.recordDelete('搬家'), isTrue);

      expect(await store.unfreeze('加班'), 1);
      expect(await store.unban('前任'), 1);
      // 没有匹配记录时解除返回 0，不是失败。
      expect(await store.unfreeze('不存在的事'), 0);
      final cleared = await store.load();
      expect(cleared.frozenSummaries, isEmpty);
      expect(cleared.bannedSummaries, isEmpty);

      // 删除记录只读、绝不因解除操作被移除，ID 因此永不复用（定稿）。
      expect(cleared.deletedSummaries, {'搬家'});
      expect(await store.unfreeze('搬家'), 0);
      expect(await store.unban('搬家'), 0);
      final contents = File(
        '${directory.path}/memory-controls.md',
      ).readAsStringSync();
      expect(contents, contains('- [MC003] chat | 搬家'));
      // 解除后幂等：重复删除同一对象不产生新记录。
      expect(await store.recordDelete('搬家'), isTrue);
      expect(
        File('${directory.path}/memory-controls.md').readAsStringSync(),
        contents,
      );
    });

    test(
      'unreadable controls refuse mutations but reads degrade gracefully',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'qiyu-memory-controls-unreadable-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        File(
          '${directory.path}/memory-controls.md',
        ).writeAsStringSync('这是手写内容，不是受管结构。\n');
        final store = MemoryControlsStore(memoryDirectory: directory.path);

        final controls = await store.load();
        expect(controls.readable, isFalse);
        expect(await store.ban('新禁提'), isFalse);
        expect(await store.freeze('新冻结'), isFalse);
        expect(await store.recordDelete('新删除'), isFalse);
        expect(await store.unfreeze(' anything'), isNull);
        // 拒绝写入时文件原样保留。
        expect(
          File('${directory.path}/memory-controls.md').readAsStringSync(),
          contains('这是手写内容'),
        );
      },
    );

    test('release only removes exact-match records (S3)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-memory-controls-release-match-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = MemoryControlsStore(memoryDirectory: directory.path);
      expect(await store.freeze('周末跑步计划'), isTrue);
      expect(await store.freeze('跑步'), isTrue);

      // 解除只认精确相等：解除「跑步」不能连带解除「周末跑步计划」——
      // 过度解除会让用户没要求恢复的内容复活。
      expect(await store.unfreeze('跑'), 0);
      expect(await store.unfreeze('跑步计划'), 0);
      expect(await store.unfreeze('跑步'), 1);
      final controls = await store.load();
      expect(controls.frozenSummaries, {'周末跑步计划'});

      // 禁提侧同样只精确解除。
      expect(await store.ban('前任'), isTrue);
      expect(await store.ban('前任的猫'), isTrue);
      expect(await store.unban('前任'), 1);
      expect((await store.load()).bannedSummaries, {'前任的猫'});
    });
  });

  group('ban persistence', () {
    test(
      'open-loop ban survives restart and stays in the blocked set',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'qiyu-ban-persistence-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = OpenLoopStore(memoryDirectory: directory.path);
        expect(await store.banTitle('加班'), isTrue);

        final reopened = OpenLoopStore(memoryDirectory: directory.path);
        expect(await reopened.bannedTitles(), {'加班'});
        expect(await reopened.blockedTitles(), {'加班'});
        final contents = File(
          '${directory.path}/memory-controls.md',
        ).readAsStringSync();
        expect(contents, contains('- [MC001] open-loop | 加班'));
      },
    );
  });

  group('forget', () {
    test('memory_forget keeps the turn out of episodes and persona', () async {
      DateTime clock() => DateTime(2026, 8, 16, 22, 30);
      final gateway = ScriptedModelGateway(
        streamScript: [
          const ScriptedStreamReply('''好，不记这个。
<qiyu-actions>
[{"action":"memory_signal","summary":"用户正在找新工作","branch":"preferences","nature":"behavior"},
{"action":"memory_forget","summary":"用户正在找新工作"}]
</qiyu-actions>'''),
          const ScriptedStreamReply('''都记下了。
<qiyu-actions>
[{"action":"memory_signal","summary":"用户对芒果过敏"},
{"action":"memory_forget","summary":"找新工作"}]
</qiyu-actions>'''),
        ],
      );
      final harness = await InProcessChatHost.start(
        modelGateway: gateway,
        clock: clock,
      );
      addTearDown(harness.dispose);

      final exchange = await harness.sendChat(
        requestId: 'f-1',
        text: '我在找工作，别记下来',
      );

      // 内容条目不落盘，只留审计簿记；没有条目能进提升、索引或画像。
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: harness.memoryDirectory,
        clock: clock,
      );
      final day = await pipeline.readDay('2026-08-16');
      expect(day.entries.map((entry) => entry.summary), ['不记录: 用户正在找新工作']);
      expect(day.entries.single.kind, episodeKindOpenLoopEvent);
      expect(
        File(
          '${harness.memoryDirectory}/persona-tree/preferences.md',
        ).existsSync(),
        isFalse,
      );
      // 不记录是当轮控制：memory-controls.md 不产生持久记录。
      expect(
        File('${harness.memoryDirectory}/memory-controls.md').existsSync(),
        isFalse,
      );
      // 同轮未被遗忘的记忆照常写入。
      await harness.sendChat(
        requestId: 'f-2',
        text: '顺便说我对芒果过敏',
        sessionId: exchange.sessionId,
      );
      final dayAfter = await pipeline.readDay('2026-08-16');
      expect(
        dayAfter.entries.map((entry) => entry.summary),
        contains('用户对芒果过敏'),
      );
    });
  });

  group('freeze', () {
    test('freezing stops injection everywhere but keeps files; unfreeze '
        'restores', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-freeze-injection-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      File('${directory.path}/long-memory.md').writeAsStringSync(
        '''# long-memory

## 重要事件
- 用户去年完成了第一个马拉松

## 人与关系
- 用户和朋友每周末爬山
''',
      );
      File('${directory.path}/persona.md').writeAsStringSync('''# persona

## 偏好与习惯
- 用户喜欢爬山
- 用户喜欢安静
''');
      File('${directory.path}/open-loops.md').writeAsStringSync('''# open-loops

- [o1] 爬山
  proactive: yes
  status: active
- [o2] 买牛奶
  proactive: yes
  status: active
''');
      final controls = MemoryControlsStore(memoryDirectory: directory.path);
      final openLoopStore = OpenLoopStore(
        memoryDirectory: directory.path,
        memoryControls: controls,
      );
      final reader = StatePackReader(
        memoryDirectory: directory.path,
        openLoopStore: openLoopStore,
      );

      expect(await controls.freeze('爬山'), isTrue);

      // 长期印象：冻结条目不注入，其余保留。
      final longMemory = await reader.readLongMemoryBlock();
      expect(longMemory, isNot(contains('爬山')));
      expect(longMemory, contains('用户去年完成了第一个马拉松'));
      // 用户画像：命中冻结的主张不注入。
      final persona = await reader.readPersonaBlock();
      expect(persona, isNot(contains('用户喜欢爬山')));
      expect(persona, contains('用户喜欢安静'));
      // 近况：冻结事项不进未闭环投影，也不进主动跟进候选。
      final dailyState = await reader.readDailyStateBlock();
      expect(dailyState, isNot(contains('爬山')));
      expect(dailyState, contains('买牛奶'));
      // 源文件保持可见（冻结只停注入，不清内容）。
      expect(
        File('${directory.path}/long-memory.md').readAsStringSync(),
        contains('用户和朋友每周末爬山'),
      );
      expect(
        File('${directory.path}/open-loops.md').readAsStringSync(),
        contains('[o1] 爬山'),
      );

      // 用户明确解除后恢复注入。
      expect(await controls.unfreeze('爬山'), 1);
      expect(await reader.readLongMemoryBlock(), contains('爬山'));
      expect(await reader.readPersonaBlock(), contains('用户喜欢爬山'));
      expect(await reader.readDailyStateBlock(), contains('爬山'));
    });

    test(
      'an unparseable long-memory is injected verbatim (D3 baseline)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'qiyu-long-memory-baseline-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        const handwritten = '这是用户手写的一段话，没有受管结构。';
        File(
          '${directory.path}/long-memory.md',
        ).writeAsStringSync('$handwritten\n');
        final reader = StatePackReader(memoryDirectory: directory.path);

        // 基线行为（用户裁定 2026-08-18，D3 按基线）：解析失败原样注入。
        expect(await reader.readLongMemoryBlock(), handwritten);
      },
    );

    test('frozen content is hidden from recall', () async {
      final root = await Directory.systemTemp.createTemp(
        'qiyu-freeze-recall-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
      await pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          '2026-08-10',
          entries: [
            EpisodeEntry(
              id: 'seed:1:0',
              sessionId: 'seed',
              requestId: 'seed',
              summary: '用户每周爬山',
              at: DateTime(2026, 8, 10, 21).toUtc(),
            ),
          ],
          summary: '用户每周爬山',
          finalized: true,
          finalizedAt: DateTime(2026, 8, 10, 22).toUtc(),
        ),
      );
      final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
      final recall = RecallOrchestrator(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        modelClient: ScriptedChatClient(const []),
        openLoopStore: openLoopStore,
      );
      await pipeline.synchronizedOnDayFiles(() => recall.indexStore.rebuild());

      expect(await openLoopStore.memoryControls.freeze('爬山'), isTrue);

      final result = await recall.runTurnRecall(
        userText: '我之前说的运动',
        recallActions: [MemoryRecallAction(query: '爬山')],
      );
      // 索引关键词全部命中冻结：目录整行隐藏，模型调用不发生。
      expect(result.bubbleText, isNull);
      expect(result.diagnostics.join('\n'), contains('no-visible-months'));
      expect((recall.modelClient! as ScriptedChatClient).calls, isEmpty);
    });

    test('day-end organize leaves frozen leaves untouched', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-freeze-organize-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: directory.path,
        clock: () => DateTime(2026, 8, 16, 22),
      );
      final openLoopStore = OpenLoopStore(memoryDirectory: directory.path);
      final tree = PersonaTreeStore(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        openLoopStore: openLoopStore,
        diagnosticsSink: (_) {},
      );
      final entries = [
        EpisodeEntry(
          id: 's1:r1:0',
          sessionId: 's1',
          requestId: 'r1',
          summary: '用户靠跑步解压',
          at: DateTime(2026, 8, 10, 21).toUtc(),
          personaBranch: 'preferences',
          personaNature: 'behavior',
        ),
        EpisodeEntry(
          id: 's1:r2:0',
          sessionId: 's1',
          requestId: 'r2',
          summary: '用户靠跑步解压',
          at: DateTime(2026, 8, 14, 21).toUtc(),
          personaBranch: 'preferences',
          personaNature: 'behavior',
        ),
      ];
      await tree.createLeaves(entries);
      expect(await openLoopStore.memoryControls.freeze('跑步'), isTrue);

      await tree.processDay('2026-08-14', extraEntries: entries);
      var snapshot = await tree.readSnapshot();
      var view = snapshot.branches['preferences']!;
      // 冻结停止自动整理：两天证据也不形成中间理解，叶原地保留。
      expect(view.unrooted, isEmpty);
      expect(view.roots, isEmpty);

      // 解除后同样的证据整理出中间理解。
      expect(await openLoopStore.memoryControls.unfreeze('跑步'), 1);
      await tree.processDay('2026-08-14', extraEntries: entries);
      snapshot = await tree.readSnapshot();
      view = snapshot.branches['preferences']!;
      expect(view.unrooted, hasLength(1));
      expect(view.unrooted.single.claim, contains('跑步'));
    });

    test('dream keeps frozen long-memory items verbatim and rejects drafts '
        'that drop them', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-freeze-dream-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var now = DateTime(2026, 8, 15, 23, 10);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: directory.path,
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了工作');
      File('${directory.path}/long-memory.md').writeAsStringSync(
        '''# long-memory

## 重要事件
- 用户去年完成了第一个马拉松

## 人与关系
- 用户和朋友每周末爬山
''',
      );
      final openLoopStore = OpenLoopStore(memoryDirectory: directory.path);
      expect(await openLoopStore.memoryControls.freeze('爬山'), isTrue);
      final client = ScriptedChatClient([
        // 第一稿丢掉冻结条目。
        ModelCompletion.reply(
          _candidate([
            _item('重要事件', '用户去年完成了第一个马拉松', ['2026-08-14']),
          ]),
        ),
        // 第二稿原样带回冻结条目。
        ModelCompletion.reply(
          _candidate([
            _item('重要事件', '用户去年完成了第一个马拉松', ['2026-08-14']),
            _item('人与关系', '用户和朋友每周末爬山', ['2026-08-14']),
          ]),
        ),
      ]);
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        openLoopStore: openLoopStore,
        modelClient: client,
        clock: () => now,
        diagnosticsSink: (_) {},
      );

      final rejected = await dream.run(bedtime: true);
      expect(rejected.status, DreamStatus.validationFailed);
      expect(rejected.detail, 'frozen');
      // 旧长期印象原样保留，冻结内容绝不因 Dream 丢失。
      final afterReject = File(
        '${directory.path}/long-memory.md',
      ).readAsStringSync();
      expect(afterReject, contains('用户和朋友每周末爬山'));

      final accepted = await dream.run(bedtime: true);
      expect(accepted.status, DreamStatus.accepted);
      final afterAccept = File(
        '${directory.path}/long-memory.md',
      ).readAsStringSync();
      expect(afterAccept, contains('- 用户和朋友每周末爬山'));
      expect(afterAccept, contains('- 用户去年完成了第一个马拉松'));
    });

    test('dream root proposals touching frozen nodes are rejected', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-freeze-dream-proposal-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var now = DateTime(2026, 8, 15, 23, 10);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: directory.path,
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了工作');
      final branchFile = File('${directory.path}/persona-tree/preferences.md');
      branchFile.createSync(recursive: true);
      branchFile.writeAsStringSync('''# 偏好习惯

## 未归根中间节点

### [PR-M001] 重复模式｜用户靠跑步解压
- 形成: 2026-07-20 · 复核: 2026-08-02
- [PR-L001] 2026-07-20 | 明确自述 | support | 用户靠跑步解压 | episodes/2026/07/2026-07-20.md [m1]
- [PR-L002] 2026-08-02 | 明确自述 | support | 用户靠跑步解压 | episodes/2026/08/2026-08-02.md [m2]
''');
      final openLoopStore = OpenLoopStore(memoryDirectory: directory.path);
      expect(await openLoopStore.memoryControls.freeze('跑步'), isTrue);
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          _candidateWithRoots(
            [
              _item('模式与轨迹', '用户状态平稳', ['2026-08-14']),
            ],
            [
              {
                'op': 'promote',
                'branch': 'preferences',
                'claim': '用户靠跑步解压',
                'middles': ['PR-M001'],
              },
            ],
          ),
        ),
      ]);
      final tree = PersonaTreeStore(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        openLoopStore: openLoopStore,
        diagnosticsSink: (_) {},
      );
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        openLoopStore: openLoopStore,
        personaTree: tree,
        modelClient: client,
        clock: () => now,
        diagnosticsSink: (_) {},
      );

      final outcome = await dream.run(bedtime: true);
      expect(outcome.status, DreamStatus.accepted);
      expect(outcome.rootOpsApplied, 0);
      expect(outcome.rootOpsRejected, 1);
      // 冻结节点的提案被拒：树结构保持原样，没有新根。
      final snapshot = await tree.readSnapshot();
      expect(snapshot.branches['preferences']!.roots, isEmpty);
      expect(snapshot.branches['preferences']!.unrooted, hasLength(1));
    });

    test('day-end understanding call never sees frozen/banned file contents '
        '(S1)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-understanding-input-filter-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: directory.path,
        clock: () => DateTime(2026, 8, 14, 23),
      );
      await pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          '2026-08-14',
          entries: [
            EpisodeEntry(
              id: 's1:r1:0',
              sessionId: 's1',
              requestId: 'r1',
              summary: '用户聊了工作',
              at: DateTime(2026, 8, 14, 21).toUtc(),
            ),
          ],
          summary: '用户聊了工作',
          finalized: false,
        ),
      );
      final openLoopStore = OpenLoopStore(memoryDirectory: directory.path);
      expect(await openLoopStore.memoryControls.freeze('爬山'), isTrue);
      expect(await openLoopStore.memoryControls.ban('前任'), isTrue);
      File('${directory.path}/open-loops.md').writeAsStringSync('''# open-loops

- [o1] 爬山
  proactive: yes
  status: active
- [o2] 买牛奶
  proactive: yes
  status: active
''');
      File('${directory.path}/relationship.md').writeAsStringSync(
        '''# relationship

stage: 熟悉
since: 2026-08-01

## 近期变化
- 2026-08-10 用户提到前任
- 2026-08-12 用户聊了工作
''',
      );
      File('${directory.path}/daily-state.md').writeAsStringSync(
        '''# daily-state

- 用户最近常提到前任
- 用户睡眠平稳
''',
      );
      final client = ScriptedChatClient([
        ModelCompletion.reply('{"summary":"用户聊了工作"}'),
      ]);
      final service = DailyFinalizationService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        openLoopStore: openLoopStore,
        modelClient: client,
        clock: () => DateTime(2026, 8, 14, 23, 30),
        diagnosticsSink: (_) {},
      );

      await service.finalizeDay('2026-08-14');

      expect(client.calls, hasLength(1));
      final promptText = client.calls.single
          .map((message) => message.content)
          .join('\n');
      // 受控内容绝不随理解调用离开本机；未受控内容照常可见。
      expect(promptText, isNot(contains('爬山')));
      expect(promptText, isNot(contains('前任')));
      expect(promptText, contains('买牛奶'));
      expect(promptText, contains('用户睡眠平稳'));
      expect(promptText, contains('用户聊了工作'));
    });

    test('dream prompt hides frozen persona claims and rejects new frozen '
        'items (S2)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-freeze-dream-persona-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var now = DateTime(2026, 8, 15, 23, 10);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: directory.path,
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了工作');
      final branchFile = File('${directory.path}/persona-tree/preferences.md');
      branchFile.createSync(recursive: true);
      branchFile.writeAsStringSync('''# 偏好习惯

## 未归根中间节点

### [PR-M001] 重复模式｜用户靠跑步解压
- 形成: 2026-07-20 · 复核: 2026-08-02
- [PR-L001] 2026-07-20 | 明确自述 | support | 用户靠跑步解压 | episodes/2026/07/2026-07-20.md [m1]
''');
      final openLoopStore = OpenLoopStore(memoryDirectory: directory.path);
      expect(await openLoopStore.memoryControls.freeze('跑步'), isTrue);
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          _candidate([
            _item('模式与轨迹', '用户靠跑步解压', ['2026-08-14']),
          ]),
        ),
      ]);
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        openLoopStore: openLoopStore,
        personaTree: PersonaTreeStore(
          memoryDirectory: directory.path,
          episodePipeline: pipeline,
          openLoopStore: openLoopStore,
          diagnosticsSink: (_) {},
        ),
        modelClient: client,
        clock: () => now,
        diagnosticsSink: (_) {},
      );

      final outcome = await dream.run(bedtime: true);
      // 冻结禁止新增关：新印象命中冻结且不在原样保留清单 → 拒绝。
      expect(outcome.status, DreamStatus.validationFailed);
      expect(outcome.detail, 'frozen');
      // 冻结清单只列冻结标题；冻结主张原文不进 Dream 提示词。
      final promptText = client.calls.single
          .map((message) => message.content)
          .join('\n');
      expect(promptText, isNot(contains('用户靠跑步解压')));
      expect(promptText, contains('跑步'));
    });

    test(
      'freezing and banning the same target does not deadlock dream (M2)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'qiyu-freeze-ban-overlap-dream-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        var now = DateTime(2026, 8, 15, 23, 10);
        final pipeline = EpisodeMemoryPipeline(
          memoryDirectory: directory.path,
          clock: () => now,
        );
        await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了工作');
        File('${directory.path}/long-memory.md').writeAsStringSync(
          '''# long-memory

## 重要事件
- 用户去年完成了第一个马拉松

## 人与关系
- 用户和朋友每周末爬山
''',
        );
        final openLoopStore = OpenLoopStore(memoryDirectory: directory.path);
        // 同一事项先冻结后禁提：禁提胜出（最保守），冻结保留关不得再
        // 强制带回该条目，否则每一稿都被拒，Dream 永久卡死。
        expect(await openLoopStore.memoryControls.freeze('爬山'), isTrue);
        expect(await openLoopStore.memoryControls.ban('爬山'), isTrue);
        final client = ScriptedChatClient([
          ModelCompletion.reply(
            _candidate([
              _item('重要事件', '用户去年完成了第一个马拉松', ['2026-08-14']),
            ]),
          ),
        ]);
        final dream = DreamService(
          memoryDirectory: directory.path,
          episodePipeline: pipeline,
          openLoopStore: openLoopStore,
          modelClient: client,
          clock: () => now,
          diagnosticsSink: (_) {},
        );

        final outcome = await dream.run(bedtime: true);
        expect(outcome.status, DreamStatus.accepted);
        final longMemory = File(
          '${directory.path}/long-memory.md',
        ).readAsStringSync();
        expect(longMemory, contains('- 用户去年完成了第一个马拉松'));
        expect(longMemory, isNot(contains('爬山')));
        // 两条控制记录都在：禁提与冻结各自独立可查。
        final controls = await openLoopStore.memoryControls.load();
        expect(controls.bannedSummaries, contains('爬山'));
        expect(controls.frozenSummaries, contains('爬山'));
      },
    );
  });

  group('delete', () {
    test(
      'writes the control record first, then purges every derived layer',
      () async {
        DateTime clock() => DateTime(2026, 8, 16, 22, 30);
        final gateway = ScriptedModelGateway(
          streamScript: [
            const ScriptedStreamReply('''好，都清掉。
<qiyu-actions>
[{"action":"memory_delete","summary":"青岛"}]
</qiyu-actions>'''),
            const ScriptedStreamReply('''已经删过了。
<qiyu-actions>
[{"action":"memory_delete","summary":"青岛"}]
</qiyu-actions>'''),
          ],
        );
        final harness = await InProcessChatHost.start(
          modelGateway: gateway,
          clock: clock,
          seedMemory: (memoryDirectory) async {
            final directory = memoryDirectory.path;
            final pipeline = EpisodeMemoryPipeline(
              memoryDirectory: directory,
              clock: clock,
            );
            // 七月的一天：稍后进入月摘要。
            await pipeline.synchronizedOnDayFiles(
              () => pipeline.writeFinalization(
                '2026-07-05',
                entries: [
                  EpisodeEntry(
                    id: 'seed:july:0',
                    sessionId: 'seed',
                    requestId: 'seed',
                    summary: '用户在青岛工作',
                    at: DateTime(2026, 7, 5, 21).toUtc(),
                  ),
                ],
                summary: '用户在青岛工作',
                finalized: true,
                finalizedAt: DateTime(2026, 7, 5, 23).toUtc(),
              ),
            );
            final monthlySummary = MonthlySummaryStore(
              memoryDirectory: directory,
              episodePipeline: pipeline,
              diagnosticsSink: (_) {},
            );
            await monthlySummary.compressMonth('2026-07');
            expect(
              File('$directory/episodes/2026/07/summary.md').readAsStringSync(),
              contains('用户在青岛工作'),
            );

            final memoryControls = MemoryControlsStore(
              memoryDirectory: directory,
            );
            final store = OpenLoopStore(
              memoryDirectory: directory,
              memoryControls: memoryControls,
            );
            // 关系证据：受管结构里带一条命中目标的近期变化。
            File('$directory/relationship.md').writeAsStringSync(
              '''# relationship

stage: 熟悉
since: 2026-08-01
阶段描述: 熟悉阶段：可以自然提起用户说过的事，偶尔分享自己的想法；仍不调侃、不翻旧账、不主动追问私事。

## 近期变化
- 2026-08-10 用户提到在青岛工作
''',
            );
            // 未闭环事项与长期印象各放一条命中内容。
            File('$directory/open-loops.md').writeAsStringSync('''# open-loops

- [o1] 青岛旅行计划
  proactive: yes
  status: active
- [o2] 买牛奶
  proactive: yes
  status: active
''');
            File('$directory/long-memory.md').writeAsStringSync('''# long-memory

## 人与关系
- 用户在青岛工作
- 用户喜欢喝热牛奶
''');
            final personaTree = PersonaTreeStore(
              memoryDirectory: directory,
              episodePipeline: pipeline,
              openLoopStore: store,
              diagnosticsSink: (_) {},
            );
            await personaTree.createLeaves([
              EpisodeEntry(
                id: 'seed:persona:0',
                sessionId: 'seed',
                requestId: 'seed',
                summary: '用户在青岛工作',
                at: DateTime(2026, 8, 12, 21).toUtc(),
                personaBranch: 'identity',
                personaNature: 'self_report',
              ),
            ]);
          },
        );
        addTearDown(harness.dispose);
        final directory = harness.memoryDirectory;
        final pipeline = EpisodeMemoryPipeline(
          memoryDirectory: directory,
          clock: clock,
        );

        final exchange = await harness.sendChat(
          requestId: 'd-1',
          text: '把青岛的事都删了',
        );

        // 1. 控制记录先落盘：deleted 区留下抽象防复活范围。
        final controlsContents = File(
          '$directory/memory-controls.md',
        ).readAsStringSync();
        expect(controlsContents, contains('## deleted'));
        expect(controlsContents, contains('- [MC001] chat | 青岛'));

        // 2. episodes 清除目标条目，其他条目与簿记留痕保留。
        final july = await pipeline.readDay('2026-07-05');
        expect(july.entries, isEmpty);
        expect(july.summary, isNull);

        // 3. 索引重建后不再含受控关键词。
        final topIndex = await EpisodeIndexStore(
          memoryDirectory: directory,
          episodePipeline: pipeline,
        ).readTopIndex();
        expect(
          topIndex == null ||
              topIndex.every((line) => !line.keywords.join().contains('青岛')),
          isTrue,
        );

        // 4. 长期印象只删命中条目。
        final longMemory = File('$directory/long-memory.md').readAsStringSync();
        expect(longMemory, isNot(contains('青岛')));
        expect(longMemory, contains('用户喜欢喝热牛奶'));

        // 5. PersonaTree 节点清除。
        final snapshot = await PersonaTreeStore(
          memoryDirectory: directory,
          episodePipeline: pipeline,
          diagnosticsSink: (_) {},
        ).readSnapshot();
        final identity = snapshot.branches['identity']!;
        expect(identity.roots, isEmpty);
        expect(identity.unrooted, isEmpty);

        // 6. 月摘要条目清除。
        final monthSummary = File(
          '$directory/episodes/2026/07/summary.md',
        ).readAsStringSync();
        expect(monthSummary, isNot(contains('青岛')));

        // 7. 关系证据行清除，结构保留。
        final relationship = File(
          '$directory/relationship.md',
        ).readAsStringSync();
        expect(relationship, isNot(contains('青岛')));
        expect(relationship, contains('stage: 熟悉'));

        // 8. 未闭环事项清除命中条目。
        final loops = File('$directory/open-loops.md').readAsStringSync();
        expect(loops, isNot(contains('青岛旅行计划')));
        expect(loops, contains('买牛奶'));

        // 9. sessions 保留：用户轮次仍在。
        final session = await harness.sessionReader().openSession(
          sessionId: exchange.sessionId,
        );
        expect(session.turns, isNotEmpty);
        expect(session.turns.map((turn) => turn.text), contains('把青岛的事都删了'));

        // 重复执行安全：再次删除没有新控制记录、不再扩大范围。
        await harness.sendChat(
          requestId: 'd-2',
          text: '再删一次青岛',
          sessionId: exchange.sessionId,
        );
        final controlsAfter = File(
          '$directory/memory-controls.md',
        ).readAsStringSync();
        expect('- [MC'.allMatches(controlsAfter).length, 1);
      },
    );

    test('delete filters day understanding metadata before index rebuild '
        '(M1)', () async {
      DateTime clock() => DateTime(2026, 8, 16, 22, 30);
      final gateway = ScriptedModelGateway(
        streamScript: [
          const ScriptedStreamReply('''好，删掉。
<qiyu-actions>
[{"action":"memory_delete","summary":"青岛"}]
</qiyu-actions>'''),
        ],
      );
      final harness = await InProcessChatHost.start(
        modelGateway: gateway,
        clock: clock,
        seedMemory: (memoryDirectory) async {
          final pipeline = EpisodeMemoryPipeline(
            memoryDirectory: memoryDirectory.path,
            clock: clock,
          );
          // 一天两条条目 + 日终理解元数据：索引重建优先取理解里的
          // indexKeywords，删除若不过滤它，被删关键词会永久残留在索引。
          await pipeline.synchronizedOnDayFiles(
            () => pipeline.writeFinalization(
              '2026-08-05',
              entries: [
                EpisodeEntry(
                  id: 'seed:m1:0',
                  sessionId: 'seed',
                  requestId: 'seed',
                  summary: '用户在青岛出差',
                  at: DateTime(2026, 8, 5, 20).toUtc(),
                ),
                EpisodeEntry(
                  id: 'seed:m1:1',
                  sessionId: 'seed',
                  requestId: 'seed',
                  summary: '用户喜欢喝热牛奶',
                  at: DateTime(2026, 8, 5, 21).toUtc(),
                ),
              ],
              summary: '用户聊了青岛出差和热牛奶',
              finalized: true,
              finalizedAt: DateTime(2026, 8, 5, 23).toUtc(),
              understanding: const {
                'summary': '用户聊了青岛出差和热牛奶',
                'indexKeywords': ['青岛', '热牛奶'],
                'entryCount': 2,
                'lastEntryId': 'seed:m1:1',
              },
            ),
          );
        },
      );
      addTearDown(harness.dispose);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: harness.memoryDirectory,
        clock: clock,
      );

      await harness.sendChat(requestId: 'm1-1', text: '把青岛的事删了');

      // 条目层：命中条目清除，其余保留。
      final day = await pipeline.readDay('2026-08-05');
      expect(day.entries.map((entry) => entry.summary), ['用户喜欢喝热牛奶']);
      // 理解元数据同范围过滤：受控摘要置空、受控关键词移除。
      final understanding = day.understanding!;
      expect(understanding['summary'], isNull);
      expect(understanding['indexKeywords'], ['热牛奶']);
      // 索引重建后顶层索引不再含被删关键词。
      final topIndex = await EpisodeIndexStore(
        memoryDirectory: harness.memoryDirectory,
        episodePipeline: pipeline,
      ).readTopIndex();
      expect(topIndex, isNotNull);
      expect(
        topIndex!.every((line) => !line.keywords.join().contains('青岛')),
        isTrue,
      );
    });

    test(
      'delete without any locatable target writes no control record',
      () async {
        DateTime clock() => DateTime(2026, 8, 16, 22, 30);
        final gateway = ScriptedModelGateway(
          streamScript: [
            const ScriptedStreamReply('''我一时找不到这个内容，你说的是哪件事？
<qiyu-actions>
[{"action":"memory_delete","summary":"从未提过的事"}]
</qiyu-actions>'''),
          ],
        );
        final harness = await InProcessChatHost.start(
          modelGateway: gateway,
          clock: clock,
        );
        addTearDown(harness.dispose);

        await harness.sendChat(requestId: 'd-0', text: '删掉那个');

        // 没有可定位对象：不落控制记录，不产生宽泛封禁。
        final file = File('${harness.memoryDirectory}/memory-controls.md');
        if (file.existsSync()) {
          expect(file.readAsStringSync(), isNot(contains('从未提过的事')));
        }
      },
    );

    test('a deleted scope blocks dream drafts like a ban', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-delete-dream-gate-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var now = DateTime(2026, 8, 15, 23, 10);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: directory.path,
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了工作');
      final openLoopStore = OpenLoopStore(memoryDirectory: directory.path);
      expect(await openLoopStore.memoryControls.recordDelete('搬家'), isTrue);
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          _candidate([
            _item('重要事件', '用户搬家了', ['2026-08-14']),
          ]),
        ),
      ]);
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        openLoopStore: openLoopStore,
        modelClient: client,
        clock: () => now,
        diagnosticsSink: (_) {},
      );

      final outcome = await dream.run(bedtime: true);
      expect(outcome.status, DreamStatus.validationFailed);
      expect(outcome.detail, 'banned');
      expect(File('${directory.path}/long-memory.md').existsSync(), isFalse);
    });
  });

  group('hidden action validation', () {
    test('new control actions parse with summaries and limits', () {
      final parse = parseHiddenActions('''好的。
<qiyu-actions>
[{"action":"memory_freeze","summary":"加班"}]
</qiyu-actions>''');
      final freeze = parse.actions.single as MemoryFreezeAction;
      expect(freeze.kind, HiddenActionKind.memoryFreeze);
      expect(freeze.title, '加班');

      for (final wireName in const [
        'memory_forget',
        'memory_unfreeze',
        'memory_delete',
      ]) {
        final single = parseHiddenActions(
          '<qiyu-actions>[{"action":"$wireName","summary":"某件事"}]'
          '</qiyu-actions>',
        );
        expect(single.actions, hasLength(1), reason: wireName);
        expect(single.diagnostics, isEmpty, reason: wireName);
      }
    });

    test('control actions without a valid summary are dropped', () {
      for (final wireName in const [
        'memory_forget',
        'memory_freeze',
        'memory_unfreeze',
        'memory_delete',
      ]) {
        final missing = parseHiddenActions(
          '<qiyu-actions>[{"action":"$wireName"}]</qiyu-actions>',
        );
        expect(missing.actions, isEmpty, reason: wireName);
        expect(
          missing.diagnostics,
          contains(HiddenActionDiagnostics.invalidFields),
          reason: wireName,
        );
        final secret = parseHiddenActions(
          '<qiyu-actions>[{"action":"$wireName","summary":"密码: abc123"}]'
          '</qiyu-actions>',
        );
        expect(secret.actions, isEmpty, reason: wireName);
        expect(
          secret.diagnostics,
          contains(HiddenActionDiagnostics.sensitiveContent),
          reason: wireName,
        );
      }
    });
  });
}

Future<void> _seedFinalizedDay(
  EpisodeMemoryPipeline pipeline,
  String date,
  String summary,
) => pipeline.synchronizedOnDayFiles(
  () => pipeline.writeFinalization(
    date,
    entries: [
      EpisodeEntry(
        id: 'seed:$date:0',
        sessionId: 'seed',
        requestId: 'seed',
        summary: summary,
        at: DateTime.parse('${date}T21:00:00').toUtc(),
      ),
    ],
    summary: summary,
    finalized: true,
    finalizedAt: DateTime.parse('${date}T23:00:00').toUtc(),
  ),
);

String _candidate(List<Map<String, Object?>> items) =>
    jsonEncode({'items': items});

String _candidateWithRoots(
  List<Map<String, Object?>> items,
  List<Map<String, Object?>> rootProposals,
) => jsonEncode({'items': items, 'rootProposals': rootProposals});

Map<String, Object?> _item(
  String section,
  String text,
  List<String> evidence,
) => {'section': section, 'text': text, 'evidence': evidence};
