import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('leaves store only pointer info, never the raw evidence text', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-leaf-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(root.path);

    await store.createLeaves([
      _entry(
        's1:r1:0',
        '用户养了一只叫米子的猫',
        branch: 'identity',
        nature: 'self_report',
        evidence: '我家米子最近老是半夜跑酷',
      ),
    ]);

    final contents = _readBranch(root.path, 'identity.md');
    expect(contents, isNotNull);
    // 定稿六项：稳定 ID、日期、来源性质、关系、摘要、episode 指针。
    expect(
      contents,
      contains(
        '- [ID-L001] 2026-08-16 | 明确自述 | support | 用户养了一只叫米子的猫'
        ' | episodes/2026/08/2026-08-16.md [s1:r1:0]',
      ),
    );
    // 叶是指针不是副本：原话摘录不进树。
    expect(contents, isNot(contains('半夜跑酷')));
    // 未归类叶区等待日终归类。
    expect(contents, contains('## 未归类叶'));
  });

  test('same-day similar signals merge; the same entry never duplicates', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-dup-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(root.path);
    final entries = [
      _entry(
        's1:r1:0',
        '用户睡前习惯听白噪音',
        branch: 'preferences',
        nature: 'behavior',
      ),
      _entry(
        's1:r1:1',
        '用户睡前习惯听白噪音',
        branch: 'preferences',
        nature: 'behavior',
      ),
    ];

    await store.createLeaves(entries);
    // 同一批条目再次处理（重试/重复投递）不产生重复叶。
    await store.createLeaves(entries);

    final contents = _readBranch(root.path, 'preferences.md')!;
    expect('[PR-L'.allMatches(contents).length, 1);
  });

  test('cross-day repeat evidence forms a middle; single-day behavior does not', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-middle-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(root.path);
    final day1 = [
      _entry(
        's1:r1:0',
        '被夸时用玩笑卸力',
        branch: 'expression',
        nature: 'behavior',
        at: DateTime(2026, 8, 2, 22),
      ),
    ];
    final day2 = [
      _entry(
        's2:r2:0',
        '被夸时用玩笑卸力',
        branch: 'expression',
        nature: 'behavior',
        at: DateTime(2026, 8, 9, 22),
      ),
    ];
    await _seedEpisodes(root.path, {'2026-08-02': day1, '2026-08-09': day2});

    // 只有一天证据时不足以形成中间理解（单轮/临时表现不成人格结论）。
    await store.processDay('2026-08-02');
    final early = _readBranch(root.path, 'expression.md')!;
    expect(early, contains('## 未归类叶'));
    expect(early, isNot(contains('重复模式')));

    // 跨日期第二条一致证据出现后，日终才建立重复模式。
    await store.processDay('2026-08-09');
    final contents = _readBranch(root.path, 'expression.md')!;
    expect(contents, contains('### [EX-M001] 重复模式｜被夸时用玩笑卸力'));
    expect(contents, contains('- 形成: 2026-08-09 · 复核: 2026-08-09'));
    expect(contents, contains('[EX-L001] 2026-08-02'));
    expect(contents, contains('[EX-L002] 2026-08-09'));
    expect(contents, isNot(contains('## 未归类叶')));
  });

  test('one self-reported identity leaf forms a pending fact; behavior never does', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-identity-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(root.path);
    await _seedEpisodes(root.path, {
      '2026-08-02': [
        _entry(
          's1:r1:0',
          '用户是中学老师',
          branch: 'identity',
          nature: 'self_report',
          at: DateTime(2026, 8, 2, 22),
        ),
      ],
    });

    await store.processDay('2026-08-02');
    final contents = _readBranch(root.path, 'identity.md')!;
    expect(contents, contains('### [ID-M001] 待稳定事实｜用户是中学老师'));
    expect(contents, contains('明确自述'));

    // 身份事实禁止行为推断：即使绕过隐藏动作层，树这边也不建叶。
    await store.createLeaves([
      _entry(
        's2:r2:0',
        '用户像是经常熬夜的人',
        branch: 'identity',
        nature: 'behavior',
      ),
    ]);
    expect(
      _readBranch(root.path, 'identity.md')!,
      isNot(contains('经常熬夜')),
    );
  });

  test('contradicting evidence coexists as a conflict leaf instead of overwriting', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-conflict-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(root.path);
    await _seedEpisodes(root.path, {
      '2026-08-02': [
        _entry(
          's1:r1:0',
          '用户靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 2, 22),
        ),
      ],
      '2026-08-09': [
        _entry(
          's2:r2:0',
          '用户靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 9, 22),
        ),
      ],
      '2026-08-12': [
        _entry(
          's3:r3:0',
          '用户不靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 12, 22),
        ),
      ],
    });
    await store.processDay('2026-08-02');
    await store.processDay('2026-08-09');

    // 第一条反向证据：挂在原理解下成为 conflict 叶，理解本身保留。
    await store.processDay('2026-08-12');
    final contents = _readBranch(root.path, 'expression.md')!;
    expect(contents, contains('### [EX-M001] 重复模式｜用户靠跑步解压'));
    expect('[EX-L'.allMatches(contents).length, 3);
    expect('| support |'.allMatches(contents).length, 2);
    expect(contents, contains('| conflict |'));
    // 新证据到来即复核（置信下降可追溯）。
    expect(contents, contains('- 形成: 2026-08-09 · 复核: 2026-08-12'));
  });

  test('a second conflict on another date forms an opposing middle understanding', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-opposing-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(root.path);
    await _seedEpisodes(root.path, {
      '2026-08-02': [
        _entry(
          's1:r1:0',
          '用户靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 2, 22),
        ),
      ],
      '2026-08-09': [
        _entry(
          's2:r2:0',
          '用户靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 9, 22),
        ),
      ],
      '2026-08-12': [
        _entry(
          's3:r3:0',
          '用户不靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 12, 22),
        ),
      ],
      '2026-08-13': [
        _entry(
          's4:r4:0',
          '用户不再靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 13, 22),
        ),
      ],
    });
    for (final date in ['2026-08-02', '2026-08-09', '2026-08-12']) {
      await store.processDay(date);
    }
    await store.processDay('2026-08-13');

    final contents = _readBranch(root.path, 'expression.md')!;
    // 旧理解保留仍成立的支持证据；两条反向证据组成新的反向理解。
    expect(contents, contains('### [EX-M001] 重复模式｜用户靠跑步解压'));
    expect(contents, contains('### [EX-M002] 重复模式｜用户不再靠跑步解压'));
    final opposingBlock = contents.substring(
      contents.indexOf('### [EX-M002]'),
    );
    expect(opposingBlock, contains('[EX-L003]'));
    expect(opposingBlock, contains('[EX-L004]'));
    expect(opposingBlock, isNot(contains('| conflict |')));
  });

  test('an explicit identity correction revokes the old understanding with archive trace', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-correct-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(root.path);
    await _seedEpisodes(root.path, {
      '2026-07-01': [
        _entry(
          's1:r1:0',
          '用户是中学老师',
          branch: 'identity',
          nature: 'self_report',
          at: DateTime(2026, 7, 1, 22),
        ),
      ],
      '2026-07-02': [
        _entry(
          's2:r2:0',
          '用户不是中学老师',
          branch: 'identity',
          nature: 'self_report',
          at: DateTime(2026, 7, 2, 22),
        ),
      ],
    });
    await store.processDay('2026-07-01');
    expect(
      _readBranch(root.path, 'identity.md'),
      contains('### [ID-M001] 待稳定事实｜用户是中学老师'),
    );

    await store.processDay('2026-07-02');

    // 最新明确陈述胜出：旧理解移出活跃分支，新说法用全新 ID。
    final active = _readBranch(root.path, 'identity.md')!;
    expect(active, isNot(contains('ID-M001')));
    expect(active, contains('### [ID-M002] 待稳定事实｜用户不是中学老师'));
    // 归档保留失效元数据与原关联叶，供追溯但不参与注入。
    final archive = _readBranch(
      root.path,
      path.join('archive', 'identity.md'),
    )!;
    expect(archive, contains('### [ID-M001] 待稳定事实｜用户是中学老师'));
    expect(archive, contains('- 失效: 2026-07-02 · 原因: 明确纠正 · 关联: ID-L001'));
    expect(archive, contains('[ID-L001]'));
  });

  test('a user ban outranks extraction: banned content is deleted, not archived', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-ban-');
    addTearDown(() => root.delete(recursive: true));
    final openLoopStore = OpenLoopStore(memoryDirectory: root.path);
    final store = _store(root.path, openLoopStore: openLoopStore);
    await _seedEpisodes(root.path, {
      '2026-08-02': [
        _entry(
          's1:r1:0',
          '用户靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 2, 22),
        ),
      ],
      '2026-08-09': [
        _entry(
          's2:r2:0',
          '用户靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 9, 22),
        ),
      ],
    });
    await store.processDay('2026-08-02');
    await store.processDay('2026-08-09');
    expect(
      _readBranch(root.path, 'expression.md'),
      contains('### [EX-M001] 重复模式｜用户靠跑步解压'),
    );

    expect(await openLoopStore.banTitle('跑步解压'), isTrue);
    expect(await store.applyBan('跑步解压'), isTrue);

    // 禁提内容连理解带叶彻底删除，且不进归档（不得留下可复活的副本）。
    expect(_readBranch(root.path, 'expression.md'), isNull);
    expect(
      _readBranch(root.path, path.join('archive', 'expression.md')),
      isNull,
    );

    // 禁提之后同一话题再来，也不再提炼。
    await store.createLeaves([
      _entry(
        's3:r3:0',
        '用户靠跑步解压了',
        branch: 'expression',
        nature: 'behavior',
      ),
    ]);
    expect(_readBranch(root.path, 'expression.md'), isNull);
  });

  test('secrets are redacted before becoming leaf summaries', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-secret-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(root.path);

    await store.createLeaves([
      _entry(
        's1:r1:0',
        'api_key: sk-abcdefghijklmnopqrst 的事',
        branch: 'preferences',
        nature: 'self_report',
      ),
    ]);

    final contents = _readBranch(root.path, 'preferences.md')!;
    expect(contents, isNot(contains('sk-abcdefghijklmnopqrst')));
    expect(contents, contains('[已脱敏]'));
  });

  test('a fresh store rebuilds the same tree from episodes across restarts', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-rebuild-');
    addTearDown(() => root.delete(recursive: true));
    await _seedEpisodes(root.path, {
      '2026-08-02': [
        _entry(
          's1:r1:0',
          '被夸时用玩笑卸力',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 2, 22),
        ),
      ],
      '2026-08-09': [
        _entry(
          's2:r2:0',
          '被夸时用玩笑卸力',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 9, 22),
        ),
      ],
    });

    final first = _store(root.path);
    await first.processDay('2026-08-02');
    await first.processDay('2026-08-09');
    final original = _readBranch(root.path, 'expression.md')!;

    // 同实例重复日终幂等：不重复建叶、不重复建理解。
    await first.processDay('2026-08-09');
    expect(_readBranch(root.path, 'expression.md'), original);

    // 树文件丢失后，新实例从 episodes 原始证据重建出同样的树。
    Directory(path.join(root.path, 'persona-tree')).deleteSync(
      recursive: true,
    );
    final second = _store(root.path);
    await second.processDay('2026-08-02');
    await second.processDay('2026-08-09');
    expect(_readBranch(root.path, 'expression.md'), original);
  });

  test('day-end finalization runs PersonaTree maintenance as step six', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-finalize-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    final service = DailyFinalizationService(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
    );
    await pipeline.synchronizedOnDayFiles(
      () => pipeline.writeFinalization(
        '2026-08-09',
        entries: [
          _entry(
            's1:r1:0',
            '用户是中学老师',
            branch: 'identity',
            nature: 'self_report',
            at: DateTime(2026, 8, 9, 22),
          ),
        ],
        finalized: false,
      ),
    );

    final outcome = await service.finalizeDay('2026-08-09');
    expect(outcome.status, FinalizationStatus.finalized);
    expect(
      _readBranch(root.path, 'identity.md'),
      contains('### [ID-M001] 待稳定事实｜用户是中学老师'),
    );
  });

  test('an unreadable branch file is preserved, never overwritten', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-corrupt-');
    addTearDown(() => root.delete(recursive: true));
    final diagnostics = <String>[];
    final store = _store(root.path, diagnostics: diagnostics);
    final file = File(path.join(root.path, 'persona-tree', 'identity.md'));
    file.createSync(recursive: true);
    file.writeAsStringSync('用户手写的笔记，不是栖语格式。');

    await store.createLeaves([
      _entry(
        's1:r1:0',
        '用户是中学老师',
        branch: 'identity',
        nature: 'self_report',
      ),
    ]);

    expect(file.readAsStringSync(), '用户手写的笔记，不是栖语格式。');
    expect(
      diagnostics.join('\n'),
      contains('persona leaves skipped reason=identity-unreadable'),
    );
  });

  test('entries with unsafe identifiers never become leaf pointers', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-ref-');
    addTearDown(() => root.delete(recursive: true));
    final diagnostics = <String>[];
    final store = _store(root.path, diagnostics: diagnostics);

    await store.createLeaves([
      _entry(
        'bad]id | [x',
        '用户是中学老师',
        branch: 'identity',
        nature: 'self_report',
      ),
    ]);

    // 条目号会破坏叶行解析：不建叶、不留半份文件，只记诊断。
    expect(_readBranch(root.path, 'identity.md'), isNull);
    expect(diagnostics.join('\n'), contains('reason=unsafe-entry-ref'));
  });

  test('a middle understanding missing meta lines survives a rewrite', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-meta-');
    addTearDown(() => root.delete(recursive: true));
    final diagnostics = <String>[];
    final store = _store(root.path, diagnostics: diagnostics);
    final file = File(path.join(root.path, 'persona-tree', 'expression.md'));
    file.createSync(recursive: true);
    // 手改文件少了「形成/复核」元数据行：解析要宽容，回写不得
    // 产出空日期行把文件变成永久不可读。
    file.writeAsStringSync('''# 性格表达

## 未归根中间节点

### [EX-M001] 重复模式｜被夸时用玩笑卸力
- [EX-L001] 2026-08-02 | 行为观察 | support | 被夸时用玩笑卸力 | episodes/2026/08/2026-08-02.md [m1]
''');

    await store.createLeaves([
      _entry(
        's1:r1:0',
        '用户养了一只叫米子的猫',
        branch: 'expression',
        nature: 'behavior',
      ),
    ]);

    final rewritten = file.readAsStringSync();
    expect(rewritten, contains('### [EX-M001] 重复模式｜被夸时用玩笑卸力'));
    expect(rewritten, isNot(contains('形成:  · 复核')));

    // 回写后仍可解析：日终照常运行，分支不被锁死。
    await _seedEpisodes(root.path, {
      '2026-08-16': [
        _entry(
          's2:r2:0',
          '用户养了一只叫米子的猫',
          branch: 'expression',
          nature: 'behavior',
        ),
      ],
    });
    await store.processDay('2026-08-16');
    expect(diagnostics.join('\n'), isNot(contains('unreadable')));
    expect(
      file.readAsStringSync(),
      contains('### [EX-M001] 重复模式｜被夸时用玩笑卸力'),
    );
  });

  test('default-wired finalization still honors bans in the persona sweep', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-defban-');
    addTearDown(() => root.delete(recursive: true));
    final pipeline = EpisodeMemoryPipeline(memoryDirectory: root.path);
    // 两个组件都不显式传入：全部默认接线。禁提清扫必须仍然生效，
    // 而不是因 PersonaTree 拿不到禁提列表静默失效。
    final service = DailyFinalizationService(
      memoryDirectory: root.path,
      episodePipeline: pipeline,
      clock: () => DateTime(2026, 8, 9, 23),
    );
    final loops = OpenLoopStore(memoryDirectory: root.path);
    expect(await loops.banTitle('跑步解压'), isTrue);
    await _seedEpisodes(root.path, {
      '2026-08-02': [
        _entry(
          's1:r1:0',
          '用户靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 2, 22),
        ),
      ],
      '2026-08-09': [
        _entry(
          's2:r2:0',
          '用户靠跑步解压',
          branch: 'expression',
          nature: 'behavior',
          at: DateTime(2026, 8, 9, 22),
        ),
      ],
    });

    expect(
      (await service.finalizeDay('2026-08-02')).status,
      FinalizationStatus.finalized,
    );
    expect(
      (await service.finalizeDay('2026-08-09')).status,
      FinalizationStatus.finalized,
    );
    expect(_readBranch(root.path, 'expression.md'), isNull);
  });

  test('root blocks pass through untouched while new leaves are appended', () async {
    final root = await Directory.systemTemp.createTemp('qiyu-persona-roots-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(root.path);
    final file = File(path.join(root.path, 'persona-tree', 'identity.md'));
    file.createSync(recursive: true);
    file.writeAsStringSync('''# 身份事实

## [ID-R001] 用户是中学老师

### [ID-M001] 待稳定事实｜用户是中学老师
- [ID-L001] 2026-07-01 | 明确自述 | support | 用户是中学老师 | episodes/2026/07/2026-07-01.md [m1]
''');

    await store.createLeaves([
      _entry(
        's1:r1:0',
        '用户养了一只叫米子的猫',
        branch: 'identity',
        nature: 'self_report',
      ),
    ]);

    final contents = file.readAsStringSync();
    // 根节点归 Dream 维护：日终链路只透传，不创建、不修改根。
    expect(contents, contains('## [ID-R001] 用户是中学老师'));
    expect(contents, contains('[ID-L001] 2026-07-01'));
    expect(contents, contains('## 未归类叶'));
    // 新叶 ID 不与根下已有节点序号冲突（L001 已用，新叶为 L002）。
    expect(contents, contains('[ID-L002]'));
    // 已挂在根下的条目再来不重复建叶。
    await store.createLeaves([
      _entry(
        'm1',
        '用户是中学老师',
        branch: 'identity',
        nature: 'self_report',
      ),
    ]);
    expect('[ID-L'.allMatches(file.readAsStringSync()).length, 2);
  });
}

Future<void> _seedEpisodes(
  String memoryDirectory,
  Map<String, List<EpisodeEntry>> entriesByDate,
) async {
  final pipeline = EpisodeMemoryPipeline(memoryDirectory: memoryDirectory);
  for (final MapEntry(:key, :value) in entriesByDate.entries) {
    await pipeline.synchronizedOnDayFiles(
      () => pipeline.writeFinalization(
        key,
        entries: value,
        summary: value.first.summary,
        finalized: false,
      ),
    );
  }
}

PersonaTreeStore _store(
  String memoryDirectory, {
  OpenLoopStore? openLoopStore,
  List<String>? diagnostics,
}) => PersonaTreeStore(
  memoryDirectory: memoryDirectory,
  episodePipeline: EpisodeMemoryPipeline(memoryDirectory: memoryDirectory),
  openLoopStore: openLoopStore,
  diagnosticsSink: diagnostics == null ? (_) {} : diagnostics.add,
);

String? _readBranch(String memoryDirectory, String relative) {
  final file = File(path.join(memoryDirectory, 'persona-tree', relative));
  if (!file.existsSync()) {
    return null;
  }
  return file.readAsStringSync();
}

EpisodeEntry _entry(
  String id,
  String summary, {
  String? branch,
  String? nature,
  String? evidence,
  DateTime? at,
}) => EpisodeEntry(
  id: id,
  sessionId: 'seed',
  requestId: 'seed',
  summary: summary,
  evidence: evidence,
  at: (at ?? DateTime(2026, 8, 16, 22)).toUtc(),
  personaBranch: branch,
  personaNature: nature,
);
