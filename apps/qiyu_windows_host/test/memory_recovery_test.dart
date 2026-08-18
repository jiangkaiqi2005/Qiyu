import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String memoryDirectory;
  late EpisodeMemoryPipeline pipeline;
  late MemoryControlsStore memoryControls;
  late OpenLoopStore openLoopStore;
  late PersonaTreeStore personaTree;
  late MonthlySummaryStore monthlySummary;
  late RelationshipLifecycle relationshipLifecycle;
  late MemoryActionService actions;
  late DreamService dreamService;
  late MemoryRecoveryService recovery;

  final clock = DateTime(2026, 8, 19, 21);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-recovery-test-',
    );
    memoryDirectory = temporaryDirectory.path;
    pipeline = EpisodeMemoryPipeline(memoryDirectory: memoryDirectory);
    memoryControls = MemoryControlsStore(
      memoryDirectory: memoryDirectory,
      diagnosticsSink: (_) {},
    );
    openLoopStore = OpenLoopStore(
      memoryDirectory: memoryDirectory,
      memoryControls: memoryControls,
    );
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
    dreamService = DreamService(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      openLoopStore: openLoopStore,
      monthlySummary: monthlySummary,
      personaTree: personaTree,
      clock: () => clock,
      diagnosticsSink: (_) {},
    );
    recovery = MemoryRecoveryService(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      memoryControls: memoryControls,
      personaTree: personaTree,
      dreamService: dreamService,
      monthlySummary: monthlySummary,
      relationshipLifecycle: relationshipLifecycle,
      memoryActions: actions,
      clock: () => clock,
      diagnosticsSink: (_) {},
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  String b64(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

  Future<File> seedSession(
    String date,
    int segment,
    List<(String speaker, String text)> turns,
  ) async {
    final session = RawSession(
      id: 'session-$date-$segment',
      date: date,
      segment: segment,
      createdAt: DateTime.parse('${date}T20:00:00').toUtc(),
      updatedAt: DateTime.parse('${date}T20:30:00').toUtc(),
      turns: [
        for (var index = 0; index < turns.length; index += 1)
          turns[index].$1 == '用户'
              ? RawSessionTurn.user(
                  requestId: 'r$index',
                  text: turns[index].$2,
                  at: DateTime.parse(
                    '${date}T20:${(10 + index).toString().padLeft(2, '0')}:00',
                  ).toUtc(),
                )
              : RawSessionTurn.qiyu(
                  requestId: 'r$index',
                  messages: [turns[index].$2],
                  at: DateTime.parse(
                    '${date}T20:${(10 + index).toString().padLeft(2, '0')}:30',
                  ).toUtc(),
                  source: ReplySource.local,
                  mode: 'local',
                ),
      ],
    );
    final file = File(
      path.join(
        memoryDirectory,
        'sessions',
        date.substring(0, 4),
        date.substring(5, 7),
        '$date-${segment.toString().padLeft(3, '0')}.md',
      ),
    );
    await file.create(recursive: true);
    await file.writeAsString(renderSessionMarkdown(session), flush: true);
    return file;
  }

  EpisodeEntry entry(
    String date,
    String id,
    String summary, {
    String kind = episodeKindMemory,
  }) => EpisodeEntry(
    id: id,
    sessionId: 'seed-session',
    requestId: 'seed',
    summary: summary,
    at: DateTime.parse('${date}T20:00:00').toUtc(),
    kind: kind,
  );

  Future<void> seedEpisodeDay(
    String date,
    List<EpisodeEntry> entries, {
    String? summary,
    bool finalized = true,
  }) => pipeline.synchronizedOnDayFiles(
    () => pipeline.writeFinalization(
      date,
      entries: entries,
      summary: summary,
      finalized: finalized,
      finalizedAt: finalized
          ? DateTime.parse('${date}T23:00:00').toUtc()
          : null,
    ),
  );

  Future<void> overwrite(File file, String contents) async {
    await file.create(recursive: true);
    await file.writeAsString(contents, flush: true);
  }

  File dayFile(String date) => File(
    path.join(
      memoryDirectory,
      'episodes',
      date.substring(0, 4),
      date.substring(5, 7),
      '$date.md',
    ),
  );

  MemoryRecoveryFinding? findByKey(
    MemoryRecoveryReport report,
    String layerKey,
  ) {
    for (final finding in report.findings) {
      if (finding.layerKey == layerKey) {
        return finding;
      }
    }
    return null;
  }

  int quarantineCount() {
    final directory = Directory(
      path.join(memoryDirectory, 'recovery', 'quarantine'),
    );
    if (!directory.existsSync()) {
      return 0;
    }
    return directory.listSync().whereType<File>().length;
  }

  group('sessions', () {
    test('截断会话按完整对话块抢救，隔离原件保留', () async {
      final file = await seedSession('2026-08-05', 1, [
        ('用户', '今天有点累'),
        ('栖语', '那就早点休息。'),
        ('用户', '再聊一会儿'),
        ('栖语', '好，我在。'),
      ]);
      final contents = await file.readAsString();
      // 在第三个对话块（第二条用户轮）的标记中间截断。
      final firstTurn = contents.indexOf('<!-- qiyu-turn:');
      final secondTurn = contents.indexOf(
        '<!-- qiyu-turn:',
        firstTurn + 10,
      );
      final thirdTurn = contents.indexOf(
        '<!-- qiyu-turn:',
        secondTurn + 10,
      );
      await overwrite(file, contents.substring(0, thirdTurn + 20));

      final report = await recovery.sweepAndRecover();

      final listing = await MarkdownMemoryRepository(
        memoryDirectory: memoryDirectory,
      ).readHistory();
      expect(listing.sessions, hasLength(1));
      expect(listing.sessions.single.turns, hasLength(2));
      expect(listing.unavailable, isEmpty);

      final finding = findByKey(report, 'session');
      expect(finding, isNotNull);
      expect(finding!.kind, MemoryDamageKind.incomplete);
      expect(finding.outcome, MemoryRecoveryOutcome.partial);
      expect(finding.loss, isNotNull);
      expect(quarantineCount(), 1);
    });

    test('无元数据的会话被隔离，健康会话不受影响', () async {
      await seedSession('2026-08-04', 1, [('用户', '你好')]);
      await overwrite(
        File(
          path.join(
            memoryDirectory,
            'sessions',
            '2026',
            '08',
            '2026-08-05-001.md',
          ),
        ),
        '无法识别的二进制乱码',
      );

      final report = await recovery.sweepAndRecover();

      expect(
        File(
          path.join(
            memoryDirectory,
            'sessions',
            '2026',
            '08',
            '2026-08-05-001.md',
          ),
        ).existsSync(),
        isFalse,
      );
      final listing = await MarkdownMemoryRepository(
        memoryDirectory: memoryDirectory,
      ).readHistory();
      expect(listing.sessions, hasLength(1));
      expect(listing.sessions.single.date, '2026-08-04');

      final finding = findByKey(report, 'session');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.pending);
      expect(finding.loss, contains('会话头信息'));
      expect(quarantineCount(), 1);
    });

    test('写入中断留下的临时文件被清理', () async {
      final tempFile = File(
        path.join(
          memoryDirectory,
          'sessions',
          '2026',
          '08',
          '2026-08-01-001.md.1750000000000000.tmp',
        ),
      );
      await overwrite(tempFile, '中断写入的半成品');

      final report = await recovery.sweepAndRecover();

      expect(tempFile.existsSync(), isFalse);
      expect(findByKey(report, 'temp-files'), isNotNull);
    });
  });

  group('episodes', () {
    test('截断每日记录抢救完整条目，摘要与归档标记保留', () async {
      await seedEpisodeDay(
        '2026-08-05',
        [entry('2026-08-05', 'e1', '用户在准备演讲'),
         entry('2026-08-05', 'e2', '用户睡了个好觉')],
        summary: '聊了演讲和睡眠',
      );
      final file = dayFile('2026-08-05');
      final contents = await file.readAsString();
      final secondEntry = contents.indexOf('<!-- qiyu-episode-entry:');
      final cutAt = contents.indexOf(
        '<!-- qiyu-episode-entry:',
        secondEntry + 10,
      );
      // 截断点落在第二个条目的 base64 载荷中间。
      await overwrite(file, contents.substring(0, cutAt + 40));

      final report = await recovery.sweepAndRecover();

      final day = await pipeline.readDay('2026-08-05');
      expect(day.readable, isTrue);
      expect(day.entries, hasLength(1));
      expect(day.entries.single.id, 'e1');
      expect(day.summary, '聊了演讲和睡眠');
      expect(day.finalized, isTrue);

      final finding = findByKey(report, 'episode-day');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.partial);
      expect(quarantineCount(), 1);
    });

    test('元数据损坏时条目保留，摘要与归档标记诚实重置', () async {
      await seedEpisodeDay(
        '2026-08-05',
        [entry('2026-08-05', 'e1', '用户在准备演讲')],
        summary: '今日摘要',
      );
      final file = dayFile('2026-08-05');
      final contents = await file.readAsString();
      await overwrite(
        file,
        contents.replaceFirst(
          RegExp(r'<!-- qiyu-episode:[A-Za-z0-9_-]+ -->'),
          '<!-- qiyu-episode:broken-metadata -->',
        ),
      );

      final report = await recovery.sweepAndRecover();

      final day = await pipeline.readDay('2026-08-05');
      expect(day.readable, isTrue);
      expect(day.entries, hasLength(1));
      expect(day.summary, isNull);
      expect(day.finalized, isFalse);

      final finding = findByKey(report, 'episode-day');
      expect(finding, isNotNull);
      expect(finding!.kind, MemoryDamageKind.incomplete);
      expect(finding.loss, contains('摘要'));
    });

    test('用户手写的日文件绝不触碰', () async {
      final file = dayFile('2026-08-05');
      const handWritten = '# 我的手写笔记\n\n今天自己记了点东西。\n';
      await overwrite(file, handWritten);

      final report = await recovery.sweepAndRecover();

      expect(await file.readAsString(), handWritten);
      expect(findByKey(report, 'episode-day'), isNull);
    });
  });

  group('checkpoint', () {
    test('损坏检查点重置为完整恢复，不残留隔离副本', () async {
      await overwrite(
        File(path.join(memoryDirectory, 'episodes', 'checkpoint.md')),
        '检查点乱码',
      );

      final report = await recovery.sweepAndRecover();

      expect(
        File(path.join(memoryDirectory, 'episodes', 'checkpoint.md'))
            .existsSync(),
        isFalse,
      );
      final finding = findByKey(report, 'checkpoint');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.full);
      expect(quarantineCount(), 0);
    });

    test('指向不存在会话的检查点按引用失效重置', () async {
      await seedSession('2026-08-05', 1, [('用户', '你好')]);
      await overwrite(
        File(path.join(memoryDirectory, 'episodes', 'checkpoint.md')),
        '# 栖语整理检查点\n\n'
        '<!-- qiyu-checkpoint:${b64({
          'schemaVersion': 1,
          'sessionId': 'ghost-session',
          'lastRequestId': 'r0',
          'updatedAt': clock.toUtc().toIso8601String(),
        })} -->\n',
      );

      final report = await recovery.sweepAndRecover();

      final finding = findByKey(report, 'checkpoint');
      expect(finding, isNotNull);
      expect(finding!.kind, MemoryDamageKind.orphaned);
      expect(
        File(path.join(memoryDirectory, 'episodes', 'checkpoint.md'))
            .existsSync(),
        isFalse,
      );
    });

    test('检查点重置后重跑整理，语义去重不产生重复条目', () async {
      final session = RawSession(
        id: 'session-replay',
        date: '2026-08-19',
        segment: 1,
        createdAt: DateTime.parse('2026-08-19T20:00:00').toUtc(),
        updatedAt: DateTime.parse('2026-08-19T20:30:00').toUtc(),
        turns: [
          RawSessionTurn.user(
            requestId: 'r0',
            text: '说说海',
            at: DateTime.parse('2026-08-19T20:10:00').toUtc(),
          ),
          RawSessionTurn.qiyu(
            requestId: 'r0',
            messages: ['海很宽。'],
            at: DateTime.parse('2026-08-19T20:10:30').toUtc(),
            source: ReplySource.local,
            mode: 'local',
          ),
        ],
      );
      const action = HiddenAction(
        kind: HiddenActionKind.memorySignal,
        summary: '用户喜欢海',
      );
      final first = await pipeline.processReply(
        session: session,
        requestId: 'req-1',
        hiddenActions: [action],
      );
      expect(first.writtenEntries, 1);

      // 模拟检查点损坏后的重置：游标从头重扫。
      await File(
        path.join(memoryDirectory, 'episodes', 'checkpoint.md'),
      ).delete();

      final second = await pipeline.processReply(
        session: session,
        requestId: 'req-1',
        hiddenActions: [action],
      );
      expect(second.writtenEntries, 0);
      expect(second.skippedDuplicates, 1);
      final day = await pipeline.readDay('2026-08-19');
      expect(day.entries, hasLength(1));
    });
  });

  group('索引', () {
    test('损坏的月份索引从有效每日记录重建', () async {
      await seedEpisodeDay(
        '2026-08-05',
        [entry('2026-08-05', 'e1', '用户在准备演讲')],
        summary: '演讲',
      );
      final indexStore = EpisodeIndexStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      await pipeline.synchronizedOnDayFiles(
        () => indexStore.rebuild(includeUnfinalized: true),
      );
      expect(await indexStore.readTopIndex(), isNotNull);
      await overwrite(indexStore.topIndexFile, '索引乱码');

      final report = await recovery.sweepAndRecover();

      final top = await indexStore.readTopIndex();
      expect(top, isNotNull);
      expect(top!.single.month, '2026-08');
      final finding = findByKey(report, 'top-index');
      expect(finding, isNotNull);
      expect(finding!.kind, MemoryDamageKind.corrupt);
      expect(finding.outcome, MemoryRecoveryOutcome.full);
      expect(quarantineCount(), 0);
    });

    test('每日索引的孤儿行重建后消失', () async {
      await seedEpisodeDay(
        '2026-08-05',
        [entry('2026-08-05', 'e1', '用户在准备演讲')],
        summary: '演讲',
      );
      final indexStore = EpisodeIndexStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      await pipeline.synchronizedOnDayFiles(
        () => indexStore.rebuild(includeUnfinalized: true),
      );
      final monthFile = indexStore.monthIndexFile('2026-08');
      await overwrite(
        monthFile,
        '${await monthFile.readAsString()}'
        '- 2026-08-09 | 幽灵日期 | 2026-08-09.md\n',
      );

      final report = await recovery.sweepAndRecover();

      final monthIndex = await indexStore.readMonthIndex('2026-08');
      expect(monthIndex, isNotNull);
      expect(
        monthIndex!.map((line) => line.date),
        isNot(contains('2026-08-09')),
      );
      final finding = findByKey(report, 'month-index');
      expect(finding, isNotNull);
      expect(finding!.kind, MemoryDamageKind.orphaned);
    });

    test('缺失的索引按缺失重建', () async {
      await seedEpisodeDay(
        '2026-08-05',
        [entry('2026-08-05', 'e1', '用户在准备演讲')],
        summary: '演讲',
      );
      final indexStore = EpisodeIndexStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      expect(await indexStore.readTopIndex(), isNull);

      final report = await recovery.sweepAndRecover();

      expect(await indexStore.readTopIndex(), isNotNull);
      final finding = findByKey(report, 'top-index');
      expect(finding, isNotNull);
      expect(finding!.kind, MemoryDamageKind.missing);
    });
  });

  group('月度摘要', () {
    test('损坏的月摘要从同月每日记录重新压缩', () async {
      await seedEpisodeDay(
        '2026-07-05',
        [entry('2026-07-05', 'e1', '用户去了海边')],
        summary: '海边',
      );
      await monthlySummary.compressMonth('2026-07');
      final summaryFile = monthlySummary.summaryFile('2026-07');
      expect(await summaryFile.exists(), isTrue);
      await overwrite(summaryFile, '摘要乱码');

      final report = await recovery.sweepAndRecover();

      final summary = await monthlySummary.readMonthSummary('2026-07');
      expect(summary, isNotNull);
      expect(summary!.readable, isTrue);
      expect(summary.items.map((item) => item.text), contains('用户去了海边'));
      final finding = findByKey(report, 'month-summary');
      expect(finding, isNotNull);
      expect(finding!.kind, MemoryDamageKind.corrupt);
      expect(finding.outcome, MemoryRecoveryOutcome.full);
      expect(quarantineCount(), 0);
    });
  });

  group('记忆控制', () {
    test('控制记录从审计重建，被控内容不随抢救复活', () async {
      await seedEpisodeDay('2026-08-05', [
        entry('2026-08-05', 'e1', '用户喜欢咖啡'),
        entry(
          '2026-08-05',
          'audit-ban',
          '禁提: 秘密项目',
          kind: episodeKindOpenLoopEvent,
        ),
        entry(
          '2026-08-05',
          'audit-freeze',
          '冻结: 旧习惯',
          kind: episodeKindOpenLoopEvent,
        ),
        entry(
          '2026-08-05',
          'audit-delete',
          '删除: 痛苦回忆',
          kind: episodeKindOpenLoopEvent,
        ),
        // 命中删除范围的派生条目：恢复后必须被清除，不得复活。
        entry('2026-08-05', 'e2', '痛苦回忆的细节'),
      ]);
      await overwrite(
        File(path.join(memoryDirectory, 'memory-controls.md')),
        '控制文件乱码',
      );

      final report = await recovery.sweepAndRecover();

      final controls = await memoryControls.load();
      expect(controls.readable, isTrue);
      expect(controls.bannedSummaries, contains('秘密项目'));
      expect(controls.frozenSummaries, contains('旧习惯'));
      expect(controls.deletedSummaries, contains('痛苦回忆'));

      final day = await pipeline.readDay('2026-08-05');
      final summaries = day.entries.map((entry) => entry.summary).toList();
      expect(summaries, contains('用户喜欢咖啡'));
      expect(summaries, isNot(contains('痛苦回忆的细节')));
      // 审计簿记条目本身保留（sessions 与审计永不销毁）。
      expect(summaries, contains('禁提: 秘密项目'));

      final finding = findByKey(report, 'controls');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.partial);
      expect(finding.evidence, contains('审计'));
      expect(quarantineCount(), greaterThanOrEqualTo(1));
    });

    test('审计为空时按空控制重建并诚实报告失守风险', () async {
      await overwrite(
        File(path.join(memoryDirectory, 'memory-controls.md')),
        '控制文件乱码',
      );

      final report = await recovery.sweepAndRecover();

      final controls = await memoryControls.load();
      expect(controls.readable, isTrue);
      expect(controls.bannedSummaries, isEmpty);
      final finding = findByKey(report, 'controls');
      expect(finding, isNotNull);
      expect(finding!.loss, contains('失守'));
    });

    test('恢复幂等：重复扫描不重复写控制记录', () async {
      await seedEpisodeDay('2026-08-05', [
        entry(
          '2026-08-05',
          'audit-ban',
          '禁提: 秘密项目',
          kind: episodeKindOpenLoopEvent,
        ),
      ]);
      await overwrite(
        File(path.join(memoryDirectory, 'memory-controls.md')),
        '控制文件乱码',
      );

      await recovery.sweepAndRecover();
      await recovery.sweepAndRecover();

      final controls = await memoryControls.load();
      expect(controls.banned, hasLength(1));
    });
  });

  group('长期印象与 Dream', () {
    test('长期印象从 Dream 备份完整恢复', () async {
      const backupContent = '# long-memory\n\n## 人与关系\n- 一条长期印象\n';
      await overwrite(
        File(path.join(memoryDirectory, 'long-memory.md')),
        '# long-memory\n这是损坏的内容',
      );
      await overwrite(
        File(path.join(memoryDirectory, 'dream', 'backup', 'long-memory.md')),
        backupContent,
      );

      final report = await recovery.sweepAndRecover();

      expect(
        await File(path.join(memoryDirectory, 'long-memory.md'))
            .readAsString(),
        backupContent,
      );
      final finding = findByKey(report, 'long-memory');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.full);
      expect(finding.evidence, contains('备份'));
      expect(quarantineCount(), 0);
    });

    test('无备份的长期印象隔离等待恢复，绝不补写', () async {
      await overwrite(
        File(path.join(memoryDirectory, 'long-memory.md')),
        '# long-memory\n这是损坏的内容',
      );

      final report = await recovery.sweepAndRecover();

      expect(
        File(path.join(memoryDirectory, 'long-memory.md')).existsSync(),
        isFalse,
      );
      final finding = findByKey(report, 'long-memory');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.pending);
      expect(finding.loss, contains('长期印象'));
      expect(quarantineCount(), 1);
    });

    test('长期印象从备份恢复后，被删除内容不随旧备份复活', () async {
      // 现行控制（健康文件）：用户已删除「痛苦回忆」。
      expect(
        await memoryControls.recordDelete('痛苦回忆', origin: 'user'),
        isTrue,
      );
      // Dream 备份定格在删除之前：仍含命中删除范围的条目。
      const backupContent =
          '# long-memory\n\n## 人与关系\n- 痛苦回忆的细节\n- 一条正常印象\n';
      await overwrite(
        File(path.join(memoryDirectory, 'dream', 'backup', 'long-memory.md')),
        backupContent,
      );
      // 现行长期印象损坏，触发备份恢复。
      await overwrite(
        File(path.join(memoryDirectory, 'long-memory.md')),
        '# long-memory\n这是损坏的内容',
      );

      final report = await recovery.sweepAndRecover();

      final finding = findByKey(report, 'long-memory');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.full);
      // 备份已恢复，但命中现行删除范围的条目必须被再次清除。
      final restored = await File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).readAsString();
      expect(parseLongMemory(restored).readable, isTrue);
      expect(restored, contains('一条正常印象'));
      expect(restored, isNot(contains('痛苦回忆')));
      expect(quarantineCount(), 0);
    });

    test('损坏的 Dream 状态重置为空', () async {
      await overwrite(
        File(path.join(memoryDirectory, 'dream', 'state.md')),
        '状态乱码',
      );

      final report = await recovery.sweepAndRecover();

      expect(
        File(path.join(memoryDirectory, 'dream', 'state.md')).existsSync(),
        isFalse,
      );
      final state = await dreamService.readState();
      expect(state.lastSuccess, isNull);
      expect(state.pending, isFalse);
      final finding = findByKey(report, 'dream-state');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.partial);
    });
  });

  group('PersonaTree', () {
    test('损坏分支从 Dream 备份恢复并重投影', () async {
      const branchContent = '# 身份事实\n\n## 未归根中间节点\n';
      await overwrite(
        File(path.join(memoryDirectory, 'persona-tree', 'identity.md')),
        '分支乱码',
      );
      await overwrite(
        File(
          path.join(
            memoryDirectory,
            'dream',
            'backup',
            'persona-tree',
            'identity.md',
          ),
        ),
        branchContent,
      );

      final report = await recovery.sweepAndRecover();

      expect(
        await File(
          path.join(memoryDirectory, 'persona-tree', 'identity.md'),
        ).readAsString(),
        branchContent,
      );
      final snapshot = await personaTree.readSnapshot();
      expect(snapshot.branches['identity']!.readable, isTrue);
      final finding = findByKey(report, 'persona-branch-identity');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.full);
      expect(quarantineCount(), 0);
    });

    test('无备份的损坏分支隔离等待恢复', () async {
      await overwrite(
        File(path.join(memoryDirectory, 'persona-tree', 'identity.md')),
        '分支乱码',
      );

      final report = await recovery.sweepAndRecover();

      expect(
        File(path.join(memoryDirectory, 'persona-tree', 'identity.md'))
            .existsSync(),
        isFalse,
      );
      final finding = findByKey(report, 'persona-branch-identity');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.pending);
      expect(quarantineCount(), 1);
    });

    test('归档无法恢复时暂停受影响分支的根节点操作', () async {
      // 留下已归档的日期材料供 Dream 输入使用。
      await seedEpisodeDay(
        '2026-08-05',
        [entry('2026-08-05', 'e1', '用户是一名教师')],
        summary: '职业',
      );
      await overwrite(
        File(
          path.join(
            memoryDirectory,
            'persona-tree',
            'archive',
            'identity.md',
          ),
        ),
        '归档乱码',
      );

      final report = await recovery.sweepAndRecover();

      final snapshot = await personaTree.readSnapshot();
      expect(snapshot.branches['identity']!.archiveReadable, isFalse);
      final finding = findByKey(report, 'persona-archive-identity');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.pending);
      expect(finding.loss, contains('暂停'));

      // Dream 提案在该分支一律被拒（archive-unavailable）。
      final diagnostics = <String>[];
      final dream = DreamService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        openLoopStore: openLoopStore,
        monthlySummary: monthlySummary,
        personaTree: personaTree,
        modelClient: _ScriptedClient([
          ModelCompletion.reply(
            '{"items":[{"section":"人与关系","text":"一条印象",'
            '"evidence":["2026-08-05"]}],'
            '"rootProposals":[{"op":"promote","branch":"identity",'
            '"claim":"用户是一名教师","middles":["ID-M001"]}]}',
          ),
        ]),
        clock: () => clock,
        diagnosticsSink: diagnostics.add,
      );
      await overwrite(
        File(path.join(memoryDirectory, 'dream', 'state.md')),
        '# dream-state\n\n'
        '<!-- qiyu-dream-state:${b64({
          'schemaVersion': 1,
          'pending': true,
        })} -->\n',
      );
      final outcome = await dream.run(bedtime: false);
      expect(outcome.status, DreamStatus.accepted);
      expect(outcome.rootOpsApplied, 0);
      expect(outcome.rootOpsRejected, 1);
      expect(
        diagnostics.any(
          (message) => message.contains('archive-unavailable'),
        ),
        isTrue,
      );
    });
  });

  group('热层', () {
    test('关系记录从剧集证据整体重建，完整恢复不留隔离副本', () async {
      await seedEpisodeDay(
        '2026-08-05',
        [entry('2026-08-05', 'e1', '用户打了招呼')],
        summary: '打招呼',
      );
      await overwrite(
        File(path.join(memoryDirectory, 'relationship.md')),
        '# relationship\n{损坏的结构',
      );

      final report = await recovery.sweepAndRecover();

      final rebuilt = File(path.join(memoryDirectory, 'relationship.md'));
      expect(await rebuilt.exists(), isTrue);
      expect(
        parseRelationshipFile(await rebuilt.readAsString()),
        isNotNull,
      );
      final finding = findByKey(report, 'relationship');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.full);
      expect(finding.quarantined, isFalse);
      expect(quarantineCount(), 0);
    });
  });

  group('整体', () {
    test('多层同时损坏不阻塞健康日期浏览与恢复呈现', () async {
      await seedSession('2026-08-04', 1, [('用户', '你好'), ('栖语', '你好呀')]);
      await seedEpisodeDay(
        '2026-08-04',
        [entry('2026-08-04', 'ok', '用户打了招呼')],
        summary: '打招呼',
      );
      await seedEpisodeDay(
        '2026-08-05',
        [entry('2026-08-05', 'bad', '本条随文件损坏')],
        summary: '损坏日',
      );
      final badDay = dayFile('2026-08-05');
      final contents = await badDay.readAsString();
      final marker = contents.indexOf('<!-- qiyu-episode-entry:');
      // 截断点落在条目的 base64 载荷中间。
      await overwrite(badDay, contents.substring(0, marker + 40));

      final report = await recovery.sweepAndRecover();

      final memoryCenter = MemoryCenterService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryControls: memoryControls,
        dreamService: dreamService,
        memoryRecovery: recovery,
        clock: () => clock,
        diagnosticsSink: (_) {},
      );
      final overview = await memoryCenter.overview();
      expect(
        overview.recent.days.map((day) => day.date),
        contains('2026-08-04'),
      );
      expect(overview.recovery.healthy, isFalse);
      expect(overview.recovery.findings, isNotEmpty);
      expect(overview.recovery.quarantinedFiles, greaterThanOrEqualTo(1));
      expect(report.healthy, isFalse);
    });

    test('报告持久化后可读取，隔离清单在后续扫描持续可见', () async {
      await overwrite(
        File(
          path.join(
            memoryDirectory,
            'sessions',
            '2026',
            '08',
            '2026-08-05-001.md',
          ),
        ),
        '无法识别的乱码',
      );

      await recovery.sweepAndRecover();
      final persisted = await recovery.readReport();
      expect(persisted, isNotNull);
      expect(persisted!.findings, isNotEmpty);

      // 第二次扫描没有新损坏，但隔离原件仍保留：持续可见。
      final second = await recovery.sweepAndRecover();
      final sessionFinding = findByKey(second, 'session');
      expect(sessionFinding, isNotNull);
      expect(sessionFinding!.quarantined, isTrue);
      expect(sessionFinding.loss, contains('隔离'));

      final logFile = File(
        path.join(memoryDirectory, 'recovery', 'recovery.log'),
      );
      expect(await logFile.exists(), isTrue);
      final logLines = await logFile.readAsLines();
      expect(logLines, isNotEmpty);
      // 日志只记时间、类型、结果与损失，绝不记正文。
      for (final line in logLines) {
        expect(line.split(' | '), hasLength(4));
      }
    });

    test('健康记忆库扫描后保持健康', () async {
      await seedSession('2026-08-04', 1, [('用户', '你好')]);
      await seedEpisodeDay(
        '2026-08-04',
        [entry('2026-08-04', 'ok', '用户打了招呼')],
        summary: '打招呼',
      );
      await pipeline.synchronizedOnDayFiles(
        () => EpisodeIndexStore(
          memoryDirectory: memoryDirectory,
          episodePipeline: pipeline,
        ).rebuild(includeUnfinalized: true),
      );

      final report = await recovery.sweepAndRecover();

      expect(report.healthy, isTrue);
      expect(report.findings, isEmpty);
      expect(quarantineCount(), 0);
    });
  });
}

/// 供 Dream 测试使用的脚本化模型客户端。
final class _ScriptedClient implements ProviderChatClient {
  _ScriptedClient(this.completions);

  final List<ModelCompletion?> completions;
  var _index = 0;

  @override
  Future<ModelCompletion?> complete(List<ModelMessage> messages) async {
    if (_index >= completions.length) {
      return null;
    }
    return completions[_index++];
  }
}
