import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('evidence thresholds map to stages at exact boundaries', () {
    RelationshipEvidence evidence({
      int totalEntries = 0,
      int activeDays = 0,
      int spanDays = 0,
      int deepTalkSignals = 0,
    }) => RelationshipEvidence(
      totalEntries: totalEntries,
      activeDays: activeDays,
      spanDays: spanDays,
      deepTalkSignals: deepTalkSignals,
    );

    expect(evaluateTargetStage(evidence()), RelationshipStage.stranger);
    // 熟悉：活跃天数与互动数量同时达标。
    expect(
      evaluateTargetStage(
        evidence(totalEntries: 3, activeDays: 3, spanDays: 3),
      ),
      RelationshipStage.familiar,
    );
    expect(
      evaluateTargetStage(
        evidence(totalEntries: 3, activeDays: 2, spanDays: 3),
      ),
      RelationshipStage.stranger,
    );
    expect(
      evaluateTargetStage(
        evidence(totalEntries: 2, activeDays: 3, spanDays: 3),
      ),
      RelationshipStage.stranger,
    );
    // 朋友：时间跨度、活跃天数与深谈证据同时达标。
    expect(
      evaluateTargetStage(
        evidence(
          totalEntries: 40,
          activeDays: 12,
          spanDays: 12,
          deepTalkSignals: 2,
        ),
      ),
      RelationshipStage.friend,
    );
    expect(
      evaluateTargetStage(
        evidence(
          totalEntries: 40,
          activeDays: 12,
          spanDays: 11,
          deepTalkSignals: 2,
        ),
      ),
      RelationshipStage.familiar,
    );
    expect(
      evaluateTargetStage(
        evidence(
          totalEntries: 40,
          activeDays: 12,
          spanDays: 12,
          deepTalkSignals: 1,
        ),
      ),
      RelationshipStage.familiar,
    );
    // 深交：更长的跨度与更多深谈证据。
    expect(
      evaluateTargetStage(
        evidence(
          totalEntries: 90,
          activeDays: 30,
          spanDays: 30,
          deepTalkSignals: 4,
        ),
      ),
      RelationshipStage.deep,
    );
    expect(
      evaluateTargetStage(
        evidence(
          totalEntries: 90,
          activeDays: 30,
          spanDays: 30,
          deepTalkSignals: 3,
        ),
      ),
      RelationshipStage.friend,
    );
    expect(
      evaluateTargetStage(
        evidence(
          totalEntries: 90,
          activeDays: 29,
          spanDays: 30,
          deepTalkSignals: 4,
        ),
      ),
      RelationshipStage.friend,
    );
  });

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
    expect(contents, contains('不调侃、不翻旧账'));
  });

  test(
    'promotion is ratcheted: one level per day, replays never repeat it',
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
      // 12 个活跃日 + 两次深谈：证据直接够到朋友。
      final dates = <String>[];
      for (var day = 1; day <= 12; day += 1) {
        final date = '2026-08-${day.toString().padLeft(2, '0')}';
        dates.add(date);
        now = DateTime(2026, 8, day, 22);
        final actions = <HiddenAction>[
          const MemorySignalAction(summary: '聊了日常'),
          if (day == 3 || day == 7)
            RelationshipSignalAction(
              signal: RelationshipSignal.deepTalk,
              summary: '深谈信号 $day',
            ),
        ];
        await _reply(
          pipeline,
          now,
          requestId: 'req-$day',
          session: 'session-1',
          actions: actions,
        );
      }
      final lifecycle = RelationshipLifecycle(
        memoryDirectory: temporaryDirectory.path,
        clock: () => now,
      );
      final file = File('${temporaryDirectory.path}/relationship.md');

      // 首次日终：播种并按整体证据评估——证据够到朋友，但单次最多升一级。
      await lifecycle.updateAtEndOfDay('2026-08-12', pipeline, dates);
      expect(await _stage(file), RelationshipStage.familiar);
      expect(
        await file.readAsString(encoding: utf8),
        contains('since: 2026-08-12'),
      );

      // 同一天重复执行：绝不重复升级。
      await lifecycle.updateAtEndOfDay('2026-08-12', pipeline, dates);
      await lifecycle.updateAtEndOfDay('2026-08-12', pipeline, dates);
      expect(await _stage(file), RelationshipStage.familiar);

      // 次日日终：再升一级到朋友；之后证据不变不再前进。
      now = DateTime(2026, 8, 13, 22);
      await lifecycle.updateAtEndOfDay('2026-08-13', pipeline, dates);
      expect(await _stage(file), RelationshipStage.friend);
      await lifecycle.updateAtEndOfDay('2026-08-13', pipeline, dates);
      expect(await _stage(file), RelationshipStage.friend);
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

  test('an advanced stage never regresses when evidence is thin', () async {
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
      // 活跃天数刻意压到 2（<3），保证阶段停在初识——温度不碰阶段。
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
      // 10 个活跃日够到熟悉：预算关不影响阶段判定本身。
      expect(contents, contains('stage: 熟悉'));
    },
  );
}

Future<RelationshipStage> _stage(File file) async =>
    parseRelationshipStage(await file.readAsString(encoding: utf8));

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
