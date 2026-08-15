import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('locates evidence through both index levels and reads the raw day', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [
        _entry('seed:1:0', '用户准备第一次演讲', evidence: '下周第一次演讲，好紧张'),
      ],
      '2026-08-10': [_entry('seed:2:0', '用户去看了演唱会')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(root.path);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '第一次演讲',
    );

    expect(result.status, RecallStatus.hit);
    expect(result.matchedDate, '2026-07-02');
    expect(result.memoryContext, contains('2026-07-02'));
    expect(result.memoryContext, contains('第一次演讲'));
    // 命中的是原始证据的原话摘录，不是索引关键词。
    expect(result.memoryContext, contains('下周第一次演讲，好紧张'));
    // 短期 memory context 只注入一次（临时透镜）。
    expect(recall.consumePendingContext('session-1'), result.memoryContext);
    expect(recall.consumePendingContext('session-1'), isNull);
    // 其他会话取不到。
    expect(recall.consumePendingContext('session-2'), isNull);
  });

  test('a miss writes nothing and does not fabricate similar memories', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(root.path);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '潜水装备',
    );

    expect(result.status, RecallStatus.miss);
    expect(result.memoryContext, isNull);
    expect(recall.consumePendingContext('session-1'), isNull);
    expect(result.diagnostics.join('\n'), contains('no-month-match'));
  });

  test('an index hit without readable evidence never becomes a fact', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-recall-ghost-');
    addTearDown(() => root.delete(recursive: true));
    // 手写一份指向不存在日文件的索引：索引摘要本身不是事实来源。
    File('${root.path}/episodes/index.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# episodes index\n\n- 2026-07 | 演讲 | episodes/2026/07/index.md\n',
        encoding: utf8,
      );
    File('${root.path}/episodes/2026/07/index.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# 2026-07 index\n\n- 2026-07-02 | 演讲 | 2026-07-02.md\n',
        encoding: utf8,
      );
    final (recall, _) = _recallService(root.path);

    final result = await recall.search(sessionId: 'session-1', query: '演讲');

    expect(result.status, RecallStatus.miss);
    expect(recall.consumePendingContext('session-1'), isNull);
  });

  test('cross-month location finds the best evidence across months', () async {
    final root = await _seedEpisodes({
      '2026-07-28': [_entry('seed:1:0', '用户提到想去青岛旅行')],
      '2026-08-02': [_entry('seed:2:0', '用户确认青岛行程定下来')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(root.path);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '青岛行程定下来',
    );

    expect(result.status, RecallStatus.hit);
    expect(result.matchedDate, '2026-08-02');
  });

  test('a relative month hint resolves against the clock', () async {
    final root = await _seedEpisodes({
      '2025-08-20': [_entry('seed:1:0', '用户提到去年夏天在学游泳')],
      '2026-08-10': [_entry('seed:2:0', '用户去看了演唱会')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(
      root.path,
      clock: () => DateTime(2026, 8, 16),
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '去年这时候在学什么',
    );

    expect(result.status, RecallStatus.hit);
    expect(result.matchedDate, '2025-08-20');
  });

  test('a month-only hint matches every indexed year of that month', () async {
    final root = await _seedEpisodes({
      '2025-07-15': [_entry('seed:1:0', '用户聊到七月的读书会')],
      '2026-07-15': [_entry('seed:2:0', '用户说七月读书会改期了')],
      '2026-08-10': [_entry('seed:3:0', '用户去看了演唱会')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(
      root.path,
      clock: () => DateTime(2026, 8, 16),
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '7月读书会改期',
    );

    expect(result.status, RecallStatus.hit);
    expect(result.matchedDate, '2026-07-15');
  });

  test('a month hint missing from the index misses instead of substituting', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户去看了演唱会')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(
      root.path,
      clock: () => DateTime(2026, 8, 16),
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '去年三月的事',
    );

    expect(result.status, RecallStatus.miss);
    expect(result.diagnostics.join('\n'), contains('month-hint-not-indexed'));
  });

  test('conflicting evidence for one topic is not forced into a fact', () async {
    final root = await _seedEpisodes({
      '2026-07-03': [_entry('seed:1:0', '用户的猫叫小白')],
      '2026-07-20': [_entry('seed:2:0', '用户的猫叫团团')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(root.path);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '我的猫叫什么名字',
    );

    expect(result.status, RecallStatus.conflict);
    expect(recall.consumePendingContext('session-1'), isNull);
    final diagnostics = result.diagnostics.join('\n');
    expect(diagnostics, contains('reason=conflict'));
    expect(diagnostics, contains('2026-07-03'));
    expect(diagnostics, contains('2026-07-20'));
    // 诊断不泄露正文。
    expect(diagnostics, isNot(contains('小白')));
    expect(diagnostics, isNot(contains('团团')));
  });

  test('ambiguous candidates across topics are not forced either', () async {
    final root = await _seedEpisodes({
      '2026-07-05': [_entry('seed:1:0', '用户聊到想养一只猫')],
      '2026-07-12': [_entry('seed:2:0', '用户聊到最近失眠')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(root.path);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '之前聊到的事',
    );

    expect(result.status, RecallStatus.ambiguous);
    expect(recall.consumePendingContext('session-1'), isNull);
    expect(result.diagnostics.join('\n'), contains('reason=ambiguous'));
  });

  test('the same memory recorded twice is deduplicated, not a conflict', () async {
    final root = await _seedEpisodes({
      '2026-07-03': [_entry('seed:1:0', '用户对芒果过敏')],
      '2026-07-20': [_entry('seed:2:0', '用户对芒果过敏')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(root.path);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '芒果过敏',
    );

    expect(result.status, RecallStatus.hit);
    expect(result.matchedDate, '2026-07-03');
  });

  test('a corrupt top index is rebuilt from raw episodes before searching', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _recallService(root.path);
    await _rebuildUnderLock(recall, pipeline);
    File('${root.path}/episodes/index.md').writeAsStringSync(
      '这不是索引，是用户写坏的内容。\n',
      encoding: utf8,
    );

    final result = await recall.search(
      sessionId: 'session-1',
      query: '第一次演讲',
    );

    expect(result.status, RecallStatus.hit);
    expect(result.diagnostics.join('\n'), contains('index rebuilt'));
    expect(
      File('${root.path}/episodes/index.md').readAsStringSync(encoding: utf8),
      contains('# episodes index'),
    );
  });

  test('deleted indexes are rebuilt including unfinalized days', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
    });
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    // 再写一个未归档的日子：修复重建来自原始 episode，不受归档限制。
    await pipeline.synchronizedOnDayFiles(
      () => pipeline.writeFinalization(
        '2026-08-14',
        entries: [_entry('seed:3:0', '用户说想吃火锅')],
        finalized: false,
      ),
    );
    final (recall, _) = _recallService(root.path);
    // 没有任何索引文件：检索触发从原始 episode 重建。

    final result = await recall.search(
      sessionId: 'session-1',
      query: '想吃火锅',
    );

    expect(result.status, RecallStatus.hit);
    expect(result.matchedDate, '2026-08-14');
    expect(
      File('${root.path}/episodes/index.md').existsSync(),
      isTrue,
    );
  });

  test('banned topics never reach the memory context', () async {
    final root = await _seedEpisodes({
      '2026-07-03': [_entry('seed:1:0', '用户说下周去医院检查')],
    });
    addTearDown(() => root.delete(recursive: true));
    // 禁提记录存的是事项简称，比 episode 摘要短：按包含关系匹配。
    File('${root.path}/memory-controls.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# memory-controls\n'
        '## frozen\n'
        '## banned\n'
        '- [MC001] open-loop | 医院检查\n'
        '## deleted\n',
        encoding: utf8,
      );
    final (recall, pipeline) = _recallService(
      root.path,
      openLoopStore: OpenLoopStore(memoryDirectory: root.path),
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.search(
      sessionId: 'session-1',
      query: '医院检查的事',
    );

    expect(result.status, RecallStatus.miss);
    expect(recall.consumePendingContext('session-1'), isNull);
    expect(result.diagnostics.join('\n'), contains('reason=banned'));
  });

  test('recall-style inputs are recognized for the rule fallback', () {
    expect(looksLikeRecallInput('你还记得我上次说的演讲吗'), isTrue);
    expect(looksLikeRecallInput('我之前说的面试怎么样了'), isTrue);
    expect(looksLikeRecallInput('我上次说的那本书'), isTrue);
    expect(looksLikeRecallInput('今天天气怎么样'), isFalse);
    expect(looksLikeRecallInput('晚安'), isFalse);
    expect(looksLikeRecallInput('有点累'), isFalse);
  });
}

Future<Directory> _seedEpisodes(
  Map<String, List<EpisodeEntry>> entriesByDate,
) async {
  final root = await Directory.systemTemp.createTemp('qiyu-recall-test-');
  final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
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

(MemoryRecallService, EpisodeMemoryPipeline) _recallService(
  String memoryDirectory, {
  OpenLoopStore? openLoopStore,
  Clock? clock,
}) {
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: memoryDirectory,
    clock: clock ?? () => DateTime(2026, 8, 16, 22),
  );
  final service = MemoryRecallService(
    memoryDirectory: memoryDirectory,
    episodePipeline: pipeline,
    openLoopStore: openLoopStore,
    clock: clock,
    diagnosticsSink: (_) {},
  );
  return (service, pipeline);
}

/// 重建契约要求调用方持有 episode 日文件写锁，测试也照做。
Future<void> _rebuildUnderLock(
  MemoryRecallService recall,
  EpisodeMemoryPipeline pipeline,
) => pipeline.synchronizedOnDayFiles(() => recall.indexStore.rebuild());

EpisodeEntry _entry(String id, String summary, {String? evidence}) =>
    EpisodeEntry(
      id: id,
      sessionId: 'seed',
      requestId: 'seed',
      summary: summary,
      evidence: evidence,
      at: DateTime(2026, 8, 15, 21).toUtc(),
    );
