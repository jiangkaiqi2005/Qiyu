import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/scripted_chat_client.dart';

void main() {
  test(
    'legacy month keywords are redacted without changing an empty selection',
    () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户聊到旧书店')],
      });
      addTearDown(() => root.delete(recursive: true));
      final client = ScriptedChatClient([
        ModelCompletion.reply(_selectionReply()),
      ]);
      final (recall, pipeline) = _orchestrator(root.path, client: client);
      await _rebuildUnderLock(recall, pipeline);
      final monthFile = recall.indexStore.topIndexFile;
      final dayFile = recall.indexStore.monthIndexFile('2026-08');
      await monthFile.writeAsString(
        '# 旧索引\n'
        '- 2026-08 | {"pwd":"M1"}, 旧书店, {"count":42}, 12345678 | '
        'episodes/2026/08/index.md\n',
      );
      await dayFile.writeAsString(
        '# 旧索引\n- 2026-08-10 | 旧书店 | 2026-08-10.md\n',
      );
      final monthBytes = await monthFile.readAsBytes();
      final dayBytes = await dayFile.readAsBytes();

      final result = await recall.runTurnRecall(
        userText: '上次说的书店',
        recallActions: [MemoryRecallAction(query: '旧书店')],
      );

      expect(client.calls, hasLength(1));
      for (final message in client.calls.single) {
        expect(message.content, isNot(contains('M1')));
      }
      expect(client.calls.single.map((message) => message.role), [
        ModelMessageRole.system,
        ModelMessageRole.user,
      ]);
      expect(
        client.calls.single.last.content,
        '查找意图：旧书店\n用户当时的原话：上次说的书店\n\n'
        '## 月份索引（episodes/index.md）\n'
        '- 2026-08 | {"pwd":"[已脱敏]"}, 旧书店, {"count":42}, 12345678 | '
        'episodes/2026/08/index.md\n\n'
        '## 每日索引（2026-08）\n'
        '- 2026-08-10 | 旧书店 | 2026-08-10.md\n',
      );
      expect(client.maxTokens, [16384]);
      expect(result.bubbleText, isNull);
      expect(result.pendingContext, isNull);
      expect(result.diagnostics, ['recall miss reason=no-date-selection']);
      expect(await monthFile.readAsBytes(), monthBytes);
      expect(await dayFile.readAsBytes(), dayBytes);
    },
  );

  test(
    'legacy daily keywords are redacted on initial and supplemental selections',
    () async {
      final root = await _seedEpisodes({
        '2025-03-05': [_entry('seed:1:0', '用户聊到旧书店的老板')],
        '2026-06-01': [_entry('seed:2:0', '用户最近在跑步')],
        '2026-07-01': [_entry('seed:3:0', '用户说想去青岛')],
        '2026-08-10': [_entry('seed:4:0', '用户去看了演唱会')],
      });
      addTearDown(() => root.delete(recursive: true));
      final client = ScriptedChatClient([
        ModelCompletion.reply(_selectionReply(months: ['2025-03'])),
        ModelCompletion.reply(_selectionReply(dates: ['2025-03-05'])),
        ModelCompletion.reply('书店那件事想起来了。'),
      ]);
      final (recall, pipeline) = _orchestrator(root.path, client: client);
      await _rebuildUnderLock(recall, pipeline);
      final monthFile = recall.indexStore.topIndexFile;
      final recentDayFile = recall.indexStore.monthIndexFile('2026-08');
      final oldDayFile = recall.indexStore.monthIndexFile('2025-03');
      await monthFile.writeAsString(
        '# 旧索引\n'
        '- 2025-03 | {"pwd":"M1"}, 旧书店 | episodes/2025/03/index.md\n'
        '- 2026-06 | 跑步 | episodes/2026/06/index.md\n'
        '- 2026-07 | 青岛 | episodes/2026/07/index.md\n'
        '- 2026-08 | 演唱会 | episodes/2026/08/index.md\n',
      );
      await recentDayFile.writeAsString(
        '# 旧索引\n'
        '- 2026-08-10 | {"pwd":"D1"}, 演唱会 | 2026-08-10.md\n',
      );
      await oldDayFile.writeAsString(
        '# 旧索引\n'
        '- 2025-03-05 | {"pwd":"D2"}, 旧书店, {"count":42}, 12345678 | '
        '2025-03-05.md\n',
      );
      final monthBytes = await monthFile.readAsBytes();
      final recentDayBytes = await recentDayFile.readAsBytes();
      final oldDayBytes = await oldDayFile.readAsBytes();

      final result = await recall.runTurnRecall(
        userText: '以前聊过的书店',
        recallActions: [MemoryRecallAction(query: '旧书店')],
      );

      expect(client.calls, hasLength(3));
      expect(
        client.calls
            .expand((messages) => messages)
            .map((message) => message.content),
        everyElement(
          allOf(
            isNot(contains('M1')),
            isNot(contains('D1')),
            isNot(contains('D2')),
          ),
        ),
      );
      for (final selection in client.calls.take(2)) {
        expect(selection.map((message) => message.role), [
          ModelMessageRole.system,
          ModelMessageRole.user,
        ]);
        expect(
          selection.last.content,
          contains(
            '查找意图：旧书店\n用户当时的原话：以前聊过的书店\n\n'
            '## 月份索引（episodes/index.md）\n'
            '- 2025-03 | {"pwd":"[已脱敏]"}, 旧书店 | episodes/2025/03/index.md\n'
            '- 2026-06 | 跑步 | episodes/2026/06/index.md\n'
            '- 2026-07 | 青岛 | episodes/2026/07/index.md\n'
            '- 2026-08 | 演唱会 | episodes/2026/08/index.md\n',
          ),
        );
        expect(
          selection.last.content,
          contains(
            '## 每日索引（2026-08）\n'
            '- 2026-08-10 | {"pwd":"[已脱敏]"}, 演唱会 | 2026-08-10.md\n',
          ),
        );
      }
      expect(client.calls[1].first.content, client.calls[0].first.content);
      expect(client.calls[0].last.content, isNot(contains('每日索引（2025-03）')));
      expect(
        client.calls[1].last.content,
        contains(
          '## 每日索引（2025-03）\n'
          '- 2025-03-05 | {"pwd":"[已脱敏]"}, 旧书店, {"count":42}, 12345678 | '
          '2025-03-05.md\n',
        ),
      );
      expect(client.maxTokens, [16384, 16384, 16384]);
      expect(result.bubbleText, '书店那件事想起来了。');
      expect(result.pendingContext, contains('2025-03-05'));
      expect(result.pendingContext, contains('用户聊到旧书店的老板'));
      expect(result.diagnostics, [
        'recall month index supplemented month=2025-03',
      ]);
      expect(await monthFile.readAsBytes(), monthBytes);
      expect(await recentDayFile.readAsBytes(), recentDayBytes);
      expect(await oldDayFile.readAsBytes(), oldDayBytes);
    },
  );

  for (final (keywords, expectedKeywords) in [
    ('旧书店, {"count":42}, 12345678', '旧书店, {"count":42}, 12345678'),
    ('{"pwd":"D1"}, 旧书店', '{"pwd":"[已脱敏]"}, 旧书店'),
    ('{"pwd":",D"}, 旧书店', '{"pwd":"[已脱敏]"}, 旧书店'),
    (
      'cookie:a=b, 旧书店, {"count":42}, 12345678',
      'cookie:[已脱敏], 旧书店, {"count":42}, 12345678',
    ),
    ('Cookie:教程, page=42, 旧书店', 'Cookie:教程, page=42, 旧书店'),
    ('Cookie:, page=42, 旧书店', 'Cookie:, page=42, 旧书店'),
    ('Cookie:a=b, 旧书店, 12345678', 'Cookie:[已脱敏], 旧书店, 12345678'),
    (
      'cookie:a=b, {"pwd":",D"}, 旧书店, {"count":42}, 12345678',
      'cookie:[已脱敏], {"pwd":"[已脱敏]"}, 旧书店, {"count":42}, 12345678',
    ),
    (
      '{"cookie":["sid=a","other=b"]}, 旧书店, {"count":42}',
      '{"cookie":["[已脱敏]", "[已脱敏]"]}, 旧书店, {"count":42}',
    ),
    (
      'Cookie:教程, {"count":42,"note":"甲,乙"}, 旧书店, 12345678',
      'Cookie:教程, {"count":42, "note":"甲, 乙"}, 旧书店, 12345678',
    ),
    ('cookie:a=b; c=d, 旧书店, 12345678', 'cookie:[已脱敏], 旧书店, 12345678'),
  ]) {
    test(
      'direct recall preserves a normal hit with keywords $keywords',
      () async {
        final root = await _seedEpisodes({
          '2026-08-10': [
            _entry('seed:1:0', '用户聊到旧书店的老板', evidence: '上回在旧书店挑了本画册'),
          ],
        });
        addTearDown(() => root.delete(recursive: true));
        final client = ScriptedChatClient([
          ModelCompletion.reply(_selectionReply(dates: ['2026-08-10'])),
          ModelCompletion.reply('想起来了，你在书店挑了本画册。'),
        ]);
        final (recall, pipeline) = _orchestrator(root.path, client: client);
        await _rebuildUnderLock(recall, pipeline);
        await recall.indexStore.topIndexFile.writeAsString(
          '# 旧索引\n- 2026-08 | $keywords | episodes/2026/08/index.md\n',
        );
        await recall.indexStore
            .monthIndexFile('2026-08')
            .writeAsString('# 旧索引\n- 2026-08-10 | $keywords | 2026-08-10.md\n');
        final monthBytes = await recall.indexStore.topIndexFile.readAsBytes();
        final dayBytes = await recall.indexStore
            .monthIndexFile('2026-08')
            .readAsBytes();

        final result = await recall.runTurnRecall(
          userText: '上次说的书店',
          recallActions: [MemoryRecallAction(query: '旧书店')],
        );

        expect(client.calls, hasLength(2));
        for (final message in client.calls.expand((messages) => messages)) {
          expect(message.content, isNot(contains('D1')));
        }
        expect(
          client.calls.first.last.content,
          '查找意图：旧书店\n用户当时的原话：上次说的书店\n\n'
          '## 月份索引（episodes/index.md）\n'
          '- 2026-08 | $expectedKeywords | episodes/2026/08/index.md\n\n'
          '## 每日索引（2026-08）\n'
          '- 2026-08-10 | $expectedKeywords | 2026-08-10.md\n',
        );
        expect(client.calls.last.last.content, contains('上回在旧书店挑了本画册'));
        expect(client.maxTokens, [16384, 16384]);
        expect(result.bubbleText, '想起来了，你在书店挑了本画册。');
        expect(result.pendingContext, contains('2026-08-10'));
        expect(result.pendingContext, contains('用户聊到旧书店的老板'));
        expect(result.pendingContext, contains('上回在旧书店挑了本画册'));
        expect(result.diagnostics, isEmpty);
        expect(await recall.indexStore.topIndexFile.readAsBytes(), monthBytes);
        expect(
          await recall.indexStore.monthIndexFile('2026-08').readAsBytes(),
          dayBytes,
        );
      },
    );
  }

  test(
    'blocked credential prefixes leave no fragments in recall indexes',
    () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户傍晚去河边散步')],
      });
      addTearDown(() => root.delete(recursive: true));
      final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
      expect(
        (await MemoryBanExecution(openLoopStore: openLoopStore).execute(
          '书',
          origin: 'open-loop',
        )).controlWritten,
        isTrue,
      );
      final client = ScriptedChatClient([
        ModelCompletion.reply(_selectionReply(dates: ['2026-08-10'])),
        ModelCompletion.reply('想起来了，你去了河边。'),
      ]);
      final (recall, pipeline) = _orchestrator(
        root.path,
        client: client,
        openLoopStore: openLoopStore,
      );
      await _rebuildUnderLock(recall, pipeline);
      const keywords = '{"密码":"书,D"}, 旧书店, 散步, {"count":42}, 12345678';
      final monthFile = recall.indexStore.topIndexFile;
      final dayFile = recall.indexStore.monthIndexFile('2026-08');
      await monthFile.writeAsString(
        '# 旧索引\n- 2026-08 | $keywords | episodes/2026/08/index.md\n',
      );
      await dayFile.writeAsString(
        '# 旧索引\n- 2026-08-10 | $keywords | 2026-08-10.md\n',
      );
      final monthBytes = await monthFile.readAsBytes();
      final dayBytes = await dayFile.readAsBytes();

      final result = await recall.runTurnRecall(
        userText: '上次散步的事',
        recallActions: [MemoryRecallAction(query: '散步')],
      );

      expect(client.calls, hasLength(2));
      for (final message in client.calls.expand((messages) => messages)) {
        expect(message.content, isNot(contains('D"}')));
        expect(message.content, isNot(contains('书')));
      }
      final selection = client.calls.first.last.content;
      expect(selection, contains('## 月份索引（episodes/index.md）\n- 2026-08 | '));
      expect(selection, contains('## 每日索引（2026-08）\n- 2026-08-10 | '));
      expect(
        selection,
        contains('散步, {"count":42}, 12345678 | episodes/2026/08/index.md'),
      );
      expect(selection, contains('散步, {"count":42}, 12345678 | 2026-08-10.md'));
      expect(client.maxTokens, [16384, 16384]);
      expect(result.bubbleText, '想起来了，你去了河边。');
      expect(result.pendingContext, contains('2026-08-10'));
      expect(result.pendingContext, contains('用户傍晚去河边散步'));
      expect(result.diagnostics, isEmpty);
      expect(await monthFile.readAsBytes(), monthBytes);
      expect(await dayFile.readAsBytes(), dayBytes);
    },
  );

  for (final hideMonth in [true, false]) {
    test(
      'fully blocked credential indexes stay hidden month=$hideMonth',
      () async {
        final root = await _seedEpisodes({
          '2026-08-10': [_entry('seed:1:0', '用户傍晚去河边散步')],
        });
        addTearDown(() => root.delete(recursive: true));
        final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
        expect(
          (await MemoryBanExecution(openLoopStore: openLoopStore).execute(
            '书',
            origin: 'open-loop',
          )).controlWritten,
          isTrue,
        );
        final client = ScriptedChatClient([
          ModelCompletion.reply(_selectionReply(dates: ['2026-08-10'])),
        ]);
        final (recall, pipeline) = _orchestrator(
          root.path,
          client: client,
          openLoopStore: openLoopStore,
        );
        await _rebuildUnderLock(recall, pipeline);
        const blockedKeywords = '{"密码":"书,书"}, 旧书店';
        final monthKeywords = hideMonth ? blockedKeywords : '散步';
        final monthFile = recall.indexStore.topIndexFile;
        final dayFile = recall.indexStore.monthIndexFile('2026-08');
        await monthFile.writeAsString(
          '# 旧索引\n- 2026-08 | $monthKeywords | episodes/2026/08/index.md\n',
        );
        await dayFile.writeAsString(
          '# 旧索引\n- 2026-08-10 | $blockedKeywords | 2026-08-10.md\n',
        );
        final monthBytes = await monthFile.readAsBytes();
        final dayBytes = await dayFile.readAsBytes();

        final result = await recall.runTurnRecall(
          userText: '上次散步的事',
          recallActions: [MemoryRecallAction(query: '散步')],
        );

        expect(client.calls, hasLength(hideMonth ? 0 : 1));
        if (hideMonth) {
          expect(
            result.diagnostics,
            contains('recall miss reason=no-visible-months'),
          );
        } else {
          final selection = client.calls.single.last.content;
          expect(
            selection,
            contains('- 2026-08 | 散步 | episodes/2026/08/index.md'),
          );
          expect(selection, isNot(contains('2026-08-10')));
          expect(selection, isNot(contains('书')));
          expect(
            result.diagnostics.join('\n'),
            contains('not-in-passed-index'),
          );
        }
        expect(
          result.diagnostics,
          contains('recall index line hidden reason=blocked'),
        );
        expect(result.bubbleText, isNull);
        expect(result.pendingContext, isNull);
        expect(await monthFile.readAsBytes(), monthBytes);
        expect(await dayFile.readAsBytes(), dayBytes);
      },
    );
  }

  test('in-turn loop walks both index levels and composes bubble 2', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲', evidence: '下周第一次演讲，好紧张')],
      '2026-08-10': [_entry('seed:2:0', '用户去看了演唱会')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _orchestrator(
      root.path,
      client: ScriptedChatClient([
        ModelCompletion.reply(_selectionReply(dates: ['2026-07-02'])),
        ModelCompletion.reply('是想起来了，演讲那件事。'),
      ]),
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说的演讲准备得怎么样了',
      recallActions: [MemoryRecallAction(query: '第一次演讲')],
    );

    // 命中：bubble 2 候选 + 压缩结果都在。
    expect(result.bubbleText, '是想起来了，演讲那件事。');
    expect(result.pendingContext, contains('2026-07-02'));
    expect(result.pendingContext, contains('第一次演讲'));
    // 压缩结果带原话摘录，但标注只是临时参考。
    expect(result.pendingContext, contains('下周第一次演讲，好紧张'));
    expect(result.pendingContext, contains('临时参考'));

    // 调用2 收到顶层索引与近期每日索引；调用3 收到回读的日原文。
    final client = recall.modelClient! as ScriptedChatClient;
    expect(client.calls, hasLength(2));
    final selectionInput = client.calls[0].last.content;
    expect(selectionInput, contains('2026-07'));
    expect(selectionInput, contains('2026-08'));
    expect(selectionInput, contains('2026-07-02'));
    expect(selectionInput, contains('第一次演讲'));
    expect(selectionInput, contains('用户当时的原话'));
    final composeInput = client.calls[1].last.content;
    expect(composeInput, contains('下周第一次演讲，好紧张'));
    expect(composeInput, contains('用户刚才说'));
  });

  test('recall selection and compose calls carry an explicit output budget', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲', evidence: '下周第一次演讲，好紧张')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _orchestrator(
      root.path,
      client: ScriptedChatClient([
        ModelCompletion.reply(_selectionReply(dates: ['2026-07-02'])),
        ModelCompletion.reply('是想起来了，演讲那件事。'),
      ]),
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说的演讲准备得怎么样了',
      recallActions: [MemoryRecallAction(query: '第一次演讲')],
    );

    expect(result.bubbleText, isNotNull);
    // 理解类调用必须显式给足输出预算：缺省会吃聊天护栏 512，材料变
    // 大后输出截断即整轮召回失败。
    final client = recall.modelClient! as ScriptedChatClient;
    expect(client.calls, hasLength(2));
    expect(client.maxTokens, [16384, 16384]);
  });

  test('the recall compose prompt states the appellation wording rule', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
    });
    addTearDown(() => root.delete(recursive: true));
    // 称呼来自 persona.md 受保护设定行（称呼定稿）。
    File('${root.path}/persona.md').writeAsStringSync('# persona\n称呼：老王\n');
    final (recall, pipeline) = _orchestrator(
      root.path,
      client: ScriptedChatClient([
        ModelCompletion.reply(_selectionReply(dates: ['2026-07-02'])),
        ModelCompletion.reply('是想起来了，演讲那件事。'),
        ModelCompletion.reply(_selectionReply(dates: ['2026-07-02'])),
        ModelCompletion.reply('嗯，想起来了。'),
      ]),
    );
    await _rebuildUnderLock(recall, pipeline);

    await recall.runTurnRecall(
      userText: '我上次说的演讲准备得怎么样了',
      recallActions: [MemoryRecallAction(query: '第一次演讲')],
    );
    final client = recall.modelClient! as ScriptedChatClient;
    // 有称呼：语境自然时可以用称呼，绝不自创昵称。
    final composeSystem = client.calls[1].first.content;
    expect(composeSystem, contains('语境自然时可以用「老王」称呼用户'));
    expect(composeSystem, contains('不要替用户起其他昵称'));

    // 无称呼：退回「你」。
    File('${root.path}/persona.md').deleteSync();
    await recall.runTurnRecall(
      userText: '再说说那天的事',
      recallActions: [MemoryRecallAction(query: '演讲')],
    );
    final fallbackSystem = client.calls[3].first.content;
    expect(fallbackSystem, contains('称呼用户时用「你」'));
    expect(fallbackSystem, contains('不要替用户起昵称'));
  });

  test('fabricated selections are dropped; members survive', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _orchestrator(
      root.path,
      client: ScriptedChatClient([
        // 编造的日期与真实日期混在一起。
        ModelCompletion.reply(
          _selectionReply(dates: ['2026-07-02', '2031-01-01']),
        ),
        ModelCompletion.reply('补一句。'),
      ]),
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '演讲的事',
      recallActions: [MemoryRecallAction(query: '演讲')],
    );

    expect(result.bubbleText, '补一句。');
    expect(
      result.diagnostics.join('\n'),
      contains('date=2031-01-01 reason=not-in-passed-index'),
    );
  });

  test(
    'a month-level pointer triggers a supplemental daily-index pass',
    () async {
      final root = await _seedEpisodes({
        // 老月 + 足够多的近期月份，让老月不在首递的近期每日索引里。
        '2025-03-05': [_entry('seed:1:0', '用户聊到旧书店的老板')],
        '2026-06-01': [_entry('seed:2:0', '用户最近在跑步')],
        '2026-07-01': [_entry('seed:3:0', '用户说想去青岛')],
        '2026-08-10': [_entry('seed:4:0', '用户去看了演唱会')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (recall, pipeline) = _orchestrator(
        root.path,
        client: ScriptedChatClient([
          // 第一次只指到月份（老月没有递过每日索引）。
          ModelCompletion.reply(_selectionReply(months: ['2025-03'])),
          // 补读每日索引后给出具体日期。
          ModelCompletion.reply(_selectionReply(dates: ['2025-03-05'])),
          ModelCompletion.reply('书店那件事想起来了。'),
        ]),
      );
      await _rebuildUnderLock(recall, pipeline);

      final result = await recall.runTurnRecall(
        userText: '以前聊过的书店',
        recallActions: [MemoryRecallAction(query: '旧书店')],
      );

      expect(result.bubbleText, '书店那件事想起来了。');
      final client = recall.modelClient! as ScriptedChatClient;
      expect(client.calls, hasLength(3));
      // 第一次选择调用没有递老月每日索引，第二次补上了。
      expect(client.calls[0].last.content, isNot(contains('每日索引（2025-03）')));
      expect(client.calls[1].last.content, contains('每日索引（2025-03）'));
      expect(client.calls[1].last.content, contains('2025-03-05'));
      expect(
        result.diagnostics.join('\n'),
        contains('month index supplemented month=2025-03'),
      );
    },
  );

  test('an empty selection misses without further calls', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _orchestrator(
      root.path,
      client: ScriptedChatClient([ModelCompletion.reply(_selectionReply())]),
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '潜水的事',
      recallActions: [MemoryRecallAction(query: '潜水装备')],
    );

    expect(result.bubbleText, isNull);
    expect(result.pendingContext, isNull);
    expect(result.diagnostics.join('\n'), contains('no-date-selection'));
    expect((recall.modelClient! as ScriptedChatClient).calls, hasLength(1));
  });

  test('an unconfigured provider skips the whole loop', () async {
    final root = await _seedEpisodes({
      '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
    });
    addTearDown(() => root.delete(recursive: true));
    final (recall, pipeline) = _orchestrator(root.path);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '演讲的事',
      recallActions: [MemoryRecallAction(query: '演讲')],
    );

    expect(result.bubbleText, isNull);
    expect(result.pendingContext, isNull);
    expect(result.diagnostics.join('\n'), contains('reason=no-provider'));
  });

  test(
    'a corrupt top index is rebuilt from raw episodes before locating',
    () async {
      final root = await _seedEpisodes({
        '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (recall, pipeline) = _orchestrator(
        root.path,
        client: ScriptedChatClient([
          ModelCompletion.reply(_selectionReply(dates: ['2026-07-02'])),
          ModelCompletion.reply('想起来了。'),
        ]),
      );
      await _rebuildUnderLock(recall, pipeline);
      File(
        '${root.path}/episodes/index.md',
      ).writeAsStringSync('这不是索引，是用户写坏的内容。\n', encoding: utf8);

      final result = await recall.runTurnRecall(
        userText: '演讲的事',
        recallActions: [MemoryRecallAction(query: '演讲')],
      );

      expect(result.bubbleText, '想起来了。');
      expect(result.diagnostics.join('\n'), contains('index rebuilt'));
      expect(
        File('${root.path}/episodes/index.md').readAsStringSync(encoding: utf8),
        contains('# episodes index'),
      );
    },
  );

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
    final (recall, _) = _orchestrator(
      root.path,
      client: ScriptedChatClient([
        ModelCompletion.reply(_selectionReply(dates: ['2026-08-14'])),
        ModelCompletion.reply('火锅想起来了。'),
      ]),
    );
    // 没有任何索引文件：查找触发从原始 episode 重建。

    final result = await recall.runTurnRecall(
      userText: '上次说的火锅',
      recallActions: [MemoryRecallAction(query: '火锅')],
    );

    expect(result.bubbleText, '火锅想起来了。');
    expect(result.pendingContext, contains('2026-08-14'));
    expect(File('${root.path}/episodes/index.md').existsSync(), isTrue);
  });

  test('banned topics never reach the raw evidence or the context', () async {
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
    final (recall, pipeline) = _orchestrator(
      root.path,
      client: ScriptedChatClient([
        ModelCompletion.reply(_selectionReply(dates: ['2026-07-03'])),
        ModelCompletion.reply('不该被组织出来。'),
      ]),
      openLoopStore: OpenLoopStore(memoryDirectory: root.path),
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '医院检查的事',
      recallActions: [MemoryRecallAction(query: '医院检查')],
    );

    expect(result.bubbleText, isNull);
    expect(result.pendingContext, isNull);
    // 唯一月份的索引行关键词全部被禁：顶层目录直接为空，任何模型
    // 调用都不发生，被禁内容绝不递给模型。
    expect(result.diagnostics.join('\n'), contains('reason=blocked'));
    expect(result.diagnostics.join('\n'), contains('no-visible-months'));
    expect((recall.modelClient! as ScriptedChatClient).calls, isEmpty);
  });

  test(
    'a banned evidence quote is dropped even when the summary passes',
    () async {
      final root = await _seedEpisodes({
        '2026-07-03': [
          _entry('seed:1:0', '用户说周末有安排', evidence: '周末顺便去医院检查，然后吃火锅'),
        ],
      });
      addTearDown(() => root.delete(recursive: true));
      final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
      expect(
        (await MemoryBanExecution(openLoopStore: openLoopStore).execute(
          '医院检查',
          origin: 'open-loop',
        )).controlWritten,
        isTrue,
      );
      final (recall, pipeline) = _orchestrator(
        root.path,
        client: ScriptedChatClient([
          ModelCompletion.reply(_selectionReply(dates: ['2026-07-03'])),
          ModelCompletion.reply('想起来了。'),
        ]),
        openLoopStore: openLoopStore,
      );
      await _rebuildUnderLock(recall, pipeline);

      final result = await recall.runTurnRecall(
        userText: '我周末的安排',
        recallActions: [MemoryRecallAction(query: '周末安排')],
      );

      // 摘要未命中禁提得以保留，命中的原话摘录整段丢掉。
      expect(result.bubbleText, '想起来了。');
      expect(result.pendingContext, contains('用户说周末有安排'));
      expect(result.pendingContext, isNot(contains('医院检查')));
      expect(result.pendingContext, isNot(contains('原话摘录')));
      final composeInput =
          (recall.modelClient! as ScriptedChatClient).calls[1].last.content;
      expect(composeInput, contains('用户说周末有安排'));
      expect(composeInput, isNot(contains('医院检查')));
      expect(composeInput, isNot(contains('火锅')));
      expect(result.diagnostics.join('\n'), contains('evidence dropped'));
    },
  );

  test(
    'banned index keywords hide their lines from the selection catalog',
    () async {
      final root = await _seedEpisodes({
        '2026-07-03': [_entry('seed:1:0', '用户聊到青岛行程')],
        '2026-08-10': [_entry('seed:2:0', '用户去看了演唱会')],
      });
      addTearDown(() => root.delete(recursive: true));
      final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
      expect(
        (await MemoryBanExecution(openLoopStore: openLoopStore).execute(
          '青岛行程',
          origin: 'open-loop',
        )).controlWritten,
        isTrue,
      );
      final (recall, pipeline) = _orchestrator(
        root.path,
        client: ScriptedChatClient([
          ModelCompletion.reply(_selectionReply(dates: ['2026-07-03'])),
        ]),
        openLoopStore: openLoopStore,
      );
      await _rebuildUnderLock(recall, pipeline);

      final result = await recall.runTurnRecall(
        userText: '青岛的事',
        recallActions: [MemoryRecallAction(query: '青岛')],
      );

      // 关键词全部被禁的索引行整体隐藏：日期不可选，成员校验丢弃。
      final selectionInput =
          (recall.modelClient! as ScriptedChatClient).calls[0].last.content;
      expect(selectionInput, isNot(contains('2026-07-03')));
      expect(selectionInput, contains('2026-08-10'));
      expect(result.bubbleText, isNull);
      expect(result.pendingContext, isNull);
      final diagnostics = result.diagnostics.join('\n');
      expect(diagnostics, contains('index line hidden reason=blocked'));
      expect(diagnostics, contains('not-in-passed-index'));
    },
  );

  test('an index hit without readable evidence stays a miss', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-recall-ghost-');
    addTearDown(() => root.delete(recursive: true));
    // 手写一份指向不存在日文件的索引：索引关键词本身不是事实来源。
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
    final (recall, _) = _orchestrator(
      root.path,
      client: ScriptedChatClient([
        ModelCompletion.reply(_selectionReply(dates: ['2026-07-02'])),
        ModelCompletion.reply('不该被组织出来。'),
      ]),
    );

    final result = await recall.runTurnRecall(
      userText: '演讲的事',
      recallActions: [MemoryRecallAction(query: '演讲')],
    );

    expect(result.bubbleText, isNull);
    expect(result.pendingContext, isNull);
    expect(result.diagnostics.join('\n'), contains('reason=no-evidence'));
  });

  test(
    'a failed compose call keeps the compressed result for the next turn',
    () async {
      final root = await _seedEpisodes({
        '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (recall, pipeline) = _orchestrator(
        root.path,
        client: ScriptedChatClient([
          ModelCompletion.reply(_selectionReply(dates: ['2026-07-02'])),
          const ModelCompletion.failure(ModelFailureKind.network),
        ]),
      );
      await _rebuildUnderLock(recall, pipeline);

      final result = await recall.runTurnRecall(
        userText: '演讲的事',
        recallActions: [MemoryRecallAction(query: '演讲')],
      );

      expect(result.bubbleText, isNull);
      expect(result.pendingContext, contains('第一次演讲'));
    },
  );

  test(
    'the sentinel keeps the model from forcing an unrelated bubble',
    () async {
      final root = await _seedEpisodes({
        '2026-07-02': [_entry('seed:1:0', '用户准备第一次演讲')],
      });
      addTearDown(() => root.delete(recursive: true));
      final (recall, pipeline) = _orchestrator(
        root.path,
        client: ScriptedChatClient([
          ModelCompletion.reply(_selectionReply(dates: ['2026-07-02'])),
          ModelCompletion.reply('没有了'),
        ]),
      );
      await _rebuildUnderLock(recall, pipeline);

      final result = await recall.runTurnRecall(
        userText: '潜水的事',
        recallActions: [MemoryRecallAction(query: '潜水')],
      );

      expect(result.bubbleText, isNull);
      expect(result.pendingContext, isNotNull);
    },
  );

  test(
    'persona tree paths join the selection catalog, compose and context',
    () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山', evidence: '这周末打算去爬山')],
      });
      addTearDown(() => root.delete(recursive: true));
      _seedPersonaTree(root);
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          _selectionReply(
            dates: ['2026-08-10'],
            paths: ['PR-R001/PR-M002', 'PR-R003/PR-M006'],
          ),
        ),
        ModelCompletion.reply(
          '想起来了，你周末打算去爬山。\n'
          '<qiyu-actions>[{"action":"memory_recall","query":"爬山",'
          '"entries":["seed:1:0"]}]</qiyu-actions>',
        ),
      ]);
      final (recall, pipeline) = _orchestratorWithTree(root, client: client);
      await _rebuildUnderLock(recall, pipeline);

      final result = await recall.runTurnRecall(
        userText: '我上次说爬山的事',
        recallActions: [MemoryRecallAction(query: '爬山')],
      );

      // 选择调用收到紧凑画像索引：活跃根 + 中间理解 + 叶 ID，归档不在内。
      final selectionInput = client.calls[0].last.content;
      expect(selectionInput, contains('## 画像树路径索引'));
      expect(selectionInput, contains('- 根 [PR-R001] 用户喜欢晚上散步'));
      expect(selectionInput, contains('中间理解 [PR-M002] 重复模式｜用户周末常去河边'));
      expect(selectionInput, contains('PR-L001 2026-08-02 明确自述'));
      expect(selectionInput, isNot(contains('PR-R009')));
      // 没有叶证据的中间理解照常进索引（不带叶段）。
      expect(selectionInput, contains('中间理解 [PR-M006] 重复模式｜用户周末常看纪录片\n'));
      expect(selectionInput, isNot(contains('PR-M006] 重复模式｜用户周末常看纪录片（叶:')));
      // 组织调用收到展开的路径素材与带条目 ID 的记录。
      final composeInput = client.calls[1].last.content;
      expect(composeInput, contains('## 画像树路径'));
      expect(composeInput, contains('- 根 [PR-R001] 用户喜欢晚上散步'));
      expect(composeInput, contains('用户周末常去河边'));
      // 无叶路径只展开根与中间理解。
      expect(composeInput, contains('- 根 [PR-R003] 用户习惯周末看纪录片'));
      expect(composeInput, contains('- [seed:1:0] 用户说周末要去爬山'));
      expect(result.bubbleText, '想起来了，你周末打算去爬山。');
      // 下一轮临时上下文：条目级相关性只收回声明的条目，路径素材并入。
      expect(result.pendingContext, contains('画像树路径'));
      expect(result.pendingContext, contains('用户喜欢晚上散步'));
      expect(result.pendingContext, contains('用户习惯周末看纪录片'));
      expect(result.pendingContext, contains('2026-08-10'));
      expect(result.pendingContext, contains('用户说周末要去爬山'));
      expect(result.diagnostics, isEmpty);
    },
  );

  test('fabricated persona paths are dropped like fabricated dates', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    _seedPersonaTree(root);
    final client = ScriptedChatClient([
      ModelCompletion.reply(
        _selectionReply(
          dates: ['2026-08-10'],
          paths: ['PR-R001/PR-M002', 'VA-R001/VA-M001'],
        ),
      ),
      ModelCompletion.reply('想起来了。'),
    ]);
    final (recall, pipeline) = _orchestratorWithTree(root, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说爬山的事',
      recallActions: [MemoryRecallAction(query: '爬山')],
    );

    expect(result.bubbleText, '想起来了。');
    expect(
      result.diagnostics.join('\n'),
      contains('path=VA-R001/VA-M001 reason=not-in-passed-index'),
    );
    // 合法路径照常展开。
    expect(result.pendingContext, contains('用户喜欢晚上散步'));
  });

  test('selected leaf pointers expand with the path', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    _seedPersonaTree(root);
    final client = ScriptedChatClient([
      ModelCompletion.reply(
        _selectionReply(
          dates: ['2026-08-10'],
          paths: ['PR-R001/PR-M002/PR-L001,PR-L009'],
        ),
      ),
      ModelCompletion.reply('想起来了。'),
    ]);
    final (recall, pipeline) = _orchestratorWithTree(root, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说爬山的事',
      recallActions: [MemoryRecallAction(query: '爬山')],
    );

    final composeInput = client.calls[1].last.content;
    // 编造的叶 ID 丢弃，真实叶指针展开。
    expect(composeInput, contains('叶 [PR-L001] 2026-08-02 明确自述：用户周六去了河边散步'));
    expect(composeInput, isNot(contains('PR-L009')));
    expect(
      result.diagnostics.join('\n'),
      contains('leaf=PR-L009 reason=not-in-passed-index'),
    );
  });

  test('persona path budget drops the path that does not fit', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    _seedPersonaTree(root, bulky: true);
    final client = ScriptedChatClient([
      ModelCompletion.reply(
        _selectionReply(
          dates: ['2026-08-10'],
          paths: [
            'PR-R001/PR-M002/PR-L001,PR-L004',
            'PR-R002/PR-M003/PR-L002,PR-L005',
          ],
        ),
      ),
      ModelCompletion.reply('想起来了。'),
    ]);
    final (recall, pipeline) = _orchestratorWithTree(root, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说爬山的事',
      recallActions: [MemoryRecallAction(query: '爬山')],
    );

    final composeInput = client.calls[1].last.content;
    // 第一条路径在预算内照常展开，第二条整条放弃。
    expect(composeInput, contains('- 根 [PR-R001]'));
    expect(composeInput, isNot(contains('- 根 [PR-R002]')));
    expect(
      result.diagnostics.join('\n'),
      contains('recall persona path dropped root=PR-R002 reason=over-budget'),
    );
    expect(result.pendingContext, isNot(contains('PR-R002')));
  });

  test(
    'controlled persona nodes never reach the index or the context',
    () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
      });
      addTearDown(() => root.delete(recursive: true));
      _seedPersonaTree(root);
      final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
    expect(
      (await MemoryBanExecution(openLoopStore: openLoopStore).execute(
        '晚上散步',
        origin: 'open-loop',
      )).controlWritten,
      isTrue,
    );
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          _selectionReply(dates: ['2026-08-10'], paths: ['PR-R001/PR-M002']),
        ),
        ModelCompletion.reply('想起来了。'),
      ]);
      final (recall, pipeline) = _orchestratorWithTree(
        root,
        client: client,
        openLoopStore: openLoopStore,
      );
      await _rebuildUnderLock(recall, pipeline);

      final result = await recall.runTurnRecall(
        userText: '我上次说爬山的事',
        recallActions: [MemoryRecallAction(query: '爬山')],
      );

      // 禁提的根不进索引，路径选取随之丢弃；episode 命中照常留记录。
      final selectionInput = client.calls[0].last.content;
      expect(selectionInput, isNot(contains('PR-R001')));
      expect(selectionInput, isNot(contains('晚上散步')));
      final diagnostics = result.diagnostics.join('\n');
      expect(
        diagnostics,
        contains('recall persona node dropped reason=blocked root=PR-R001'),
      );
      expect(
        diagnostics,
        contains('path=PR-R001/PR-M002 reason=not-in-passed-index'),
      );
      expect(result.pendingContext, isNotNull);
      expect(result.pendingContext, isNot(contains('画像树路径')));
      expect(result.pendingContext, isNot(contains('晚上散步')));
    },
  );

  test(
    'a blocked middle claim drops the whole path from the catalog',
    () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
      });
      addTearDown(() => root.delete(recursive: true));
      _seedPersonaTree(root);
      final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
      expect(
        (await MemoryBanExecution(
          openLoopStore: openLoopStore,
        ).execute('常去河边', origin: 'open-loop')).controlWritten,
        isTrue,
      );
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          _selectionReply(dates: ['2026-08-10'], paths: ['PR-R001/PR-M002']),
        ),
        ModelCompletion.reply('想起来了。'),
      ]);
      final (recall, pipeline) = _orchestratorWithTree(
        root,
        client: client,
        openLoopStore: openLoopStore,
      );
      await _rebuildUnderLock(recall, pipeline);

      final result = await recall.runTurnRecall(
        userText: '我上次说爬山的事',
        recallActions: [MemoryRecallAction(query: '爬山')],
      );

      // 中间理解被禁：整条路径不可走，根也不进索引（没有可走中间理解）。
      final selectionInput = client.calls[0].last.content;
      expect(selectionInput, isNot(contains('PR-R001')));
      expect(selectionInput, isNot(contains('常去河边')));
      // 其他根不受影响。
      expect(selectionInput, contains('- 根 [PR-R002]'));
      final diagnostics = result.diagnostics.join('\n');
      expect(
        diagnostics,
        contains('recall persona node dropped reason=blocked middle=PR-M002'),
      );
      expect(
        diagnostics,
        contains('path=PR-R001/PR-M002 reason=not-in-passed-index'),
      );
      expect(result.pendingContext, isNot(contains('画像树路径')));
    },
  );

  test('a malformed compose block only costs the entry receipt', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    final client = ScriptedChatClient([
      ModelCompletion.reply(_selectionReply(dates: ['2026-08-10'])),
      // 隐藏块损坏：气泡照常交付，回执作废，退回受封顶的全量记录。
      ModelCompletion.reply('想起来了。\n<qiyu-actions>{not json</qiyu-actions>'),
    ]);
    final (recall, pipeline) = _orchestrator(root.path, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说爬山的事',
      recallActions: [MemoryRecallAction(query: '爬山')],
    );

    expect(result.bubbleText, '想起来了。');
    expect(
      result.diagnostics.join('\n'),
      contains('recall compose dropped [hidden_action_invalid_format]'),
    );
    expect(result.pendingContext, contains('用户说周末要去爬山'));
  });

  test('archived persona paths never enter the recall catalog', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    _seedPersonaTree(root, archived: true);
    final client = ScriptedChatClient([
      ModelCompletion.reply(
        _selectionReply(
          dates: ['2026-08-10'],
          paths: ['PR-R009/PR-M009', 'PR-R001/PR-M002'],
        ),
      ),
      ModelCompletion.reply('想起来了。'),
    ]);
    final (recall, pipeline) = _orchestratorWithTree(root, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说爬山的事',
      recallActions: [MemoryRecallAction(query: '爬山')],
    );

    final selectionInput = client.calls[0].last.content;
    expect(selectionInput, isNot(contains('PR-R009')));
    expect(selectionInput, isNot(contains('半夜')));
    expect(
      result.diagnostics.join('\n'),
      contains('path=PR-R009/PR-M009 reason=not-in-passed-index'),
    );
    expect(result.pendingContext, contains('用户喜欢晚上散步'));
  });

  test(
    'an unreadable branch skips paths but keeps the episode chain',
    () async {
      final root = await _seedEpisodes({
        '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
      });
      addTearDown(() => root.delete(recursive: true));
      File('${root.path}/persona-tree/preferences.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('这是用户写坏的内容。\n', encoding: utf8);
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          _selectionReply(dates: ['2026-08-10'], paths: ['PR-R001/PR-M002']),
        ),
        ModelCompletion.reply('想起来了。'),
      ]);
      final (recall, pipeline) = _orchestratorWithTree(root, client: client);
      await _rebuildUnderLock(recall, pipeline);

      final result = await recall.runTurnRecall(
        userText: '我上次说爬山的事',
        recallActions: [MemoryRecallAction(query: '爬山')],
      );

      // 路径是增强不是门槛：分支不可读时 episode 检索链路照常工作。
      expect(result.bubbleText, '想起来了。');
      expect(
        result.diagnostics.join('\n'),
        contains('recall persona skipped reason=preferences-unreadable'),
      );
      expect(
        result.diagnostics.join('\n'),
        contains('path=PR-R001/PR-M002 reason=not-in-passed-index'),
      );
    },
  );

  test('an entry receipt keeps only the entries the bubble used', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [
        _entry('seed:1:0', '用户说周末要去爬山'),
        _entry('seed:1:1', '用户顺便提到想买新登山包', evidence: '想买个新登山包'),
      ],
    });
    addTearDown(() => root.delete(recursive: true));
    final client = ScriptedChatClient([
      ModelCompletion.reply(_selectionReply(dates: ['2026-08-10'])),
      ModelCompletion.reply(
        '想起来了，你周末打算去爬山。\n'
        '<qiyu-actions>[{"action":"memory_recall","query":"爬山",'
        '"entries":["seed:1:0"]}]</qiyu-actions>',
      ),
    ]);
    final (recall, pipeline) = _orchestrator(root.path, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说爬山的事',
      recallActions: [MemoryRecallAction(query: '爬山')],
    );

    // 条目级相关性：只收组织气泡声明用到的条目，不再全量 dump。
    expect(result.pendingContext, contains('用户说周末要去爬山'));
    expect(result.pendingContext, isNot(contains('登山包')));
    expect(result.diagnostics, isEmpty);
  });

  test('a fabricated entry receipt falls back to the capped dump', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    final client = ScriptedChatClient([
      ModelCompletion.reply(_selectionReply(dates: ['2026-08-10'])),
      ModelCompletion.reply(
        '想起来了。\n'
        '<qiyu-actions>[{"action":"memory_recall","query":"爬山",'
        '"entries":["seed:9:9"]}]</qiyu-actions>',
      ),
    ]);
    final (recall, pipeline) = _orchestrator(root.path, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说爬山的事',
      recallActions: [MemoryRecallAction(query: '爬山')],
    );

    // 幻觉回执不构成相关性信号：丢弃并退回受总量预算封顶的全量记录。
    expect(
      result.diagnostics.join('\n'),
      contains(
        'recall entry dropped id=seed:9:9 reason=not-in-passed-evidence',
      ),
    );
    expect(result.pendingContext, contains('用户说周末要去爬山'));
  });

  test('the pending context stays bounded without an entry receipt', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [
        for (var index = 0; index < 30; index += 1)
          _entry(
            'seed:1:$index',
            '用户聊到第$index件事${'甲' * 100}',
            evidence: '原话${'乙' * 90}',
          ),
      ],
    });
    addTearDown(() => root.delete(recursive: true));
    final client = ScriptedChatClient([
      ModelCompletion.reply(_selectionReply(dates: ['2026-08-10'])),
      // 组织调用没给回执：退回全量，但总量预算必须封顶。
      ModelCompletion.reply('想起来了。'),
    ]);
    final (recall, pipeline) = _orchestrator(root.path, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '聊过的那些事',
      recallActions: [MemoryRecallAction(query: '聊天')],
    );

    expect(
      result.diagnostics.join('\n'),
      contains('recall pending context truncated reason=over-budget'),
    );
    expect(result.pendingContext, contains('第0件事'));
    expect(result.pendingContext, isNot(contains('第29件事')));
    expect(
      result.pendingContext!.runes.length,
      lessThan(recallPendingContextMaxRunes + 200),
    );
  });

  test('unreadable episode evidence still leaves the persona paths', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    _seedPersonaTree(root);
    final client = ScriptedChatClient([
      // 选中日期，但日文件不可读（索引指向不存在的文件）。
      ModelCompletion.reply(
        _selectionReply(
          dates: ['2026-08-10'],
          paths: ['PR-R001/PR-M002'],
        ),
      ),
      ModelCompletion.reply('可能因为你平时就喜欢晚上散步。'),
    ]);
    final (recall, pipeline) = _orchestratorWithTree(root, client: client);
    await _rebuildUnderLock(recall, pipeline);
    File('${root.path}/episodes/2026/08/2026-08-10.md').deleteSync();

    final result = await recall.runTurnRecall(
      userText: '我为什么会有这样的习惯',
      recallActions: [MemoryRecallAction(query: '习惯依据')],
    );

    // 日期命中但证据不可读：路径素材自含依据，仍可组句。
    expect(
      result.diagnostics.join('\n'),
      contains('recall episode evidence skipped reason=no-evidence'),
    );
    expect(result.bubbleText, '可能因为你平时就喜欢晚上散步。');
    expect(result.pendingContext, contains('画像树路径'));
    expect(result.pendingContext, contains('用户喜欢晚上散步'));
    expect(result.pendingContext, isNot(contains('爬山')));
  });

  test('a persona-basis question recalls paths without any date', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    _seedPersonaTree(root);
    final client = ScriptedChatClient([
      // 纯画像依据：只选路径，不选月份和日期。
      ModelCompletion.reply(_selectionReply(paths: ['PR-R001/PR-M002'])),
      ModelCompletion.reply('可能因为你平时就喜欢晚上散步。'),
    ]);
    final (recall, pipeline) = _orchestratorWithTree(root, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '你为什么觉得我是这样的人',
      recallActions: [MemoryRecallAction(query: '画像依据')],
    );

    // 选择提示词教了这种输出合法。
    expect(client.calls[0].last.content, contains('可以只选 paths、不选月份和日期'));
    // 组织调用只带画像路径素材，不递空的记录节。
    final composeInput = client.calls[1].last.content;
    expect(composeInput, contains('## 画像树路径'));
    expect(composeInput, isNot(contains('## 查到的记录')));
    expect(result.bubbleText, '可能因为你平时就喜欢晚上散步。');
    // 下一轮临时上下文只带路径素材，没有 episode 记录。
    expect(result.pendingContext, contains('画像树路径'));
    expect(result.pendingContext, contains('用户喜欢晚上散步'));
    expect(result.pendingContext, isNot(contains('2026-08-10')));
    expect(result.pendingContext, isNot(contains('爬山')));
    expect(result.diagnostics, isEmpty);
  });

  test('a failed compose on a paths-only recall keeps the paths', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    _seedPersonaTree(root);
    final client = ScriptedChatClient([
      ModelCompletion.reply(_selectionReply(paths: ['PR-R001/PR-M002'])),
      const ModelCompletion.failure(ModelFailureKind.network),
    ]);
    final (recall, pipeline) = _orchestratorWithTree(root, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '你为什么觉得我是这样的人',
      recallActions: [MemoryRecallAction(query: '画像依据')],
    );

    // 组织调用失败：气泡没有，路径素材仍以降级形态留给下一轮。
    expect(result.bubbleText, isNull);
    expect(result.pendingContext, contains('画像树路径'));
    expect(result.pendingContext, contains('用户喜欢晚上散步'));
  });

  test('a blocked leaf never reaches the index or the context', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [_entry('seed:1:0', '用户说周末要去爬山')],
    });
    addTearDown(() => root.delete(recursive: true));
    _seedPersonaTree(root);
    final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
    expect(
      (await MemoryBanExecution(openLoopStore: openLoopStore).execute(
        '走了一圈',
        origin: 'open-loop',
      )).controlWritten,
      isTrue,
    );
    final client = ScriptedChatClient([
      ModelCompletion.reply(
        _selectionReply(
          dates: ['2026-08-10'],
          paths: ['PR-R001/PR-M002/PR-L004'],
        ),
      ),
      ModelCompletion.reply('想起来了。'),
    ]);
    final (recall, pipeline) = _orchestratorWithTree(
      root,
      client: client,
      openLoopStore: openLoopStore,
    );
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说爬山的事',
      recallActions: [MemoryRecallAction(query: '爬山')],
    );

    // 禁提的叶不进索引，其余叶照常。
    final selectionInput = client.calls[0].last.content;
    expect(selectionInput, contains('PR-L001 2026-08-02 明确自述'));
    expect(selectionInput, isNot(contains('PR-L004')));
    // 选中被禁提的叶：整条路径的成员校验失败按 not-in-passed-index 丢叶，
    // 路径本身仍展开（只剩根与中间理解）。
    expect(
      result.diagnostics.join('\n'),
      contains('leaf=PR-L004 reason=not-in-passed-index'),
    );
    final composeInput = client.calls[1].last.content;
    expect(composeInput, contains('- 根 [PR-R001] 用户喜欢晚上散步'));
    expect(composeInput, isNot(contains('叶 [PR-L004]')));
    expect(result.pendingContext, isNot(contains('走了一圈')));
  });

  test('multiple entry receipts keep only the first action', () async {
    final root = await _seedEpisodes({
      '2026-08-10': [
        _entry('seed:1:0', '用户说周末要去爬山'),
        _entry('seed:1:1', '用户顺便提到想买新登山包'),
      ],
    });
    addTearDown(() => root.delete(recursive: true));
    final client = ScriptedChatClient([
      ModelCompletion.reply(_selectionReply(dates: ['2026-08-10'])),
      // 同一隐藏块里两条 memory_recall 回执：只认第一条。
      ModelCompletion.reply(
        '想起来了，你周末打算去爬山。\n'
        '<qiyu-actions>[{"action":"memory_recall","query":"爬山",'
        '"entries":["seed:1:0"]},{"action":"memory_recall","query":"爬山",'
        '"entries":["seed:1:1"]}]</qiyu-actions>',
      ),
    ]);
    final (recall, pipeline) = _orchestrator(root.path, client: client);
    await _rebuildUnderLock(recall, pipeline);

    final result = await recall.runTurnRecall(
      userText: '我上次说爬山的事',
      recallActions: [MemoryRecallAction(query: '爬山')],
    );

    expect(result.pendingContext, contains('用户说周末要去爬山'));
    expect(result.pendingContext, isNot(contains('登山包')));
  });

  test('pending context is one-shot per session and latest wins', () {
    final root = Directory.systemTemp.createTempSync('qiyu-recall-pending-');
    final recall = RecallOrchestrator(
      memoryDirectory: root.path,
      episodePipeline: EpisodeMemoryPipeline(memoryDirectory: root.path),
    );

    recall.storePendingContext('session-1', '旧结果');
    recall.storePendingContext('session-1', '新结果');
    expect(recall.consumePendingContext('session-1'), '新结果');
    expect(recall.consumePendingContext('session-1'), isNull);
    expect(recall.consumePendingContext('session-2'), isNull);

    // restore 不覆盖已有命中。
    recall.storePendingContext('session-1', '命中');
    recall.restorePendingContext('session-1', '放回');
    expect(recall.consumePendingContext('session-1'), '命中');
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

(RecallOrchestrator, EpisodeMemoryPipeline) _orchestrator(
  String memoryDirectory, {
  ProviderChatClient? client,
  OpenLoopStore? openLoopStore,
}) {
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: memoryDirectory,
    clock: () => DateTime(2026, 8, 16, 22),
  );
  final orchestrator = RecallOrchestrator(
    memoryDirectory: memoryDirectory,
    episodePipeline: pipeline,
    modelClient: client,
    openLoopStore: openLoopStore,
  );
  return (orchestrator, pipeline);
}

/// 注入了画像树只读来源的编排器（路径检索用例）：树与 episode 管线
/// 共用同一时钟，供 PersonaTreeStore 的提交链读取。
(RecallOrchestrator, EpisodeMemoryPipeline) _orchestratorWithTree(
  Directory root, {
  ProviderChatClient? client,
  OpenLoopStore? openLoopStore,
}) {
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: root.path,
    clock: () => DateTime(2026, 8, 16, 22),
  );
  final orchestrator = RecallOrchestrator(
    memoryDirectory: root.path,
    episodePipeline: pipeline,
    modelClient: client,
    openLoopStore: openLoopStore,
    personaTree: PersonaTreeStore(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
    ),
  );
  return (orchestrator, pipeline);
}

/// 播种一份可解析的画像树：偏好分支两个活跃根（含根下中间理解与叶），
/// 归档分支一条已失效路径（[archived] 时写入）。[bulky] 用超长主张与
/// 叶摘要撑爆路径预算，供预算用例断言第二条路径被整条放弃。
void _seedPersonaTree(
  Directory root, {
  bool archived = false,
  bool bulky = false,
}) {
  String claim(String text) => bulky ? '${'长' * 100}$text' : text;
  final file = File('${root.path}/persona-tree/preferences.md')
    ..createSync(recursive: true);
  file.writeAsStringSync(
    '# 偏好习惯\n\n'
    '## [PR-R001] ${claim('用户喜欢晚上散步')}\n\n'
    '### [PR-M002] 重复模式｜${claim('用户周末常去河边')}\n'
    '- 形成: 2026-08-01 · 复核: 2026-08-10\n'
    '- [PR-L001] 2026-08-02 | 明确自述 | support | '
    '${claim('用户周六去了河边散步')} | episodes/2026/08/2026-08-02.md [seed:1:0]\n'
    '- [PR-L004] 2026-08-09 | 行为观察 | support | '
    '${claim('用户周末又在河边走了一圈')} | episodes/2026/08/2026-08-09.md [seed:2:0]\n\n'
    '## [PR-R002] ${claim('用户习惯早起喝手冲咖啡')}\n\n'
    '### [PR-M003] 重复模式｜${claim('用户工作日清晨冲咖啡')}\n'
    '- 形成: 2026-08-03 · 复核: 2026-08-11\n'
    '- [PR-L002] 2026-08-04 | 明确自述 | support | '
    '${claim('用户说他每天早上都手冲')} | episodes/2026/08/2026-08-04.md [seed:3:0]\n'
    '- [PR-L005] 2026-08-12 | 行为观察 | support | '
    '${claim('用户清晨又在冲咖啡')} | episodes/2026/08/2026-08-12.md [seed:4:0]\n\n'
    '## [PR-R003] ${claim('用户习惯周末看纪录片')}\n\n'
    '### [PR-M006] 重复模式｜${claim('用户周末常看纪录片')}\n'
    '- 形成: 2026-08-05 · 复核: 2026-08-13\n',
    encoding: utf8,
  );
  if (!archived) {
    return;
  }
  File('${root.path}/persona-tree/archive/preferences.md')
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '# 偏好习惯（归档）\n\n'
      '## [PR-R009] 用户以前喜欢熬夜\n'
      '- 失效: 2026-08-01 · 原因: 明确纠正 · 关联: PR-M009\n\n'
      '### [PR-M009] 重复模式｜用户以前经常半夜睡\n'
      '- 形成: 2026-07-01 · 复核: 2026-07-20\n'
      '- [PR-L090] 2026-07-02 | 明确自述 | support | 用户半夜还在写代码 | '
      'episodes/2026/07/2026-07-02.md [seed:9:0]\n',
      encoding: utf8,
    );
}

/// 重建契约要求调用方持有 episode 日文件写锁，测试也照做。
Future<void> _rebuildUnderLock(
  RecallOrchestrator recall,
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

/// 模拟选择调用的模型输出：只带 memory_recall 选择块。
String _selectionReply({
  List<String> months = const [],
  List<String> dates = const [],
  List<String> paths = const [],
}) {
  final monthsJson = months.map((month) => '"$month"').join(',');
  final datesJson = dates.map((date) => '"$date"').join(',');
  final pathsJson = paths.map((path) => '"$path"').join(',');
  return '<qiyu-actions>[{"action":"memory_recall","query":"测试查找",'
      '"months":[$monthsJson],"dates":[$datesJson],"paths":[$pathsJson]}]'
      '</qiyu-actions>';
}
