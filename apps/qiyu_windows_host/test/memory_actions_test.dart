import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String memoryDirectory;
  late EpisodeMemoryPipeline pipeline;
  late PersonaTreeStore personaTree;
  late MemoryControlsStore memoryControls;
  late OpenLoopStore openLoopStore;
  late MonthlySummaryStore monthlySummary;
  late RelationshipLifecycle relationshipLifecycle;
  late MemoryActionService actions;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-memory-actions-test-',
    );
    memoryDirectory = temporaryDirectory.path;
    pipeline = EpisodeMemoryPipeline(memoryDirectory: memoryDirectory);
    memoryControls = MemoryControlsStore(memoryDirectory: memoryDirectory);
    openLoopStore = OpenLoopStore(
      memoryDirectory: memoryDirectory,
      memoryControls: memoryControls,
    );
    // 必须注入 openLoopStore：applyBan 经它读取控制集合。
    personaTree = PersonaTreeStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      openLoopStore: openLoopStore,
      diagnosticsSink: (_) {},
    );
    monthlySummary = MonthlySummaryStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );
    relationshipLifecycle = RelationshipLifecycle(
      memoryDirectory: memoryDirectory,
    );
    actions = MemoryActionService(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      personaTree: personaTree,
      memoryControls: memoryControls,
      openLoopStore: openLoopStore,
      monthlySummary: monthlySummary,
      relationshipLifecycle: relationshipLifecycle,
      diagnosticsSink: (_) {},
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<EpisodeEntry> seedEntry(
    String date,
    String summary, {
    String id = 'seed:r1:0',
    String? evidence,
    String? branch,
    String? nature,
    bool finalized = true,
  }) async {
    final entry = EpisodeEntry(
      id: id,
      sessionId: 'seed-session',
      requestId: 'seed',
      summary: summary,
      evidence: evidence,
      at: DateTime.parse('${date}T20:00:00').toUtc(),
      personaBranch: branch,
      personaNature: nature,
    );
    await pipeline.synchronizedOnDayFiles(
      () => pipeline.writeFinalization(
        date,
        entries: [entry],
        summary: summary,
        finalized: finalized,
        finalizedAt: finalized
            ? DateTime.parse('${date}T23:00:00').toUtc()
            : null,
      ),
    );
    return entry;
  }

  MemoryEntryRef entryRef(String date, String id) => MemoryEntryRef(date, id);

  group('edit', () {
    test(
      'episode correction is stored as a user statement, not evidence',
      () async {
        await seedEntry('2026-08-17', '用户在准备演讲', evidence: '周四有个演讲，有点紧张');
        File(
          path.join(memoryDirectory, 'sessions', 'seed-session.md'),
        ).createSync(recursive: true);

        final result = await actions.edit(
          entryRef('2026-08-17', 'seed:r1:0'),
          '用户在准备一场重要的比赛',
        );
        expect(result.status, MemoryActionStatus.success);

        final day = await pipeline.readDay('2026-08-17');
        final entry = day.entries.single;
        expect(entry.summary, '用户在准备一场重要的比赛');
        expect(entry.userEdited, isTrue);
        // 修正不伪装原始会话证据：摘录被移除，原文只留在 sessions。
        expect(entry.evidence, isNull);
        // sessions 原样保留。
        final sessions = Directory(
          path.join(memoryDirectory, 'sessions'),
        ).listSync();
        expect(sessions, hasLength(1));
      },
    );

    test(
      'episode edit rebuilds only the derived layers of that content',
      () async {
        await seedEntry(
          '2026-08-17',
          '用户在青岛出差',
          id: 'seed:q:0',
          evidence: '去青岛开会',
          branch: 'identity',
          nature: 'self_report',
        );
        await seedEntry('2026-08-16', '用户喜欢喝热牛奶', id: 'seed:m:0');
        await EpisodeIndexStore(
          memoryDirectory: memoryDirectory,
          episodePipeline: pipeline,
        ).rebuild();
        // 身份自述建叶并形成待稳定事实：叶指向被编辑条目。
        await personaTree.processDay('2026-08-17');
        var snapshot = await personaTree.readSnapshot();
        expect(snapshot.branches['identity']!.unrooted, isNotEmpty);

        final result = await actions.edit(
          entryRef('2026-08-17', 'seed:q:0'),
          '用户在北京出差',
        );
        expect(result.status, MemoryActionStatus.success);

        // 索引重建：旧关键词消失，其余日期不受影响。
        final index = EpisodeIndexStore(
          memoryDirectory: memoryDirectory,
          episodePipeline: pipeline,
        );
        final monthIndex = await index.readMonthIndex('2026-08');
        expect(monthIndex, isNotNull);
        final keywords = monthIndex!
            .map((line) => line.keywords.join(','))
            .join(',');
        expect(keywords, isNot(contains('青岛')));
        expect(keywords, contains('热牛奶'));

        // 指向该条目的叶摘要同步为新文本。
        snapshot = await personaTree.readSnapshot();
        final leaves = snapshot.branches['identity']!.unrooted
            .expand((middle) => middle.leaves)
            .toList();
        expect(
          leaves.where((leaf) => leaf.entryRef == 'seed:q:0').single.summary,
          '用户在北京出差',
        );
      },
    );

    test('long-memory edit replaces the line atomically', () async {
      File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).writeAsStringSync('# long-memory\n\n## 人与关系\n- 用户和家人关系亲近\n- 用户养了一只猫\n');
      final result = await actions.edit(
        const MemoryLongTermRef('人与关系', '用户养了一只猫'),
        '用户养了一只狗',
      );
      expect(result.status, MemoryActionStatus.success);

      final contents = File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).readAsStringSync();
      expect(contents, isNot(contains('用户养了一只猫')));
      expect(contents, contains('- 用户养了一只狗'));
      expect(contents, contains('- 用户和家人关系亲近'));
    });

    test('edit rejects empty, oversized and unknown targets', () async {
      File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).writeAsStringSync('# long-memory\n\n## 人与关系\n- 用户养了一只猫\n');
      expect(
        (await actions.edit(
          const MemoryLongTermRef('人与关系', '用户养了一只猫'),
          '   ',
        )).code,
        'memory_action_not_allowed',
      );
      expect(
        (await actions.edit(
          const MemoryLongTermRef('人与关系', '用户养了一只猫'),
          '长' * 61,
        )).code,
        'memory_action_not_allowed',
      );
      expect(
        (await actions.edit(
          const MemoryLongTermRef('人与关系', '不存在的条目'),
          '新内容',
        )).code,
        'memory_item_not_found',
      );
      // 原文不受影响。
      final contents = File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).readAsStringSync();
      expect(contents, contains('- 用户养了一只猫'));
    });

    test('persona claims cannot be edited directly', () async {
      final result = await actions.edit(
        const MemoryRootRef('identity', 'ID-R001'),
        '新主张',
      );
      expect(result.code, 'memory_action_not_allowed');
    });
  });

  group('freeze / unfreeze', () {
    test('freeze writes controls and survives a restart', () async {
      await seedEntry('2026-08-17', '用户在准备演讲');
      final result = await actions.freeze(entryRef('2026-08-17', 'seed:r1:0'));
      expect(result.status, MemoryActionStatus.success);

      // 跨重启：新实例读同一 controls 文件仍见冻结。
      final freshControls = MemoryControlsStore(
        memoryDirectory: memoryDirectory,
      );
      final controls = await freshControls.load();
      expect(controls.frozenSummaries, contains('用户在准备演讲'));

      final unfrozen = await actions.unfreeze(
        entryRef('2026-08-17', 'seed:r1:0'),
      );
      expect(unfrozen.status, MemoryActionStatus.success);
      expect(
        (await freshControls.load()).frozenSummaries,
        isNot(contains('用户在准备演讲')),
      );
    });

    test(
      'freeze is refused while controls are unreadable (recoverable)',
      () async {
        await seedEntry('2026-08-17', '用户在准备演讲');
        File(
          path.join(memoryDirectory, 'memory-controls.md'),
        ).writeAsStringSync('这不是受控结构');
        final result = await actions.freeze(
          entryRef('2026-08-17', 'seed:r1:0'),
        );
        expect(result.status, MemoryActionStatus.failed);
        expect(result.retryable, isTrue);
        // 旧数据保持可用：controls 未被写入，内容原样。
        final contents = File(
          path.join(memoryDirectory, 'memory-controls.md'),
        ).readAsStringSync();
        expect(contents, '这不是受控结构');
      },
    );
  });

  group('ban / unban', () {
    test('ban writes controls and clears the persona projection', () async {
      // 两日相同信号形成重复模式理解，作为禁提清除的目标。
      await seedEntry(
        '2026-08-16',
        '被夸时用玩笑卸力',
        id: 'seed:b:0',
        branch: 'expression',
        nature: 'behavior',
      );
      await seedEntry(
        '2026-08-17',
        '被夸时用玩笑卸力',
        id: 'seed:b:1',
        branch: 'expression',
        nature: 'behavior',
      );
      await personaTree.processDay('2026-08-16');
      await personaTree.processDay('2026-08-17');
      var snapshot = await personaTree.readSnapshot();
      expect(snapshot.branches['expression']!.unrooted, isNotEmpty);

      final result = await actions.ban(entryRef('2026-08-17', 'seed:b:1'));
      expect(result.status, MemoryActionStatus.success);

      expect(
        (await memoryControls.load()).bannedSummaries,
        contains('被夸时用玩笑卸力'),
      );
      snapshot = await personaTree.readSnapshot();
      final expression = snapshot.branches['expression']!;
      expect(expression.roots, isEmpty);
      expect(
        expression.unrooted.where(
          (middle) => bannedTitleMatches(normalizeMemoryText(middle.claim), {
            normalizeMemoryText('被夸时用玩笑卸力'),
          }),
        ),
        isEmpty,
      );

      final unban = await actions.unban(entryRef('2026-08-17', 'seed:b:1'));
      expect(unban.status, MemoryActionStatus.success);
      expect(
        (await memoryControls.load()).bannedSummaries,
        isNot(contains('被夸时用玩笑卸力')),
      );
    });
  });

  group('delete', () {
    Future<void> seedDeleteWorld() async {
      await seedEntry(
        '2026-08-17',
        '用户在青岛工作',
        id: 'seed:q:0',
        evidence: '在青岛上班',
      );
      await seedEntry('2026-08-16', '用户喜欢喝热牛奶', id: 'seed:m:0');
      File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).writeAsStringSync('# long-memory\n\n## 人与关系\n- 用户在青岛工作\n- 用户喜欢喝热牛奶\n');
      File(path.join(memoryDirectory, 'relationship.md')).writeAsStringSync(
        '# relationship\n\n'
        'stage: 熟悉\n'
        'since: 2026-08-01\n'
        '阶段描述: 熟悉阶段。\n\n'
        '## 近期变化\n'
        '- 2026-08-10 用户在青岛工作\n',
      );
      File(path.join(memoryDirectory, 'open-loops.md')).writeAsStringSync(
        '# open-loops\n\n'
        '- [o1] 用户在青岛工作\n'
        '  proactive: yes\n'
        '  status: active\n',
      );
      File(
        path.join(memoryDirectory, 'daily-state.md'),
      ).writeAsStringSync('# daily-state\n\n## 近日状态\n- 用户在青岛工作\n');
      await monthlySummary.compressMonth('2026-08');
      await personaTree.createLeaves([
        EpisodeEntry(
          id: 'seed:q:0',
          sessionId: 'seed-session',
          requestId: 'seed',
          summary: '用户在青岛工作',
          at: DateTime(2026, 8, 17, 20).toUtc(),
          personaBranch: 'identity',
          personaNature: 'self_report',
        ),
      ]);
      await personaTree.processDay('2026-08-17');
    }

    test('preview reports the exact impact before anything changes', () async {
      await seedDeleteWorld();
      final before = File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).readAsStringSync();

      final impact = await actions.deletePreview(
        entryRef('2026-08-17', 'seed:q:0'),
      );
      expect(impact, isNotNull);
      expect(impact!.episodeEntries, 1);
      expect(impact.longTermItems, 1);
      expect(impact.relationshipLines, 1);
      expect(impact.dailyStateLines, 1);
      expect(impact.openLoops, 1);
      expect(impact.personaNodes, greaterThanOrEqualTo(1));
      expect(impact.rebuildsIndex, isTrue);
      expect(impact.targetMasked, isFalse);
      expect(impact.lines.join(), contains('原始对话记录保留'));

      // 未归类叶也在清除范围（与 applyBan 一致）：预览计数随之加一。
      await personaTree.createLeaves([
        EpisodeEntry(
          id: 'seed:q:1',
          sessionId: 'seed-session',
          requestId: 'seed',
          summary: '用户在青岛工作',
          at: DateTime(2026, 8, 18, 20).toUtc(),
          personaBranch: 'preferences',
          personaNature: 'behavior',
        ),
      ]);
      final impactWithLeaf = await actions.deletePreview(
        entryRef('2026-08-17', 'seed:q:0'),
      );
      expect(impactWithLeaf!.personaNodes, impact.personaNodes + 1);

      // 预览只读：任何文件都没有变化。
      expect(
        File(path.join(memoryDirectory, 'long-memory.md')).readAsStringSync(),
        before,
      );
      expect(
        File(path.join(memoryDirectory, 'memory-controls.md')).existsSync(),
        isFalse,
      );
    });

    test(
      'delete clears derived layers, keeps sessions and the raw day',
      () async {
        await seedDeleteWorld();
        final result = await actions.delete(entryRef('2026-08-17', 'seed:q:0'));
        expect(result.status, MemoryActionStatus.success);

        final controls = await memoryControls.load();
        expect(controls.deletedSummaries, contains('用户在青岛工作'));

        final day = await pipeline.readDay('2026-08-17');
        expect(day.entries, isEmpty);
        final keptDay = await pipeline.readDay('2026-08-16');
        expect(keptDay.entries.single.summary, '用户喜欢喝热牛奶');

        final longMemory = File(
          path.join(memoryDirectory, 'long-memory.md'),
        ).readAsStringSync();
        expect(longMemory, isNot(contains('青岛')));
        expect(longMemory, contains('用户喜欢喝热牛奶'));

        final relationship = File(
          path.join(memoryDirectory, 'relationship.md'),
        ).readAsStringSync();
        expect(relationship, isNot(contains('青岛')));
        expect(relationship, contains('stage: 熟悉'));

        final loops = File(
          path.join(memoryDirectory, 'open-loops.md'),
        ).readAsStringSync();
        expect(loops, isNot(contains('青岛')));

        final dailyState = File(
          path.join(memoryDirectory, 'daily-state.md'),
        ).readAsStringSync();
        expect(dailyState, isNot(contains('青岛')));

        // sessions 保留：删除不动原始对话。
        final sessionsDirectory = Directory(
          path.join(memoryDirectory, 'sessions'),
        );
        if (sessionsDirectory.existsSync()) {
          expect(sessionsDirectory.listSync(), isNotEmpty);
        }
        // 重复执行安全。
        final again = await actions.delete(entryRef('2026-08-17', 'seed:q:0'));
        expect(again.code, 'memory_item_not_found');
        expect((await memoryControls.load()).deleted, hasLength(1));
      },
    );

    test(
      'delete refuses when controls cannot be written (recoverable)',
      () async {
        await seedEntry('2026-08-17', '用户在青岛工作');
        File(
          path.join(memoryDirectory, 'memory-controls.md'),
        ).writeAsStringSync('这不是受控结构');
        final result = await actions.delete(
          entryRef('2026-08-17', 'seed:r1:0'),
        );
        expect(result.status, MemoryActionStatus.failed);
        expect(result.retryable, isTrue);
        // 控制记录写不进时绝不清除派生内容。
        final day = await pipeline.readDay('2026-08-17');
        expect(day.entries, hasLength(1));
      },
    );

    test('state pack lines are not control targets', () async {
      File(path.join(memoryDirectory, 'relationship.md')).writeAsStringSync(
        '# relationship\n\n'
        'stage: 熟悉\n'
        'since: 2026-08-01\n'
        '阶段描述: 熟悉阶段。\n\n'
        '## 当前相处方式\n'
        '已确认：\n'
        '- 可以自然提起说过的事\n',
      );
      final ref = const MemoryRelationshipRef('confirmed', '可以自然提起说过的事');
      expect(await actions.deletePreview(ref), isNull);
      expect((await actions.delete(ref)).code, 'memory_action_not_allowed');
      expect((await actions.freeze(ref)).code, 'memory_action_not_allowed');
      expect(
        (await actions.edit(ref, '新内容')).code,
        'memory_action_not_allowed',
      );
    });
  });

  group('reveal', () {
    test(
      'returns the masked text once and only for sensitive content',
      () async {
        await seedEntry('2026-08-17', '用户的手机号是13812345678');
        final revealed = await actions.reveal(
          entryRef('2026-08-17', 'seed:r1:0'),
          'content',
        );
        expect(revealed.status, MemoryActionStatus.success);
        expect(revealed.revealedText, '用户的手机号是13812345678');

        await seedEntry('2026-08-16', '用户喜欢喝热牛奶', id: 'seed:m:0');
        final plain = await actions.reveal(
          entryRef('2026-08-16', 'seed:m:0'),
          'content',
        );
        expect(plain.code, 'memory_item_not_masked');
      },
    );

    test('reveal is read-only: no file changes on disk', () async {
      await seedEntry('2026-08-17', '用户的手机号是13812345678');
      final before = _directorySnapshot(memoryDirectory);
      final result = await actions.reveal(
        entryRef('2026-08-17', 'seed:r1:0'),
        'content',
      );
      expect(result.revealedText, isNotNull);
      // 揭示不落盘、不写日志文件：目录快照前后一致。
      expect(_directorySnapshot(memoryDirectory), before);
    });
  });

  group('shared long-memory 共同过往', () {
    test(
      'shared past items support edit and control like long-memory',
      () async {
        File(
          path.join(memoryDirectory, 'long-memory.md'),
        ).writeAsStringSync('# long-memory\n\n## 共同过往\n- 一起聊到过深夜\n');
        const ref = MemoryRelationshipRef('sharedPast', '一起聊到过深夜');
        final frozen = await actions.freeze(ref);
        expect(frozen.status, MemoryActionStatus.success);
        expect(
          (await memoryControls.load()).frozenSummaries,
          contains('一起聊到过深夜'),
        );
        final edited = await actions.edit(ref, '一起聊到过后半夜');
        expect(edited.status, MemoryActionStatus.success);
        final contents = File(
          path.join(memoryDirectory, 'long-memory.md'),
        ).readAsStringSync();
        expect(contents, contains('- 一起聊到过后半夜'));
      },
    );
  });

  group('记忆删除 scope 口径统一', () {
    // 手写画像分支文件：一个根断言（EX-R001，下挂根下中间理解
    // EX-M001）、一个独立中间理解（EX-M002）、一个未归类叶
    // （EX-L003）。四类节点文本互不包含，也不出现在其它记忆层，
    // 供逐类构造「只命中这一类」的删除范围。
    Future<void> seedPersonaTree() async {
      final file = File(
        path.join(memoryDirectory, 'persona-tree', 'expression.md'),
      );
      file.createSync(recursive: true);
      file.writeAsStringSync('''
# 性格表达

## 未归根中间节点

### [EX-M002] 重复模式｜独立理解熬夜赶工
- 形成: 2026-08-16 · 复核: 2026-08-17
- [EX-L002] 2026-08-17 | 行为观察 | support | 独立理解熬夜赶工的证据 | episodes/2026/08/2026-08-17.md [seed:s:1]

## [EX-R001] 根主张求稳不求快

### [EX-M001] 重复模式｜根下理解遇事先自嘲
- 形成: 2026-08-16 · 复核: 2026-08-17
- [EX-L001] 2026-08-16 | 行为观察 | support | 根下理解遇事先自嘲的证据 | episodes/2026/08/2026-08-16.md [seed:s:0]

## 未归类叶
- [EX-L003] 2026-08-17 | 行为观察 | support | 未归类叶深夜散步 | episodes/2026/08/2026-08-17.md [seed:s:2]
''');
    }

    test('只命中根下中间理解：预览、定位与删除一致', () async {
      await seedPersonaTree();

      final preview = await actions.deletePreview(
        const MemoryMiddleRef('expression', 'EX-M001'),
      );
      expect(preview, isNotNull);
      expect(preview!.personaNodes, 1);
      expect(preview.episodeEntries, 0);
      expect(preview.episodeDaySummaries, 0);
      expect(preview.longTermItems, 0);
      expect(preview.monthSummaryItems, 0);
      expect(preview.relationshipLines, 0);
      expect(preview.dailyStateLines, 0);
      expect(preview.openLoops, 0);

      final result = await actions.deleteByScope('根下理解遇事先自嘲');
      expect(result.status, MemoryActionStatus.success);

      final expression =
          (await personaTree.readSnapshot()).branches['expression']!;
      // 落盘与预览一致：只删命中的根下中间理解，根保留，
      // 独立中间理解与未归类叶不受影响。
      expect(expression.roots.single.claim, '根主张求稳不求快');
      expect(expression.roots.single.middles, isEmpty);
      expect(expression.unrooted.single.claim, '独立理解熬夜赶工');
      expect(expression.unclassified.single.summary, '未归类叶深夜散步');
      expect(
        (await memoryControls.load()).deletedSummaries,
        contains('根下理解遇事先自嘲'),
      );

      // 同一范围第二次删除稳定返回无目标，且不追加控制记录。
      final again = await actions.deleteByScope('根下理解遇事先自嘲');
      expect(again.code, 'memory_delete_no_target');
      expect((await memoryControls.load()).deleted, hasLength(1));
      expect(
        await actions.deletePreview(
          const MemoryMiddleRef('expression', 'EX-M001'),
        ),
        isNull,
      );
    });

    test('命中根断言：连子树整体删除', () async {
      await seedPersonaTree();
      final preview = await actions.deletePreview(
        const MemoryRootRef('expression', 'EX-R001'),
      );
      expect(preview, isNotNull);
      expect(preview!.personaNodes, 1);

      final result = await actions.deleteByScope('根主张求稳不求快');
      expect(result.status, MemoryActionStatus.success);

      final expression =
          (await personaTree.readSnapshot()).branches['expression']!;
      // 根命中连子树删：根下中间理解随根消失，其余节点不受影响。
      expect(expression.roots, isEmpty);
      expect(expression.unrooted.single.claim, '独立理解熬夜赶工');
      expect(expression.unclassified.single.summary, '未归类叶深夜散步');

      expect(
        (await actions.deleteByScope('根主张求稳不求快')).code,
        'memory_delete_no_target',
      );
    });

    test('只命中独立中间理解', () async {
      await seedPersonaTree();
      final preview = await actions.deletePreview(
        const MemoryMiddleRef('expression', 'EX-M002'),
      );
      expect(preview, isNotNull);
      expect(preview!.personaNodes, 1);

      final result = await actions.deleteByScope('独立理解熬夜赶工');
      expect(result.status, MemoryActionStatus.success);

      final expression =
          (await personaTree.readSnapshot()).branches['expression']!;
      expect(expression.unrooted, isEmpty);
      expect(expression.roots.single.middles.single.claim, '根下理解遇事先自嘲');
      expect(expression.unclassified.single.summary, '未归类叶深夜散步');

      expect(
        (await actions.deleteByScope('独立理解熬夜赶工')).code,
        'memory_delete_no_target',
      );
    });

    test('只命中未归类叶', () async {
      await seedPersonaTree();

      final result = await actions.deleteByScope('未归类叶深夜散步');
      expect(result.status, MemoryActionStatus.success);

      final expression =
          (await personaTree.readSnapshot()).branches['expression']!;
      expect(expression.unclassified, isEmpty);
      expect(expression.roots.single.middles, hasLength(1));
      expect(expression.unrooted, hasLength(1));

      expect(
        (await actions.deleteByScope('未归类叶深夜散步')).code,
        'memory_delete_no_target',
      );
    });

    test('命中 episode 条目', () async {
      await seedEntry('2026-08-19', '临时记忆条目', id: 'seed:t:0');
      final result = await actions.deleteByScope('临时记忆条目');
      expect(result.status, MemoryActionStatus.success);
      expect((await pipeline.readDay('2026-08-19')).entries, isEmpty);
      expect(
        (await actions.deleteByScope('临时记忆条目')).code,
        'memory_delete_no_target',
      );
    });

    test('只命中当日小结：条目保留', () async {
      await pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          '2026-08-19',
          entries: [
            EpisodeEntry(
              id: 'seed:t:0',
              sessionId: 'seed-session',
              requestId: 'seed',
              summary: '条目内容不命中',
              at: DateTime.parse('2026-08-19T20:00:00').toUtc(),
            ),
          ],
          summary: '当天的小结命中了',
          finalized: true,
          finalizedAt: DateTime.parse('2026-08-19T23:00:00').toUtc(),
        ),
      );
      final result = await actions.deleteByScope('当天的小结命中了');
      expect(result.status, MemoryActionStatus.success);
      final day = await pipeline.readDay('2026-08-19');
      expect(day.summary, isNull);
      expect(day.entries.single.summary, '条目内容不命中');
      expect(
        (await actions.deleteByScope('当天的小结命中了')).code,
        'memory_delete_no_target',
      );
    });

    test('只命中长期印象', () async {
      File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).writeAsStringSync('# long-memory\n\n## 人与关系\n- 命中长期印象\n- 另一条长期印象\n');
      final result = await actions.deleteByScope('命中长期印象');
      expect(result.status, MemoryActionStatus.success);
      final contents = File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).readAsStringSync();
      expect(contents, isNot(contains('命中长期印象')));
      expect(contents, contains('- 另一条长期印象'));
      expect(
        (await actions.deleteByScope('命中长期印象')).code,
        'memory_delete_no_target',
      );
    });

    test('只命中月份摘要', () async {
      await seedEntry('2026-08-16', '月摘要里记录的事', id: 'seed:z:0');
      await monthlySummary.compressMonth('2026-08');
      // 改写条目后，旧文本只剩月份摘要一处引用。
      final edited = await actions.edit(
        entryRef('2026-08-16', 'seed:z:0'),
        '月摘要记录的事已经改写',
      );
      expect(edited.status, MemoryActionStatus.success);

      final result = await actions.deleteByScope('月摘要里记录的事');
      expect(result.status, MemoryActionStatus.success);
      final summary = await monthlySummary.readMonthSummary('2026-08');
      expect(
        summary!.items.map((item) => item.text),
        isNot(contains('月摘要里记录的事')),
      );
      // 条目本体（已改写）不受影响。
      final day = await pipeline.readDay('2026-08-16');
      expect(day.entries.single.summary, '月摘要记录的事已经改写');
      expect(
        (await actions.deleteByScope('月摘要里记录的事')).code,
        'memory_delete_no_target',
      );
    });

    test('只命中受管关系记录的行', () async {
      File(path.join(memoryDirectory, 'relationship.md')).writeAsStringSync(
        '# relationship\n\n'
        'stage: 熟悉\n'
        'since: 2026-08-01\n'
        '阶段描述: 熟悉阶段。\n\n'
        '## 当前相处方式\n'
        '已确认：\n'
        '- 可以自然提起说过的事\n\n'
        '## 近期变化\n'
        '- 2026-08-10 命中的关系变化\n',
      );
      final result = await actions.deleteByScope('命中的关系变化');
      expect(result.status, MemoryActionStatus.success);
      final contents = File(
        path.join(memoryDirectory, 'relationship.md'),
      ).readAsStringSync();
      expect(contents, isNot(contains('命中的关系变化')));
      expect(contents, contains('可以自然提起说过的事'));
      expect(
        (await actions.deleteByScope('命中的关系变化')).code,
        'memory_delete_no_target',
      );
    });

    test('手写关系文件不算删除目标', () async {
      // 清除管线对不可解析的受管文件一律不动，定位也不得把它
      // 当成命中——否则宽泛范围会借手写文件变成永久封禁。
      File(
        path.join(memoryDirectory, 'relationship.md'),
      ).writeAsStringSync('# relationship\n\n- 关系记录的手写内容\n');
      final result = await actions.deleteByScope('关系记录的手写内容');
      expect(result.code, 'memory_delete_no_target');
      expect(
        File(path.join(memoryDirectory, 'memory-controls.md')).existsSync(),
        isFalse,
      );
      expect(
        File(path.join(memoryDirectory, 'relationship.md')).readAsStringSync(),
        contains('关系记录的手写内容'),
      );
    });

    test('只命中近日状态', () async {
      File(
        path.join(memoryDirectory, 'daily-state.md'),
      ).writeAsStringSync('# daily-state\n\n## 近日状态\n- 命中的近日状态\n- 另一条近日状态\n');
      final result = await actions.deleteByScope('命中的近日状态');
      expect(result.status, MemoryActionStatus.success);
      final contents = File(
        path.join(memoryDirectory, 'daily-state.md'),
      ).readAsStringSync();
      expect(contents, isNot(contains('命中的近日状态')));
      expect(contents, contains('- 另一条近日状态'));
      expect(
        (await actions.deleteByScope('命中的近日状态')).code,
        'memory_delete_no_target',
      );
    });

    test('只命中未闭环事项', () async {
      File(path.join(memoryDirectory, 'open-loops.md')).writeAsStringSync(
        '# open-loops\n\n'
        '- [o1] 命中的未闭环事项\n'
        '  proactive: yes\n'
        '  status: active\n',
      );
      final result = await actions.deleteByScope('命中的未闭环事项');
      expect(result.status, MemoryActionStatus.success);
      expect(
        File(path.join(memoryDirectory, 'open-loops.md')).readAsStringSync(),
        isNot(contains('命中的未闭环事项')),
      );
      expect(
        (await actions.deleteByScope('命中的未闭环事项')).code,
        'memory_delete_no_target',
      );
    });

    test('全部未命中：无目标且什么都不写', () async {
      await seedPersonaTree();
      await seedEntry('2026-08-19', '不相干的记忆条目', id: 'seed:t:0');
      final result = await actions.deleteByScope('完全不相干的范围文本');
      expect(result.code, 'memory_delete_no_target');
      // 无目标时绝不写控制记录（宽泛范围不得变成永久封禁）。
      expect(
        File(path.join(memoryDirectory, 'memory-controls.md')).existsSync(),
        isFalse,
      );
      final day = await pipeline.readDay('2026-08-19');
      expect(day.entries.single.summary, '不相干的记忆条目');
    });
  });
}

Map<String, List<int>> _directorySnapshot(String root) {
  final snapshot = <String, List<int>>{};
  final directory = Directory(root);
  if (!directory.existsSync()) {
    return snapshot;
  }
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) {
      snapshot[path.relative(entity.path, from: root)] = entity
          .readAsBytesSync();
    }
  }
  return snapshot;
}
