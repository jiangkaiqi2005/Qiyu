import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
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
          'active_items': ['项目 X deadline 临近', '用户在准备演讲'],
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
      expect(understanding.activeItems, ['项目 X deadline 临近', '用户在准备演讲']);
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

    test('episode entry keep marks are whitelist-validated', () {
      final diagnostics = <String>[];
      final understanding = parseDayUnderstanding(
        jsonEncode({
          'episode_entries': [
            {
              'request_id': 'r1',
              'summary': '用户认定长期记忆只放长远的事',
              'keep': 'month',
            },
            {'request_id': 'r2', 'summary': '用户晚饭吃了小馄饨'},
            {
              'request_id': 'r3',
              'summary': '用户喜欢爬山',
              'keep': 'day',
            },
            {
              'request_id': 'r4',
              'summary': '用户提到了旧书店',
              'keep': 7,
            },
          ],
          'covered_request_ids': ['r1', 'r2', 'r3', 'r4'],
        }),
        bannedTitles: const {},
        diagnosticsSink: diagnostics.add,
      );

      expect(understanding!.episodeEntries, hasLength(4));
      expect(understanding.episodeEntries[0].keep, memorySignalKeepMonth);
      // 没标 keep 的条目按未标记落盘，月压缩不收。
      expect(understanding.episodeEntries[1].keep, isNull);
      // 白名单外取值按字段丢弃并记诊断，条目本身保留。
      expect(understanding.episodeEntries[2].keep, isNull);
      // 非字符串取值与字段缺失同效：不记诊断。
      expect(understanding.episodeEntries[3].keep, isNull);
      expect(
        diagnostics.where((line) => line.contains('keep')),
        hasLength(1),
      );
    });

    test('loop candidate and relationship signal keep marks are validated', () {
      final diagnostics = <String>[];
      final understanding = parseDayUnderstanding(
        jsonEncode({
          'loop_candidates': [
            {'title': '租房事宜', 'keep': 'month'},
            {'title': '普通待办', 'keep': 'day'},
          ],
          'relationship_signals': [
            {'signal': 'deep_talk', 'summary': '用户聊到家庭', 'keep': 'month'},
          ],
        }),
        bannedTitles: const {},
        diagnosticsSink: diagnostics.add,
      );

      expect(understanding!.loopCandidates, hasLength(2));
      expect(understanding.loopCandidates[0].keep, memorySignalKeepMonth);
      // 白名单外取值按字段丢弃并记诊断，候选本身保留。
      expect(understanding.loopCandidates[1].keep, isNull);
      expect(understanding.relationshipSignals, hasLength(1));
      expect(understanding.relationshipSignals[0].keep, memorySignalKeepMonth);
      expect(
        diagnostics.where((line) => line.contains('keep')),
        hasLength(1),
      );

      // 关系信号的越界 keep 同样只丢字段，信号保留。
      final signalDiagnostics = <String>[];
      final signal = parseDayUnderstanding(
        jsonEncode({
          'relationship_signals': [
            {'signal': 'temperature', 'summary': '今晚话少', 'keep': 'week'},
          ],
        }),
        bannedTitles: const {},
        diagnosticsSink: signalDiagnostics.add,
      );
      expect(signal!.relationshipSignals.single.keep, isNull);
      expect(
        signalDiagnostics.where((line) => line.contains('keep')),
        hasLength(1),
      );
    });

    test('active items are count- and length-limited with diagnostics', () {
      final diagnostics = <String>[];
      final understanding = parseDayUnderstanding(
        jsonEncode({
          'active_items': [
            '项目截止日临近',
            '   ',
            '用户在准备周末的露营活动，需要确认装备清单、天气情况和交通方式',
            '用户在筹备演讲',
            '用户在赶项目进度',
            '用户在跟进体检预约',
            '养绿萝的习惯还在保持',
            '第七条不应进来',
          ],
        }),
        bannedTitles: const {},
        diagnosticsSink: diagnostics.add,
      );

      // 数量上限 6：先校验后计数，无效项不占名额；越界即停并记诊断。
      expect(
        understanding!.activeItems,
        hasLength(understandingMaxActiveItems),
      );
      expect(understanding.activeItems.last, '养绿萝的习惯还在保持');
      // 超长条目截断保留（与其余理解字段同一口径），但记诊断。
      expect(
        understanding.activeItems[1].runes.length,
        lessThanOrEqualTo(understandingActiveItemMaxRunes),
      );
      final lines = diagnostics.join('\n');
      expect(lines, contains('active item over rune limit'));
      expect(lines, contains('active item invalid'));
      expect(lines, contains('active items over count limit'));
    });

    test('banned titles never enter the active item list', () {
      final diagnostics = <String>[];
      final understanding = parseDayUnderstanding(
        jsonEncode({
          'active_items': ['换工作的面试准备', '周末露营计划'],
        }),
        bannedTitles: {normalizeLoopTitle('换工作')},
        diagnosticsSink: diagnostics.add,
      );

      expect(understanding!.activeItems, ['周末露营计划']);
      expect(diagnostics.join('\n'), contains('active item banned'));
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

    test(
      'relationship stage judgment and description parse with whitelists',
      () {
        final understanding = parseDayUnderstanding(
          jsonEncode({
            'relationship_stage': '朋友',
            'stage_description': '  用户已经会把白天的事说给她听，也经得起她的直话  ',
          }),
          bannedTitles: const {},
          diagnosticsSink: (_) {},
        );

        expect(understanding!.relationshipStage, '朋友');
        expect(
          understanding.stageDescription,
          '用户已经会把白天的事说给她听，也经得起她的直话',
        );

        // 超长描述截断保留（与其余理解短句字段同一口径）。
        final clipped = parseDayUnderstanding(
          jsonEncode({'stage_description': '描述${'长' * 80}'}),
          bannedTitles: const {},
          diagnosticsSink: (_) {},
        );
        expect(
          clipped!.stageDescription!.runes.length,
          understandingStageDescriptionMaxRunes,
        );
      },
    );

    test('invalid stage wire values are dropped with diagnostics', () {
      final diagnostics = <String>[];
      final understanding = parseDayUnderstanding(
        jsonEncode({
          'relationship_stage': '知己',
          'stage_description': '没有合法阶段判断时的描述',
        }),
        bannedTitles: const {},
        diagnosticsSink: diagnostics.add,
      );

      // 逐字段校验：非法阶段值只丢阶段判断。
      expect(understanding!.relationshipStage, isNull);
      expect(
        diagnostics.join('\n'),
        contains('relationship stage not in whitelist'),
      );
    });

    test('banned titles never enter the stage description', () {
      final diagnostics = <String>[];
      final understanding = parseDayUnderstanding(
        jsonEncode({
          'relationship_stage': '熟悉',
          'stage_description': '用户聊了换工作的打算后放松下来',
        }),
        bannedTitles: {normalizeLoopTitle('换工作')},
        diagnosticsSink: diagnostics.add,
      );

      expect(understanding!.relationshipStage, '熟悉');
      expect(understanding.stageDescription, isNull);
      expect(diagnostics.join('\n'), contains('stage description banned'));
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
          (
            title: '演讲复盘',
            due: null,
            proactive: 'once',
            note: null,
            keep: memorySignalKeepMonth,
          ),
        ],
        loopClosures: const [(title: '搬家打包', result: '已完成')],
        relationshipSignals: const [
          (
            signal: 'deep_talk',
            summary: '用户聊到家庭',
            keep: memorySignalKeepMonth,
          ),
        ],
        relationshipStage: '熟悉',
        stageDescription: '用户开始把白天的小事说给她听',
        indexKeywords: const ['演讲'],
        personaHints: const [
          (branch: 'values', nature: 'self_report', summary: '用户重视诚实'),
        ],
        activeItems: const ['项目 X deadline 临近', '用户在准备演讲'],
      ).withCoverage(entries);

      final restored = DayUnderstanding.fromJson(original.toJson());
      expect(restored.summary, original.summary);
      expect(restored.mood, original.mood);
      expect(restored.activeItems, original.activeItems);
      // 阶段判断与描述随理解一起持久化：relationship_lifecycle 的
      // 每日重建与恢复重建都读同一投影。
      expect(restored.relationshipStage, '熟悉');
      expect(restored.stageDescription, '用户开始把白天的小事说给她听');
      expect(restored.loopCandidates.single.title, '演讲复盘');
      // keep 随理解一起持久化：重建路径（relationship_lifecycle）与
      // 复用路径都按同一口径还原月层资格。
      expect(restored.loopCandidates.single.keep, memorySignalKeepMonth);
      expect(restored.relationshipSignals.single.keep, memorySignalKeepMonth);
      expect(restored.loopClosures.single.result, '已完成');
      expect(restored.relationshipSignals.single.signal, 'deep_talk');
      expect(restored.indexKeywords, ['演讲']);
      expect(restored.personaHints.single.branch, 'values');
      expect(restored.entryCount, 1);
      expect(restored.lastEntryId, 's1:r1:0');
      expect(restored.covers(entries), isTrue);
      expect(restored.covers(const []), isFalse);
    });

    test('persisted understanding without active items stays compatible', () {
      // 旧元数据没有近日活跃清单字段：按空清单还原，其余字段不受影响。
      final restored = DayUnderstanding.fromJson(const {
        'summary': '旧数据没有近日活跃清单',
        'mood': '平静',
        'indexKeywords': ['旧数据'],
      });

      expect(restored.activeItems, isEmpty);
      expect(restored.summary, '旧数据没有近日活跃清单');
      expect(restored.indexKeywords, ['旧数据']);
      // 空清单不落键：持久化形态与旧数据逐字节一致。
      expect(
        DayUnderstanding(summary: '只有概括').toJson().containsKey('activeItems'),
        isFalse,
      );
      // 旧元数据同样没有阶段判断与描述：按缺失还原，阶段维持现状。
      expect(restored.relationshipStage, isNull);
      expect(restored.stageDescription, isNull);
      expect(
        DayUnderstanding(summary: '只有概括').toJson().containsKey(
          'relationshipStage',
        ),
        isFalse,
      );
      expect(
        DayUnderstanding(summary: '只有概括').toJson().containsKey(
          'stageDescription',
        ),
        isFalse,
      );
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
    test('the understanding prompt teaches the month keep mark', () async {
      final client = _FakeUnderstandingClient(reply: '{}');
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
      final system = client.lastMessages!.first.content;
      // 三类模型产出条目都教何时标 keep: month；日常琐事不标。
      expect(system, contains('"keep": 可选的 "month"'));
      expect(system, contains('不要标 keep'));
      // 未闭环整月值得进月压缩的候选才标。
      expect(system, contains('loop_candidates'));
      expect(system, contains('relationship_signals'));
    });

    test(
      'the understanding prompt teaches the still-active item list',
      () async {
        final client = _FakeUnderstandingClient(reply: '{}');
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
        final system = client.lastMessages!.first.content;
        expect(system, contains('active_items'));
        // 判断「仍活跃」的依据：当天整理记录 + 现状态包近日投影 + 未闭环事项。
        expect(system, contains('仍然活跃'));
        // 已结束、已闭环、一次性小事不列。
        expect(system, contains('已闭环'));
        // 防复读：不因上期状态包的近日投影里出现过就继续列出，
        // 要按本次读到的材料重新判断哪些仍然影响当前对话。
        expect(system, contains('不要因为上一期状态包的近日投影里出现过就继续列出'));
        expect(system, contains('按本次读到的材料重新判断哪些仍然影响当前对话'));
        // 一事只进其一：与 open-loop 的排重由宿主按文字规范化相等执行，
        // 提示词只交代边界。
        expect(system, contains('一事只进其一'));
        expect(system, contains('没有仍然活跃的事项就省略本字段'));
      },
    );

    test(
      'the understanding prompt teaches the semantic stage judgment',
      () async {
        final client = _FakeUnderstandingClient(reply: '{}');
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
        final system = client.lastMessages!.first.content;
        expect(system, contains('relationship_stage'));
        // 整体语义判断：结合当天完整互动，不数条数天数。
        expect(system, contains('整体语义判断'));
        expect(system, contains('不要数互动条数'));
        // 深谈信号可独立支持升级。
        expect(system, contains('深谈信号'));
        expect(system, contains('独立支持升级'));
        // 只能判定到有依据的级别，没有把握就省略。
        expect(system, contains('只能判定到有依据的级别'));
        expect(system, contains('省略本字段'));
        // 省略的后果如实描述：不回退、宿主不发明判断，但此前持久化
        // 的目标仍按每天最多一级兑现（与 _latestStageJudgment 的
        // 跨日棘轮行为一致）。
        expect(system, contains('省略不会让阶段回退'));
        expect(system, contains('宿主也不会自行发明判断'));
        expect(system, contains('此前日子已持久化的目标仍会按每天最多一级继续兑现'));
        expect(system, contains('永远不会让阶段下降'));
        // 描述由模型结合这个具体用户生成，替换固定文案。
        expect(system, contains('stage_description'));
        expect(system, contains('结合这个具体用户'));
        expect(system, contains('不要写认识天数或统计数字'));
      },
    );

    test('model keep marks persist with the understanding metadata', () async {
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
        reply: jsonEncode({
          'summary': '用户完成了第一次演讲',
          'loop_candidates': [
            {'title': '租房事宜', 'keep': 'month'},
            {'title': '买牛奶'},
          ],
          'relationship_signals': [
            {'signal': 'deep_talk', 'summary': '用户聊到家庭', 'keep': 'month'},
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
      // keep 随理解元数据持久化：relationship_lifecycle 的每日重建与
      // 理解复用都按同一口径还原月层资格。
      final understanding = (await pipeline.readDay('2026-08-14')).understanding;
      final candidates = understanding!['loopCandidates'] as List<Object?>;
      expect((candidates[0] as Map<String, Object?>)['keep'], 'month');
      expect((candidates[1] as Map<String, Object?>).containsKey('keep'), isFalse);
      final signals = understanding['relationshipSignals'] as List<Object?>;
      expect((signals.single as Map<String, Object?>)['keep'], 'month');
    });

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

      // 3. 关系信号投影近期变化；本次输出没有阶段判断，阶段不动。
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

    test(
      'the model active item list drives the recent-activity section',
      () async {
        final root = await Directory.systemTemp.createTemp('qiyu-understand-');
        addTearDown(() => root.delete(recursive: true));
        DateTime clock() => DateTime(2026, 8, 14, 23, 30);
        final pipeline = EpisodeMemoryPipeline(
          memoryDirectory: root.path,
          clock: clock,
        );
        await _seedDay(pipeline, '2026-08-12', [
          _entry('s1:r1:0', '08-12 用户在筹备演讲'),
        ]);
        await _seedDay(pipeline, '2026-08-13', [
          _entry('s2:r2:0', '08-13 用户还在改稿'),
        ]);
        await _seedDay(pipeline, '2026-08-14', [
          _entry('s3:r3:0', '08-14 用户聊了今晚的晚饭'),
        ]);
        final client = _FakeUnderstandingClient(
          reply: jsonEncode({
            'summary': '用户在筹备演讲',
            'active_items': ['用户在筹备周末的演讲，还在改稿'],
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
        final dailyState = File(
          '${root.path}/daily-state.md',
        ).readAsStringSync();
        // 近日活跃读模型清单：自然语言短句，不带日期前缀。
        expect(dailyState, contains('## 近日活跃'));
        expect(dailyState, contains('- 用户在筹备周末的演讲，还在改稿'));
        // 不再按日期从旧到新截取近 7 天条目。
        expect(dailyState, isNot(contains('(08-12)')));
        expect(dailyState, isNot(contains('08-12 用户在筹备演讲')));
        expect(dailyState, isNot(contains('08-13 用户还在改稿')));
        // 用户当前近况仍取最新一天，不受清单影响。
        expect(dailyState, contains('## 用户当前近况'));
        expect(dailyState, contains('08-14 用户聊了今晚的晚饭'));
      },
    );

    test('active items dedupe against open loops and clip per item', () async {
      final root = await Directory.systemTemp.createTemp('qiyu-understand-');
      addTearDown(() => root.delete(recursive: true));
      DateTime clock() => DateTime(2026, 8, 14, 23, 30);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: root.path,
        clock: clock,
      );
      await _seedDay(pipeline, '2026-08-14', [
        _entry('s1:r1:0', '08-14 用户聊了很多'),
      ]);
      File('${root.path}/open-loops.md').writeAsStringSync(
        '# open-loops\n\n- [o1] 搬家打包\n  proactive: once\n  status: active\n',
        encoding: utf8,
      );
      final longItem = '用户在准备周末的露营活动，需要确认装备清单、天气情况和交通方式还有预算';
      final client = _FakeUnderstandingClient(
        reply: jsonEncode({
          'active_items': ['搬家打包', longItem],
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
      final dailyState = File('${root.path}/daily-state.md').readAsStringSync();
      // 一事只进其一：已进 open-loop 的事项不重复进近日活跃。
      expect(dailyState, isNot(contains('搬家打包')));
      // 单条截断：渲染时仍受 daily-state 每条预算约束。
      expect(
        dailyState,
        contains('- ${String.fromCharCodes(longItem.runes.take(28))}'),
      );
      expect(dailyState, isNot(contains(longItem)));
    });

    test(
      'an empty active item list falls back to date-based projection',
      () async {
        final root = await Directory.systemTemp.createTemp('qiyu-understand-');
        addTearDown(() => root.delete(recursive: true));
        DateTime clock() => DateTime(2026, 8, 14, 23, 30);
        final pipeline = EpisodeMemoryPipeline(
          memoryDirectory: root.path,
          clock: clock,
        );
        await _seedDay(pipeline, '2026-08-12', [
          _entry('s1:r1:0', '08-12 用户在筹备演讲'),
        ]);
        await _seedDay(pipeline, '2026-08-13', [
          _entry('s2:r2:0', '08-13 用户还在改稿'),
        ]);
        await _seedDay(pipeline, '2026-08-14', [
          _entry('s3:r3:0', '08-14 用户聊了今晚的晚饭'),
        ]);
        // 模型输出空清单与未输出同义：按日期截取兜底（定稿 2026-09-22）。
        final client = _FakeUnderstandingClient(
          reply: jsonEncode({'summary': '用户在筹备演讲', 'active_items': const []}),
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
        final dailyState = File(
          '${root.path}/daily-state.md',
        ).readAsStringSync();
        expect(dailyState, contains('## 近日活跃'));
        expect(dailyState, contains('- (08-12) 08-12 用户在筹备演讲'));
        expect(dailyState, contains('- (08-13) 08-13 用户还在改稿'));
      },
    );

    test(
      'budget cuts keep the section order and spare the recent section',
      () async {
        final root = await Directory.systemTemp.createTemp('qiyu-understand-');
        addTearDown(() => root.delete(recursive: true));
        DateTime clock() => DateTime(2026, 8, 14, 23, 30);
        final pipeline = EpisodeMemoryPipeline(
          memoryDirectory: root.path,
          clock: clock,
        );
        await _seedDay(pipeline, '2026-08-14', [
          _entry('s1:r1:0', '近况甲：用户连续加班到深夜，咖啡喝了很多杯，眼睛干涩肩膀也酸'),
          _entry('s1:r1:1', '近况乙：用户明天一早要开会，材料还没准备完，打算再熬一会儿'),
          _entry('s1:r1:2', '近况丙：用户晚饭只吃了个三明治，说忙到没胃口但是有点饿'),
          _entry('s1:r1:3', '近况丁：用户说周末想补觉，哪儿都不想去就在家躺着发呆'),
        ]);
        final client = _FakeUnderstandingClient(
          reply: jsonEncode({
            'mood': '最近压力有点大，晚上总是睡不好觉，白天没精神',
            'active_items': [
              '要点甲：用户在筹备周末的露营活动，装备清单还没有确认',
              '要点乙：用户在赶项目进度，下周要交原型和文档说明',
              '要点丙：用户在跟进体检预约，时间约在月底的上午',
              '要点丁：用户养绿萝的习惯还在保持，偶尔拍照记录',
              '要点戊：用户在准备演讲的复盘提纲，列了三个问题',
              '要点己：用户提到楼下的花店关门了，只是随口一说',
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
        final dailyState = File(
          '${root.path}/daily-state.md',
        ).readAsStringSync();
        expect(dailyState.runes.length, lessThanOrEqualTo(dailyStateMaxRunes));
        // 砍序不变：先整体砍近日气氛，再砍近日活跃。
        expect(dailyState, isNot(contains('## 近日气氛')));
        // 模型清单按重要性从高到低，砍最不重要的一端。
        expect(dailyState, contains('要点甲'));
        expect(dailyState, isNot(contains('要点己')));
        // 用户当前近况永不砍。
        expect(dailyState, contains('## 用户当前近况'));
        for (final label in ['近况甲', '近况乙', '近况丙', '近况丁']) {
          expect(dailyState, contains(label));
        }
      },
    );

    test(
      'catch-up restore reads the persisted active item list with host caps',
      () async {
        final root = await Directory.systemTemp.createTemp('qiyu-understand-');
        addTearDown(() => root.delete(recursive: true));
        var now = DateTime(2026, 8, 12, 23);
        final pipeline = EpisodeMemoryPipeline(
          memoryDirectory: root.path,
          clock: () => now,
        );
        await _seedDay(pipeline, '2026-08-10', [
          _entry('s10:r10:0', '08-10 的老事项'),
        ]);
        await _seedDay(pipeline, '2026-08-12', [
          _entry('s12:r12:0', '08-12 的新事项'),
        ]);
        // 08-12 已归档，理解元数据里直接带 8 条近日活跃（超宿主上限），
        // 首条还超长：补扫重建走同一套宿主闸门。
        final longItem = '很长的一条近日活跃事项${'补' * 40}';
        await pipeline.synchronizedOnDayFiles(
          () => pipeline.writeFinalization(
            '2026-08-12',
            entries: [_entry('s12:r12:0', '08-12 的新事项')],
            summary: '08-12 摘要',
            finalized: true,
            finalizedAt: now.toUtc(),
            understanding: {
              'summary': '08-12 摘要',
              'activeItems': [
                longItem,
                '活跃一',
                '活跃二',
                '活跃三',
                '活跃四',
                '活跃五',
                '活跃六',
                '活跃七',
              ],
            },
          ),
        );

        now = DateTime(2026, 8, 13, 10);
        final service = DailyFinalizationService(
          memoryDirectory: root.path,
          episodePipeline: pipeline,
          clock: () => now,
          diagnosticsSink: (_) {},
        );
        await service.catchUpUnfinalized(before: '2026-08-13');

        final dailyState = File(
          '${root.path}/daily-state.md',
        ).readAsStringSync();
        // 重建以最新定稿日 08-12 为窗口终点，读它持久化的近日活跃清单。
        expect(dailyState, contains('date: 2026-08-12'));
        // 单条截断与条数截断都由宿主持闸。
        expect(
          dailyState,
          contains('- ${String.fromCharCodes(longItem.runes.take(28))}'),
        );
        expect(dailyState, isNot(contains(longItem)));
        expect(dailyState, contains('- 活跃一'));
        expect(dailyState, contains('- 活跃五'));
        expect(dailyState, isNot(contains('活跃六')));
        expect(dailyState, isNot(contains('活跃七')));
      },
    );

    test(
      'a deep talk signal without a stage judgment never promotes',
      () async {
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

        // 深谈信号本身只是温度投影；阶段升降只认模型的整体阶段判断。
        final relationship = File(
          '${root.path}/relationship.md',
        ).readAsStringSync();
        expect(relationship, contains('stage: 初识'));
        expect(relationship, contains('用户聊到很深的家庭话题'));
      },
    );

    test(
      'a model stage judgment drives the ratchet and lands its description',
      () async {
        final root = await Directory.systemTemp.createTemp('qiyu-understand-');
        addTearDown(() => root.delete(recursive: true));
        DateTime clock() => DateTime(2026, 8, 14, 23, 30);
        final pipeline = EpisodeMemoryPipeline(
          memoryDirectory: root.path,
          clock: clock,
        );
        await _seedDay(pipeline, '2026-08-13', [
          _entry('s0:r0:0', '08-13 用户聊了近况'),
        ]);
        await _seedDay(pipeline, '2026-08-14', [
          _entry('s1:r1:0', '用户聊了一件心事'),
        ]);
        final client = _FakeUnderstandingClient(
          reply: jsonEncode({
            'relationship_stage': '熟悉',
            'stage_description': '用户开始把白天的小事说给她听',
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

        final outcome = await service.finalizeDay('2026-08-14');

        expect(outcome.status, FinalizationStatus.finalized);
        // 判断与描述随理解元数据持久化。
        final understanding = (await pipeline.readDay('2026-08-14')).understanding;
        expect(understanding!['relationshipStage'], '熟悉');
        expect(
          understanding['stageDescription'],
          '用户开始把白天的小事说给她听',
        );
        // 目标熟悉：单次日终最多一级，从初识前进一步。
        final relationship = File(
          '${root.path}/relationship.md',
        ).readAsStringSync();
        expect(relationship, contains('stage: 熟悉'));
        expect(relationship, contains('阶段描述: 用户开始把白天的小事说给她听'));
        // 深谈信号仍照常投影近期变化。
        expect(relationship, contains('用户聊到很深的家庭话题'));
      },
    );

    test(
      'the persisted judgment carries the ratchet on a deterministic day',
      () async {
        final root = await Directory.systemTemp.createTemp('qiyu-understand-');
        addTearDown(() => root.delete(recursive: true));
        var now = DateTime(2026, 8, 14, 23, 30);
        final pipeline = EpisodeMemoryPipeline(
          memoryDirectory: root.path,
          clock: () => now,
        );
        await _seedDay(pipeline, '2026-08-13', [
          _entry('s0:r0:0', '08-13 用户聊了近况'),
        ]);
        await _seedDay(pipeline, '2026-08-14', [
          _entry('s1:r1:0', '用户聊了一件心事'),
        ]);
        final client = _FakeUnderstandingClient(
          reply: jsonEncode({
            'relationship_stage': '朋友',
            'stage_description': '用户和她已经能互相说心事',
          }),
        );
        final service = DailyFinalizationService(
          memoryDirectory: root.path,
          episodePipeline: pipeline,
          clock: () => now,
          modelClient: client,
          diagnosticsSink: (_) {},
        );
        await service.finalizeDay('2026-08-14');
        expect(
          File('${root.path}/relationship.md').readAsStringSync(),
          contains('stage: 熟悉'),
        );

        // 次日没有模型参与：读 08-14 持久化的判断，棘轮再追一级。
        now = DateTime(2026, 8, 15, 23, 30);
        await _seedDay(pipeline, '2026-08-15', [
          _entry('s2:r2:0', '用户随口聊了天气'),
        ]);
        final nextService = DailyFinalizationService(
          memoryDirectory: root.path,
          episodePipeline: pipeline,
          clock: () => now,
          diagnosticsSink: (_) {},
        );
        await nextService.finalizeDay('2026-08-15');

        final relationship = File(
          '${root.path}/relationship.md',
        ).readAsStringSync();
        expect(relationship, contains('stage: 朋友'));
        expect(relationship, contains('阶段描述: 用户和她已经能互相说心事'));
      },
    );

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
      expect(
        (await MemoryBanExecution(openLoopStore: openLoopStore).execute(
          '换工作',
          origin: 'open-loop',
        )).controlWritten,
        isTrue,
      );

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
