import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';

void main() {
  test('a finished month compresses into four traceable sections', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-basic-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    await _seedDay(pipeline, '2026-07-02', [
      _entry('s1:r1:0', '用户完成了第一次演讲'),
      _entry('s1:r1:1', '用户可能换工作'),
      _entry(
        's1:r1:2',
        '人生第一次演讲',
        kind: episodeKindOpenLoopCandidate,
      ),
      _entry(
        's1:r1:3',
        '用户近期愿意聊到更深的家庭关系',
        kind: episodeKindRelationshipSignal,
      ),
      _entry(
        's1:r1:4',
        'Open-loop 状态: 某件事 → closed',
        kind: episodeKindOpenLoopEvent,
      ),
    ]);
    await _seedDay(pipeline, '2026-07-03', [_entry('s2:r2:0', '用户去看了演唱会')]);
    // 当月主题来自月份索引，先重建索引。
    await _rebuildIndex(pipeline);
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
    expect(contents, contains('# 2026-07 月度摘要'));
    expect(contents, contains('## 当月主题'));
    expect(
      contents,
      contains(
        '- 2026-07-02 · 用户完成了第一次演讲 | episodes/2026/07/2026-07-02.md [s1:r1:0]',
      ),
    );
    expect(contents, contains('## 仍未解决的线索'));
    expect(contents, contains('人生第一次演讲'));
    expect(contents, contains('## 关系变化'));
    expect(contents, contains('用户近期愿意聊到更深的家庭关系'));
    // 带不确定措辞的条目单独归类，不混进「发生过的事情」。
    expect(contents, contains('## 不确定内容'));
    expect(contents, contains('用户可能换工作'));
    // 簿记条目不进摘要。
    expect(contents, isNot(contains('Open-loop 状态')));
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

  test('unfinalized and corrupt days are skipped, then recovered later', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-month-skip-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    final diagnostics = <String>[];
    await _seedDay(pipeline, '2026-07-02', [_entry('s1:r1:0', '用户完成了演讲')]);
    await _seedDay(
      pipeline,
      '2026-07-03',
      [_entry('s2:r2:0', '用户去了演唱会')],
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
    await _seedDay(pipeline, '2026-07-03', [_entry('s2:r2:0', '用户去了演唱会')]);
    await _seedDay(pipeline, '2026-07-04', [_entry('s3:r3:0', '用户整理了房间')]);
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
    await _seedDay(pipeline, '2025-12-31', [_entry('s1:r1:0', '用户跨年在家看电影')]);
    await _seedDay(pipeline, '2026-01-05', [_entry('s2:r2:0', '用户开始新项目')]);
    await _seedDay(pipeline, '2026-02-01', [_entry('s3:r3:0', '用户当月还在进行中的事')]);
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
      _entry('s1:r1:0', '用户完成了第一次演讲'),
      _entry('s1:r1:1', '用户可能换工作'),
    ]);
    await _seedDay(pipeline, '2026-07-03', [_entry('s2:r2:0', '用户去看了演唱会')]);
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
      _entry('s1:r1:0', '用户可能换工作'),
      _entry('s1:r1:1', '用户确认换工作'),
      _entry('s1:r1:2', '用户完成了演讲'),
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

EpisodeEntry _entry(String id, String summary, {String kind = episodeKindMemory}) =>
    EpisodeEntry(
      id: id,
      sessionId: 'seed',
      requestId: 'seed',
      summary: summary,
      // 月压缩的条目日期取自日文件而非 entry.at，这里只给合法值。
      at: DateTime(2026, 7, 2, 21).toUtc(),
      kind: kind,
    );
