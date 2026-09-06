import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';

void main() {
  group('parseDayUnderstanding whitelist validation', () {
    test('a fully valid payload parses into every field', () {
      final understanding = parseDayUnderstanding(
        jsonEncode({
          'summary': '用户完成了第一次演讲',
          'mood': '有点累但放松',
          'loop_candidates': [
            {'title': '演讲复盘', 'due': '2026-08-20 晚上', 'proactive': 'yes', 'note': '用户想总结经验'},
          ],
          'loop_closures': [
            {'title': '搬家打包', 'result': '已经搬完了'},
          ],
          'relationship_signals': [
            {'signal': 'temperature', 'summary': '用户近期语气更放松'},
          ],
          'index_keywords': ['演讲', '深夜聊天', '演讲'],
          'persona_hints': [
            {'branch': 'preferences', 'nature': 'self_report', 'summary': '用户喜欢睡前复盘'},
          ],
        }),
        bannedTitles: const {},
        diagnosticsSink: (_) {},
      );

      expect(understanding, isNotNull);
      expect(understanding!.summary, '用户完成了第一次演讲');
      expect(understanding.mood, '有点累但放松');
      expect(understanding.loopCandidates, hasLength(1));
      expect(understanding.loopCandidates.single.title, '演讲复盘');
      expect(understanding.loopCandidates.single.proactive, 'yes');
      expect(understanding.loopClosures.single.title, '搬家打包');
      expect(understanding.relationshipSignals.single.signal, 'temperature');
      // 重复关键词去重。
      expect(understanding.indexKeywords, ['演讲', '深夜聊天']);
      expect(understanding.personaHints.single.branch, 'preferences');
      expect(understanding.isEmpty, isFalse);
    });

    test('code fences and surrounding text are tolerated', () {
      final understanding = parseDayUnderstanding(
        '好的，结果如下：\n```json\n{"summary": "用户整理了房间"}\n```\n以上。',
        bannedTitles: const {},
        diagnosticsSink: (_) {},
      );
      expect(understanding!.summary, '用户整理了房间');
    });

    test('invalid fields are dropped per field, valid ones kept', () {
      final diagnostics = <String>[];
      final understanding = parseDayUnderstanding(
        jsonEncode({
          'summary': '用户完成了演讲',
          'loop_candidates': [
            {'note': '没有标题的候选'},
            {'title': '有效候选'},
          ],
          'relationship_signals': [
            {'signal': 'not_a_signal', 'summary': '非法信号'},
          ],
          'persona_hints': [
            {'branch': 'identity', 'nature': 'behavior', 'summary': '身份不接受行为推断'},
            {'branch': 'not_a_branch', 'nature': 'self_report', 'summary': '非法分支'},
          ],
        }),
        bannedTitles: const {},
        diagnosticsSink: diagnostics.add,
      );

      expect(understanding!.summary, '用户完成了演讲');
      expect(understanding.loopCandidates, hasLength(1));
      expect(understanding.loopCandidates.single.title, '有效候选');
      expect(understanding.relationshipSignals, isEmpty);
      expect(understanding.personaHints, isEmpty);
      expect(diagnostics.join('\n'), contains('signal not in whitelist'));
      expect(diagnostics.join('\n'), contains('identity hint must be self_report'));
    });

    test('banned titles never enter any field', () {
      final understanding = parseDayUnderstanding(
        jsonEncode({
          'summary': '用户聊了换工作的打算',
          'mood': '为换工作焦虑',
          'loop_candidates': [
            {'title': '换工作面试'},
            {'title': '演讲复盘', 'due': '2026-09-01 聊换工作进展', 'note': '围绕换工作'},
            {'title': '搬家计划', 'due': '2026-09-05 晚上'},
          ],
          'index_keywords': ['换工作', '演讲'],
        }),
        bannedTitles: {normalizeLoopTitle('换工作')},
        diagnosticsSink: (_) {},
      );

      expect(understanding!.summary, isNull);
      expect(understanding.mood, isNull);
      // due/note 也过禁提：违规子字段置空，合法候选保留。
      expect(understanding.loopCandidates, hasLength(2));
      expect(understanding.loopCandidates[0].title, '演讲复盘');
      expect(understanding.loopCandidates[0].due, isNull);
      expect(understanding.loopCandidates[0].note, isNull);
      expect(understanding.loopCandidates[1].title, '搬家计划');
      expect(understanding.loopCandidates[1].due, '2026-09-05 晚上');
      expect(understanding.indexKeywords, ['演讲']);
    });

    test('non-JSON output returns null and empty object stays empty', () {
      expect(
        parseDayUnderstanding('今天没什么特别的', bannedTitles: const {}),
        isNull,
      );
      final empty = parseDayUnderstanding('{}', bannedTitles: const {});
      expect(empty, isNotNull);
      expect(empty!.isEmpty, isTrue);
    });

    test('persisted understanding round-trips through JSON', () {
      final entries = [
        EpisodeEntry(
          id: 's1:r1:0',
          sessionId: 'seed',
          requestId: 'req',
          summary: '条目',
          at: DateTime(2026, 8, 14, 21).toUtc(),
        ),
      ];
      final original = DayUnderstanding(
        summary: '用户完成了演讲',
        mood: '放松',
        loopCandidates: const [
          (title: '演讲复盘', due: null, proactive: 'once', note: null),
        ],
        loopClosures: const [(title: '搬家打包', result: '已完成')],
        relationshipSignals: const [
          (signal: 'deep_talk', summary: '用户聊到家庭'),
        ],
        indexKeywords: const ['演讲'],
        personaHints: const [
          (branch: 'values', nature: 'self_report', summary: '用户重视诚实'),
        ],
      ).withCoverage(entries);

      final restored = DayUnderstanding.fromJson(original.toJson());
      expect(restored.summary, original.summary);
      expect(restored.mood, original.mood);
      expect(restored.loopCandidates.single.title, '演讲复盘');
      expect(restored.loopClosures.single.result, '已完成');
      expect(restored.relationshipSignals.single.signal, 'deep_talk');
      expect(restored.indexKeywords, ['演讲']);
      expect(restored.personaHints.single.branch, 'values');
      expect(restored.entryCount, 1);
      expect(restored.lastEntryId, 's1:r1:0');
      expect(restored.covers(entries), isTrue);
      expect(restored.covers(const []), isFalse);
    });

    test('pending request ids survive redaction and get a plain copy list', () async {
      final client = _FakeUnderstandingClient(reply: '{}');
      // requestId 中段恰为「15-19 位数字夹分隔符」的银行卡形状，
      // 整包脱敏会把它改成 [已脱敏]，模型便永远无法复述完整 id。
      const unluckyId = 'chat-c5844040-4144-4382-8d54-5c0f9449b8db';
      await fetchDayUnderstanding(
        client: client,
        date: '2026-08-20',
        entries: const [],
        openLoops: '# open-loops\n\n- [o1] 搬家打包\n',
        relationship: '# relationship\n\nstage: 初识\n',
        dailyState: '# daily-state\n\ndate: 2026-08-20\n'
            'token: sk-abcdefghijklmnop1234\n',
        bannedTitles: const {},
        sessions: [
          RawSession(
            id: 'MrD41LDCG6g7vZUxxxjl1J8i',
            date: '2026-08-20',
            segment: 1,
            createdAt: DateTime.utc(2026, 8, 20, 9),
            updatedAt: DateTime.utc(2026, 8, 20, 16),
            turns: [
              RawSessionTurn.user(
                requestId: unluckyId,
                text: '还可以吧，只是暑假过太久了，明天要早起',
                at: DateTime.utc(2026, 8, 20, 15, 28),
              ),
            ],
          ),
        ],
        pendingRequestIds: const {unluckyId},
        diagnosticsSink: (_) {},
      );
      final user = client.lastMessages!.last.content;
      // requestId 与 session id 必须原样出现，模型才有机会覆盖它。
      expect(user, contains(unluckyId));
      expect(user, contains('MrD41LDCG6g7vZUxxxjl1J8i'));
      // 记忆文件段（状态包等）仍要脱敏。
      expect(user, isNot(contains('sk-abcdefghijklmnop1234')));
      // 待补 id 另附纯清单，供模型原样复制，降低复述遗漏。
      expect(user, contains('## 待补 requestId 清单'));
      expect(
        RegExp('^- $unluckyId\$', multiLine: true).hasMatch(user),
        isTrue,
      );
    });

    test('the understanding prompt states the appellation wording rule', () async {
      final client = _FakeUnderstandingClient(reply: '{}');
      // 记忆表述惯例（称呼定稿）：有称呼用称呼、无称呼用「用户」。
      await fetchDayUnderstanding(
        client: client,
        date: '2026-08-20',
        entries: const [],
        openLoops: '# open-loops\n',
        relationship: '# relationship\n',
        dailyState: '# daily-state\n',
        bannedTitles: const {},
        appellation: '老王',
        diagnosticsSink: (_) {},
      );
      final system = client.lastMessages!.first.content;
      expect(system, contains('一律用称呼「老王」'));
      expect(system, contains('不要写「用户」'));
      expect(system, contains('也不要替用户起昵称'));

      await fetchDayUnderstanding(
        client: client,
        date: '2026-08-20',
        entries: const [],
        openLoops: '# open-loops\n',
        relationship: '# relationship\n',
        dailyState: '# daily-state\n',
        bannedTitles: const {},
        diagnosticsSink: (_) {},
      );
      final fallback = client.lastMessages!.first.content;
      expect(fallback, contains('一律写「用户」'));
      expect(fallback, contains('不要替用户起昵称'));
    });
  });

  group('end-of-day finalization with a model understanding call', () {
    test('model materials flow through every existing gate', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户完成了第一次演讲'),
        _entry('s1:r1:1', '用户聊到很晚才睡'),
      ]);
      File('${root.path}/open-loops.md').writeAsStringSync(
        '# open-loops\n\n- [o1] 搬家打包\n  proactive: once\n  status: active\n',
        encoding: utf8,
      );
      final client = _FakeUnderstandingClient(
        reply: jsonEncode({
          'summary': '用户完成第一次演讲，夜里聊了很久',
          'mood': '有点累但很放松',
          'loop_candidates': [
            {'title': '演讲复盘', 'note': '用户想总结这次经验'},
          ],
          'loop_closures': [
            {'title': '搬家打包', 'result': '已经搬完了'},
          ],
          'relationship_signals': [
            {'signal': 'temperature', 'summary': '用户近期语气更放松'},
          ],
          'index_keywords': ['演讲', '深夜聊天'],
          'persona_hints': [
            {'branch': 'preferences', 'nature': 'self_report', 'summary': '用户喜欢睡前复盘'},
          ],
        }),
      );
      final service = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: clock,
        modelClient: client,
        diagnosticsSink: (_) {},
      );

      final outcome = await service.finalizeDay('2026-08-14');

      expect(outcome.status, FinalizationStatus.finalized);
      expect(outcome.usedModel, isTrue);
      expect(client.calls, 1);

      // 1. 当天摘要来自模型并持久化理解元数据。
      final day = await pipeline.readDay('2026-08-14');
      expect(day.summary, '用户完成第一次演讲，夜里聊了很久');
      expect(day.understanding, isNotNull);

      // 2. 模型候选被提升，闭环判断归档既有事项。
      final loops = File('${root.path}/open-loops.md').readAsStringSync();
      expect(loops, contains('演讲复盘'));
      expect(loops, isNot(contains('搬家打包')));
      final archive = File(
        '${root.path}/open-loops.archive.md',
      ).readAsStringSync();
      expect(archive, contains('搬家打包 | 闭环: 2026-08-14 | 已经搬完了'));

      // 3. 关系信号投影近期变化；阶段棘轮不受模型判断影响。
      final relationship = File(
        '${root.path}/relationship.md',
      ).readAsStringSync();
      expect(relationship, contains('stage: 初识'));
      expect(relationship, contains('用户近期语气更放松'));

      // 4. 情绪余波进「近日气氛」，模型未配置时该节不存在（见降级用例）。
      final dailyState = File('${root.path}/daily-state.md').readAsStringSync();
      expect(dailyState, contains('## 近日气氛'));
      expect(dailyState, contains('有点累但很放松'));

      // 5. 索引使用模型主题词，不再机械截断。
      final monthIndex = File(
        '${root.path}/episodes/2026/08/index.md',
      ).readAsStringSync();
      expect(monthIndex, contains('- 2026-08-14 | 演讲, 深夜聊天 |'));

      // 6. 画像候选提示建叶。
      final preferences = File(
        '${root.path}/persona-tree/preferences.md',
      ).readAsStringSync();
      expect(preferences, contains('用户喜欢睡前复盘'));
    });

    test('a model deep_talk signal never promotes the stage ratchet', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户聊了一件心事'),
      ]);
      final client = _FakeUnderstandingClient(
        reply: jsonEncode({
          'relationship_signals': [
            {'signal': 'deep_talk', 'summary': '用户聊到很深的家庭话题'},
          ],
        }),
      );
      final service = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: clock,
        modelClient: client,
        diagnosticsSink: (_) {},
      );

      await service.finalizeDay('2026-08-14');

      // 模型深谈信号只是温度投影；阶段证据只认真实 episodes 互动。
      final relationship = File(
        '${root.path}/relationship.md',
      ).readAsStringSync();
      expect(relationship, contains('stage: 初识'));
      expect(relationship, contains('用户聊到很深的家庭话题'));
    });

    test('Provider failure falls back to the deterministic path', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户完成了第一次演讲'),
      ]);
      final client = _FakeUnderstandingClient(
        failure: ModelFailureKind.timeout,
      );
      final service = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: clock,
        modelClient: client,
        diagnosticsSink: (_) {},
      );

      final outcome = await service.finalizeDay('2026-08-14');

      expect(outcome.status, FinalizationStatus.finalized);
      expect(outcome.usedModel, isTrue);
      final day = await pipeline.readDay('2026-08-14');
      expect(day.summary, '用户完成了第一次演讲');
      expect(day.understanding, isNull);
      final dailyState = File('${root.path}/daily-state.md').readAsStringSync();
      expect(dailyState, isNot(contains('近日气氛')));
      // 索引回退机械截断。
      final monthIndex = File(
        '${root.path}/episodes/2026/08/index.md',
      ).readAsStringSync();
      expect(monthIndex, contains('- 2026-08-14 | 用户完成了第一次演讲 |'));
    });

    test('an unconfigured Provider or unusable output stays deterministic', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户整理了房间'),
      ]);
      final notConfigured = _FakeUnderstandingClient(configured: false);
      final service = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: clock,
        modelClient: notConfigured,
        diagnosticsSink: (_) {},
      );
      var outcome = await service.finalizeDay('2026-08-14');
      expect(outcome.status, FinalizationStatus.finalized);
      expect(notConfigured.calls, 1);
      expect((await pipeline.readDay('2026-08-14')).summary, '用户整理了房间');

      // 输出全废（空对象）同样降级。
      await _seedDay(pipeline, '2026-08-15', [
        _entry('s2:r2:0', '用户去跑了步'),
      ]);
      final emptyOutput = _FakeUnderstandingClient(reply: '{}');
      final fallbackService = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: () => DateTime(2026, 8, 15, 23, 30),
        modelClient: emptyOutput,
        diagnosticsSink: (_) {},
      );
      outcome = await fallbackService.finalizeDay('2026-08-15');
      expect(outcome.status, FinalizationStatus.finalized);
      expect((await pipeline.readDay('2026-08-15')).summary, '用户去跑了步');
      expect((await pipeline.readDay('2026-08-15')).understanding, isNull);
    });

    test('a failed write keeps the understanding for the retry', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户完成了演讲'),
      ]);
      final client = _FakeUnderstandingClient(
        reply: jsonEncode({'summary': '模型概括：用户完成了演讲'}),
      );
      DailyFinalizationService buildService(AtomicTextWriter writer) =>
          DailyFinalizationService(
            memoryDirectory: root.path,
            episodePipeline: pipeline,
            clock: clock,
            modelClient: client,
            atomicWriter: writer,
            diagnosticsSink: (_) {},
          );
      var dailyStateFailures = 1;
      final failing = buildService(
        FailingAtomicTextWriter(
          shouldFail: (path) {
            if (dailyStateFailures > 0 && path.endsWith('daily-state.md')) {
              dailyStateFailures -= 1;
              return true;
            }
            return false;
          },
          exception: const FileSystemException(
            'mock interrupted daily-state write',
          ),
        ),
      );

      // 写入失败抛异常且 finalized 保持 false（下次触发幂等重试）。
      await expectLater(
        failing.finalizeDay('2026-08-14'),
        throwsA(isA<MemoryRepositoryException>()),
      );
      expect((await pipeline.readDay('2026-08-14')).finalized, isFalse);
      expect(client.calls, 1);

      final retry = await buildService(const IoAtomicTextWriter())
          .finalizeDay('2026-08-14');
      expect(retry.status, FinalizationStatus.finalized);
      // 重试复用已持久化理解，不重复调用模型。
      expect(client.calls, 1);
      expect(retry.usedModel, isFalse);
      expect(
        (await pipeline.readDay('2026-08-14')).summary,
        '模型概括：用户完成了演讲',
      );
    });

    test('new entries after finalization invalidate the stored understanding', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户完成了演讲'),
      ]);
      final client = _FakeUnderstandingClient(
        reply: jsonEncode({'summary': '第一次概括'}),
      );
      final service = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: clock,
        modelClient: client,
        diagnosticsSink: (_) {},
      );
      await service.finalizeDay('2026-08-14');
      expect(client.calls, 1);

      // 归档后当天又来新条目：finalized 复位，理解覆盖范围失效。
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户完成了演讲'),
        _entry('s1:r2:0', '用户又聊了宵夜'),
      ]);
      await service.finalizeDay('2026-08-14');
      expect(client.calls, 2);
    });

    test('catch-up spends the model budget on the most recent days only', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 6, 9);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      for (var day = 1; day <= 5; day += 1) {
        final date = '2026-08-0$day';
        await _seedDay(pipeline, date, [
          _entry('s$day:r$day:0', '用户第 $day 天的记录'),
        ]);
      }
      final client = _FakeUnderstandingClient(
        reply: jsonEncode({'summary': '模型概括'}),
      );
      final service = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: clock,
        modelClient: client,
        diagnosticsSink: (_) {},
      );

      final report = await service.catchUpUnfinalized(before: '2026-08-06');

      expect(
        report.outcomes.map((outcome) => outcome.date),
        ['2026-08-01', '2026-08-02', '2026-08-03', '2026-08-04', '2026-08-05'],
      );
      expect(report.outcomes.every((o) => o.status == FinalizationStatus.finalized), isTrue);
      // 预算 3 天：最近三天走模型，更早的确定性归档。
      expect(client.calls, catchUpModelDayBudget);
      expect((await pipeline.readDay('2026-08-05')).understanding, isNotNull);
      expect((await pipeline.readDay('2026-08-04')).understanding, isNotNull);
      expect((await pipeline.readDay('2026-08-03')).understanding, isNotNull);
      expect((await pipeline.readDay('2026-08-02')).understanding, isNull);
      expect((await pipeline.readDay('2026-08-01')).understanding, isNull);
      expect((await pipeline.readDay('2026-08-02')).summary, '用户第 2 天的记录');
      // 升序写入：补扫结束后状态包以最新日为窗口终点，不停留在最旧日。
      final dailyState = File('${root.path}/daily-state.md').readAsStringSync();
      expect(dailyState, contains('date: 2026-08-05'));
      expect(dailyState, contains('用户第 5 天的记录'));
    });

    test('a day without valid content never calls the model', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry(
          's1:r1:0',
          'Open-loop 状态: 某件事 → closed',
          kind: episodeKindOpenLoopEvent,
        ),
      ]);
      final client = _FakeUnderstandingClient(reply: '{}');
      final service = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: clock,
        modelClient: client,
        diagnosticsSink: (_) {},
      );

      final outcome = await service.finalizeDay('2026-08-14');

      expect(outcome.status, FinalizationStatus.finalizedEmpty);
      expect(client.calls, 0);
      expect(File('${root.path}/daily-state.md').existsSync(), isFalse);
    });

    test('the understanding prompt carries the redacted full package', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户说 api_key: sk-abcdefghijklmnop1234 要保存好'),
        _entry(
          's1:r1:1',
          '禁提: 秘密计划',
          kind: episodeKindOpenLoopEvent,
        ),
        _entry(
          's1:r1:2',
          '用户愿意聊更深的话题',
          kind: episodeKindRelationshipSignal,
          signal: 'deep_talk',
        ),
      ]);
      File('${root.path}/open-loops.md').writeAsStringSync(
        '# open-loops\n\n- [o1] 搬家打包\n  proactive: once\n  status: active\n',
        encoding: utf8,
      );
      File('${root.path}/relationship.md').writeAsStringSync(
        '# relationship\n\nstage: 初识\nsince: 2026-08-14\n阶段描述: 初识阶段。\n',
        encoding: utf8,
      );
      final client = _FakeUnderstandingClient(reply: '{}');
      final service = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: clock,
        modelClient: client,
        diagnosticsSink: (_) {},
      );

      await service.finalizeDay('2026-08-14');

      final messages = client.lastMessages!;
      expect(messages.first.role, ModelMessageRole.system);
      final user = messages.last.content;
      expect(user, contains('## 当天对话整理记录'));
      expect(user, contains('## 未闭环事项'));
      expect(user, contains('搬家打包'));
      expect(user, contains('## 关系状态'));
      expect(user, contains('## 现状态包'));
      expect(user, contains('[已脱敏]'));
      expect(user, isNot(contains('sk-abcdefghijklmnop1234')));
      // 簿记条目含禁提标题，绝不发送给 Provider；关系信号作为上下文保留。
      expect(user, isNot(contains('秘密计划')));
      expect(user, contains('用户愿意聊更深的话题'));
    });

    test('a model relationship signal survives the next day rebuild', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: () => DateTime(2026, 8, 14, 23, 30),
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户聊了一件心事'),
      ]);
      final client = _FakeUnderstandingClient(
        reply: jsonEncode({
          'relationship_signals': [
            {'signal': 'temperature', 'summary': '用户近期语气更放松'},
          ],
        }),
      );
      final service = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: () => DateTime(2026, 8, 14, 23, 30),
        modelClient: client,
        diagnosticsSink: (_) {},
      );
      await service.finalizeDay('2026-08-14');

      // 次日确定性归档（无模型参与）整体重建 relationship.md：
      // 前一天的模型信号随日文件元数据持久化，投影不被抹掉。
      await _seedDay(pipeline, '2026-08-15', [
        _entry('s2:r2:0', '用户随口聊了天气'),
      ]);
      final nextService = DailyFinalizationService(
        memoryDirectory: root.path,
        episodePipeline: pipeline,
        clock: () => DateTime(2026, 8, 15, 23, 30),
        diagnosticsSink: (_) {},
      );
      await nextService.finalizeDay('2026-08-15');

      final relationship = File(
        '${root.path}/relationship.md',
      ).readAsStringSync();
      expect(relationship, contains('用户近期语气更放松'));
    });

    test('a ban added before retry is enforced on the reuse path', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '用户完成了演讲'),
      ]);
      final client = _FakeUnderstandingClient(
        reply: jsonEncode({
          'summary': '用户完成了演讲',
          'index_keywords': ['换工作', '演讲'],
        }),
      );
      final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
      DailyFinalizationService buildService(AtomicTextWriter writer) =>
          DailyFinalizationService(
            memoryDirectory: root.path,
            episodePipeline: pipeline,
            openLoopStore: openLoopStore,
            clock: clock,
            modelClient: client,
            atomicWriter: writer,
            diagnosticsSink: (_) {},
          );

      // 第一次归档在 daily-state 写入处失败，理解已随第 1 步落盘。
      var dailyStateFailures = 1;
      await expectLater(
        buildService(
          FailingAtomicTextWriter(
            shouldFail: (path) {
              if (dailyStateFailures > 0 && path.endsWith('daily-state.md')) {
                dailyStateFailures -= 1;
                return true;
              }
              return false;
            },
            exception: const FileSystemException(
              'mock interrupted daily-state write',
            ),
          ),
        ).finalizeDay('2026-08-14'),
        throwsA(isA<MemoryRepositoryException>()),
      );
      // 失败与重试之间用户新增禁提。
      expect(await openLoopStore.banTitle('换工作'), isTrue);

      final retry = await buildService(const IoAtomicTextWriter())
          .finalizeDay('2026-08-14');
      expect(retry.status, FinalizationStatus.finalized);
      expect(client.calls, 1, reason: '重试复用理解，不重复调用模型');
      // 复用路径按当前禁提复查：被禁关键词不得复活进索引。
      final monthIndex = File(
        '${root.path}/episodes/2026/08/index.md',
      ).readAsStringSync();
      expect(monthIndex, isNot(contains('换工作')));
      expect(monthIndex, contains('演讲'));
    });
  });
}

Future<void> _seedDay(
  EpisodeMemoryPipeline pipeline,
  String date,
  List<EpisodeEntry> entries,
) => pipeline.synchronizedOnDayFiles(
  () => pipeline.writeFinalization(date, entries: entries, finalized: false),
);

EpisodeEntry _entry(
  String id,
  String summary, {
  String kind = episodeKindMemory,
  String? signal,
}) => EpisodeEntry(
  id: id,
  sessionId: 'seed',
  requestId: 'seed',
  summary: summary,
  at: DateTime(2026, 8, 14, 21).toUtc(),
  kind: kind,
  signal: signal,
);

final class _FakeUnderstandingClient implements ProviderChatClient {
  _FakeUnderstandingClient({this.reply, this.failure, this.configured = true});

  final String? reply;
  final ModelFailureKind? failure;
  final bool configured;
  int calls = 0;
  List<ModelMessage>? lastMessages;

  @override
  Future<ModelCompletion?> complete(
    List<ModelMessage> messages, {
    int? maxTokens,
  }) async {
    calls += 1;
    lastMessages = messages;
    if (!configured) {
      return null;
    }
    final kind = failure;
    if (kind != null) {
      return ModelCompletion.failure(kind);
    }
    return ModelCompletion.reply(reply ?? '{}');
  }
}
