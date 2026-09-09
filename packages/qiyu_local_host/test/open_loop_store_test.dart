import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  test('promotes validated candidates with stable ids and four fields', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-promote-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);

    final promoted = await store.promoteCandidates([
      _candidate(
        id: 'entry-1',
        title: '人生第一次演讲',
        due: '2026-08-20 晚上',
        proactive: 'once',
        note: '用户说这是人生第一次演讲',
      ),
      _candidate(id: 'entry-2', title: '医院检查', proactive: 'no'),
    ]);

    expect(promoted, 2);
    final contents = await File(
      '${temporaryDirectory.path}/open-loops.md',
    ).readAsString(encoding: utf8);
    expect(contents, contains('- [o1] 人生第一次演讲'));
    expect(contents, contains('due: 2026-08-20 晚上'));
    expect(contents, contains('proactive: once'));
    expect(contents, contains('status: active'));
    expect(contents, contains('note: 用户说这是人生第一次演讲'));
    expect(contents, contains('- [o2] 医院检查'));
    expect(contents, contains('proactive: no'));
    expect(contents, isNot(contains('o3')));
  });

  test('repeated end-of-day runs never duplicate the same matter', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-dedupe-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    final candidates = [
      _candidate(id: 'entry-1', title: '下周搬家'),
      _candidate(id: 'entry-2', title: '下周搬家'),
    ];

    await store.promoteCandidates(candidates);
    final replay = await store.promoteCandidates([
      _candidate(id: 'entry-3', title: '下周搬家'),
    ]);

    expect(replay, 0);
    final contents = await File(
      '${temporaryDirectory.path}/open-loops.md',
    ).readAsString(encoding: utf8);
    expect('下周搬家'.allMatches(contents).length, 1);
  });

  test('banned matters are removed at once and can never be re-promoted', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-ban-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    await store.promoteCandidates([
      _candidate(id: 'entry-1', title: '医院检查'),
    ]);

    final banned = await store.banTitle('医院检查');

    expect(banned, isTrue);
    expect(await store.readItems(), isEmpty);
    final controls = await File(
      '${temporaryDirectory.path}/memory-controls.md',
    ).readAsString(encoding: utf8);
    expect(controls, contains('# memory-controls'));
    expect(controls, contains('## banned'));
    expect(controls, contains('- [MC001] open-loop | 医院检查'));

    // 幂等：重复禁提不产生重复控制记录。
    await store.banTitle('医院检查');
    final controlsAgain = await File(
      '${temporaryDirectory.path}/memory-controls.md',
    ).readAsString(encoding: utf8);
    expect('MC001'.allMatches(controlsAgain).length, 1);

    // 后续整理不得重新激活。
    final promoted = await store.promoteCandidates([
      _candidate(id: 'entry-2', title: '医院检查'),
    ]);
    expect(promoted, 0);
    expect(await store.readItems(), isEmpty);
  });

  test('a ban is all-or-nothing when controls are unrecognizable', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-ban-blocked-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    const foreign = '这是用户自己写的备忘，不是记忆控制文件。\n';
    File('${temporaryDirectory.path}/memory-controls.md').writeAsStringSync(
      foreign,
      encoding: utf8,
    );
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    await store.promoteCandidates([
      _candidate(id: 'entry-1', title: '医院检查'),
    ]);

    // controls 不可识别：禁提整体不生效，热层原样保留——
    // 绝不出现「事项移走了、控制记录却没留下」的可复活空洞。
    expect(await store.banTitle('医院检查'), isFalse);
    expect(await store.readItems(), hasLength(1));
    expect(
      File('${temporaryDirectory.path}/memory-controls.md')
          .readAsStringSync(encoding: utf8),
      foreign,
    );
  });

  test('status changes apply immediately and are idempotent', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-status-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    await store.promoteCandidates([
      _candidate(
        id: 'entry-1',
        title: '人生第一次演讲',
        proactive: 'once',
        note: '用户说这是人生第一次演讲',
      ),
    ]);

    expect(
      await store.applyStatusChange(title: '人生第一次演讲', status: 'paused'),
      isTrue,
    );
    expect(
      (await store.readItems())!.single.status,
      OpenLoopStatus.paused,
    );

    // 用户重新提起：paused 回到 active。
    expect(
      await store.applyStatusChange(title: '人生第一次演讲', status: 'active'),
      isTrue,
    );
    expect(
      (await store.readItems())!.single.status,
      OpenLoopStatus.active,
    );

    expect(
      await store.applyStatusChange(title: '人生第一次演讲', status: 'closed'),
      isTrue,
    );
    final item = (await store.readItems())!.single;
    expect(item.status, OpenLoopStatus.closed);
    // note 与其余字段在状态改写中保持原样。
    expect(item.note, '用户说这是人生第一次演讲');
    expect(item.proactive, OpenLoopProactive.once);

    // 未知事项静默跳过。
    expect(
      await store.applyStatusChange(title: '不存在的事', status: 'closed'),
      isFalse,
    );
  });

  test('closed entries are archived with item, date and result', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-archive-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    await store.promoteCandidates([
      _candidate(id: 'entry-1', title: '人生第一次演讲', note: '演讲很顺利'),
      _candidate(id: 'entry-2', title: '背单词打卡', proactive: 'yes'),
    ]);
    await store.applyStatusChange(title: '人生第一次演讲', status: 'closed');

    final moved = await store.archiveClosed('2026-08-16');

    expect(moved, 1);
    final hotLayer = await File(
      '${temporaryDirectory.path}/open-loops.md',
    ).readAsString(encoding: utf8);
    expect(hotLayer, isNot(contains('人生第一次演讲')));
    expect(hotLayer, contains('- [o2] 背单词打卡'));
    final archive = await File(
      '${temporaryDirectory.path}/open-loops.archive.md',
    ).readAsString(encoding: utf8);
    expect(archive, contains('- 人生第一次演讲 | 闭环: 2026-08-16 | 演讲很顺利'));

    // 重复归档幂等。
    expect(await store.archiveClosed('2026-08-16'), 0);
    final archiveAgain = await File(
      '${temporaryDirectory.path}/open-loops.archive.md',
    ).readAsString(encoding: utf8);
    expect(archiveAgain, archive);
  });

  test('stale loops expire after the window; fresh or undated loops stay', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-expiry-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    await store.promoteCandidates([
      _candidate(id: 'entry-1', title: '早已过期的事项', due: '2026-07-01'),
      _candidate(id: 'entry-2', title: '昨天才到期', due: '2026-08-15'),
      _candidate(id: 'entry-3', title: '没有时间的约定'),
    ]);

    final expired = await store.expireStale(DateTime(2026, 8, 16, 22));

    expect(expired, 1);
    final remaining = (await store.readItems())!;
    expect(remaining.map((item) => item.title), ['昨天才到期', '没有时间的约定']);
    final archive = await File(
      '${temporaryDirectory.path}/open-loops.archive.md',
    ).readAsString(encoding: utf8);
    expect(archive, contains('- 早已过期的事项 | 闭环: 2026-08-16 | 过期'));
  });

  test('due arrival respects date and time-of-day', () {
    final evening = DateTime(2026, 8, 16, 20);
    expect(loopDueArrived('2026-08-15', evening), isTrue);
    expect(loopDueArrived('2026-08-17', evening), isFalse);
    expect(loopDueArrived('2026-08-16 晚上', DateTime(2026, 8, 16, 15)), isFalse);
    expect(loopDueArrived('2026-08-16 晚上', evening), isTrue);
    expect(loopDueArrived('2026-08-16 evening', evening), isTrue);
    expect(loopDueArrived('2026-08-16', evening), isTrue);
    expect(loopDueArrived(null, evening), isTrue);
    expect(loopDueArrived('无效日期', evening), isFalse);
  });

  test('proactive gate follows stage table and field rules', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-gate-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    await store.promoteCandidates([
      _candidate(id: 'a', title: '到点的活动', due: '2026-08-15'),
      _candidate(id: 'b', title: '敏感事项', due: '2026-08-15', proactive: 'no'),
      _candidate(id: 'c', title: '还没到点', due: '2026-09-01'),
    ]);
    await store.promoteCandidates([
      _candidate(id: 'd', title: '暂停的事项', due: '2026-08-15'),
    ]);
    await store.applyStatusChange(title: '暂停的事项', status: 'paused');
    final now = DateTime(2026, 8, 16, 22);

    expect(stageAllowsProactive(RelationshipStage.stranger), isFalse);
    expect(stageAllowsProactive(RelationshipStage.familiar), isTrue);
    // 初识：候选池为空（不主动翻旧事）。
    expect(
      await store.proactiveCandidates(now, RelationshipStage.stranger),
      isEmpty,
    );
    // 熟悉：只有 active、允许主动且 due 已到的事项进入候选池。
    final candidates = await store.proactiveCandidates(
      now,
      RelationshipStage.familiar,
    );
    expect(candidates.map((item) => item.title), ['到点的活动']);
  });

  test('a hand-written open-loops file is never rewritten', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-foreign-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    const foreign = '# open-loops\n\n这是用户自己写的清单，别动它。\n';
    File('${temporaryDirectory.path}/open-loops.md').writeAsStringSync(
      foreign,
      encoding: utf8,
    );
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);

    expect(await store.readItems(), isNull);
    expect(await store.promoteCandidates([_candidate(id: 'x', title: '新事项')]), 0);
    expect(await store.archiveClosed('2026-08-16'), 0);
    expect(await store.expireStale(DateTime(2026, 9, 30)), 0);
    expect(await store.applyStatusChange(title: '新事项', status: 'closed'), isFalse);
    expect(
      File('${temporaryDirectory.path}/open-loops.md')
          .readAsStringSync(encoding: utf8),
      foreign,
    );
  });

  test('a fresh store instance resumes from persisted markdown', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-restart-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final first = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    await first.promoteCandidates([
      _candidate(id: 'entry-1', title: '跨重启的事项', due: '2026-08-20'),
    ]);

    // 模拟 Host 重启。
    final second = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    final items = await second.readItems();
    expect(items, hasLength(1));
    expect(items!.single.title, '跨重启的事项');

    // 重启后继续提升：编号接着走，不覆盖既有条目。
    await second.promoteCandidates([
      _candidate(id: 'entry-2', title: '重启后的新事项'),
    ]);
    final titles = (await second.readItems())!
        .map((item) => '${item.id}:${item.title}');
    expect(titles, ['o1:跨重启的事项', 'o2:重启后的新事项']);
  });

  test('budget keeps the hot layer within the designed token cap', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-loop-budget-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final store = OpenLoopStore(memoryDirectory: temporaryDirectory.path);
    final longNote = '背' * 100;

    await store.promoteCandidates([
      _candidate(id: 'a', title: '第一件大事', note: longNote),
      _candidate(id: 'b', title: '第二件大事', note: longNote),
      _candidate(id: 'c', title: '第三件大事', note: longNote),
    ]);

    final contents = await File(
      '${temporaryDirectory.path}/open-loops.md',
    ).readAsString(encoding: utf8);
    expect(contents.runes.length, lessThanOrEqualTo(openLoopsMaxRunes));
    final items = await store.readItems();
    expect(items!.length, lessThan(3));
    expect(items.isNotEmpty, isTrue);
  });
}

EpisodeEntry _candidate({
  required String id,
  required String title,
  String? due,
  String? proactive,
  String? note,
}) => EpisodeEntry(
  id: 'session-1:$id:0',
  sessionId: 'session-1',
  requestId: id,
  summary: title,
  at: DateTime(2026, 8, 16, 22).toUtc(),
  kind: episodeKindOpenLoopCandidate,
  due: due,
  proactive: proactive,
  note: note,
);
