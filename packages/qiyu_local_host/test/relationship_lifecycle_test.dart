import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  test('seeds stranger from the earliest traceable interaction date', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-seed-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    var now = DateTime(2026, 8, 14, 23);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    await _reply(
      pipeline,
      now,
      requestId: 'req-1',
      session: 'session-1',
      actions: const [MemorySignalAction(summary: '聊了工作')],
    );
    final lifecycle = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );

    await lifecycle.updateAtEndOfDay('2026-08-14', pipeline, ['2026-08-14']);

    final contents = await File(
      '${temporaryDirectory.path}/relationship.md',
    ).readAsString(encoding: utf8);
    expect(contents, contains('stage: 初识'));
    expect(contents, contains('since: 2026-08-14'));
    // 没有模型判断：描述回落阶段表行为边界文案。
    expect(contents, contains('阶段描述: 初识阶段：以回应当前话题、倾听为主；'));
    expect(contents, contains('不调侃、不翻旧账'));
  });

  test(
    'judgment drives the ratchet: one level per day, replays never repeat it',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-relationship-promote-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      var now = DateTime(2026, 8, 12, 22);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      // 12 天互动，最新一天的日终模型整体判定够到朋友。
      final dates = <String>[];
      for (var day = 1; day <= 12; day += 1) {
        final date = '2026-08-${day.toString().padLeft(2, '0')}';
        dates.add(date);
        now = DateTime(2026, 8, day, 22);
        await _reply(
          pipeline,
          now,
          requestId: 'req-$day',
          session: 'session-1',
          actions: const [MemorySignalAction(summary: '聊了日常')],
        );
      }
      await _persistJudgment(
        pipeline,
        '2026-08-12',
        stage: '朋友',
        description: '用户已经会把白天的事说给她听，也经得起她的直话',
      );
      final lifecycle = RelationshipLifecycle(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final file = File('${temporaryDirectory.path}/relationship.md');

      // 首次日终：播种，目标朋友但单次最多升一级。
      await lifecycle.updateAtEndOfDay('2026-08-12', pipeline, dates);
      expect(await _stage(file), RelationshipStage.familiar);
      var contents = await file.readAsString(encoding: utf8);
      expect(contents, contains('since: 2026-08-12'));
      // 阶段描述取模型结合这个具体用户生成的文案。
      expect(contents, contains('阶段描述: 用户已经会把白天的事说给她听，也经得起她的直话'));

      // 同一天重复执行：绝不重复升级。
      await lifecycle.updateAtEndOfDay('2026-08-12', pipeline, dates);
      await lifecycle.updateAtEndOfDay('2026-08-12', pipeline, dates);
      expect(await _stage(file), RelationshipStage.familiar);

      // 次日日终：再升一级到朋友；之后判断不变不再前进。
      now = DateTime(2026, 8, 13, 22);
      await lifecycle.updateAtEndOfDay('2026-08-13', pipeline, dates);
      expect(await _stage(file), RelationshipStage.friend);
      await lifecycle.updateAtEndOfDay('2026-08-13', pipeline, dates);
      expect(await _stage(file), RelationshipStage.friend);
    },
  );

  test('a deep-talk day alone supports a promotion judgment', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-deeptalk-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    var now = DateTime(2026, 8, 13, 22);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    await _reply(
      pipeline,
      now,
      requestId: 'req-13',
      session: 'session-1',
      actions: const [MemorySignalAction(summary: '聊了日常')],
    );
    now = DateTime(2026, 8, 14, 23);
    await _reply(
      pipeline,
      now,
      requestId: 'req-14',
      session: 'session-1',
      actions: const [
        RelationshipSignalAction(
          signal: RelationshipSignal.deepTalk,
          summary: '用户愿意聊到很深的家庭关系',
        ),
      ],
    );
    // 只有一次深谈信号的一天：模型据此整体判定熟悉即支持升级。
    await _persistJudgment(pipeline, '2026-08-14', stage: '熟悉');
    final lifecycle = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );

    await lifecycle.updateAtEndOfDay('2026-08-14', pipeline, [
      '2026-08-13',
      '2026-08-14',
    ]);

    final contents = await File(
      '${temporaryDirectory.path}/relationship.md',
    ).readAsString(encoding: utf8);
    expect(contents, contains('stage: 熟悉'));
    // 深谈信号仍照常投影近期变化。
    expect(contents, contains('用户愿意聊到很深的家庭关系'));
    // 判断未带描述：回落阶段表行为边界文案。
    expect(contents, contains('阶段描述: 熟悉阶段：可以自然提起用户说过的事'));
  });

  test('no judgment leaves the stage untouched', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-nojudgment-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    var now = DateTime(2026, 8, 12, 22);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    final dates = <String>[];
    for (var day = 1; day <= 12; day += 1) {
      final date = '2026-08-${day.toString().padLeft(2, '0')}';
      dates.add(date);
      now = DateTime(2026, 8, day, 22);
      await _reply(
        pipeline,
        now,
        requestId: 'req-$day',
        session: 'session-1',
        actions: const [MemorySignalAction(summary: '聊了日常')],
      );
    }
    final lifecycle = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    final file = File('${temporaryDirectory.path}/relationship.md');

    // 没有持久化的阶段判断（未配模型或模型未输出）：阶段原地不动。
    await lifecycle.updateAtEndOfDay('2026-08-12', pipeline, dates);
    expect(await _stage(file), RelationshipStage.stranger);
    now = DateTime(2026, 8, 13, 22);
    await lifecycle.updateAtEndOfDay('2026-08-13', pipeline, dates);
    expect(await _stage(file), RelationshipStage.stranger);
  });

  test('an advanced stage never regresses without a judgment', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-ratchet-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    var now = DateTime(2026, 8, 14, 23);
    File('${temporaryDirectory.path}/relationship.md').writeAsStringSync(
      '# relationship\n'
      '\n'
      'stage: 朋友\n'
      'since: 2026-07-20\n'
      '阶段描述: 朋友阶段：可以轻调侃、翻旧账、直说。\n',
      encoding: utf8,
    );
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    await _reply(
      pipeline,
      now,
      requestId: 'req-1',
      session: 'session-1',
      actions: const [MemorySignalAction(summary: '只聊了一句')],
    );
    final lifecycle = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );

    await lifecycle.updateAtEndOfDay('2026-08-14', pipeline, ['2026-08-14']);

    final contents = await File(
      '${temporaryDirectory.path}/relationship.md',
    ).readAsString(encoding: utf8);
    expect(contents, contains('stage: 朋友'));
    expect(contents, contains('since: 2026-07-20'));
  });

  test('a judgment below the current stage never regresses', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-noregress-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    var now = DateTime(2026, 8, 14, 23);
    File('${temporaryDirectory.path}/relationship.md').writeAsStringSync(
      '# relationship\n'
      '\n'
      'stage: 朋友\n'
      'since: 2026-07-20\n'
      '阶段描述: 朋友阶段：可以轻调侃、翻旧账、直说。\n',
      encoding: utf8,
    );
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    await _reply(
      pipeline,
      now,
      requestId: 'req-1',
      session: 'session-1',
      actions: const [MemorySignalAction(summary: '只聊了一句')],
    );
    // 模型当天整体判定只到初识：低于当前阶段，棘轮只升不降。
    await _persistJudgment(pipeline, '2026-08-14', stage: '初识');
    final lifecycle = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );

    await lifecycle.updateAtEndOfDay('2026-08-14', pipeline, ['2026-08-14']);

    final contents = await File(
      '${temporaryDirectory.path}/relationship.md',
    ).readAsString(encoding: utf8);
    expect(contents, contains('stage: 朋友'));
    expect(contents, contains('since: 2026-07-20'));
    // 判断未带描述：描述回落当前阶段（朋友）的行为边界文案，
    // 不跟着被压低的判断走。
    expect(contents, contains('阶段描述: 朋友阶段：可以轻调侃、翻旧账'));
  });

  test(
    'temperature changes slowly and never touches stage permissions',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-relationship-temperature-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      var now = DateTime(2026, 8, 10, 22);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final dates = <String>[];
      // 两天四条温度信号 + 三条边界开合：窗口只保留最近几条。
      // 没有任何阶段判断，阶段停在初识——温度不碰阶段。
      final signals = [
        ('2026-08-09', RelationshipSignal.temperature, '用户这几天火气比较大'),
        ('2026-08-09', RelationshipSignal.deepTalk, '用户愿意聊到更深的家庭关系'),
        ('2026-08-10', RelationshipSignal.temperature, '用户回复热度回升'),
        ('2026-08-10', RelationshipSignal.temperature, '用户今晚话很少'),
      ];
      for (var index = 0; index < signals.length; index += 1) {
        final (date, signal, summary) = signals[index];
        if (!dates.contains(date)) {
          dates.add(date);
        }
        now = DateTime.parse(
          '${date}T22:${index.toString().padLeft(2, '0')}:00',
        );
        await _reply(
          pipeline,
          now,
          requestId: 'req-signal-$index',
          session: 'session-1',
          actions: [RelationshipSignalAction(signal: signal, summary: summary)],
        );
      }
      now = DateTime(2026, 8, 10, 22);
      await _reply(
        pipeline,
        now,
        requestId: 'req-bounds-a',
        session: 'session-1',
        actions: const [
          RelationshipSignalAction(
            signal: RelationshipSignal.boundaryOpen,
            summary: '熬夜可以轻调侃',
            evidence: '用户笑并反逗',
          ),
          RelationshipSignalAction(
            signal: RelationshipSignal.boundaryOpen,
            summary: '咖啡胃疼可以翻旧账',
            evidence: '用户接受念叨',
          ),
        ],
      );
      now = DateTime(2026, 8, 10, 22, 5);
      await _reply(
        pipeline,
        now,
        requestId: 'req-bounds-b',
        session: 'session-1',
        actions: const [
          RelationshipSignalAction(
            signal: RelationshipSignal.boundaryOpen,
            summary: '工作话题可以多问',
            evidence: '用户主动展开',
          ),
          RelationshipSignalAction(
            signal: RelationshipSignal.boundaryClose,
            summary: '家庭话题能探多深',
            evidence: '用户绕开了',
          ),
        ],
      );
      final lifecycle = RelationshipLifecycle(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );

      await lifecycle.updateAtEndOfDay('2026-08-10', pipeline, dates);

      final contents = await File(
        '${temporaryDirectory.path}/relationship.md',
      ).readAsString(encoding: utf8);
      // 温度窗口新换旧：最旧的一条被挤出，窗口固定为三。
      expect(contents, isNot(contains('火气比较大')));
      expect(contents, contains('家庭关系'));
      expect(contents, contains('回复热度回升'));
      expect(contents, contains('话很少'));
      expect(contents, contains('- 2026-08-10'));
      // 边界证据同样限量保留：三条已确认只留最近两条。
      expect(contents, isNot(contains('熬夜可以轻调侃')));
      expect(contents, contains('咖啡胃疼可以翻旧账（用户接受念叨）'));
      expect(contents, contains('工作话题可以多问（用户主动展开）'));
      expect(contents, contains('待试探：'));
      expect(contents, contains('家庭话题能探多深（用户绕开了）'));
      // 温度不改变阶段。
      expect(contents, contains('stage: 初识'));
    },
  );

  test('a hand-written relationship file is never rewritten', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-foreign-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    const foreign = '这是用户自己写的关系笔记，别动它。\n';
    File(
      '${temporaryDirectory.path}/relationship.md',
    ).writeAsStringSync(foreign, encoding: utf8);
    var now = DateTime(2026, 8, 14, 23);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    await _reply(
      pipeline,
      now,
      requestId: 'req-1',
      session: 'session-1',
      actions: const [MemorySignalAction(summary: '聊了工作')],
    );
    final lifecycle = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );

    await lifecycle.updateAtEndOfDay('2026-08-14', pipeline, ['2026-08-14']);

    expect(
      File(
        '${temporaryDirectory.path}/relationship.md',
      ).readAsStringSync(encoding: utf8),
      foreign,
    );

    // 貌似受管结构但阶段值不受支持：同样视为手写，不改写。
    const foreignStage =
        '# relationship\n\nstage: 知己\nsince: 2026-01-01\n'
        '阶段描述: 用户自定义。\n';
    File(
      '${temporaryDirectory.path}/relationship.md',
    ).writeAsStringSync(foreignStage, encoding: utf8);
    await lifecycle.updateAtEndOfDay('2026-08-14', pipeline, ['2026-08-14']);
    expect(
      File(
        '${temporaryDirectory.path}/relationship.md',
      ).readAsStringSync(encoding: utf8),
      foreignStage,
    );
  });

  test('a fresh lifecycle instance resumes from persisted markdown', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-restart-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    var now = DateTime(2026, 8, 12, 22);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    final dates = <String>[];
    for (var day = 1; day <= 12; day += 1) {
      final date = '2026-08-${day.toString().padLeft(2, '0')}';
      dates.add(date);
      now = DateTime(2026, 8, day, 22);
      await _reply(
        pipeline,
        now,
        requestId: 'req-$day',
        session: 'session-1',
        actions: [
          RelationshipSignalAction(
            signal: day <= 2
                ? RelationshipSignal.deepTalk
                : RelationshipSignal.temperature,
            summary: '关系证据 $day',
          ),
        ],
      );
    }
    await _persistJudgment(pipeline, '2026-08-12', stage: '朋友');
    now = DateTime(2026, 8, 12, 22);
    final first = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    await first.updateAtEndOfDay('2026-08-12', pipeline, dates);
    await first.updateAtEndOfDay('2026-08-12', pipeline, dates);

    // 模拟 Host 重启：新实例从落盘文件恢复阶段。
    final second = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => now,
    );
    await second.updateAtEndOfDay('2026-08-12', pipeline, dates);
    final file = File('${temporaryDirectory.path}/relationship.md');
    expect(await _stage(file), RelationshipStage.familiar);
  });

  test(
    'the write gate keeps relationship.md within the token budget',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-relationship-budget-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      var now = DateTime(2026, 8, 10, 22);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final dates = <String>[];
      for (var day = 1; day <= 10; day += 1) {
        final date = '2026-08-${day.toString().padLeft(2, '0')}';
        dates.add(date);
        now = DateTime(2026, 8, day, 22);
        await _reply(
          pipeline,
          now,
          requestId: 'req-$day',
          session: 'session-1',
          actions: [
            RelationshipSignalAction(
              signal: RelationshipSignal.temperature,
              summary: '很长的温度描述 ${'暖' * 50} $day',
            ),
            RelationshipSignalAction(
              signal: RelationshipSignal.boundaryOpen,
              summary: '很长的边界描述 ${'开' * 50} $day',
              evidence: '很长的证据 ${'证' * 50}',
            ),
          ],
        );
      }
      // 模型整体判定熟悉：预算关不影响阶段判定本身。
      await _persistJudgment(pipeline, '2026-08-10', stage: '熟悉');
      now = DateTime(2026, 8, 10, 22);
      final lifecycle = RelationshipLifecycle(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );

      await lifecycle.updateAtEndOfDay('2026-08-10', pipeline, dates);

      final contents = await File(
        '${temporaryDirectory.path}/relationship.md',
      ).readAsString(encoding: utf8);
      expect(contents.runes.length, lessThanOrEqualTo(relationshipMaxRunes));
      expect(contents, contains('stage: 熟悉'));
    },
  );

  test(
    'catch-up backfill across old days promotes at most once per calendar day',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-relationship-backfill-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      var now = DateTime(2026, 8, 16, 22);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final dates = <String>[];
      for (var day = 1; day <= 12; day += 1) {
        final date = '2026-08-${day.toString().padLeft(2, '0')}';
        dates.add(date);
        now = DateTime(2026, 8, day, 22);
        await _reply(
          pipeline,
          now,
          requestId: 'req-$day',
          session: 'session-1',
          actions: [
            RelationshipSignalAction(
              signal: day == 2 || day == 5
                  ? RelationshipSignal.deepTalk
                  : RelationshipSignal.temperature,
              summary: '关系证据 $day',
            ),
          ],
        );
      }
      await _persistJudgment(pipeline, '2026-08-12', stage: '朋友');
      now = DateTime(2026, 8, 16, 22);
      final lifecycle = RelationshipLifecycle(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final file = File('${temporaryDirectory.path}/relationship.md');
      await lifecycle.updateAtEndOfDay('2026-08-01', pipeline, dates);

      // 启动补扫连续归档多个旧日：同一自然日只升一级。
      for (final date in dates.skip(1)) {
        await lifecycle.updateAtEndOfDay(date, pipeline, dates);
      }
      expect(await _stage(file), RelationshipStage.familiar);
    },
  );

  test('recovery restores the latest persisted judgment directly', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-recovery-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    // 回复发生在 08-05：episode 落当天日文件（processReply 按时钟
    // 所在日归档）。
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 5, 22),
    );
    await _reply(
      pipeline,
      DateTime(2026, 8, 5, 22),
      requestId: 'req-1',
      session: 'session-1',
      actions: const [MemorySignalAction(summary: '聊了工作')],
    );
    await _persistJudgment(
      pipeline,
      '2026-08-05',
      stage: '深交',
      description: '用户和她之间已经可以直接说心事，也经得起互相挑战',
    );
    // 损坏文件先被恢复流程隔离移走，rebuildForRecovery 面对的是
    // 「文件已不存在」的现场。
    File(
      '${temporaryDirectory.path}/relationship.md',
    ).writeAsStringSync('# relationship\n{损坏的结构', encoding: utf8);
    await File('${temporaryDirectory.path}/relationship.md').delete();
    final lifecycle = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 19, 21),
    );

    // 整体重建不受「每次最多一级」限制：直接按持久化判断定级。
    final rebuild = await lifecycle.rebuildForRecovery(pipeline, [
      '2026-08-05',
    ], '2026-08-19');

    expect(rebuild, RelationshipRebuild.restored);
    final contents = await File(
      '${temporaryDirectory.path}/relationship.md',
    ).readAsString(encoding: utf8);
    expect(contents, contains('stage: 深交'));
    expect(contents, contains('since: 2026-08-05'));
    expect(contents, contains('阶段描述: 用户和她之间已经可以直接说心事，也经得起互相挑战'));
  });

  test('recovery seeds stranger when no judgment survives', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-recovery-seed-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 5, 22),
    );
    await _reply(
      pipeline,
      DateTime(2026, 8, 5, 22),
      requestId: 'req-1',
      session: 'session-1',
      actions: const [MemorySignalAction(summary: '聊了工作')],
    );
    // 损坏文件先被恢复流程隔离移走，rebuildForRecovery 面对的是
    // 「文件已不存在」的现场。
    File(
      '${temporaryDirectory.path}/relationship.md',
    ).writeAsStringSync('# relationship\n{损坏的结构', encoding: utf8);
    await File('${temporaryDirectory.path}/relationship.md').delete();
    final lifecycle = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 19, 21),
    );

    // 没有任何持久化判断：按初识保守重建，等后续日终棘轮追认。
    final rebuild = await lifecycle.rebuildForRecovery(pipeline, [
      '2026-08-05',
    ], '2026-08-19');

    expect(rebuild, RelationshipRebuild.seeded);
    final contents = await File(
      '${temporaryDirectory.path}/relationship.md',
    ).readAsString(encoding: utf8);
    expect(contents, contains('stage: 初识'));
    expect(contents, contains('since: 2026-08-05'));
    expect(contents, contains('阶段描述: 初识阶段：以回应当前话题、倾听为主；'));
  });

  test('recovery skips an existing relationship file', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-relationship-recovery-skip-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    const existing =
        '# relationship\n\nstage: 朋友\nsince: 2026-07-01\n'
        '阶段描述: 朋友阶段：可以轻调侃。\n';
    File(
      '${temporaryDirectory.path}/relationship.md',
    ).writeAsStringSync(existing, encoding: utf8);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 5, 22),
    );
    await _reply(
      pipeline,
      DateTime(2026, 8, 5, 22),
      requestId: 'req-1',
      session: 'session-1',
      actions: const [MemorySignalAction(summary: '聊了工作')],
    );
    await _persistJudgment(pipeline, '2026-08-05', stage: '深交');
    final lifecycle = RelationshipLifecycle(
      memoryDirectory: temporaryDirectory.path,
      clock: () => DateTime(2026, 8, 19, 21),
    );

    // 文件仍在（无论可读与否）绝不动它。
    final rebuild = await lifecycle.rebuildForRecovery(pipeline, [
      '2026-08-05',
    ], '2026-08-19');

    expect(rebuild, RelationshipRebuild.skipped);
    expect(
      File(
        '${temporaryDirectory.path}/relationship.md',
      ).readAsStringSync(encoding: utf8),
      existing,
    );
  });
}

Future<RelationshipStage> _stage(File file) async =>
    parseRelationshipStage(await file.readAsString(encoding: utf8));

/// 模拟日终模型把阶段判断持久化进当日文件元数据（键与形态同
/// [DayUnderstanding.toJson]）。
Future<void> _persistJudgment(
  EpisodeMemoryPipeline pipeline,
  String date, {
  required String stage,
  String? description,
}) => pipeline.synchronizedOnDayFiles(() async {
  final day = await pipeline.readDay(date);
  final understanding = <String, Object?>{'relationshipStage': stage};
  if (description != null) {
    understanding['stageDescription'] = description;
  }
  await pipeline.writeFinalization(
    date,
    entries: day.entries,
    finalized: true,
    finalizedAt: DateTime.utc(2026, 8, 20, 23),
    understanding: understanding,
  );
});

Future<void> _reply(
  EpisodeMemoryPipeline pipeline,
  DateTime at, {
  required String requestId,
  required String session,
  required List<HiddenAction> actions,
}) => pipeline.processReply(
  session: RawSession(
    id: session,
    date: localSessionDate(at),
    segment: 1,
    createdAt: at.toUtc(),
    updatedAt: at.toUtc(),
    turns: [RawSessionTurn.user(requestId: requestId, text: '聊聊天', at: at)],
  ),
  requestId: requestId,
  hiddenActions: actions,
);
