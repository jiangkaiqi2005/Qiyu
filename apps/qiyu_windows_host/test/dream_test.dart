import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('the first bedtime dream accepts a validated draft', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-accept-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-14', '用户完成了人生第一次演讲');
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户和朋友去爬山');
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '用户完成人生第一次演讲', ['2026-08-14']),
        _item('人与关系', '用户有位常一起爬山的朋友', ['2026-08-15']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.accepted);
    final longMemory = File(
      '${directory.path}/long-memory.md',
    ).readAsStringSync();
    expect(longMemory, contains('# long-memory'));
    expect(longMemory, contains('## 重要事件'));
    expect(longMemory, contains('- 用户完成人生第一次演讲'));
    expect(longMemory, contains('## 人与关系'));
    expect(longMemory, contains('- 用户有位常一起爬山的朋友'));

    // 草稿清空，清单归档 history；首次接纳没有旧文件不产生备份。
    expect(
      File('${directory.path}/dream/draft/long-memory.md').existsSync(),
      isFalse,
    );
    expect(File('${directory.path}/dream/changes.md').existsSync(), isFalse);
    final history = Directory('${directory.path}/dream/history').listSync();
    expect(history, hasLength(1));
    expect(
      File('${directory.path}/dream/backup/long-memory.md').existsSync(),
      isFalse,
    );

    // 变更清单是诊断档案：逐条记录证据与结果。
    final archived = File(history.single.path).readAsStringSync();
    expect(archived, contains('result: accepted'));
    expect(archived, contains('证据: 2026-08-14'));

    // episodes 原样：Dream 只读证据层，绝不修改。
    expect(await pipeline.listEpisodeDates(), ['2026-08-14', '2026-08-15']);
  });

  test('less than seven days later the bedtime dream stays ineligible', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-interval-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了工作');
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '用户换了新工作', ['2026-08-15']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );
    expect((await dream.run(bedtime: true)).status, DreamStatus.accepted);
    final acceptedLongMemory = File(
      '${directory.path}/long-memory.md',
    ).readAsStringSync();

    // 三天后（少于七天）：不具备资格，模型绝不被调用。
    now = DateTime(2026, 8, 18, 23, 10);
    await _seedFinalizedDay(pipeline, '2026-08-18', '用户聊了新同事');
    final tooSoon = await dream.run(bedtime: true);
    expect(tooSoon.status, DreamStatus.notDue);
    expect(client.calls, hasLength(1));
    // 重复触发同样被间隔挡住。
    expect((await dream.run(bedtime: true)).status, DreamStatus.notDue);
    expect(client.calls, hasLength(1));
    expect(
      File('${directory.path}/long-memory.md').readAsStringSync(),
      acceptedLongMemory,
    );

    // 正好第七天：具备资格并接纳。证据白名单从上次成功之后算起，
    // 只能引用新递过去的整理日期。
    now = DateTime(2026, 8, 22, 23, 5);
    client.completions.add(
      ModelCompletion.reply(_candidate([
        _item('人与关系', '用户和新同事相处得来', ['2026-08-18']),
      ])),
    );
    final due = await dream.run(bedtime: true);
    expect(due.status, DreamStatus.accepted);
    expect(client.calls, hasLength(2));
    final refreshed = File(
      '${directory.path}/long-memory.md',
    ).readAsStringSync();
    expect(refreshed, contains('- 用户和新同事相处得来'));
    // 替换前备份了旧文件（T10 回滚依据）。
    expect(
      File('${directory.path}/dream/backup/long-memory.md').readAsStringSync(),
      acceptedLongMemory,
    );
  });

  test('without bedtime or pending dream never runs on its own', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-eligibility-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 9, 30, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-09-30', '用户聊了很久');
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '不应出现', ['2026-09-30']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );

    // 没有晚安、也没有 pending：即使材料齐全、间隔无限制也不运行。
    final outcome = await dream.run(bedtime: false);

    expect(outcome.status, DreamStatus.notEligible);
    expect(client.calls, isEmpty);
    expect(
      File('${directory.path}/long-memory.md').existsSync(),
      isFalse,
    );
  });

  test('model failure keeps old impressions and retries via catch-up', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-retry-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了搬家');
    File('${directory.path}/long-memory.md').writeAsStringSync(
      '# long-memory\n\n## 重要事件\n- 旧印象保留\n',
      encoding: utf8,
    );
    final client = _ScriptedDreamClient([
      const ModelCompletion.failure(ModelFailureKind.network),
      ModelCompletion.reply(_candidate([
        _item('重要事件', '旧印象保留', ['2026-08-15']),
        _item('重要事件', '用户下个月搬家', ['2026-08-15']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );

    final failed = await dream.run(bedtime: true);

    expect(failed.status, DreamStatus.modelFailed);
    // 失败不更新成功时间，也不破坏旧长期记忆。
    expect(
      File('${directory.path}/long-memory.md').readAsStringSync(),
      '# long-memory\n\n## 重要事件\n- 旧印象保留\n',
    );
    // 晚安请求转为待补跑：启动路径（非晚安）即可重试成功。
    final retried = await dream.run(bedtime: false);
    expect(retried.status, DreamStatus.accepted);
    final refreshed = File(
      '${directory.path}/long-memory.md',
    ).readAsStringSync();
    expect(refreshed, contains('- 旧印象保留'));
    expect(refreshed, contains('- 用户下个月搬家'));
  });

  test('duplicate items are merged before the gates run', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-dedup-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了近况');
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '用户喜欢爬山', ['2026-08-15']),
        _item('模式与轨迹', '用户喜欢爬山', ['2026-08-15']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.accepted);
    final longMemory = File(
      '${directory.path}/long-memory.md',
    ).readAsStringSync();
    // 同文条目只保留一条：去重是写入前的确定性兜底。
    expect('用户喜欢爬山'.allMatches(longMemory), hasLength(1));
  });

  test('an unparseable model reply rejects without touching memory', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-unparseable-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了搬家');
    final client = _ScriptedDreamClient([
      const ModelCompletion.reply('这一次没有按格式输出。'),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.modelFailed);
    expect(outcome.detail, 'unparseable');
    expect(File('${directory.path}/long-memory.md').existsSync(), isFalse);
    expect(
      File('${directory.path}/dream/changes.md').readAsStringSync(),
      contains('result: rejected (unparseable)'),
    );
  });

  group('draft gates reject the whole draft', () {
    Future<void> expectRejected({
      required String candidate,
      required String reason,
      required List<String> candidateTexts,
      String? existingLongMemory,
      Future<void> Function(Directory directory)? prepare,
    }) async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-dream-gate-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final now = DateTime(2026, 8, 15, 23, 10);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: directory.path,
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了近况');
      if (existingLongMemory != null) {
        File('${directory.path}/long-memory.md').writeAsStringSync(
          existingLongMemory,
          encoding: utf8,
        );
      }
      if (prepare != null) {
        await prepare(directory);
      }
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        openLoopStore: OpenLoopStore(memoryDirectory: directory.path),
        modelClient: _ScriptedDreamClient([ModelCompletion.reply(candidate)]),
        clock: () => now,
      );

      final outcome = await dream.run(bedtime: true);

      expect(outcome.status, DreamStatus.validationFailed);
      expect(outcome.detail, reason);
      expect(
        File('${directory.path}/long-memory.md').existsSync()
            ? File('${directory.path}/long-memory.md').readAsStringSync()
            : null,
        existingLongMemory,
        reason: '验证失败绝不能改动长期印象',
      );
      expect(
        File('${directory.path}/dream/changes.md').readAsStringSync(),
        contains('result: rejected ($reason)'),
      );
      // 作废草稿清空，只留清单。
      expect(
        File('${directory.path}/dream/draft/long-memory.md').existsSync(),
        isFalse,
      );
      final state = _decodeStateFile(
        File('${directory.path}/dream/state.md').readAsStringSync(),
      );
      expect(state['lastSuccess'], isNull, reason: '验证失败不得更新上次成功时间');
      expect(state['pending'], isTrue, reason: '失败的晚安请求留给补跑');
      // 被拒草稿的候选原文绝不落盘：清单只记结果码与数量。
      final changes = File(
        '${directory.path}/dream/changes.md',
      ).readAsStringSync();
      for (final text in candidateTexts) {
        expect(changes, isNot(contains(text)));
      }
    }

    test('fabricated evidence', () async {
      await expectRejected(
        candidate: _candidate([
          _item('重要事件', '用户去过南极', ['2020-01-01']),
        ]),
        reason: 'unknown-evidence',
        candidateTexts: const ['用户去过南极'],
      );
    });

    test('month evidence not handed over', () async {
      await expectRejected(
        candidate: _candidate([
          _item('重要事件', '用户上半年很忙', ['2026-01']),
        ]),
        reason: 'unknown-evidence',
        candidateTexts: const ['用户上半年很忙'],
      );
    });

    test('missing evidence', () async {
      await expectRejected(
        candidate: _candidate([
          _item('重要事件', '用户喜欢爬山', []),
        ]),
        reason: 'missing-evidence',
        candidateTexts: const ['用户喜欢爬山'],
      );
    });

    test('sensitive content', () async {
      await expectRejected(
        candidate: _candidate([
          _item(
            '重要事件',
            '用户的密钥是 sk-abcdefghijklmnopqrstuvwxyz123456',
            ['2026-08-15'],
          ),
        ]),
        reason: 'sensitive',
        candidateTexts: const ['sk-abcdefghijklmnopqrstuvwxyz123456'],
      );
    });

    test('banned content', () async {
      await expectRejected(
        candidate: _candidate([
          _item('重要事件', '用户下周去医院检查', ['2026-08-15']),
        ]),
        reason: 'banned',
        candidateTexts: const ['用户下周去医院检查'],
        prepare: (directory) async {
          final store = OpenLoopStore(memoryDirectory: directory.path);
          expect(await store.banTitle('医院检查'), isTrue);
        },
      );
    });

    test('mutually contradictory items', () async {
      await expectRejected(
        candidate: _candidate([
          _item('重要事件', '用户去年换了工作', ['2026-08-15']),
          _item('重要事件', '用户去年没有换工作', ['2026-08-15']),
        ]),
        reason: 'contradiction',
        candidateTexts: const ['用户去年换了工作', '用户去年没有换工作'],
      );
    });

    test('too many items', () async {
      await expectRejected(
        candidate: _candidate([
          for (var index = 0; index < dreamMaxItems + 1; index += 1)
            _item('模式与轨迹', '印象条目$index', ['2026-08-15']),
        ]),
        reason: 'too-many',
        candidateTexts: const ['印象条目0', '印象条目24'],
      );
    });

    test('over budget', () async {
      await expectRejected(
        candidate: _candidate([
          // 24 条互不相同的满长条目：总量必然超出 1500 runes 预算。
          for (var index = 0; index < dreamMaxItems; index += 1)
            _item(
              '模式与轨迹',
              _uniqueMaxRunesText(index),
              ['2026-08-15'],
            ),
        ]),
        reason: 'over-budget',
        candidateTexts: [_uniqueMaxRunesText(0)],
      );
    });

    test('empty candidate over existing impressions', () async {
      await expectRejected(
        candidate: _candidate(const []),
        reason: 'empty',
        candidateTexts: const [],
        existingLongMemory: '# long-memory\n\n## 重要事件\n- 旧印象\n',
      );
    });
  });

  test('a failed acceptance keeps the old long-memory byte for byte', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-atomic-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了近况');
    const oldContent = '# long-memory\n\n## 重要事件\n- 旧印象\n';
    File('${directory.path}/long-memory.md').writeAsStringSync(
      oldContent,
      encoding: utf8,
    );
    final longMemoryPath = '${directory.path}${Platform.pathSeparator}'
        'long-memory.md';
    final candidate = _candidate([
      _item('重要事件', '新印象', ['2026-08-15']),
    ]);
    final failingDream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: _ScriptedDreamClient([ModelCompletion.reply(candidate)]),
      clock: () => now,
      atomicWriter: _TargetedFailingWriter((path) => path == longMemoryPath),
    );

    final failed = await failingDream.run(bedtime: true);

    expect(failed.status, DreamStatus.writeFailed);
    // 旧文件一字不动；备份已在替换前写好，可以回滚。
    expect(
      File(longMemoryPath).readAsStringSync(),
      oldContent,
    );
    expect(
      File('${directory.path}/dream/backup/long-memory.md').readAsStringSync(),
      oldContent,
    );
    // 上次成功时间未更新：pending 留给补跑。
    // 修复写入后，补跑路径直接接纳。
    final recoveredDream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: _ScriptedDreamClient([ModelCompletion.reply(candidate)]),
      clock: () => now,
    );
    final recovered = await recoveredDream.run(bedtime: false);
    expect(recovered.status, DreamStatus.accepted);
    expect(File(longMemoryPath).readAsStringSync(), contains('- 新印象'));
  });

  test('daily finalization never resets or bypasses the dream interval', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-finalization-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了近况');
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '基准印象', ['2026-08-15']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );
    expect((await dream.run(bedtime: true)).status, DreamStatus.accepted);
    final stateAfterSuccess = File(
      '${directory.path}/dream/state.md',
    ).readAsStringSync();

    // 之后三天日终归档照常执行。
    for (final day in ['2026-08-16', '2026-08-17', '2026-08-18']) {
      await _seedUnfinalizedDay(pipeline, day, '当天聊了别的事');
    }
    final finalization = DailyFinalizationService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      clock: () => now,
    );
    for (final day in ['2026-08-16', '2026-08-17', '2026-08-18']) {
      now = DateTime(2026, 8, int.parse(day.substring(8)), 23, 20);
      final outcome = await finalization.finalizeDay(day);
      expect(outcome.status, FinalizationStatus.finalized);
    }

    // Dream 状态一字未变，晚安触发仍被七天间隔挡住。
    expect(
      File('${directory.path}/dream/state.md').readAsStringSync(),
      stateAfterSuccess,
    );
    final blocked = await dream.run(bedtime: true);
    expect(blocked.status, DreamStatus.notDue);
    expect(client.calls, hasLength(1));
  });

  test('no finalized material means nothing to reorganize', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-nomaterial-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    final client = _ScriptedDreamClient(const []);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.skippedNoMaterial);
    expect(client.calls, isEmpty);
    expect(File('${directory.path}/long-memory.md').existsSync(), isFalse);
  });

  test('no provider never fabricates long-term impressions', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-noprovider-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了近况');
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: null,
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.skippedNoProvider);
    expect(File('${directory.path}/long-memory.md').existsSync(), isFalse);

    // 配置 Provider 后，留下的晚安请求在补跑路径兑现。
    final configured = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: _ScriptedDreamClient([
        ModelCompletion.reply(_candidate([
          _item('重要事件', '迟来的印象', ['2026-08-15']),
        ])),
      ]),
      clock: () => now,
    );
    final caughtUp = await configured.run(bedtime: false);
    expect(caughtUp.status, DreamStatus.accepted);
    expect(
      File('${directory.path}/long-memory.md').readAsStringSync(),
      contains('- 迟来的印象'),
    );
  });

  test('an unreadable long-memory waits for recovery instead of overwrite', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-corrupt-memory-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了近况');
    const corrupted = '这是用户手写坏的内容，没有结构。';
    File('${directory.path}/long-memory.md').writeAsStringSync(
      corrupted,
      encoding: utf8,
    );
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '新印象', ['2026-08-15']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.skippedUnreadable);
    expect(client.calls, isEmpty);
    expect(
      File('${directory.path}/long-memory.md').readAsStringSync(),
      corrupted,
    );
  });

  test('a corrupted dream state refuses to run', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-corrupt-state-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了近况');
    File('${directory.path}/dream/state.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('坏掉的状态\n', encoding: utf8);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: _ScriptedDreamClient(const []),
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.skippedUnreadable);
    expect(File('${directory.path}/long-memory.md').existsSync(), isFalse);
  });

  test('input respects the summary window and the month cap', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-budget-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 8, 20, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    // 连续 20 天 finalized 摘要：窗口只递最近 14 天。
    for (var index = 1; index <= 20; index += 1) {
      final date = '2026-08-${'$index'.padLeft(2, '0')}';
      await _seedFinalizedDay(pipeline, date, '第$index天的摘要内容');
    }
    // 8 个月的月摘要：至多递最近 6 个月。
    final compressor = MonthlySummaryStore(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );
    for (var month = 1; month <= 8; month += 1) {
      final monthKey = '2026-${'$month'.padLeft(2, '0')}';
      await _seedFinalizedDay(
        pipeline,
        '$monthKey-05',
        '$monthKey 的月度材料',
      );
      await compressor.compressMonth(monthKey);
    }
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '编造旧日期', ['2026-08-01']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      monthlySummary: compressor,
      modelClient: client,
      clock: () => now,
    );

    // 证据白名单与输入窗口同步收窄：窗口外日期不得作为证据。
    // （先跑拒绝场景，成功后七天间隔会挡住同一天的下一次运行。）
    final rejected = await dream.run(bedtime: true);
    expect(rejected.status, DreamStatus.validationFailed);
    expect(rejected.detail, 'unknown-evidence');
    final rejectedPrompt = client.calls.single
        .map((message) => message.content)
        .join('\n');
    expect(rejectedPrompt, isNot(contains('2026-08-01:')));

    // 换成合规候选：接纳，并检查输入窗口与月上限。
    client.completions.add(
      ModelCompletion.reply(_candidate([
        _item('重要事件', '近况印象', ['2026-08-20']),
      ])),
    );
    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.accepted);
    final prompt = client.calls.last
        .map((message) => message.content)
        .join('\n');
    // 日摘要窗口：最近 14 天在内，更早的被裁掉。
    expect(prompt, contains('2026-08-20: 第20天的摘要内容'));
    expect(prompt, contains('2026-08-07: 第7天的摘要内容'));
    expect(prompt, isNot(contains('2026-08-06:')));
    // 月摘要上限：最近 6 个月在内，更早的被裁掉。
    expect(prompt, contains('### 2026-08'));
    expect(prompt, contains('### 2026-03'));
    expect(prompt, isNot(contains('### 2026-02')));
    expect(prompt, isNot(contains('### 2026-01')));
  });

  test('a stale draft from an interrupted run is discarded', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-stale-draft-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了近况');
    File('${directory.path}/dream/draft/long-memory.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('上一轮被打断的草稿\n', encoding: utf8);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: _ScriptedDreamClient([
        ModelCompletion.reply(_candidate([
          _item('重要事件', '新印象', ['2026-08-15']),
        ])),
      ]),
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.accepted);
    expect(
      File('${directory.path}/dream/draft/long-memory.md').existsSync(),
      isFalse,
    );
    expect(
      File('${directory.path}/long-memory.md').readAsStringSync(),
      contains('- 新印象'),
    );
  });

  test('markBedtime registers the request before the dream chain runs', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-mark-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 8, 15, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-15', '用户聊了近况');
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: null,
      clock: () => now,
    );

    // 晚安预登记：间隔已到，pending 先落盘；重复登记幂等。
    await dream.markBedtime();
    var state = _decodeStateFile(
      File('${directory.path}/dream/state.md').readAsStringSync(),
    );
    expect(state['pending'], isTrue);
    expect(state['lastSuccess'], isNull);
    await dream.markBedtime();
    state = _decodeStateFile(
      File('${directory.path}/dream/state.md').readAsStringSync(),
    );
    expect(state['pending'], isTrue);

    // 成功之后七天内的晚安不再登记：间隔未到。
    final accepted = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: _ScriptedDreamClient([
        ModelCompletion.reply(_candidate([
          _item('重要事件', '一条印象', ['2026-08-15']),
        ])),
      ]),
      clock: () => now,
    );
    expect((await accepted.run(bedtime: true)).status, DreamStatus.accepted);
    now = DateTime(2026, 8, 18, 23, 10);
    await dream.markBedtime();
    state = _decodeStateFile(
      File('${directory.path}/dream/state.md').readAsStringSync(),
    );
    expect(state['pending'], isFalse);
    expect(state['lastSuccess'], isNotNull);
  });

  test('an oversized side input is trimmed months first, then days', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-trim-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime(2026, 8, 20, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-07-05', '七月的月度材料');
    final compressor = MonthlySummaryStore(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );
    await compressor.compressMonth('2026-07');
    for (final date in ['2026-08-18', '2026-08-19', '2026-08-20']) {
      await _seedFinalizedDay(pipeline, date, '八月的日摘要内容');
    }
    // 关系与未闭环线索不参与裁剪：一份接近预算的 open-loops 把总量顶过
    // 输入预算，验证裁剪循环先裁最旧月摘要、再裁最旧日摘要。
    File('${directory.path}/open-loops.md').writeAsStringSync(
      '# open-loops\n\n${'超长的未闭环线索内容。' * 811}',
      encoding: utf8,
    );
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '一条印象', ['2026-08-20']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      monthlySummary: compressor,
      modelClient: client,
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    expect(outcome.status, DreamStatus.accepted);
    final prompt = client.calls.single
        .map((message) => message.content)
        .join('\n');
    expect(prompt, contains('超长的未闭环线索内容'));
    // 月摘要整份被裁，日摘要从最旧开始裁（7 月日与 8 月近日保留）。
    expect(prompt, isNot(contains('### 2026-07')));
    expect(prompt, isNot(contains('2026-07-05: 七月的月度材料')));
    expect(prompt, contains('2026-08-20: 八月的日摘要内容'));
    // 证据白名单随裁剪同步：被裁掉的日期不再能当证据。
    expect(prompt, isNot(contains('- 2026-07-05:')));
  });

  test('a side input that crowds out all organized material skips the model', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-trim-all-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime(2026, 8, 20, 23, 10);
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      clock: () => now,
    );
    await _seedFinalizedDay(pipeline, '2026-08-20', '八月的日摘要内容');
    File('${directory.path}/open-loops.md').writeAsStringSync(
      '# open-loops\n\n${'超长的未闭环线索内容。' * 980}',
      encoding: utf8,
    );
    final client = _ScriptedDreamClient(const []);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => now,
    );

    final outcome = await dream.run(bedtime: true);

    // 侧输入占满预算、整理材料被裁空：不调模型也不记成功。
    expect(outcome.status, DreamStatus.skippedNoMaterial);
    expect(client.calls, isEmpty);
    expect(File('${directory.path}/long-memory.md').existsSync(), isFalse);
  });

  test('parseLongMemory only accepts the four-section structure', () {
    final valid = parseLongMemory(
      '# long-memory\n\n## 人与关系\n- 妈妈\n\n## 共同过往\n- 深夜聊天的梗\n',
    );
    expect(valid.readable, isTrue);
    expect(valid.sections['人与关系'], ['妈妈']);
    expect(valid.sections['共同过往'], ['深夜聊天的梗']);
    expect(valid.allItems, ['妈妈', '深夜聊天的梗']);

    expect(parseLongMemory('随便一段话').readable, isFalse);
    expect(
      parseLongMemory('# long-memory\n\n## 未知分区\n- 条目').readable,
      isFalse,
    );
    expect(
      parseLongMemory('# long-memory\n\n自由文字没有列表符').readable,
      isFalse,
    );
  });

  test('clipLongMemoryBlock trims tail sections first within budget', () {
    final sections = <String, List<String>>{
      for (final section in longMemorySections)
        section: [for (var index = 0; index < 6; index += 1) '$section的印象$index'],
    };
    final content = renderLongMemory(sections);
    final clipped = clipLongMemoryBlock(content, 300);
    expect(clipped.runes.length, lessThanOrEqualTo(300));
    // 逆序裁剪：共同过往先被裁，人与关系尽量保留。
    expect(clipped, contains('## 人与关系'));
    expect(clipped, isNot(contains('共同过往的印象5')));
    // 全部裁空时空块不输出。
    expect(clipLongMemoryBlock(content, 20), '');
    // 预算内原样保留。
    expect(clipLongMemoryBlock(content, content.runes.length), content);
    // 不可解析内容：预算内原样保留，超预算整体放弃不裁半。
    expect(clipLongMemoryBlock('随手写的', 100), '随手写的');
    expect(clipLongMemoryBlock('坏' * 200, 100), '');
  });
}

/// 播种已归档（finalized）的 episode 日文件。
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

/// 播种未归档的 episode 日文件，供日终归档测试使用。
Future<void> _seedUnfinalizedDay(
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
    finalized: false,
  ),
);

String _candidate(List<Map<String, Object?>> items) =>
    jsonEncode({'items': items});

/// 互不相同的满长（60 runes）条目文本。
String _uniqueMaxRunesText(int index) {
  final prefix = '第$index条';
  return prefix + '长' * (longMemoryItemMaxRunes - prefix.runes.length);
}

Map<String, Object?> _item(
  String section,
  String text,
  List<String> evidence,
) => {'section': section, 'text': text, 'evidence': evidence};

/// 解码 dream/state.md 的元数据，供断言上次成功时间与 pending 使用。
Map<String, Object?> _decodeStateFile(String contents) {
  final match = RegExp(
    r'^<!-- qiyu-dream-state:([A-Za-z0-9_-]+) -->\r?$',
    multiLine: true,
  ).firstMatch(contents);
  expect(match, isNotNull);
  final value = match!.group(1)!;
  final padded = value.padRight(value.length + (4 - value.length % 4) % 4, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded)))
      as Map<String, Object?>;
}

final class _ScriptedDreamClient implements ProviderChatClient {
  _ScriptedDreamClient(this.completions);

  final List<ModelCompletion?> completions;
  final List<List<ModelMessage>> calls = [];
  var _index = 0;

  @override
  Future<ModelCompletion?> complete(List<ModelMessage> messages) async {
    calls.add(messages);
    if (completions.isEmpty) {
      return null;
    }
    final completion = completions[
      _index < completions.length ? _index : completions.length - 1
    ];
    _index += 1;
    return completion;
  }
}

final class _TargetedFailingWriter implements AtomicTextWriter {
  _TargetedFailingWriter(this.shouldFail);

  final bool Function(String path) shouldFail;
  final AtomicTextWriter _delegate = const IoAtomicTextWriter();

  @override
  Future<void> replace(String path, String contents) {
    if (shouldFail(path)) {
      throw const FileSystemException('mock interrupted write');
    }
    return _delegate.replace(path, contents);
  }
}
