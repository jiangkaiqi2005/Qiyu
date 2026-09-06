import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('the first bedtime dream accepts a validated draft', () async {
    var now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-accept-test-',
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

  test('less than three days later the bedtime dream stays ineligible', () async {
    var now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-interval-test-',
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

    // 两天后（少于三天）：不具备资格，模型绝不被调用。
    now = DateTime(2026, 8, 17, 23, 10);
    await _seedFinalizedDay(pipeline, '2026-08-17', '用户聊了新同事');
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

    // 正好第三天：具备资格并接纳。证据白名单从上次成功之后算起，
    // 只能引用新递过去的整理日期。
    now = DateTime(2026, 8, 18, 23, 5);
    client.completions.add(
      ModelCompletion.reply(_candidate([
        _item('人与关系', '用户和新同事相处得来', ['2026-08-17']),
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
    var now = DateTime(2026, 9, 30, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-eligibility-test-',
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
    var now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-retry-test-',
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
    final now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-dedup-test-',
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
    var now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-unparseable-test-',
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
      final now = DateTime(2026, 8, 15, 23, 10);
      final (:directory, :pipeline) = await _dreamFixture(
        'qiyu-dream-gate-test-',
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
    var now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-atomic-test-',
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
    var now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-finalization-test-',
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

    // 之后两天日终归档照常执行。
    for (final day in ['2026-08-16', '2026-08-17']) {
      await _seedUnfinalizedDay(pipeline, day, '当天聊了别的事');
    }
    final finalization = DailyFinalizationService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      clock: () => now,
    );
    for (final day in ['2026-08-16', '2026-08-17']) {
      now = DateTime(2026, 8, int.parse(day.substring(8)), 23, 20);
      final outcome = await finalization.finalizeDay(day);
      expect(outcome.status, FinalizationStatus.finalized);
    }

    // Dream 状态一字未变，晚安触发仍被三天间隔挡住（两天后仍未满三天）。
    expect(
      File('${directory.path}/dream/state.md').readAsStringSync(),
      stateAfterSuccess,
    );
    final blocked = await dream.run(bedtime: true);
    expect(blocked.status, DreamStatus.notDue);
    expect(client.calls, hasLength(1));
  });

  test('no finalized material means nothing to reorganize', () async {
    final now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-nomaterial-test-',
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
    var now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-noprovider-test-',
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
    final now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-corrupt-memory-test-',
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
    final now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-corrupt-state-test-',
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

  test('healthFacts shares the eligibility interval semantics', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-dream-health-facts-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: EpisodeMemoryPipeline(
        memoryDirectory: directory.path,
        clock: () => DateTime(2026, 8, 14, 22),
      ),
      clock: () => DateTime(2026, 8, 14, 22),
    );

    // 从未运行：无日差，间隔天然满足。
    var facts = await dream.healthFacts();
    expect(facts.lastSuccess, isNull);
    expect(facts.daysSinceLastSuccess, isNull);
    expect(facts.pending, isFalse);
    expect(facts.intervalSatisfied, isTrue);

    // 两天前成功且有待补跑：间隔未满（2 < 3），pending 原样透传。
    File('${directory.path}/dream/state.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        _encodedState(lastSuccess: DateTime(2026, 8, 12), pending: true),
        encoding: utf8,
      );
    facts = await dream.healthFacts();
    expect(facts.daysSinceLastSuccess, 2);
    expect(facts.intervalSatisfied, isFalse);
    expect(facts.pending, isTrue);

    // 三天前成功：间隔已满（3 >= 3）。
    File('${directory.path}/dream/state.md').writeAsStringSync(
      _encodedState(lastSuccess: DateTime(2026, 8, 11)),
      encoding: utf8,
    );
    facts = await dream.healthFacts();
    expect(facts.daysSinceLastSuccess, 3);
    expect(facts.intervalSatisfied, isTrue);
  });

  test('input respects the summary window and the month cap', () async {
    var now = DateTime(2026, 8, 20, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-budget-test-',
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
    final now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-stale-draft-test-',
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
    var now = DateTime(2026, 8, 15, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-mark-test-',
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

    // 成功之后三天内的晚安不再登记：间隔未到。
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
    now = DateTime(2026, 8, 17, 23, 10);
    await dream.markBedtime();
    state = _decodeStateFile(
      File('${directory.path}/dream/state.md').readAsStringSync(),
    );
    expect(state['pending'], isFalse);
    expect(state['lastSuccess'], isNotNull);
  });

  test('an oversized side input is trimmed months first, then days', () async {
    final now = DateTime(2026, 8, 20, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-trim-test-',
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
    final now = DateTime(2026, 8, 20, 23, 10);
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-trim-all-test-',
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

  group('dream root proposals (ticket 17)', () {
    test('parseDreamRootProposals whitelists ops, branches and id shapes', () {
      final raw = jsonEncode({
        'items': <Object?>[],
        'rootProposals': [
          {
            'op': 'promote',
            'branch': 'expression',
            'claim': '用户尴尬时倾向自嘲',
            'middles': ['EX-M001', 'bogus', 'EX-M002'],
          },
          {
            'op': 'absorb',
            'branch': 'values',
            'root': 'VA-R001',
            'middles': ['VA-M002'],
          },
          {
            'op': 'demote',
            'branch': 'preferences',
            'root': 'PR-R001',
            'counter': 'PR-M003',
          },
          {
            'op': 'merge',
            'branch': 'preferences',
            'claim': '合并主张',
            'roots': ['PR-R001', 'PR-R002'],
          },
          {'op': 'explode', 'branch': 'identity'},
          {
            'op': 'promote',
            'branch': 'not-a-branch',
            'claim': 'x',
            'middles': ['XX-M001'],
          },
          // demote 缺 counter：整条丢弃。
          {'op': 'demote', 'branch': 'identity', 'root': 'ID-R001'},
        ],
      });

      final ops = parseDreamRootProposals(raw);

      expect(ops, hasLength(4));
      final promote = ops[0] as PersonaPromoteOp;
      expect(promote.branchWire, 'expression');
      // 形态不合法的 ID 被逐条过滤。
      expect(promote.middleIds, ['EX-M001', 'EX-M002']);
      expect(ops[1], isA<PersonaAbsorbOp>());
      expect(ops[2], isA<PersonaDemoteOp>());
      expect((ops[2] as PersonaDemoteOp).counterId, 'PR-M003');
      expect(ops[3], isA<PersonaMergeOp>());
      // 无结构或无提案字段：空列表。
      expect(parseDreamRootProposals('不是 JSON'), isEmpty);
      expect(parseDreamRootProposals(jsonEncode({'items': []})), isEmpty);
    });

    test('an accepted dream applies validated root proposals and projects persona.md', () async {
      final now = DateTime(2026, 8, 15, 23, 10);
      final (:directory, :pipeline) = await _dreamFixture(
        'qiyu-dream-roots-accept-',
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊到一次尴尬经历');
      _seedPersonaBranch(directory.path, 'expression.md', '''# 性格表达

## 未归根中间节点

### [EX-M001] 重复模式｜用户尴尬时倾向自嘲
- 形成: 2026-07-20 · 复核: 2026-08-02
- [EX-L001] 2026-07-20 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/07/2026-07-20.md [m1]
- [EX-L002] 2026-08-02 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/08/2026-08-02.md [m2]
''');
      final client = _ScriptedDreamClient([
        ModelCompletion.reply(_candidateWithRoots([
          _item('模式与轨迹', '2026年夏天起用户更愿意谈起尴尬经历', ['2026-08-14']),
        ], [
          {
            'op': 'promote',
            'branch': 'expression',
            'claim': '用户尴尬时倾向自嘲',
            'middles': ['EX-M001'],
          },
        ])),
      ]);
      final personaTree = PersonaTreeStore(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
      );
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        personaTree: personaTree,
        modelClient: client,
        clock: () => now,
      );

      final outcome = await dream.run(bedtime: true);

      expect(outcome.status, DreamStatus.accepted);
      expect(outcome.rootOpsApplied, 1);
      expect(outcome.rootOpsRejected, 0);
      final active = File(
        '${directory.path}/persona-tree/expression.md',
      ).readAsStringSync();
      expect(active, contains('## [EX-R001] 用户尴尬时倾向自嘲'));
      expect(active, isNot(contains('## 未归根中间节点')));
      final persona = File('${directory.path}/persona.md').readAsStringSync();
      expect(persona, contains('## 性格与表达'));
      expect(persona, contains('- 用户尴尬时倾向自嘲'));
      // 递给模型的结构里包含未归根理解；清单记录提案裁决（只含 ID）。
      expect(
        client.calls.single.last.content,
        contains('未归根 [EX-M001] 重复模式｜用户尴尬时倾向自嘲'),
      );
      // 成长线与共同过往的写作要求进入系统提示词。
      expect(
        client.calls.single.first.content,
        contains('模式与轨迹按成长线写'),
      );
      expect(
        client.calls.single.first.content,
        contains('共同过往只收双方真实互动'),
      );
      final history = Directory('${directory.path}/dream/history').listSync();
      final archived = File(history.single.path).readAsStringSync();
      expect(archived, contains('根节点提案数: 1'));
      expect(archived, contains('- promote expression(EX-M001): accepted'));
    });

    test('proposals without enough evidence are rejected and leave the tree untouched', () async {
      final now = DateTime(2026, 8, 15, 23, 10);
      final (:directory, :pipeline) = await _dreamFixture(
        'qiyu-dream-roots-insufficient-',
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊到跑步');
      // EX-M001 单日期行为证据：不够任何一条升根门槛。
      // EX-M002 证据跨度足够，但挂着未解决的 conflict 叶：同样不得升根。
      _seedPersonaBranch(directory.path, 'expression.md', '''# 性格表达

## 未归根中间节点

### [EX-M001] 重复模式｜用户靠跑步解压
- 形成: 2026-08-10 · 复核: 2026-08-10
- [EX-L001] 2026-08-10 | 行为观察 | support | 用户靠跑步解压 | episodes/2026/08/2026-08-10.md [m1]

### [EX-M002] 重复模式｜用户尴尬时倾向自嘲
- 形成: 2026-07-20 · 复核: 2026-08-09
- [EX-L002] 2026-07-20 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/07/2026-07-20.md [m2]
- [EX-L003] 2026-08-02 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/08/2026-08-02.md [m3]
- [EX-L004] 2026-08-09 | 行为观察 | conflict | 用户被夸时一本正经道谢 | episodes/2026/08/2026-08-09.md [m4]
''');
      final client = _ScriptedDreamClient([
        ModelCompletion.reply(_candidateWithRoots([
          _item('模式与轨迹', '用户近期常聊跑步', ['2026-08-14']),
        ], [
          {
            'op': 'promote',
            'branch': 'expression',
            'claim': '用户靠跑步解压',
            'middles': ['EX-M001'],
          },
          {
            'op': 'promote',
            'branch': 'expression',
            'claim': '用户尴尬时倾向自嘲',
            'middles': ['EX-M002'],
          },
        ])),
      ]);
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        personaTree: PersonaTreeStore(
          memoryDirectory: directory.path,
          episodePipeline: pipeline,
        ),
        modelClient: client,
        clock: () => now,
      );

      final outcome = await dream.run(bedtime: true);

      expect(outcome.status, DreamStatus.accepted);
      expect(outcome.rootOpsApplied, 0);
      expect(outcome.rootOpsRejected, 2);
      final active = File(
        '${directory.path}/persona-tree/expression.md',
      ).readAsStringSync();
      expect(active, contains('## 未归根中间节点'));
      expect(active, isNot(contains('[EX-R')));
      expect(File('${directory.path}/persona.md').existsSync(), isFalse);
      final history = Directory('${directory.path}/dream/history').listSync();
      final archived = File(history.single.path).readAsStringSync();
      expect(
        archived,
        contains('- promote expression(EX-M001): rejected(insufficient-evidence)'),
      );
      // 未解决冲突（挂着 conflict 叶）的理解不得升根。
      expect(
        archived,
        contains('- promote expression(EX-M002): rejected(unresolved-conflict)'),
      );
    });

    test('time-bound, sensitive and banned root claims are rejected one by one', () async {
      final now = DateTime(2026, 8, 15, 23, 10);
      final (:directory, :pipeline) = await _dreamFixture(
        'qiyu-dream-roots-claims-',
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了近况');
      // 三个不同分支各挂一条够门槛的自述中间理解。
      _seedPersonaBranch(directory.path, 'expression.md', '''# 性格表达

## 未归根中间节点

### [EX-M001] 重复模式｜用户尴尬时倾向自嘲
- 形成: 2026-07-20 · 复核: 2026-08-02
- [EX-L001] 2026-07-20 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/07/2026-07-20.md [m1]
- [EX-L002] 2026-08-02 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/08/2026-08-02.md [m2]
''');
      _seedPersonaBranch(directory.path, 'values.md', '''# 价值原则

## 未归根中间节点

### [VA-M001] 重复模式｜用户看重说到做到
- 形成: 2026-07-20 · 复核: 2026-08-02
- [VA-L001] 2026-07-20 | 明确自述 | support | 用户看重说到做到 | episodes/2026/07/2026-07-20.md [m1]
- [VA-L002] 2026-08-02 | 明确自述 | support | 用户看重说到做到 | episodes/2026/08/2026-08-02.md [m2]
''');
      final openLoopStore = OpenLoopStore(memoryDirectory: directory.path);
      expect(await openLoopStore.banTitle('跑步解压'), isTrue);
      _seedPersonaBranch(directory.path, 'preferences.md', '''# 偏好习惯

## 未归根中间节点

### [PR-M001] 重复模式｜用户靠跑步解压
- 形成: 2026-07-20 · 复核: 2026-08-02
- [PR-L001] 2026-07-20 | 明确自述 | support | 用户靠跑步解压 | episodes/2026/07/2026-07-20.md [m1]
- [PR-L002] 2026-08-02 | 明确自述 | support | 用户靠跑步解压 | episodes/2026/08/2026-08-02.md [m2]
''');
      final client = _ScriptedDreamClient([
        ModelCompletion.reply(_candidateWithRoots([
          _item('模式与轨迹', '用户状态平稳', ['2026-08-14']),
        ], [
          {
            'op': 'promote',
            'branch': 'expression',
            'claim': '用户最近常自嘲',
            'middles': ['EX-M001'],
          },
          {
            'op': 'promote',
            'branch': 'values',
            'claim': 'api_key: abcdef123456',
            'middles': ['VA-M001'],
          },
          {
            'op': 'promote',
            'branch': 'preferences',
            'claim': '用户靠跑步解压',
            'middles': ['PR-M001'],
          },
        ])),
      ]);
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        personaTree: PersonaTreeStore(
          memoryDirectory: directory.path,
          episodePipeline: pipeline,
          openLoopStore: openLoopStore,
        ),
        openLoopStore: openLoopStore,
        modelClient: client,
        clock: () => now,
      );

      final outcome = await dream.run(bedtime: true);

      expect(outcome.status, DreamStatus.accepted);
      expect(outcome.rootOpsApplied, 0);
      expect(outcome.rootOpsRejected, 3);
      final history = Directory('${directory.path}/dream/history').listSync();
      final archived = File(history.single.path).readAsStringSync();
      expect(archived, contains('rejected(time-word-claim)'));
      expect(archived, contains('rejected(sensitive-claim)'));
      expect(archived, contains('rejected(banned-claim)'));
      // 被拒提案的主张原文绝不落盘：敏感内容不进记忆目录任何文件。
      expect(archived, isNot(contains('abcdef123456')));
      expect(File('${directory.path}/persona.md').existsSync(), isFalse);
      for (final branch in ['expression', 'values', 'preferences']) {
        expect(
          File('${directory.path}/persona-tree/$branch.md').readAsStringSync(),
          isNot(contains('-R')),
        );
      }
    });

    test('duplicate and archived claims never become roots again', () async {
      final now = DateTime(2026, 8, 15, 23, 10);
      final (:directory, :pipeline) = await _dreamFixture(
        'qiyu-dream-roots-dup-',
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了习惯');
      // 已有根：同主张再提案升根属于重复。
      _seedPersonaBranch(directory.path, 'expression.md', '''# 性格表达

## 未归根中间节点

### [EX-M002] 重复模式｜用户尴尬时倾向自嘲
- 形成: 2026-08-05 · 复核: 2026-08-12
- [EX-L003] 2026-08-05 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/08/2026-08-05.md [m3]
- [EX-L004] 2026-08-12 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/08/2026-08-12.md [m4]

## [EX-R001] 用户尴尬时倾向自嘲

### [EX-M001] 重复模式｜用户尴尬时倾向自嘲
- 形成: 2026-07-20 · 复核: 2026-08-02
- [EX-L001] 2026-07-20 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/07/2026-07-20.md [m1]
''');
      // 归档主张：已被纠正的理解不得用旧证据复活。
      _seedPersonaBranch(directory.path, path.join('archive', 'values.md'), '''# 价值原则（归档）

### [VA-M001] 重复模式｜用户看重说到做到
- 失效: 2026-08-01 · 原因: 明确纠正 · 关联: VA-L001
- 形成: 2026-07-20 · 复核: 2026-07-25
- [VA-L001] 2026-07-20 | 明确自述 | support | 用户看重说到做到 | episodes/2026/07/2026-07-20.md [m1]
''');
      _seedPersonaBranch(directory.path, 'values.md', '''# 价值原则

## 未归根中间节点

### [VA-M002] 重复模式｜用户看重说到做到
- 形成: 2026-08-05 · 复核: 2026-08-12
- [VA-L002] 2026-08-05 | 明确自述 | support | 用户看重说到做到 | episodes/2026/08/2026-08-05.md [m2]
- [VA-L003] 2026-08-12 | 明确自述 | support | 用户看重说到做到 | episodes/2026/08/2026-08-12.md [m3]
''');
      final client = _ScriptedDreamClient([
        ModelCompletion.reply(_candidateWithRoots([
          _item('模式与轨迹', '用户状态平稳', ['2026-08-14']),
        ], [
          {
            'op': 'promote',
            'branch': 'expression',
            'claim': '用户尴尬时倾向自嘲',
            'middles': ['EX-M002'],
          },
          {
            'op': 'promote',
            'branch': 'values',
            'claim': '用户看重说到做到',
            'middles': ['VA-M002'],
          },
        ])),
      ]);
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        personaTree: PersonaTreeStore(
          memoryDirectory: directory.path,
          episodePipeline: pipeline,
        ),
        modelClient: client,
        clock: () => now,
      );

      final outcome = await dream.run(bedtime: true);

      expect(outcome.status, DreamStatus.accepted);
      expect(outcome.rootOpsApplied, 0);
      expect(outcome.rootOpsRejected, 2);
      final history = Directory('${directory.path}/dream/history').listSync();
      final archived = File(history.single.path).readAsStringSync();
      expect(archived, contains('rejected(duplicate-root)'));
      expect(archived, contains('rejected(archived-claim)'));
      // 活跃区维持原状：已有根不动，未归根理解保持未归根。
      final active = File(
        '${directory.path}/persona-tree/expression.md',
      ).readAsStringSync();
      expect('[EX-R'.allMatches(active).length, 1);
      expect(active, contains('### [EX-M002]'));
    });

    test('demote needs a real counter understanding; with one it archives the root', () async {
      final now = DateTime(2026, 8, 15, 23, 10);
      final (:directory, :pipeline) = await _dreamFixture(
        'qiyu-dream-roots-demote-',
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了解压方式');
      final branchSeed = '''# 性格表达

## 未归根中间节点

### [EX-M002] 重复模式｜用户不再靠跑步解压
- 形成: 2026-08-10 · 复核: 2026-08-15
- [EX-L003] 2026-08-10 | 行为观察 | support | 用户不再靠跑步解压 | episodes/2026/08/2026-08-10.md [m3]
- [EX-L004] 2026-08-15 | 行为观察 | support | 用户不再靠跑步解压 | episodes/2026/08/2026-08-15.md [m4]

### [EX-M003] 重复模式｜用户偶尔游泳放松
- 形成: 2026-08-12 · 复核: 2026-08-12
- [EX-L005] 2026-08-12 | 行为观察 | support | 用户偶尔游泳放松 | episodes/2026/08/2026-08-12.md [m5]

## [EX-R001] 用户靠跑步解压

### [EX-M001] 重复模式｜用户靠跑步解压
- 形成: 2026-07-20 · 复核: 2026-08-01
- [EX-L001] 2026-07-20 | 行为观察 | support | 用户靠跑步解压 | episodes/2026/07/2026-07-20.md [m1]
''';
      _seedPersonaBranch(directory.path, 'expression.md', branchSeed);
      final client = _ScriptedDreamClient([
        // 第一次：引用不存在的反向理解、以及单日期证据的无关理解
        // → 两条都拒绝，树不动。
        ModelCompletion.reply(_candidateWithRoots([
          _item('模式与轨迹', '用户的解压方式在变化', ['2026-08-14']),
        ], [
          {
            'op': 'demote',
            'branch': 'expression',
            'root': 'EX-R001',
            'counter': 'EX-M999',
          },
          {
            'op': 'demote',
            'branch': 'expression',
            'root': 'EX-R001',
            'counter': 'EX-M003',
          },
        ])),
        // 第二次：真实反向理解 → 降根成立。证据只能引用第二轮递过去
        // 的整理日期（上次成功之后）。
        ModelCompletion.reply(_candidateWithRoots([
          _item('模式与轨迹', '用户不再靠跑步解压', ['2026-08-21']),
        ], [
          {
            'op': 'demote',
            'branch': 'expression',
            'root': 'EX-R001',
            'counter': 'EX-M002',
          },
        ])),
      ]);
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        personaTree: PersonaTreeStore(
          memoryDirectory: directory.path,
          episodePipeline: pipeline,
        ),
        modelClient: client,
        clock: () => now,
      );

      final first = await dream.run(bedtime: true);
      expect(first.status, DreamStatus.accepted);
      expect(first.rootOpsRejected, 2);
      expect(
        File('${directory.path}/persona-tree/expression.md').readAsStringSync(),
        contains('## [EX-R001]'),
      );
      final history = Directory('${directory.path}/dream/history').listSync();
      final firstChanges = File(history.last.path).readAsStringSync();
      expect(firstChanges, contains('rejected(unknown-counter)'));
      // 单日期证据的引用不构成反向理解，同样拒绝。
      expect(firstChanges, contains('rejected(counter-insufficient)'));

      // 七天后再跑：降根成立，旧根入归档，子树退回未归根区。
      final later = DateTime(2026, 8, 22, 23, 10);
      await _seedFinalizedDay(
        EpisodeMemoryPipeline(memoryDirectory: directory.path, clock: () => later),
        '2026-08-21',
        '用户又聊了解压方式',
      );
      final second = await DreamService(
        memoryDirectory: directory.path,
        episodePipeline: EpisodeMemoryPipeline(
          memoryDirectory: directory.path,
          clock: () => later,
        ),
        personaTree: PersonaTreeStore(
          memoryDirectory: directory.path,
          episodePipeline: EpisodeMemoryPipeline(
            memoryDirectory: directory.path,
            clock: () => later,
          ),
        ),
        modelClient: client,
        clock: () => later,
      ).run(bedtime: true);

      expect(second.status, DreamStatus.accepted);
      expect(second.rootOpsApplied, 1);
      final active = File(
        '${directory.path}/persona-tree/expression.md',
      ).readAsStringSync();
      expect(active, isNot(contains('[EX-R001]')));
      expect(active, contains('### [EX-M001]'));
      final archivedTree = File(
        '${directory.path}/persona-tree/archive/expression.md',
      ).readAsStringSync();
      expect(archivedTree, contains('## [EX-R001] 用户靠跑步解压'));
      expect(archivedTree, contains('原因: 行为冲突'));
    });

    test('a tree write failure never rolls back the accepted long-memory', () async {
      final now = DateTime(2026, 8, 15, 23, 10);
      final (:directory, :pipeline) = await _dreamFixture(
        'qiyu-dream-roots-writefail-',
        clock: () => now,
      );
      await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了习惯');
      _seedPersonaBranch(directory.path, 'expression.md', '''# 性格表达

## 未归根中间节点

### [EX-M001] 重复模式｜用户尴尬时倾向自嘲
- 形成: 2026-07-20 · 复核: 2026-08-02
- [EX-L001] 2026-07-20 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/07/2026-07-20.md [m1]
- [EX-L002] 2026-08-02 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/08/2026-08-02.md [m2]
''');
      final before = File(
        '${directory.path}/persona-tree/expression.md',
      ).readAsStringSync();
      final client = _ScriptedDreamClient([
        ModelCompletion.reply(_candidateWithRoots([
          _item('模式与轨迹', '用户状态平稳', ['2026-08-14']),
        ], [
          {
            'op': 'promote',
            'branch': 'expression',
            'claim': '用户尴尬时倾向自嘲',
            'middles': ['EX-M001'],
          },
        ])),
      ]);
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        personaTree: PersonaTreeStore(
          memoryDirectory: directory.path,
          episodePipeline: pipeline,
          atomicWriter: _TargetedFailingWriter(
            (target) => target.contains('persona-tree'),
          ),
        ),
        modelClient: client,
        clock: () => now,
      );

      final outcome = await dream.run(bedtime: true);

      // 长期印象照常接纳；树提案记为未落盘，树文件原样。
      expect(outcome.status, DreamStatus.accepted);
      expect(outcome.rootOpsApplied, 0);
      expect(outcome.rootOpsRejected, 1);
      expect(
        File('${directory.path}/long-memory.md').readAsStringSync(),
        contains('- 用户状态平稳'),
      );
      expect(
        File('${directory.path}/persona-tree/expression.md').readAsStringSync(),
        before,
      );
      final history = Directory('${directory.path}/dream/history').listSync();
      expect(
        File(history.single.path).readAsStringSync(),
        contains('rejected(apply-deferred)'),
      );
    });
  });

  test('the dream prompt states the appellation wording rule', () async {
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-appellation-test-',
      clock: () => DateTime(2026, 8, 15, 23, 10),
    );
    await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了工作');
    File('${directory.path}/persona.md').writeAsStringSync(
      '# persona\n称呼：老王\n',
    );
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '老王换了新工作', ['2026-08-14']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      personaTree: PersonaTreeStore(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
      ),
      modelClient: client,
      clock: () => DateTime(2026, 8, 15, 23, 10),
    );

    await dream.run(bedtime: true);

    // 记忆表述惯例（称呼定稿）：有称呼用称呼、无称呼用「用户」。
    final system = client.calls.single.first.content;
    expect(system, contains('一律用称呼「老王」'));
    expect(system, contains('不要写「用户」'));
    expect(system, contains('也不要替用户起昵称'));
  });

  test('the dream prompt falls back to 用户 without an appellation', () async {
    final (:directory, :pipeline) = await _dreamFixture(
      'qiyu-dream-appellation-fallback-test-',
      clock: () => DateTime(2026, 8, 15, 23, 10),
    );
    await _seedFinalizedDay(pipeline, '2026-08-14', '用户聊了工作');
    final client = _ScriptedDreamClient([
      ModelCompletion.reply(_candidate([
        _item('重要事件', '用户换了新工作', ['2026-08-14']),
      ])),
    ]);
    final dream = DreamService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      modelClient: client,
      clock: () => DateTime(2026, 8, 15, 23, 10),
    );

    await dream.run(bedtime: true);

    final system = client.calls.single.first.content;
    expect(system, contains('一律写「用户」'));
    expect(system, contains('不要替用户起昵称'));
  });
}

/// 建临时目录并装配 episode 管线：成员沿用用例原变量名。
/// DreamService 构造参数各用例不同，一律留在用例内装配；
/// 装配形态不同的用例（healthFacts 的管线内联在服务构造里）不迁移。
Future<({Directory directory, EpisodeMemoryPipeline pipeline})> _dreamFixture(
  String tempPrefix, {
  required DateTime Function() clock,
}) async {
  final directory = await Directory.systemTemp.createTemp(tempPrefix);
  addTearDown(() => directory.delete(recursive: true));
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: directory.path,
    clock: clock,
  );
  return (directory: directory, pipeline: pipeline);
}

String _candidateWithRoots(
  List<Map<String, Object?>> items,
  List<Map<String, Object?>> rootProposals,
) => jsonEncode({'items': items, 'rootProposals': rootProposals});

void _seedPersonaBranch(
  String memoryDirectory,
  String relative,
  String contents,
) {
  final file = File(path.join(memoryDirectory, 'persona-tree', relative));
  file.createSync(recursive: true);
  file.writeAsStringSync(contents);
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
  Future<ModelCompletion?> complete(
    List<ModelMessage> messages, {
    int? maxTokens,
  }) async {
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

/// 与 DreamService 内部编码同构的测试夹具：直接落一份 state.md。
String _encodedState({DateTime? lastSuccess, bool pending = false}) {
  final json = <String, Object?>{
    'schemaVersion': 1,
    if (lastSuccess != null)
      'lastSuccess': lastSuccess.toUtc().toIso8601String(),
    'pending': pending,
  };
  final encoded = base64Url
      .encode(utf8.encode(jsonEncode(json)))
      .replaceAll('=', '');
  return '# dream-state\n\n<!-- qiyu-dream-state:$encoded -->\n';
}
