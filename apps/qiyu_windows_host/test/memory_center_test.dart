import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String memoryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-memory-center-test-',
    );
    memoryDirectory = temporaryDirectory.path;
    _currentTestDirectory = temporaryDirectory.path;
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  MemoryCenterService serviceFor({DateTime? now}) {
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: memoryDirectory);
    return MemoryCenterService(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      personaTree: PersonaTreeStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      ),
      memoryControls: MemoryControlsStore(memoryDirectory: memoryDirectory),
      dreamService: DreamService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      ),
      clock: now == null ? null : () => now,
      diagnosticsSink: (_) {},
    );
  }

  test('empty memory directory yields honest empty sections', () async {
    final overview = await serviceFor().overview();

    expect(overview.recent.days, isEmpty);
    expect(overview.longTerm.present, isFalse);
    expect(overview.longTerm.groups, isEmpty);
    for (final branch in overview.persona.branches) {
      expect(branch.readable, isTrue);
      expect(branch.roots, isEmpty);
      expect(branch.unrooted, isEmpty);
    }
    expect(overview.persona.branches.map((branch) => branch.title), [
      '身份事实',
      '性格表达',
      '价值原则',
      '偏好习惯',
      '边界禁区',
    ]);
    expect(overview.relationship.present, isFalse);
    expect(overview.relationship.sharedPast, isEmpty);
  });

  test('overview loads all four sections from local md files', () async {
    final now = DateTime(2026, 8, 17, 21);
    await _seedFullMemory(now);
    final overview = await serviceFor(now: now).overview();

    // 最近发生：只收用户可理解条目；簿记条目（冻结留痕）不出现。
    expect(overview.recent.days, hasLength(2));
    final today = overview.recent.days.first;
    expect(today.date, '2026-08-17');
    expect(today.finalized, isFalse);
    expect(today.entries.map((entry) => entry.content), contains('用户说这周在准备演讲'));
    // 关系证据条目以用户语言呈现。
    expect(today.entries.map((entry) => entry.kind), contains('relationship'));
    final yesterday = overview.recent.days.last;
    expect(yesterday.date, '2026-08-16');
    expect(yesterday.finalized, isTrue);
    expect(yesterday.summary, '聊了睡前习惯');
    // 簿记条目不进记忆中心。
    final allContent = [
      for (final day in overview.recent.days)
        for (final entry in day.entries) entry.content ?? '',
    ];
    expect(allContent, isNot(contains(startsWith('冻结:'))));

    // 长期印象：三分区（共同过往归入「我们的关系」区）。
    expect(overview.longTerm.present, isTrue);
    expect(overview.longTerm.readable, isTrue);
    expect(overview.longTerm.organizedAt, isNotNull);
    expect(overview.longTerm.groups.map((group) => group.section), [
      '人与关系',
      '重要事件',
      '模式与轨迹',
    ]);
    expect(overview.longTerm.groups.first.items.single.content, '用户和家人关系亲近');

    // 关于你：根主张与未归根中间理解，不暴露内部术语作为导航。
    final expression = overview.persona.branches.singleWhere(
      (branch) => branch.wire == 'expression',
    );
    expect(expression.roots, hasLength(1));
    final root = expression.roots.single;
    expect(root.claim, '用户尴尬时倾向自嘲');
    expect(root.middleCount, 1);
    expect(root.leafCount, 2);
    expect(root.earliestEvidence, '2026-07-10');
    expect(root.latestEvidence, '2026-07-16');
    final identity = overview.persona.branches.singleWhere(
      (branch) => branch.wire == 'identity',
    );
    expect(identity.unrooted, hasLength(1));
    expect(identity.unrooted.single.type, '待稳定事实');
    expect(identity.unrooted.single.claim, '用户是中学老师');

    // 我们的关系：受管结构 + 共同过往。
    expect(overview.relationship.present, isTrue);
    expect(overview.relationship.stage, '熟悉');
    expect(overview.relationship.since, '2026-08-01');
    expect(overview.relationship.confirmed.single.content, '可以自然提起说过的事');
    expect(overview.relationship.recentChanges.single.content, '聊得比平时深一些');
    expect(overview.relationship.sharedPast.single.content, '一起聊到过深夜');
  });

  test('evidence drills layer by layer down to the episode entry', () async {
    final now = DateTime(2026, 8, 17, 21);
    await _seedFullMemory(now);
    final service = serviceFor(now: now);
    final overview = await service.overview();

    final root = overview.persona.branches
        .singleWhere((branch) => branch.wire == 'expression')
        .roots
        .single;
    final rootDetail = await service.itemDetail(root.id);
    expect(rootDetail, isA<PersonaRootDetail>());
    final rootPath = rootDetail! as PersonaRootDetail;
    expect(rootPath.branchTitle, '性格表达');
    expect(rootPath.middles, hasLength(1));

    final middleDetail = await service.itemDetail(rootPath.middles.single.id);
    expect(middleDetail, isA<PersonaMiddleDetail>());
    final middle = middleDetail! as PersonaMiddleDetail;
    expect(middle.rootClaim, '用户尴尬时倾向自嘲');
    expect(middle.formedOn, isNotEmpty);
    expect(middle.reviewedOn, isNotEmpty);
    expect(middle.leaves, hasLength(2));
    // 置信维度：来源性质逐叶可见。
    expect(middle.leaves.map((leaf) => leaf.nature), everyElement('行为观察'));

    // 叶 → 当日记录 → 条目详情（含原话摘录与会话入口）。
    final dayDetail = await service.itemDetail(middle.leaves.first.dayId);
    expect(dayDetail, isA<MemoryDayDetail>());
    final day = dayDetail! as MemoryDayDetail;
    expect(day.date, middle.leaves.first.date);
    expect(day.entries, isNotEmpty);

    final evidenceEntry = day.entries.singleWhere(
      (candidate) => candidate.hasEvidence,
    );
    final entryDetail = await service.itemDetail(evidenceEntry.id);
    expect(entryDetail, isA<EpisodeEntryDetail>());
    final entry = entryDetail! as EpisodeEntryDetail;
    expect(entry.evidence, isNotNull);
    expect(entry.sessionId, 'seed-session');
  });

  test('sensitive text is masked in overview and details', () async {
    final now = DateTime(2026, 8, 17, 21);
    await _seedEpisodes({
      '2026-08-17': [
        _entry(
          's1:r1:0',
          '用户的手机号是13812345678',
          evidence: '我的号是13812345678',
          at: DateTime(2026, 8, 17, 20),
        ),
      ],
    });
    File(
      path.join(memoryDirectory, 'long-memory.md'),
    ).writeAsStringSync('# long-memory\n\n## 人与关系\n- 用户的邮箱是user@example.com\n');
    // 关系区各行同样走读取时敏感纪律。
    File(path.join(memoryDirectory, 'relationship.md')).writeAsStringSync(
      '# relationship\n\n'
      'stage: 熟悉\n'
      'since: 2026-08-01\n'
      '阶段描述: 从初识进入熟悉\n\n'
      '## 当前相处方式\n'
      '已确认：\n'
      '- 用户的手机号是13812345678\n',
    );
    final service = serviceFor(now: now);
    final overview = await service.overview();

    final entry = overview.recent.days.single.entries.single;
    expect(entry.masked, isTrue);
    expect(entry.content, isNull);

    final detail = await service.itemDetail(entry.id) as EpisodeEntryDetail;
    expect(detail.masked, isTrue);
    expect(detail.content, isNull);
    expect(detail.evidenceMasked, isTrue);
    expect(detail.evidence, isNull);

    final item = overview.longTerm.groups.single.items.single;
    expect(item.masked, isTrue);
    expect(item.content, isNull);

    final relationshipItem = overview.relationship.confirmed.single;
    expect(relationshipItem.masked, isTrue);
    expect(relationshipItem.content, isNull);
  });

  test('frozen and banned memories carry quiet status markers', () async {
    final now = DateTime(2026, 8, 17, 21);
    await _seedEpisodes({
      '2026-08-17': [
        _entry('s1:r1:0', '用户在准备演讲', at: DateTime(2026, 8, 17, 20)),
        _entry('s1:r2:0', '用户最近失眠', at: DateTime(2026, 8, 17, 21)),
      ],
    });
    File(path.join(memoryDirectory, 'memory-controls.md')).writeAsStringSync(
      '# memory-controls\n'
      '## frozen\n'
      '- [MC001] chat | 用户在准备演讲\n'
      '## banned\n'
      '- [MC002] chat | 用户最近失眠\n'
      '## deleted\n',
    );
    final overview = await serviceFor(now: now).overview();
    final entries = overview.recent.days.single.entries;
    expect(
      entries.singleWhere((e) => e.content == '用户在准备演讲').control,
      MemoryControlStatus.frozen,
    );
    expect(
      entries.singleWhere((e) => e.content == '用户最近失眠').control,
      MemoryControlStatus.banned,
    );
  });

  test('conflict leaves surface as a review marker on the middle', () async {
    final now = DateTime(2026, 8, 17, 21);
    // 两条一致证据形成中间理解，再写入一条反向证据挂成 conflict 叶。
    await _seedEpisodes({
      '2026-08-02': [
        _entry(
          's1:r1:0',
          '用户睡前习惯听白噪音',
          branch: 'preferences',
          nature: 'behavior',
          at: DateTime(2026, 8, 2, 22),
        ),
      ],
      '2026-08-09': [
        _entry(
          's2:r2:0',
          '用户睡前习惯听白噪音',
          branch: 'preferences',
          nature: 'behavior',
          at: DateTime(2026, 8, 9, 22),
        ),
      ],
    });
    final personaTree = PersonaTreeStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: EpisodeMemoryPipeline(memoryDirectory: memoryDirectory),
    );
    await personaTree.processDay('2026-08-02');
    await personaTree.processDay('2026-08-09');
    // 手工挂一条 conflict 叶（模拟整理管线的冲突记录）。
    final branchFile = File(
      path.join(memoryDirectory, 'persona-tree', 'preferences.md'),
    );
    final contents = branchFile.readAsStringSync();
    final anchor = contents
        .split('\n')
        .lastWhere((line) => line.startsWith('- [PR-L'));
    branchFile.writeAsStringSync(
      contents.replaceFirst(
        anchor,
        '$anchor\n- [PR-L003] 2026-08-16 | 行为观察 | conflict | 用户这两天开着音乐入睡'
        ' | episodes/2026-08/2026-08-16.md [s3:r3:0]',
      ),
    );

    final overview = await serviceFor(now: now).overview();
    final middle = overview.persona.branches
        .singleWhere((branch) => branch.wire == 'preferences')
        .unrooted
        .single;
    expect(middle.hasConflict, isTrue);
  });

  test('localized corruption degrades only the affected blocks', () async {
    final now = DateTime(2026, 8, 17, 21);
    await _seedFullMemory(now);
    // 损坏一个 episode 日文件与一个画像分支文件。
    File(
      path.join(memoryDirectory, 'episodes', '2026', '08', '2026-08-16.md'),
    ).writeAsStringSync('这不是栖语的记忆文件');
    File(
      path.join(memoryDirectory, 'persona-tree', 'values.md'),
    ).writeAsStringSync('坏的分支内容 ###');

    final overview = await serviceFor(now: now).overview();

    // 损坏日整体跳过，其余日期照常展示。
    expect(overview.recent.days.map((day) => day.date), ['2026-08-17']);
    // 损坏分支标记不可读，其余分支不受影响。
    final values = overview.persona.branches.singleWhere(
      (branch) => branch.wire == 'values',
    );
    expect(values.readable, isFalse);
    final expression = overview.persona.branches.singleWhere(
      (branch) => branch.wire == 'expression',
    );
    expect(expression.readable, isTrue);
    expect(expression.roots, hasLength(1));

    // 指向损坏日的详情返回 null，UI 以「已变化」呈现。
    final service = serviceFor(now: now);
    final freshOverview = await service.overview();
    final dayId = freshOverview.recent.days.single.id;
    final dayDetail = await service.itemDetail(dayId) as MemoryDayDetail;
    expect(dayDetail.entries, isNotEmpty);
  });

  test('unfinalized day is labeled as still being organized', () async {
    final now = DateTime(2026, 8, 17, 21);
    await _seedEpisodes({
      '2026-08-17': [
        _entry('s1:r1:0', '用户说这周在准备演讲', at: DateTime(2026, 8, 17, 20)),
      ],
    });
    final overview = await serviceFor(now: now).overview();
    expect(overview.recent.days.single.finalized, isFalse);
  });

  test(
    'browsing overview and details never writes to the memory directory',
    () async {
      final now = DateTime(2026, 8, 17, 21);
      await _seedFullMemory(now);
      final service = serviceFor(now: now);
      final before = _directorySnapshot(memoryDirectory);

      final overview = await service.overview();
      final ids = <String>[
        for (final day in overview.recent.days) ...[
          day.id,
          for (final entry in day.entries) entry.id,
        ],
        for (final branch in overview.persona.branches) ...[
          for (final root in branch.roots) root.id,
          for (final middle in branch.unrooted) middle.id,
        ],
      ];
      for (final id in ids) {
        await service.itemDetail(id);
      }

      expect(_directorySnapshot(memoryDirectory), before);
    },
  );

  test('unknown or stale item ids resolve to nothing', () async {
    final service = serviceFor();
    expect(await service.itemDetail('no-such-id'), isNull);
    expect(await service.itemDetail(''), isNull);
  });

  test('days outside the recent window are not listed', () async {
    final now = DateTime(2026, 8, 17, 21);
    await _seedEpisodes({
      '2026-07-01': [_entry('s1:r1:0', '很早以前的事', at: DateTime(2026, 7, 1, 20))],
    });
    final overview = await serviceFor(now: now).overview();
    expect(overview.recent.days, isEmpty);
  });

  test('actionable items carry opaque ids resolvable to refs', () async {
    final now = DateTime(2026, 8, 17, 21);
    await _seedFullMemory(now);
    final service = serviceFor(now: now);
    final overview = await service.overview();

    final longTermItem = overview.longTerm.groups.first.items.single;
    expect(longTermItem.id, isNotEmpty);
    expect(
      service.resolveRef(longTermItem.id),
      isA<MemoryLongTermRef>().having((ref) => ref.section, 'section', '人与关系'),
    );

    final sharedPast = overview.relationship.sharedPast.single;
    expect(sharedPast.id, isNotEmpty);
    expect(
      service.resolveRef(sharedPast.id),
      isA<MemoryLongTermRef>().having((ref) => ref.section, 'section', '共同过往'),
    );

    final confirmed = overview.relationship.confirmed.single;
    expect(confirmed.id, isNotEmpty);
    expect(
      service.resolveRef(confirmed.id),
      isA<MemoryRelationshipRef>().having(
        (ref) => ref.list,
        'list',
        'confirmed',
      ),
    );

    final entry = overview.recent.days.first.entries.first;
    expect(service.resolveRef(entry.id), isA<MemoryEntryRef>());
    final root = overview.persona.branches
        .singleWhere((branch) => branch.wire == 'expression')
        .roots
        .single;
    expect(service.resolveRef(root.id), isA<MemoryRootRef>());
    expect(service.resolveRef('stale-id'), isNull);
  });

  test('user-edited entries surface the correction marker', () async {
    final now = DateTime(2026, 8, 17, 21);
    await _seedEpisodes({
      '2026-08-17': [
        EpisodeEntry(
          id: 's1:r1:0',
          sessionId: 'seed-session',
          requestId: 'seed',
          summary: '用户修正后的说法',
          at: DateTime(2026, 8, 17, 20).toUtc(),
          userEdited: true,
        ),
      ],
    });
    final service = serviceFor(now: now);
    final overview = await service.overview();
    final entry = overview.recent.days.single.entries.single;
    expect(entry.userEdited, isTrue);

    final detail = await service.itemDetail(entry.id);
    expect((detail! as EpisodeEntryDetail).userEdited, isTrue);
  });

  test(
    'overview reports recovery section as healthy when all findings are full with 0 quarantine',
    () async {
      final pipeline = EpisodeMemoryPipeline(memoryDirectory: memoryDirectory);
      final memoryControls = MemoryControlsStore(
        memoryDirectory: memoryDirectory,
      );
      final personaTree = PersonaTreeStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      final monthlySummary = MonthlySummaryStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      final relationshipLifecycle = RelationshipLifecycle(
        memoryDirectory: memoryDirectory,
      );
      final dreamService = DreamService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      final actions = MemoryActionService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryControls: memoryControls,
        openLoopStore: OpenLoopStore(
          memoryDirectory: memoryDirectory,
          memoryControls: memoryControls,
        ),
        monthlySummary: monthlySummary,
        relationshipLifecycle: relationshipLifecycle,
      );
      final recovery = MemoryRecoveryService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        memoryControls: memoryControls,
        personaTree: personaTree,
        dreamService: dreamService,
        monthlySummary: monthlySummary,
        relationshipLifecycle: relationshipLifecycle,
        memoryActions: actions,
      );

      // 制造一个已归档日期缺席索引的恢复场景（stale + full + 0 隔离）
      await _seedEpisodes({
        '2026-08-16': [
          _entry('s1:r1:0', '用户准备演讲', at: DateTime(2026, 8, 16, 20)),
        ],
      }, finalizedDates: {'2026-08-16': '演讲'});

      await recovery.sweepAndRecover();

      final service = MemoryCenterService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryControls: memoryControls,
        dreamService: dreamService,
        memoryRecovery: recovery,
      );
      final overview = await service.overview();
      expect(overview.recovery.healthy, isTrue);
      expect(overview.recovery.quarantinedFiles, 0);
    },
  );

  test(
    'overview reports recovery section as unhealthy when pending, partial or quarantined files exist',
    () async {
      final pipeline = EpisodeMemoryPipeline(memoryDirectory: memoryDirectory);
      final memoryControls = MemoryControlsStore(
        memoryDirectory: memoryDirectory,
      );
      final personaTree = PersonaTreeStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      final monthlySummary = MonthlySummaryStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      final relationshipLifecycle = RelationshipLifecycle(
        memoryDirectory: memoryDirectory,
      );
      final dreamService = DreamService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      final actions = MemoryActionService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryControls: memoryControls,
        openLoopStore: OpenLoopStore(
          memoryDirectory: memoryDirectory,
          memoryControls: memoryControls,
        ),
        monthlySummary: monthlySummary,
        relationshipLifecycle: relationshipLifecycle,
      );
      final recovery = MemoryRecoveryService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        memoryControls: memoryControls,
        personaTree: personaTree,
        dreamService: dreamService,
        monthlySummary: monthlySummary,
        relationshipLifecycle: relationshipLifecycle,
        memoryActions: actions,
      );

      // 写入损坏的 open-loops.md
      final openLoopsFile = File(
        path.join(memoryDirectory, 'open-loops.md'),
      );
      await openLoopsFile.writeAsString('# open-loops\n- 损坏的内容没有时间戳');

      await recovery.sweepAndRecover();

      final service = MemoryCenterService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryControls: memoryControls,
        dreamService: dreamService,
        memoryRecovery: recovery,
      );
      final overview = await service.overview();
      expect(overview.recovery.healthy, isFalse);
      expect(overview.recovery.findings, isNotEmpty);
      expect(overview.recovery.quarantinedFiles, greaterThanOrEqualTo(1));
    },
  );
}

/// 播种一套覆盖四区的完整记忆：两日 episode（含证据、关系信号、
/// open-loop 候选与簿记留痕）、画像根与未归根中间理解、long-memory
/// 四分区、Dream 状态与受管 relationship。
Future<void> _seedFullMemory(DateTime now) async {
  final memoryDirectory = _currentTestDirectory;
  await _seedEpisodes(
    {
      '2026-08-16': [
        _entry(
          's1:r1:0',
          '用户睡前习惯听白噪音',
          evidence: '不听点声音睡不着',
          branch: 'preferences',
          nature: 'behavior',
          at: DateTime(2026, 8, 16, 22),
        ),
      ],
      '2026-08-17': [
        _entry(
          's2:r2:0',
          '用户说这周在准备演讲',
          evidence: '周四有个演讲，有点紧张',
          at: DateTime(2026, 8, 17, 20),
        ),
        _entry(
          's2:r2:1',
          '聊得比平时深一些',
          kind: episodeKindRelationshipSignal,
          signal: 'deep_talk',
          at: DateTime(2026, 8, 17, 20, 30),
        ),
        _entry(
          's2:r2:2',
          '继续跟进演讲准备的进展',
          kind: episodeKindOpenLoopCandidate,
          at: DateTime(2026, 8, 17, 20, 40),
        ),
        _entry(
          's2:r2:3',
          '冻结: 用户在准备演讲',
          kind: episodeKindOpenLoopEvent,
          at: DateTime(2026, 8, 17, 20, 50),
        ),
      ],
    },
    finalizedDates: {'2026-08-16': '聊了睡前习惯'},
  );

  // 画像：跨日两条一致证据形成中间理解；身份分支留一个待稳定事实；
  // 再用 Dream 提案把表达分支的理解升根。证据日期放在最近窗口之外，
  // 避免与「最近发生」区的断言纠缠。
  final pipeline = EpisodeMemoryPipeline(memoryDirectory: memoryDirectory);
  final personaTree = PersonaTreeStore(
    memoryDirectory: memoryDirectory,
    episodePipeline: pipeline,
  );
  await _seedEpisodes({
    '2026-07-10': [
      _entry(
        's3:r3:0',
        '被夸时用玩笑卸力',
        evidence: '被认真夸奖后马上自嘲',
        branch: 'expression',
        nature: 'behavior',
        at: DateTime(2026, 7, 10, 22),
      ),
      _entry(
        's3:r3:1',
        '用户是中学老师',
        branch: 'identity',
        nature: 'self_report',
        at: DateTime(2026, 7, 10, 22, 30),
      ),
    ],
    '2026-07-16': [
      _entry(
        's4:r4:0',
        '被夸时用玩笑卸力',
        branch: 'expression',
        nature: 'behavior',
        at: DateTime(2026, 7, 16, 22),
      ),
    ],
  });
  await personaTree.processDay('2026-07-10');
  await personaTree.processDay('2026-07-16');
  await personaTree.applyDreamChanges(
    date: '2026-08-16',
    ops: const [
      PersonaPromoteOp(
        'expression',
        claim: '用户尴尬时倾向自嘲',
        middleIds: ['EX-M001'],
      ),
    ],
  );

  File(path.join(memoryDirectory, 'long-memory.md')).writeAsStringSync(
    '# long-memory\n\n'
    '## 人与关系\n'
    '- 用户和家人关系亲近\n\n'
    '## 重要事件\n'
    '- 用户换过城市生活\n\n'
    '## 模式与轨迹\n'
    '- 2026年上半年从焦虑到平稳\n\n'
    '## 共同过往\n'
    '- 一起聊到过深夜\n',
  );
  Directory(path.join(memoryDirectory, 'dream')).createSync(recursive: true);
  final stateJson = {
    'schemaVersion': 1,
    'lastSuccess': '2026-08-16T14:00:00.000Z',
    'pending': false,
  };
  final stateToken = base64Url
      .encode(utf8.encode(jsonEncode(stateJson)))
      .replaceAll('=', '');
  File(path.join(memoryDirectory, 'dream', 'state.md')).writeAsStringSync(
    '# dream-state\n\n<!-- qiyu-dream-state:$stateToken -->\n',
  );
  File(path.join(memoryDirectory, 'relationship.md')).writeAsStringSync(
    '# relationship\n\n'
    'stage: 熟悉\n'
    'since: 2026-08-01\n'
    '阶段描述: 从初识进入熟悉\n\n'
    '## 当前相处方式\n'
    '已确认：\n'
    '- 可以自然提起说过的事\n\n'
    '## 近期变化\n'
    '- 聊得比平时深一些\n',
  );
}

/// 当前用例的记忆目录：setUp 里创建的临时目录。测试辅助函数通过
/// 顶层变量拿到它，避免层层传参。
late String _currentTestDirectory;

Future<void> _seedEpisodes(
  Map<String, List<EpisodeEntry>> entriesByDate, {
  Map<String, String> finalizedDates = const {},
}) async {
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: _currentTestDirectory,
  );
  for (final MapEntry(:key, :value) in entriesByDate.entries) {
    await pipeline.synchronizedOnDayFiles(
      () => pipeline.writeFinalization(
        key,
        entries: value,
        summary: finalizedDates[key] ?? value.first.summary,
        finalized: finalizedDates.containsKey(key),
        finalizedAt: finalizedDates.containsKey(key)
            ? DateTime.parse(key).add(const Duration(hours: 23))
            : null,
      ),
    );
  }
}

EpisodeEntry _entry(
  String id,
  String summary, {
  String? branch,
  String? nature,
  String? evidence,
  String? kind,
  String? signal,
  DateTime? at,
}) => EpisodeEntry(
  id: id,
  sessionId: 'seed-session',
  requestId: 'seed',
  summary: summary,
  evidence: evidence,
  at: (at ?? DateTime(2026, 8, 16, 22)).toUtc(),
  kind: kind ?? episodeKindMemory,
  personaBranch: branch,
  personaNature: nature,
  signal: signal,
);

Map<String, List<int>> _directorySnapshot(String root) {
  final snapshot = <String, List<int>>{};
  final directory = Directory(root);
  if (!directory.existsSync()) {
    return snapshot;
  }
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) {
      snapshot[path.relative(entity.path, from: root)] = entity
          .readAsBytesSync();
    }
  }
  return snapshot;
}
