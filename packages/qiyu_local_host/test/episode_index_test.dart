import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  test('a missing or unreadable index reads as null, not as empty', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-index-read-');
    addTearDown(() => root.delete(recursive: true));
    final store = EpisodeIndexStore(
      memoryDirectory: root.path,
      episodePipeline: EpisodeMemoryPipeline(memoryDirectory: root.path),
    );

    expect(await store.readTopIndex(), isNull);
    expect(await store.readMonthIndex('2026-08'), isNull);

    File('${root.path}/episodes/index.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('用户写坏的内容，没有列表行。\n', encoding: utf8);
    File('${root.path}/episodes/2026/08/index.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('# 2026-08 index\n\n坏行没有前缀\n', encoding: utf8);

    expect(await store.readTopIndex(), isNull);
    expect(await store.readMonthIndex('2026-08'), isNull);
  });

  test('parsing keeps valid lines, keywords and drops malformed ones', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-index-parse-');
    addTearDown(() => root.delete(recursive: true));
    File('${root.path}/episodes/index.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# episodes index\n\n'
        '- 2026-08 | 演讲, 面试 | episodes/2026/08/index.md\n'
        '- 坏行没有月份 | 关键词 | somewhere.md\n',
        encoding: utf8,
      );
    File('${root.path}/episodes/2026/08/index.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# 2026-08 index\n\n'
        '- 2026-08-02 | 第一次演讲 | 2026-08-02.md\n'
        '- 2026-09-01 | 不属于本月 | 2026-09-01.md\n'
        '- 不是日期 | 关键词 | x.md\n',
        encoding: utf8,
      );
    final store = EpisodeIndexStore(
      memoryDirectory: root.path,
      episodePipeline: EpisodeMemoryPipeline(memoryDirectory: root.path),
    );

    final top = await store.readTopIndex();
    expect(top, hasLength(1));
    expect(top!.single.month, '2026-08');
    expect(top.single.keywords, ['演讲', '面试']);

    final month = await store.readMonthIndex('2026-08');
    expect(month, hasLength(1));
    expect(month!.single.date, '2026-08-02');
    expect(month.single.keywords, ['第一次演讲']);
  });

  test('index lines only locate: keywords and paths, never memory bodies', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-index-locate-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    await pipeline.synchronizedOnDayFiles(
      () => pipeline.writeFinalization(
        '2026-08-02',
        entries: [
          EpisodeEntry(
            id: 'seed:1:0',
            sessionId: 'seed',
            requestId: 'seed',
            summary: '用户准备第一次演讲，原话细节很长不应该进索引',
            evidence: '这段原话摘录也不应该进索引',
            at: DateTime(2026, 8, 2, 21).toUtc(),
          ),
        ],
        summary: '用户准备第一次演讲',
        finalized: true,
        finalizedAt: DateTime(2026, 8, 2, 23).toUtc(),
      ),
    );
    final store = EpisodeIndexStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
    );

    // 重建契约要求调用方持锁，测试也照做。
    await pipeline.synchronizedOnDayFiles(() => store.rebuild());

    final topContents = File('${root.path}/episodes/index.md')
        .readAsStringSync(encoding: utf8);
    final monthContents = File('${root.path}/episodes/2026/08/index.md')
        .readAsStringSync(encoding: utf8);
    expect(topContents, contains('- 2026-08 | '));
    expect(monthContents, contains('- 2026-08-02 | '));
    // 索引只放关键词和路径：原话摘录绝不进索引。
    expect(topContents, isNot(contains('原话摘录')));
    expect(monthContents, isNot(contains('原话摘录')));
    // 关键词来自摘要截断，不会搬运完整正文。
    expect(monthContents, contains('用户准备第一次演讲'));
    expect(monthContents, isNot(contains('原话细节很长')));
  });
}
