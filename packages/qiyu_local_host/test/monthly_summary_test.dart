import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';

void main() {
  test('a finished month compresses keep-marked memory entries by kind', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-basic-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    await _seedDay(pipeline, '2026-07-02', [
      _entry('s1:r1:0', '用户完成了第一次演讲', keep: memorySignalKeepMonth),
      _entry('s1:r1:1', '用户可能换工作', keep: memorySignalKeepMonth),
      _entry(
        's1:r1:4',
        'Open-loop 状态: 某件事 → closed',
        kind: episodeKindOpenLoopEvent,
      ),
    ]);
    await _seedDay(pipeline, '2026-07-03', [
      _entry('s2:r2:0', '用户去看了演唱会', keep: memorySignalKeepMonth),
      // 没标 keep 的条目不进月文件（月层资格定稿）。
      _entry('s2:r2:1', '用户晚饭吃了小馄饨'),
    ]);
    // 当月主题来自月份索引，先重建索引。
    await _rebuildIndex(pipeline);
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );

    await store.compressBefore('2026-08');

    final contents = _readSummary(root.path, '2026-07')!;
    expect(contents, contains('# 2026-07 月度摘要'));
    expect(contents, contains('## 当月主题'));
    expect(
      contents,
      contains(
        '- 2026-07-02 · 用户完成了第一次演讲 | episodes/2026/07/2026-07-02.md [s1:r1:0]',
      ),
    );
    // 带不确定措辞的标记条目单独归类，不混进「发生过的事情」。
    expect(contents, contains('## 发生过的事情'));
    expect(contents, contains('## 不确定内容'));
    expect(contents, contains('用户可能换工作'));
    // 簿记条目不进摘要；没标 keep 的日常琐事同样不进条目分区
    // （当月主题关键词仍取自全月索引，与资格规则无关）。
    expect(contents, isNot(contains('Open-loop 状态')));
    expect(contents, isNot(contains('- 2026-07-03 · 用户晚饭吃了小馄饨')));
    // T07：体量控制在 800 字内（元数据注释不是正文，不计入）。
    final visible = contents
        .split('\n')
        .where((line) => !line.contains('qiyu-month-summary'))
        .join('\n');
    expect(visible.runes.length, lessThanOrEqualTo(monthSummaryMaxRunes));

    final parsed = await store.readMonthSummary('2026-07');
    expect(parsed, isNotNull);
    expect(parsed!.readable, isTrue);
    expect(parsed.compressedDates, ['2026-07-02', '2026-07-03']);
    expect(parsed.skipped, isEmpty);
  });

  test('marked lifecycle entries reach their month sections via real paths', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-lifecycle-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: root.path,
      clock: () => DateTime(2026, 7, 2, 22, 30),
    );
    // 真实创建路径：聊天轮隐藏动作落当天条目（不手工种子 keep）。
    await pipeline.processReply(
      session: _session('session-1', ['req-1']),
      requestId: 'req-1',
      hiddenActions: const [
        OpenLoopCandidateAction(
          title: '人生第一次演讲',
          keep: memorySignalKeepMonth,
        ),
      ],
    );
    await pipeline.processReply(
      session: _session('session-1', ['req-2']),
      requestId: 'req-2',
      hiddenActions: const [
        RelationshipSignalAction(
          summary: '用户近期愿意聊到更深的家庭关系',
          signal: RelationshipSignal.deepTalk,
          keep: memorySignalKeepMonth,
        ),
      ],
    );
    await pipeline.processReply(
      session: _session('session-1', ['req-3']),
      requestId: 'req-3',
      hiddenActions: const [
        OpenLoopCandidateAction(title: '普通临时任务'),
        RelationshipSignalAction(
          summary: '今晚话少',
          signal: RelationshipSignal.temperature,
        ),
      ],
    );
    // 聊天增量整理只写未定稿日文件；归档后才能进月压缩。
    await pipeline.synchronizedOnDayFiles(() async {
      final day = await pipeline.readDay('2026-07-02');
      await pipeline.writeFinalization(
        '2026-07-02',
        entries: day.entries,
        finalized: true,
        finalizedAt: DateTime.parse('2026-07-02T23:00:00').toUtc(),
      );
    });
    // 未闭环线索分区只收至今仍未闭环的候选（open-loops 状态，不是
    // 条目创建面）。
    File(path.join(root.path, 'open-loops.md')).writeAsStringSync(
      '# open-loops\n\n- [o1] 人生第一次演讲\n  proactive: once\n  status: active\n',
    );
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      openLoopStore: OpenLoopStore(memoryDirectory: root.path),
      diagnosticsSink: (_) {},
    );

    await store.compressBefore('2026-08');

    final contents = _readSummary(root.path, '2026-07')!;
    // 标了的两类条目按 kind 进对应分区。
    expect(contents, contains('## 仍未解决的线索'));
    expect(contents, contains('人生第一次演讲'));
    expect(contents, contains('## 关系变化'));
    expect(contents, contains('用户近期愿意聊到更深的家庭关系'));
    // 没标的两类条目不进月文件。
    expect(contents, isNot(contains('普通临时任务')));
    expect(contents, isNot(contains('今晚话少')));
  });

  test('a month with no keep-marked entries keeps only the theme overview', () async {
    // 笔记字面：只收当时标了 keep: month 的条目，再加当月主题概述；
    // 一条都没标时月文件只剩当月主题概述。
    final root = await Directory.systemTemp.createTemp('qiyu-month-unmarked-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    await _seedDay(pipeline, '2026-07-02', [
      _entry('s1:r1:0', '用户晚饭吃了小馄饨'),
      _entry('s1:r1:1', '用户可能换工作'),
    ]);
    await _rebuildIndex(pipeline);
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );

    await store.compressBefore('2026-08');

    final contents = _readSummary(root.path, '2026-07')!;
    expect(contents, contains('# 2026-07 月度摘要'));
    expect(contents, contains('## 当月主题'));
    // 没有任何分区条目，也不出现分区标题。
    expect(contents, isNot(contains('## 发生过的事情')));
    expect(contents, isNot(contains('## 不确定内容')));
    expect(contents, isNot(contains('- 2026-07-02 ·')));
    final parsed = await store.readMonthSummary('2026-07');
    expect(parsed!.items, isEmpty);
    // 收录范围不变：日期已定稿，重跑不重新生成。
    expect(parsed.compressedDates, ['2026-07-02']);
  });

  test('over-budget months still trim within 800 runes', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-budget-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    // 全部标记的长摘要远超 800 runes 预算。
    await _seedDay(pipeline, '2026-07-02', [
      for (var index = 0; index < 30; index += 1)
        _entry(
          's1:r1:$index',
          '用户第 $index 天完成了一件值得记录的重要事情',
          keep: memorySignalKeepMonth,
        ),
      _entry('s1:r1:90', '用户可能考虑换个城市生活', keep: memorySignalKeepMonth),
    ]);
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );

    await store.compressBefore('2026-08');

    final contents = _readSummary(root.path, '2026-07')!;
    final visible = contents
        .split('\n')
        .where((line) => !line.contains('qiyu-month-summary'))
        .join('\n');
    expect(visible.runes.length, lessThanOrEqualTo(monthSummaryMaxRunes));
    final parsed = await store.readMonthSummary('2026-07');
    // 先裁发生过的事情：满载时不确定内容仍保留，大事分区被压减。
    expect(
      parsed!.items.where((item) => item.section == sectionHappened),
      hasLength(lessThan(30)),
    );
    expect(
      parsed.items.where((item) => item.section == sectionUncertain),
      isNotEmpty,
    );
  });

  test('unfinalized and corrupt days are skipped, then recovered later', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-skip-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    final diagnostics = <String>[];
    await _seedDay(pipeline, '2026-07-02', [
      _entry('s1:r1:0', '用户完成了演讲', keep: memorySignalKeepMonth),
    ]);
    await _seedDay(
      pipeline,
      '2026-07-03',
      [_entry('s2:r2:0', '用户去了演唱会', keep: memorySignalKeepMonth)],
      finalized: false,
    );
    // 损坏日：文件存在但没有栖语元数据标记。
    final corruptFile = File(
      path.join(root.path, 'episodes', '2026', '07', '2026-07-04.md'),
    );
    corruptFile.createSync(recursive: true);
    corruptFile.writeAsStringSync('用户手写的笔记。');
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      diagnosticsSink: diagnostics.add,
    );

    await store.compressBefore('2026-08');

    var parsed = await store.readMonthSummary('2026-07');
    expect(parsed!.compressedDates, ['2026-07-02']);
    expect(parsed.skipped, {
      '2026-07-03': skipReasonUnfinalized,
      '2026-07-04': skipReasonUnreadable,
    });
    expect(_readSummary(root.path, '2026-07'), isNot(contains('演唱会')));
    expect(diagnostics.join('\n'), contains('reason=unfinalized'));
    expect(diagnostics.join('\n'), contains('reason=unreadable'));

    // 未完成日补归档、损坏日修复后，重跑整体重建，补齐全部日期。
    await _seedDay(pipeline, '2026-07-03', [
      _entry('s2:r2:0', '用户去了演唱会', keep: memorySignalKeepMonth),
    ]);
    await _seedDay(pipeline, '2026-07-04', [
      _entry('s3:r3:0', '用户整理了房间', keep: memorySignalKeepMonth),
    ]);
    await store.compressBefore('2026-08');

    parsed = await store.readMonthSummary('2026-07');
    expect(
      parsed!.compressedDates,
      ['2026-07-02', '2026-07-03', '2026-07-04'],
    );
    expect(parsed.skipped, isEmpty);
    final contents = _readSummary(root.path, '2026-07')!;
    expect(contents, contains('用户去了演唱会'));
    expect(contents, contains('用户整理了房间'));
    // 重建是整体替换：不会出现新旧两份相互冲突的条目。
    expect('用户完成了演讲'.allMatches(contents).length, 1);
  });

  test('cross-year months each get their own summary', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-crossyear-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    await _seedDay(pipeline, '2025-12-31', [
      _entry('s1:r1:0', '用户跨年在家看电影', keep: memorySignalKeepMonth),
    ]);
    await _seedDay(pipeline, '2026-01-05', [
      _entry('s2:r2:0', '用户开始新项目', keep: memorySignalKeepMonth),
    ]);
    await _seedDay(pipeline, '2026-02-01', [
      _entry('s3:r3:0', '用户当月还在进行中的事', keep: memorySignalKeepMonth),
    ]);
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );

    await store.compressBefore('2026-02');

    expect(_readSummary(root.path, '2025-12'), contains('跨年在家看电影'));
    expect(_readSummary(root.path, '2026-01'), contains('用户开始新项目'));
    // 当前月永不压缩。
    expect(_readSummary(root.path, '2026-02'), isNull);
  });

  test('a fully covered month is never regenerated', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-idempotent-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    await _seedDay(pipeline, '2026-07-02', [_entry('s1:r1:0', '用户完成了演讲')]);
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );
    await store.compressBefore('2026-08');
    final file = File(
      path.join(root.path, 'episodes', '2026', '07', 'summary.md'),
    );
    final original = file.readAsStringSync();

    // 重复执行（新月、跨年、启动补做都可能重复触发）逐字节幂等。
    await store.compressBefore('2026-08');
    await store.compressMonth('2026-07');
    expect(file.readAsStringSync(), original);

    // 无法识别的改动静止保留，绝不被重新生成的摘要覆盖。
    file.writeAsStringSync('$original\n<!-- sentinel -->\n');
    await store.compressBefore('2026-08');
    expect(file.readAsStringSync(), contains('<!-- sentinel -->'));
  });

  test('a failed write keeps the previous summary usable', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-fail-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    await _seedDay(pipeline, '2026-07-02', [_entry('s1:r1:0', '用户完成了演讲')]);
    await _seedDay(
      pipeline,
      '2026-07-03',
      [_entry('s2:r2:0', '用户去了演唱会')],
      finalized: false,
    );
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );
    await store.compressBefore('2026-08');
    final before = _readSummary(root.path, '2026-07')!;

    // 未完成日补归档后本该重建，但写入失败：旧摘要保持可用。
    await _seedDay(pipeline, '2026-07-03', [_entry('s2:r2:0', '用户去了演唱会')]);
    final failing = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      atomicWriter: FailingAtomicTextWriter(
        shouldFail: (path) => path.endsWith('summary.md'),
        exception: const FileSystemException('mock interrupted summary write'),
      ),
      diagnosticsSink: (_) {},
    );
    await expectLater(
      () => failing.compressMonth('2026-07'),
      throwsA(isA<Object>()),
    );
    expect(_readSummary(root.path, '2026-07'), before);
    // 原始日文件不受影响。
    expect((await pipeline.readDay('2026-07-03')).readable, isTrue);
  });

  test('every summary item still points at the original episode entry', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-trace-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    await _seedDay(pipeline, '2026-07-02', [
      _entry('s1:r1:0', '用户完成了第一次演讲', keep: memorySignalKeepMonth),
      _entry('s1:r1:1', '用户可能换工作', keep: memorySignalKeepMonth),
    ]);
    await _seedDay(pipeline, '2026-07-03', [
      _entry('s2:r2:0', '用户去看了演唱会', keep: memorySignalKeepMonth),
    ]);
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );
    await store.compressBefore('2026-08');

    final parsed = await store.readMonthSummary('2026-07');
    expect(parsed!.items, isNotEmpty);
    for (final item in parsed.items) {
      final file = File(
        path.joinAll([root.path, ...path.split(item.episodePath)]),
      );
      expect(file.existsSync(), isTrue, reason: item.episodePath);
      final day = await pipeline.readDay(item.date);
      expect(day.hasEntryId(item.entryRef), isTrue, reason: item.entryRef);
    }
  });

  test('banned topics never enter the month summary, theme included', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-ban-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
    expect(
      (await MemoryBanExecution(openLoopStore: openLoopStore).execute(
        '换工作',
        origin: 'open-loop',
      )).controlWritten,
      isTrue,
    );
    await _seedDay(pipeline, '2026-07-02', [
      _entry('s1:r1:0', '用户可能换工作', keep: memorySignalKeepMonth),
      _entry('s1:r1:1', '用户确认换工作', keep: memorySignalKeepMonth),
      _entry('s1:r1:2', '用户完成了演讲', keep: memorySignalKeepMonth),
    ]);
    // 索引关键词本身不带禁提过滤：主题必须在使用侧过滤。
    await _rebuildIndex(pipeline);
    final store = MonthlySummaryStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      openLoopStore: openLoopStore,
      diagnosticsSink: (_) {},
    );

    await store.compressBefore('2026-08');

    final contents = _readSummary(root.path, '2026-07')!;
    expect(contents, isNot(contains('换工作')));
    expect(contents, contains('用户完成了演讲'));
    expect(contents, contains('## 当月主题'));
  });

}

Future<void> _seedDay(
  EpisodeMemoryPipeline pipeline,
  String date,
  List<EpisodeEntry> entries, {
  bool finalized = true,
}) => pipeline.synchronizedOnDayFiles(
  () => pipeline.writeFinalization(
    date,
    entries: entries,
    summary: entries.first.summary,
    finalized: finalized,
    finalizedAt: finalized ? DateTime.parse('${date}T23:00:00').toUtc() : null,
  ),
);

Future<void> _rebuildIndex(EpisodeMemoryPipeline pipeline) async {
  final indexStore = EpisodeIndexStore(
    memoryDirectory: pipeline.memoryDirectory,
    episodePipeline: pipeline,
  );
  await pipeline.synchronizedOnDayFiles(() => indexStore.rebuild());
}

String? _readSummary(String memoryDirectory, String month) {
  final file = File(
    path.join(
      memoryDirectory,
      'episodes',
      month.substring(0, 4),
      month.substring(5, 7),
      'summary.md',
    ),
  );
  if (!file.existsSync()) {
    return null;
  }
  return file.readAsStringSync();
}

EpisodeEntry _entry(
  String id,
  String summary, {
  String kind = episodeKindMemory,
  String? keep,
}) => EpisodeEntry(
  id: id,
  sessionId: 'seed',
  requestId: 'seed',
  summary: summary,
  // 月压缩的条目日期取自日文件而非 entry.at，这里只给合法值。
  at: DateTime(2026, 7, 2, 21).toUtc(),
  kind: kind,
  keep: keep,
);

/// 真实创建路径用的会话桩：轮次文本与月压缩无关，只提供 requestId。
RawSession _session(String id, List<String> requestIds) {
  final base = DateTime(2026, 7, 2, 22);
  final turns = <RawSessionTurn>[
    for (var index = 0; index < requestIds.length; index += 1)
      RawSessionTurn.user(
        requestId: requestIds[index],
        text: '第 ${index + 1} 轮',
        at: base.add(Duration(minutes: index)),
      ),
  ];
  return RawSession(
    id: id,
    date: '2026-07-02',
    segment: 1,
    createdAt: base.toUtc(),
    updatedAt: base.toUtc(),
    turns: turns,
  );
}
