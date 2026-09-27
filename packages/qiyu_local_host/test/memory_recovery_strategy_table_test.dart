import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

/// 票 11 新增用例：恢复策略表的「加一行＝挂新受保护层」演示，以及
/// 三条既有无独立断言的缺口（月压缩重建缺失分支、画像分支备份恢复
/// 后重跑控制、冻结内容随备份拼回）。既有 memory_recovery_test.dart
/// 的断言零修改，本文件只新增。
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
      'qiyu-recovery-table-test-',
    );
    memoryDirectory = temporaryDirectory.path;
    pipeline = EpisodeMemoryPipeline(
      memoryDirectory: memoryDirectory,
      clock: () => clock,
    );
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

  Future<void> overwrite(File file, String contents) async {
    await file.create(recursive: true);
    await file.writeAsString(contents, flush: true);
  }

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

  List<File> quarantineFiles() {
    final directory = Directory(
      path.join(memoryDirectory, 'recovery', 'quarantine'),
    );
    if (!directory.existsSync()) {
      return const [];
    }
    return directory.listSync().whereType<File>().toList();
  }

  Future<void> seedEpisodeDay(
    String date,
    List<EpisodeEntry> entries, {
    String? summary,
  }) => pipeline.synchronizedOnDayFiles(
    () => pipeline.writeFinalization(
      date,
      entries: entries,
      summary: summary,
      finalized: true,
      finalizedAt: DateTime.parse('${date}T23:00:00').toUtc(),
    ),
  );

  EpisodeEntry entry(String date, String id, String summary, {String? keep}) =>
      EpisodeEntry(
        id: id,
        sessionId: 'seed-session',
        requestId: 'seed',
        summary: summary,
        at: DateTime.parse('${date}T20:00:00').toUtc(),
        kind: episodeKindMemory,
        keep: keep,
      );

  group('策略表（票 11）', () {
    test('策略表加一行即可挂上新受保护层的恢复，走同一引擎路径', () async {
      // 对照：默认策略表不认识「手记」层，损坏文件原样保留，报告健康。
      final notes = File(path.join(memoryDirectory, 'notes.md'));
      await overwrite(notes, '# notes\n这条结构坏了\n');

      final baseline = await recovery.sweepAndRecover();
      expect(findByKey(baseline, 'notes'), isNull);
      expect(baseline.healthy, isTrue);
      expect(await notes.readAsString(), '# notes\n这条结构坏了\n');
      expect(quarantineFiles(), isEmpty);

      // 往表里追加一行「手记」策略：损坏判定 → 隔离 → 上报全部经
      // MemoryRecoveryRun 的共享样板原语，与内置层走同一引擎。
      final withNotes = MemoryRecoveryService(
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
        extraStrategies: [
          MemoryRecoveryStrategy.typed<_NotesDamage>(
            layerKey: 'notes',
            stepLabel: 'notes',
            dayLocked: false,
            detect: (run) async {
              final file = memoryFile(memoryDirectory, 'notes.md');
              if (!await file.exists()) {
                return null;
              }
              final contents = await readFileIfExists(file);
              final damaged = contents == null ||
                  (contents.trimLeft().startsWith('# notes') &&
                      !contents.contains('<!-- notes-ok -->'));
              return damaged ? (file: file) : null;
            },
            recover: (damage, run) async {
              await run.quarantineMove(damage.file, 'notes');
              run.findings.add(
                const MemoryRecoveryFinding(
                  layerKey: 'notes',
                  layer: '手记',
                  kind: MemoryDamageKind.corrupt,
                  outcome: MemoryRecoveryOutcome.partial,
                  loss: '手记内容',
                  quarantined: true,
                ),
              );
            },
          ),
        ],
      );

      final report = await withNotes.sweepAndRecover();

      // 上报：发现进入同一份报告管线。
      final finding = findByKey(report, 'notes');
      expect(finding, isNotNull);
      expect(finding!.layer, '手记');
      expect(finding.kind, MemoryDamageKind.corrupt);
      expect(finding.outcome, MemoryRecoveryOutcome.partial);
      expect(finding.quarantined, isTrue);
      expect(report.healthy, isFalse);

      // 隔离：走共享隔离原语，命名与内置层一致。
      expect(notes.existsSync(), isFalse);
      final quarantined = quarantineFiles();
      expect(quarantined, hasLength(1));
      expect(path.basename(quarantined.single.path), contains('__notes__'));

      // 持久化：报告可读、日志按统一格式落行。
      final persisted = await withNotes.readReport();
      expect(persisted, isNotNull);
      expect(findByKey(persisted!, 'notes'), isNotNull);
      final logFile = File(
        path.join(memoryDirectory, 'recovery', 'recovery.log'),
      );
      expect(await logFile.exists(), isTrue);
      expect(await logFile.readAsString(), contains('手记 | 部分恢复'));

      // 清单合并：第二轮扫描没有新损坏，但隔离原件仍持续可见，且
      // 走同一套层键 → 用户标签映射（未知层键退回「记忆文件」）。
      final second = await withNotes.sweepAndRecover();
      final inventory = findByKey(second, 'notes');
      expect(inventory, isNotNull);
      expect(inventory!.layer, '记忆文件');
      expect(inventory.loss, contains('隔离'));
      expect(inventory.quarantined, isTrue);
    });

    test('缺失的月摘要从同月每日记录重新压缩（月压缩重建缺口）', () async {
      // 既有用例只断言「存在但损坏」的月摘要重建；这里锁缺失分支：
      // 月度摘要整体丢失时按缺失重建。
      await seedEpisodeDay('2026-07-05', [
        entry('2026-07-05', 'e1', '用户去了海边', keep: memorySignalKeepMonth),
      ], summary: '海边');
      final summaryFile = monthlySummary.summaryFile('2026-07');
      expect(await summaryFile.exists(), isFalse);

      final report = await recovery.sweepAndRecover();

      final summary = await monthlySummary.readMonthSummary('2026-07');
      expect(summary, isNotNull);
      expect(summary!.readable, isTrue);
      expect(summary.items.map((item) => item.text), contains('用户去了海边'));
      final finding = findByKey(report, 'month-summary');
      expect(finding, isNotNull);
      expect(finding!.kind, MemoryDamageKind.missing);
      expect(finding.outcome, MemoryRecoveryOutcome.full);
      expect(finding.evidence, contains('重新压缩'));
      expect(quarantineFiles(), isEmpty);
      expect(report.healthy, isTrue);
    });

    test('画像分支从 Dream 备份恢复后重跑控制，被删除内容不随旧备份复活（备份恢复后重跑控制缺口）', () async {
      // 既有用例只覆盖长期印象备份恢复后的重跑控制；这里锁画像分支
      // 路径：restoreBackupFiles 的恢复同样要触发对现行控制的再清除。
      expect(await memoryControls.recordDelete('痛苦回忆', origin: 'user'), isTrue);
      // Dream 备份定格在删除之前：分支里仍有命中删除范围的未归类叶。
      const backupContent = '# 身份事实\n\n## 未归类叶\n'
          '- [ID-L001] 2026-08-05 | 明确自述 | support | 痛苦回忆的细节 | '
          'episodes/2026/08/2026-08-05.md [ID-M001]\n';
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
        backupContent,
      );
      // 现行画像分支损坏，触发备份恢复。
      await overwrite(
        File(path.join(memoryDirectory, 'persona-tree', 'identity.md')),
        '分支乱码',
      );

      final report = await recovery.sweepAndRecover();

      final finding = findByKey(report, 'persona-branch-identity');
      expect(finding, isNotNull);
      expect(finding!.outcome, MemoryRecoveryOutcome.full);
      expect(finding.evidence, contains('备份'));
      // 备份已恢复，但命中现行删除范围的叶必须被再次清除：该叶是
      // 分支里唯一内容，清除后分支为空、空分支不落盘（_writeBranch
      // 语义）。两种落点都不得再见被删内容。
      final restored = await readFileIfExists(
        File(path.join(memoryDirectory, 'persona-tree', 'identity.md')),
      );
      expect(restored ?? '', isNot(contains('痛苦回忆')));
      expect(quarantineFiles(), isEmpty);
    });

    test('冻结内容随 Dream 备份拼回长期印象，注入过滤继续拦截（Dream 冻结拼回缺口）', () async {
      // 冻结只停注入不清除：备份恢复把冻结内容如实拼回文件，控制
      // 记录与共享命中判定必须继续把它拦在注入之外。
      expect(await memoryControls.freeze('痛苦回忆', origin: 'user'), isTrue);
      // Dream 备份定格在冻结之后：长期印象仍带该条目（冻结不清除原文）。
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
      expect(finding.evidence, contains('备份'));
      // 拼回：冻结不清除，内容保留在长期印象里等待解除冻结。
      final restored = await File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).readAsString();
      expect(parseLongMemory(restored).readable, isTrue);
      expect(restored, contains('痛苦回忆的细节'));
      expect(restored, contains('一条正常印象'));
      expect(quarantineFiles(), isEmpty);
      // 控制记录完好，注入侧共享命中判定继续覆盖冻结范围。
      final controls = await memoryControls.load();
      expect(controls.frozenSummaries, contains('痛苦回忆'));
      expect(
        bannedMemoryText('痛苦回忆的细节', controls.controlledSummaries),
        isTrue,
      );
      expect(
        bannedMemoryText('一条正常印象', controls.controlledSummaries),
        isFalse,
      );
    });
  });
}

/// 演示行「手记」层的损坏证据。
typedef _NotesDamage = ({File file});
