import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'dream.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_actions.dart';
import 'memory_controls.dart';
import 'memory_marker_codec.dart';
import 'memory_text_primitives.dart';
import 'monthly_summary.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'relationship_lifecycle.dart';

/// 损坏类型（ticket 21 / T26 定稿）：启动与读取时必须区分的五类。
/// 语义冲突不算损坏，仍走事实与纠错规则。
enum MemoryDamageKind {
  /// 应存在却缺失。
  missing('缺失'),

  /// 派生层落后于下层证据，可容忍，重建即愈。
  stale('可容忍旧版本'),

  /// 编码失败、元数据标记破坏或结构解析失败。
  corrupt('语法损坏'),

  /// 元数据可读但内容结构被截断、必需字段丢失。
  incomplete('内容不完整'),

  /// 引用指向已不存在的对象（索引行指向缺失日文件、检查点指向
  /// 缺失会话）。
  orphaned('引用失效');

  const MemoryDamageKind(this.label);

  final String label;
}

/// 单项恢复结果。绝不显示虚假成功：无法从证据重建的内容明确报
/// [pending]，隔离原件保留。
enum MemoryRecoveryOutcome {
  /// 已从可信下层完整重建，功能与内容无损。
  full('完整恢复'),

  /// 部分重建成功，仍有损失；隔离原件必须保留并提示用户。
  partial('部分恢复'),

  /// 无可信证据来源（或需要语义恢复），内容暂不可用。
  pending('待恢复');

  const MemoryRecoveryOutcome(this.label);

  final String label;
}

/// 一条恢复发现：用户可见的层标签、损坏类型、结果、采用的证据与
/// 仍无法恢复的内容。只含抽象描述，绝不含记忆正文。
final class MemoryRecoveryFinding {
  const MemoryRecoveryFinding({
    required this.layerKey,
    required this.layer,
    required this.kind,
    required this.outcome,
    this.evidence,
    this.loss,
    this.quarantined = false,
    this.loggable = true,
  });

  /// 机器标识（隔离清单合并用），不进用户文案。
  final String layerKey;

  /// 用户语言标签，如「每日记录（2026-07-02）」。
  final String layer;
  final MemoryDamageKind kind;
  final MemoryRecoveryOutcome outcome;

  /// 采用的证据来源（抽象描述）。
  final String? evidence;

  /// 仍无法恢复的内容（抽象描述）；null 表示无损失。
  final String? loss;

  /// 是否有隔离原件保留。
  final bool quarantined;

  /// 是否写入 recovery.log（隔离清单合成的持续性条目不重复记日志）。
  final bool loggable;

  Map<String, Object?> toJson() => {
    'layerKey': layerKey,
    'layer': layer,
    'kind': kind.name,
    'outcome': outcome.name,
    if (evidence != null) 'evidence': evidence,
    if (loss != null) 'loss': loss,
    'quarantined': quarantined,
  };

  static MemoryRecoveryFinding? fromJson(Map<String, Object?> json) {
    final layerKey = json['layerKey'];
    final layer = json['layer'];
    final kindName = json['kind'];
    final outcomeName = json['outcome'];
    if (layerKey is! String || layer is! String) {
      return null;
    }
    final kind = MemoryDamageKind.values
        .where((candidate) => candidate.name == kindName)
        .firstOrNull;
    final outcome = MemoryRecoveryOutcome.values
        .where((candidate) => candidate.name == outcomeName)
        .firstOrNull;
    if (kind == null || outcome == null) {
      return null;
    }
    return MemoryRecoveryFinding(
      layerKey: layerKey,
      layer: layer,
      kind: kind,
      outcome: outcome,
      evidence: json['evidence'] as String?,
      loss: json['loss'] as String?,
      quarantined: json['quarantined'] == true,
      loggable: false,
    );
  }
}

/// 一次恢复扫描的完整报告：持久化在 `recovery/report.md`，记忆中心
/// 只读呈现。
final class MemoryRecoveryReport {
  const MemoryRecoveryReport({
    required this.generatedAt,
    required this.findings,
    required this.quarantinedFiles,
  });

  final DateTime generatedAt;
  final List<MemoryRecoveryFinding> findings;

  /// 隔离区保留的原件份数。
  final int quarantinedFiles;

  /// 当没有 finding，或所有 findings 均为完整恢复且无隔离原件时，
  /// 系统处于健康可用状态；存在待恢复、部分恢复或隔离原件时才需要关注。
  bool get healthy =>
      quarantinedFiles == 0 &&
      findings.every(
        (finding) =>
            !finding.quarantined &&
            finding.outcome == MemoryRecoveryOutcome.full,
      );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'quarantinedFiles': quarantinedFiles,
    'findings': findings.map((finding) => finding.toJson()).toList(),
  };

  static MemoryRecoveryReport? fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      return null;
    }
    final generatedAt = json['generatedAt'];
    final findingsRaw = json['findings'];
    if (generatedAt is! String || findingsRaw is! List<Object?>) {
      return null;
    }
    try {
      return MemoryRecoveryReport(
        generatedAt: DateTime.parse(generatedAt).toUtc(),
        findings: findingsRaw
            .whereType<Map<String, Object?>>()
            .map(MemoryRecoveryFinding.fromJson)
            .whereType<MemoryRecoveryFinding>()
            .toList(),
        quarantinedFiles: json['quarantinedFiles'] is int
            ? json['quarantinedFiles']! as int
            : 0,
      );
    } on Object {
      return null;
    }
  }
}

/// 隔离层键 → 用户语言标签。隔离文件名形如
/// `<微秒时间戳>__<层键>__<原文件名>`，清单合并按键归组。
const _quarantineLayerLabels = <String, String>{
  'session': '原始会话',
  'episode-day': '每日记录',
  'checkpoint': '整理检查点',
  'top-index': '月份索引',
  'month-index': '每日索引',
  'month-summary': '月度摘要',
  'controls': '记忆控制',
  'open-loops': '未闭环事项',
  'open-loops-archive': '未闭环事项归档',
  'daily-state': '近日状态',
  'relationship': '关系记录',
  'long-memory': '长期印象',
  'persona-projection': '画像投影',
  'dream-state': 'Dream 状态',
  // persona-tree 分支键带分支名：persona-branch-<wire> /
  // persona-archive-<wire>，动态映射见 _quarantineLayerLabel。
};

final _branchWires = {for (final branch in personaBranches) branch.wireName};

String _quarantineLayerLabel(String layerKey) {
  final direct = _quarantineLayerLabels[layerKey];
  if (direct != null) {
    return direct;
  }
  if (layerKey.startsWith('persona-branch-')) {
    final wire = layerKey.substring('persona-branch-'.length);
    if (_branchWires.contains(wire)) {
      return '画像分支（$wire）';
    }
  }
  if (layerKey.startsWith('persona-archive-')) {
    final wire = layerKey.substring('persona-archive-'.length);
    if (_branchWires.contains(wire)) {
      return '画像归档（$wire）';
    }
  }
  return '记忆文件';
}

final _sessionFileNamePattern = RegExp(r'^(\d{4}-\d{2}-\d{2})-(\d{3})\.md$');
final _tmpFilePattern = RegExp(r'\.\d+\.tmp$');

/// 归档墓碑标记（ticket 21）：归档损坏且无备份可恢复时，原位留下
/// 该标记保持「归档不可读」语义——受影响分支的根节点升降因此持续
/// 暂停（T26 定稿），直到用户通过备份导入等明确操作恢复归档。
const pausedArchiveMarker = '<!-- qiyu-paused-archive:';

/// 一轮恢复扫描的运行上下文：策略行的损坏判定与恢复动作经它上报
/// 发现、使用共享的隔离与清理原语，保证全表的隔离命名、清单合并与
/// 报告管线一致。
final class MemoryRecoveryRun {
  MemoryRecoveryRun._(this._service);

  final MemoryRecoveryService _service;

  /// 本轮累计的恢复发现（策略行逐条上报，报告与日志由此合成）。
  final List<MemoryRecoveryFinding> findings = [];

  bool _backupRestored = false;

  /// 本轮是否完成过 Dream 备份恢复（须对现行控制重跑派生清除）。
  bool get backupRestored => _backupRestored;

  /// 标记本轮完成过一次 Dream 备份恢复。
  void markBackupRestored() => _backupRestored = true;

  /// 共享隔离原语：先复制保全再移除原位文件，损坏原件退出注入、
  /// 检索与整理，证据保留在隔离区。返回隔离路径；完整恢复后由
  /// 调用方删除副本。
  Future<String> quarantineMove(File file, String layerKey) =>
      _service._quarantineMove(file, layerKey);

  /// 共享隔离原语：按字节复制损坏原件到隔离区（唯一原始证据的
  /// 保全副本）。返回隔离路径。
  Future<String> quarantineCopy(File file, String layerKey) =>
      _service._quarantineCopy(file, layerKey);

  /// 共享隔离原语：文件存在时复制保全（原位文件随后会被重建覆盖）。
  /// 不存在或失败返回 null。
  Future<String?> quarantineIfExists(File file, String layerKey) =>
      _service._quarantineIfExists(file, layerKey);

  /// 共享清理原语：删除已完整恢复层的隔离副本。
  Future<void> deleteIfExists(File file) => _service._deleteIfExists(file);
}

/// 策略行的损坏判定：返回该层当前损坏的证据（恢复动作的输入），
/// 健康返回 null。
typedef MemoryRecoveryDetect<D> = Future<D?> Function(MemoryRecoveryRun run);

/// 策略行的恢复动作：按判定证据隔离原件、从可信下层重建，并经
/// 运行上下文上报发现。
typedef MemoryRecoveryRecover<D> = Future<void> Function(
  D damage,
  MemoryRecoveryRun run,
);

/// 恢复策略表的一行：一个受保护层的「层 → 损坏判定 → 恢复动作 →
/// 上报」。判定健康即整层跳过；动作只经 [MemoryRecoveryRun] 使用
/// 共享样板原语（隔离、清理、上报），新增受保护层＝往表里加一行，
/// 引擎、隔离命名与报告管线不变。
final class MemoryRecoveryStrategy {
  const MemoryRecoveryStrategy._(
    this.layerKey,
    this.stepLabel,
    this.dayLocked,
    this._detect,
    this._recover,
  );

  /// 类型安全地装一行：判定与动作共享同一损坏证据类型 [D]。
  static MemoryRecoveryStrategy typed<D>({
    required String layerKey,
    required String stepLabel,
    required bool dayLocked,
    required MemoryRecoveryDetect<D> detect,
    required MemoryRecoveryRecover<D> recover,
  }) =>
      MemoryRecoveryStrategy._(
        layerKey,
        stepLabel,
        dayLocked,
        (run) => detect(run),
        (damage, run) => recover(damage as D, run),
      );

  /// 层键：与恢复发现、隔离清单共用同一命名空间。
  final String layerKey;

  /// 诊断封套名：同名的连续行共用一个容错封套（失败只记诊断，
  /// 绝不阻塞启动）。
  final String stepLabel;

  /// 恢复是否要求与日文件写入互斥（episodes 与索引族）。
  final bool dayLocked;

  final Future<Object?> Function(MemoryRecoveryRun) _detect;
  final Future<void> Function(Object?, MemoryRecoveryRun) _recover;
}

/// 会话文件的损坏证据：判定阶段解析出的一切，供恢复动作抢救或隔离。
typedef _SessionDamage = ({
  File file,
  String label,
  MemoryDamageKind kind,
  Map<String, Object?>? metadata,
  List<RawSessionTurn> turns,
  int failedMarkers,
  bool truncatedTurns,
});

/// 日文件的损坏证据。
typedef _EpisodeDayDamage = ({
  File file,
  String date,
  String label,
  bool truncated,
  Map<String, Object?>? metadata,
  List<EpisodeEntry> entries,
  int failedMarkers,
});

/// 索引层的损坏证据：需要重建时附上本轮已隔离的副本清单（重建
/// 成功后删除）。
typedef _IndexDamage = ({List<String> quarantined});

/// 月摘要层的损坏证据：待重建月份与重建所用的日历证据。
typedef _MonthSummaryDamage = ({
  List<String> dates,
  List<({String month, String label, bool existed})> months,
});

/// 简单文本热层文件的损坏证据。
typedef _PlainFileDamage = ({
  File file,
  String layerKey,
  String layer,
  String loss,
});

/// PersonaTree 层的损坏证据：恢复写入所需的树快照。
typedef _PersonaTreeDamage = ({PersonaTreeSnapshot snapshot});

/// 画像投影层的损坏证据：从原件抢救出的受保护称呼行（null 表示
/// 没救出）。
typedef _PersonaProjectionDamage = ({String? salvagedAppellation});

/// 诊断封套组：同 stepLabel 的连续行共用一个容错封套，任一行要求
/// 日文件互斥时整组在锁内执行——组粒度与既有扫描步骤逐一对应。
final class _StrategyGroup {
  _StrategyGroup({required this.stepLabel, required this.dayLocked});

  final String stepLabel;
  final bool dayLocked;
  final List<MemoryRecoveryStrategy> strategies = <MemoryRecoveryStrategy>[];
}

/// 损坏隔离与证据驱动恢复（ticket 21 / T26 定稿）。
///
/// 纪律：
/// - 启动扫描全部记忆层，按 sessions → episodes → 控制 → 索引与摘要
///   → 热层 → PersonaTree 与长期层的证据依赖自底向上恢复；
/// - 损坏原件先按字节复制到 `recovery/quarantine/` 再处置，完整恢复
///   才删除隔离副本，部分恢复与待恢复一律保留，未经用户明确操作
///   绝不覆盖唯一原始证据；
/// - 原始会话优先级最高；派生层只能从更可信的下层重建，无法证明的
///   内容不补写；
/// - 重建前后都遵守冻结、禁提、删除墓碑与敏感过滤：控制记录先从
///   episode 控制事件审计重建，再对派生层跑既有清除管线，绝不让被
///   控制内容随抢救复活；
/// - 恢复不阻塞对话：受损层跳过，其余有效记忆继续使用；
/// - `recovery.log` 只记时间、记忆类型、结果和损失，绝不记正文；
/// - 用户手写内容（无栖语元数据标记的文件）绝不触碰。
///
/// 执行计划就是本文件的恢复策略表（[_strategies]）：一行一个受保护
/// 层，逐行「损坏判定 → 恢复动作 → 上报」；唯一入口仍是
/// [sweepAndRecover]，策略表只是它的内部实现。
final class MemoryRecoveryService {
  MemoryRecoveryService({
    required this.memoryDirectory,
    required this.episodePipeline,
    required this.memoryControls,
    required this.personaTree,
    required this.dreamService,
    required this.monthlySummary,
    required this.relationshipLifecycle,
    required this.memoryActions,
    EpisodeIndexStore? indexStore,
    Clock? clock,
    AtomicTextWriter? atomicWriter,
    void Function(String message)? diagnosticsSink,

    /// 测试扩展点（本仓库无 meta 直接依赖，以文档契约代替
    /// `@visibleForTesting`，与 voice_tier_mapping 的行集同律）：追加到
    /// 策略表尾部的行，演示「新增受保护层＝加一行策略」。生产代码
    /// 不得传，传行即视为恢复面改动，必须同票补测试。
    List<MemoryRecoveryStrategy>? extraStrategies,
  }) : _indexStore = indexStore ??
           EpisodeIndexStore(
             memoryDirectory: memoryDirectory,
             episodePipeline: episodePipeline,
           ),
       _clock = clock ?? DateTime.now,
       _atomicWriter = episodePipeline.commits.wrap(atomicWriter),
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics,
       _extraStrategies = extraStrategies ?? const [];

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final MemoryControlsStore memoryControls;
  final PersonaTreeStore personaTree;
  final DreamService dreamService;
  final MonthlySummaryStore monthlySummary;
  final RelationshipLifecycle relationshipLifecycle;
  final MemoryActionService memoryActions;
  final EpisodeIndexStore _indexStore;
  final Clock _clock;
  final AtomicTextWriter _atomicWriter;
  final void Function(String) _diagnosticsSink;
  final List<MemoryRecoveryStrategy> _extraStrategies;

  Directory get _recoveryDirectory =>
      Directory(path.join(memoryDirectory, 'recovery'));
  Directory get _quarantineDirectory =>
      Directory(path.join(_recoveryDirectory.path, 'quarantine'));
  File get _logFile => memoryFile(_recoveryDirectory.path, 'recovery.log');
  File get _reportFile => memoryFile(_recoveryDirectory.path, 'report.md');

  /// 一次完整的启动恢复扫描。逐层检测五类损坏、隔离原件、自底向上
  /// 重建，最后落日志与报告。任一层失败只记诊断，绝不抛出阻塞启动。
  Future<MemoryRecoveryReport> sweepAndRecover() async {
    final run = MemoryRecoveryRun._(this);
    for (final group in _groupStrategies([
      ..._strategies,
      ..._extraStrategies,
    ])) {
      await _step(() async {
        Future<void> runGroup() async {
          for (final strategy in group.strategies) {
            await _runStrategy(strategy, run);
          }
        }

        if (group.dayLocked) {
          await episodePipeline.synchronizedOnDayFiles(runGroup);
        } else {
          await runGroup();
        }
      }, group.stepLabel);
    }

    await _step(() async {
      await _appendQuarantineInventory(run.findings);
    }, 'inventory');

    final report = MemoryRecoveryReport(
      generatedAt: _clock().toUtc(),
      findings: run.findings,
      quarantinedFiles: await _quarantineCount(),
    );
    await _persist(report);
    return report;
  }

  /// 最近一次持久化的恢复报告；不存在或不可读返回 null。
  Future<MemoryRecoveryReport?> readReport() async {
    final contents = await readFileIfExists(_reportFile);
    if (contents == null) {
      return null;
    }
    try {
      final match = recoveryReportMarkerPattern.firstMatch(contents);
      if (match == null) {
        return null;
      }
      return MemoryRecoveryReport.fromJson(
        decodeMarkerPayload(match.group(1)!),
      );
    } on Object {
      return null;
    }
  }

  /// 恢复策略表：一行一个受保护层，按既有「自底向上」的证据依赖
  /// 排序（sessions → episodes → 控制 → 索引与摘要 → 热层 → 长期层）。
  /// 同 stepLabel 的连续行共用一个诊断封套，dayLocked 组整组在日文件
  /// 写锁内执行。
  List<MemoryRecoveryStrategy> get _strategies => [
    // 写入中断残留：临时文件不是证据，直接删除。
    MemoryRecoveryStrategy.typed<List<File>>(
      layerKey: 'temp-files',
      stepLabel: 'temp-files',
      dayLocked: false,
      detect: _detectOrphanedTempFiles,
      recover: _recoverOrphanedTempFiles,
    ),
    // sessions：证据最底层，优先级最高。
    MemoryRecoveryStrategy.typed<List<_SessionDamage>>(
      layerKey: 'session',
      stepLabel: 'sessions',
      dayLocked: false,
      detect: _detectSessionDamage,
      recover: _recoverSessions,
    ),
    // episodes 日文件与整理检查点：与日文件写入互斥。
    MemoryRecoveryStrategy.typed<List<_EpisodeDayDamage>>(
      layerKey: 'episode-day',
      stepLabel: 'episodes',
      dayLocked: true,
      detect: _detectEpisodeDayDamage,
      recover: _recoverEpisodeDays,
    ),
    MemoryRecoveryStrategy.typed<bool>(
      layerKey: 'checkpoint',
      stepLabel: 'episodes',
      dayLocked: true,
      detect: _detectCheckpointDamage,
      recover: _recoverCheckpoint,
    ),
    // 记忆控制：必须在索引与月摘要重建之前恢复，后两者的受控过滤
    // 依赖控制集合。
    MemoryRecoveryStrategy.typed<bool>(
      layerKey: 'controls',
      stepLabel: 'controls',
      dayLocked: false,
      detect: _detectControlsDamage,
      recover: _recoverControls,
    ),
    // 索引与月摘要：与日文件写入互斥。
    MemoryRecoveryStrategy.typed<_IndexDamage>(
      layerKey: 'index',
      stepLabel: 'indexes',
      dayLocked: true,
      detect: _detectIndexDamage,
      recover: _recoverIndexes,
    ),
    MemoryRecoveryStrategy.typed<_MonthSummaryDamage>(
      layerKey: 'month-summary',
      stepLabel: 'indexes',
      dayLocked: true,
      detect: _detectMonthSummaryDamage,
      recover: _recoverMonthlySummaries,
    ),
    // 热层。
    // open-loops.md：损坏即隔离；活跃事项无法从现有证据确定性重建，
    // 诚实报部分恢复，等待日终重新整理。
    MemoryRecoveryStrategy.typed<_PlainFileDamage>(
      layerKey: 'open-loops',
      stepLabel: 'hot-layer',
      dayLocked: false,
      detect: (run) => _detectPlainFileDamage(
        file: memoryFile(memoryDirectory, 'open-loops.md'),
        layerKey: 'open-loops',
        layer: '未闭环事项',
        managedHeader: '# open-loops',
        parseable: (contents) => parseOpenLoopItems(contents) != null,
        loss: '未闭环事项内容',
      ),
      recover: _recoverPlainFile,
    ),
    MemoryRecoveryStrategy.typed<_PlainFileDamage>(
      layerKey: 'open-loops-archive',
      stepLabel: 'hot-layer',
      dayLocked: false,
      detect: (run) => _detectPlainFileDamage(
        file: memoryFile(memoryDirectory, 'open-loops.archive.md'),
        layerKey: 'open-loops-archive',
        layer: '未闭环事项归档',
        managedHeader: '# open-loops archive',
        parseable: null, // 归档格式宽松，只处理编码失败。
        loss: '已闭环事项归档',
      ),
      recover: _recoverPlainFile,
    ),
    // daily-state.md：编码失败才算损坏；重建归下一次日终归档。
    MemoryRecoveryStrategy.typed<File>(
      layerKey: 'daily-state',
      stepLabel: 'hot-layer',
      dayLocked: false,
      detect: _detectDailyStateDamage,
      recover: _recoverDailyState,
    ),
    // relationship.md：受管结构损坏时按幸存日文件里最近一次持久化
    // 的阶段判断整体重建；没有判断按初识保守重建，等日终模型追认。
    MemoryRecoveryStrategy.typed<bool>(
      layerKey: 'relationship',
      stepLabel: 'hot-layer',
      dayLocked: false,
      detect: _detectRelationshipDamage,
      recover: _recoverRelationship,
    ),
    // 长期层。long-memory 与 PersonaTree 的任何一次 Dream 备份恢复
    // 成功后，都会由表尾的 controls-reapply 行对现行控制集合重跑
    // 派生清除。
    MemoryRecoveryStrategy.typed<bool>(
      layerKey: 'long-memory',
      stepLabel: 'long-term',
      dayLocked: false,
      detect: _detectLongMemoryDamage,
      recover: _recoverLongMemoryFromBackup,
    ),
    // PersonaTree 分支与归档：优先 Dream 备份恢复；无备份时隔离并
    // 暂停受影响分支的根节点操作（快照 archiveReadable 已驱动拒绝）。
    MemoryRecoveryStrategy.typed<_PersonaTreeDamage>(
      layerKey: 'persona-tree',
      stepLabel: 'long-term',
      dayLocked: false,
      detect: _detectPersonaTreeDamage,
      recover: _recoverPersonaTreeFromBackup,
    ),
    // persona.md：纯投影＋受保护称呼设定行，结构存疑时从活跃根重投
    // 影；树不完整时隔离等待，绝不写出残缺画像。
    MemoryRecoveryStrategy.typed<_PersonaProjectionDamage>(
      layerKey: 'persona-projection',
      stepLabel: 'long-term',
      dayLocked: false,
      detect: _detectPersonaProjectionDamage,
      recover: _recoverPersonaProjection,
    ),
    // dream/state.md：损坏即隔离并重置为空状态（Dream 间隔证据丢失，
    // 下一次晚安重新评估）。
    MemoryRecoveryStrategy.typed<File>(
      layerKey: 'dream-state',
      stepLabel: 'long-term',
      dayLocked: false,
      detect: _detectDreamStateDamage,
      recover: _recoverDreamState,
    ),
    // Dream 备份恢复后，对现行控制集合（禁提 ∪ 删除）再跑一遍派生
    // 清除：备份定格在上次 Dream，其后被删除/禁提的内容可能随旧
    // 备份复活（长期印象与画像分支都会立刻重新注入），必须按现行
    // 控制拦下。
    MemoryRecoveryStrategy.typed<bool>(
      layerKey: 'controls-reapply',
      stepLabel: 'long-term',
      dayLocked: false,
      detect: _detectControlsReapply,
      recover: _recoverControlsReapply,
    ),
  ];

  /// 把策略表按连续同 stepLabel 的行折成诊断封套组。
  List<_StrategyGroup> _groupStrategies(List<MemoryRecoveryStrategy> table) {
    final groups = <_StrategyGroup>[];
    for (final strategy in table) {
      final last = groups.isEmpty ? null : groups.last;
      if (last != null &&
          last.stepLabel == strategy.stepLabel &&
          last.dayLocked == strategy.dayLocked) {
        last.strategies.add(strategy);
        continue;
      }
      groups.add(
        _StrategyGroup(
          stepLabel: strategy.stepLabel,
          dayLocked: strategy.dayLocked,
        )..strategies.add(strategy),
      );
    }
    return groups;
  }

  /// 执行一行策略：判定健康即跳过，损坏则走恢复动作。
  Future<void> _runStrategy(
    MemoryRecoveryStrategy strategy,
    MemoryRecoveryRun run,
  ) async {
    final damage = await strategy._detect(run);
    if (damage == null) {
      return;
    }
    await strategy._recover(damage, run);
  }

  Future<void> _step(Future<void> Function() body, String label) async {
    try {
      await body();
    } on Object catch (error) {
      _diagnosticsSink('memory recovery step deferred [$error] step=$label');
    }
  }

  // ---------- 写入中断残留 ----------

  /// 损坏判定：原子写中断留下的孤儿临时文件（`*.tmp`）——它们从不
  /// 参与记忆流程，也不是原始证据。
  Future<List<File>?> _detectOrphanedTempFiles(MemoryRecoveryRun run) async {
    final root = Directory(memoryDirectory);
    if (!await root.exists()) {
      return null;
    }
    final orphaned = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && _tmpFilePattern.hasMatch(entity.path)) {
        orphaned.add(entity);
      }
    }
    return orphaned.isEmpty ? null : orphaned;
  }

  /// 恢复动作：直接删除并上报（完整恢复，无隔离）。
  Future<void> _recoverOrphanedTempFiles(
    List<File> orphaned,
    MemoryRecoveryRun run,
  ) async {
    var removed = 0;
    for (final file in orphaned) {
      try {
        await file.delete();
        removed += 1;
      } on Object {
        // 残留清理失败不影响其余恢复。
      }
    }
    if (removed > 0) {
      run.findings.add(
        MemoryRecoveryFinding(
          layerKey: 'temp-files',
          layer: '写入残留',
          kind: MemoryDamageKind.orphaned,
          outcome: MemoryRecoveryOutcome.full,
          evidence: '清理中断写入遗留的临时文件 $removed 份',
        ),
      );
    }
  }

  // ---------- sessions（证据最底层，优先级最高） ----------

  /// 损坏判定：逐会话文件「存在 → 读 → 校验」（元数据与全部对话块
  /// 完整即健康，尾部无害内容不影响解析）。
  Future<List<_SessionDamage>?> _detectSessionDamage(
    MemoryRecoveryRun run,
  ) async {
    final directory = Directory(path.join(memoryDirectory, 'sessions'));
    if (!await directory.exists()) {
      return null;
    }
    final files = await directory
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File && entity.path.endsWith('.md'))
        .cast<File>()
        .toList();
    final damaged = <_SessionDamage>[];
    for (final file in files) {
      final name = path.basename(file.path);
      final nameMatch = _sessionFileNamePattern.firstMatch(name);
      if (nameMatch == null) {
        continue;
      }
      final date = nameMatch.group(1)!;
      final segment = int.parse(nameMatch.group(2)!);
      final label = '原始会话（$date 第 $segment 段）';

      String contents;
      var encodingCorrupt = false;
      try {
        contents = await file.readAsString(encoding: utf8);
      } on Object {
        encodingCorrupt = true;
        contents = await _readLenient(file);
      }

      final metadataMatch = sessionMetaMarkerPattern.firstMatch(contents);
      Map<String, Object?>? metadata;
      if (metadataMatch != null) {
        try {
          metadata = decodeMarkerPayload(metadataMatch.group(1)!);
        } on Object {
          metadata = null;
        }
      }
      final markers = sessionTurnMarkerPattern.allMatches(contents).toList();
      final turns = <RawSessionTurn>[];
      var failedMarkers = 0;
      for (final marker in markers) {
        try {
          turns.add(RawSessionTurn.fromJson(decodeMarkerPayload(marker.group(1)!)));
        } on Object {
          failedMarkers += 1;
        }
      }

      final truncatedTurns =
          _countOccurrences(contents, '<!-- qiyu-turn:') > markers.length;
      if (!encodingCorrupt &&
          metadata != null &&
          failedMarkers == 0 &&
          !truncatedTurns) {
        // 元数据与全部对话块完整：健康。
        try {
          RawSession.fromJson(metadata, turns);
          continue;
        } on Object {
          metadata = null; // 元数据字段缺失：按损坏处理。
        }
      }

      damaged.add((
        file: file,
        label: label,
        kind: encodingCorrupt || (metadataMatch != null && metadata == null)
            ? MemoryDamageKind.corrupt
            : MemoryDamageKind.incomplete,
        metadata: metadata,
        turns: turns,
        failedMarkers: failedMarkers,
        truncatedTurns: truncatedTurns,
      ));
    }
    return damaged.isEmpty ? null : damaged;
  }

  /// 恢复动作：完整对话块可独立验证时逐块重写干净文件（抢救）；
  /// 否则隔离原件（保留唯一证据），原位移除避免继续参与扫描。
  Future<void> _recoverSessions(
    List<_SessionDamage> damaged,
    MemoryRecoveryRun run,
  ) async {
    for (final damage in damaged) {
      final file = damage.file;
      if (damage.metadata != null && damage.turns.isNotEmpty) {
        // 抢救：完整对话块可独立验证，逐块重写干净文件。编码损坏但
        // 全部块完整时同样走这里——重写后内容无损，隔离副本随之删除。
        try {
          final session = RawSession.fromJson(damage.metadata!, damage.turns);
          final quarantinePath = await run.quarantineCopy(file, 'session');
          await _atomicWriter.replace(
            file.path,
            renderSessionMarkdown(session),
          );
          // 截断在标记中间时残行匹配不了完整正则，健康检查里按前缀
          // 计数的结果同样适用：这类损坏只能部分恢复。
          final full = damage.failedMarkers == 0 && !damage.truncatedTurns;
          if (full) {
            await run.deleteIfExists(File(quarantinePath));
          }
          run.findings.add(
            MemoryRecoveryFinding(
              layerKey: 'session',
              layer: damage.label,
              kind: damage.kind,
              outcome: full
                  ? MemoryRecoveryOutcome.full
                  : MemoryRecoveryOutcome.partial,
              evidence: '从文件内完整对话块 ${damage.turns.length} 段抢救',
              loss: full ? null : '未完整解析的对话块',
              quarantined: !full,
            ),
          );
          continue;
        } on Object catch (error) {
          _diagnosticsSink('session salvage deferred [$error]');
        }
      }

      try {
        await run.quarantineMove(file, 'session');
      } on Object catch (error) {
        _diagnosticsSink('session quarantine deferred [$error]');
        continue;
      }
      run.findings.add(
        MemoryRecoveryFinding(
          layerKey: 'session',
          layer: damage.label,
          kind: damage.kind,
          outcome: MemoryRecoveryOutcome.pending,
          loss: damage.metadata == null
              ? '会话头信息丢失，对话块无法归位'
              : '无完整对话块',
          quarantined: true,
        ),
      );
    }
  }

  Future<Set<String>> _validSessionIds() async {
    try {
      final repository = MarkdownMemoryRepository(
        memoryDirectory: memoryDirectory,
      );
      final listing = await repository.readHistory();
      return {for (final session in listing.sessions) session.id};
    } on Object {
      return const {};
    }
  }

  // ---------- episodes 日文件与 checkpoint ----------

  /// 损坏判定：逐日文件「存在 → 读 → 校验」；没有栖语元数据标记的
  /// 可能是用户手写的普通 Markdown，绝不触碰。宽松解析会把尾部截断
  /// 当成可读：按标记前缀计数找出丢失的块。
  Future<List<_EpisodeDayDamage>?> _detectEpisodeDayDamage(
    MemoryRecoveryRun run,
  ) async {
    final damaged = <_EpisodeDayDamage>[];
    for (final date in await episodePipeline.listEpisodeDates()) {
      final day = await episodePipeline.readDay(date);
      if (!day.exists) {
        continue;
      }
      final file = _episodeDayFile(date);
      String contents;
      try {
        contents = await file.readAsString(encoding: utf8);
      } on Object {
        contents = await _readLenient(file);
      }
      final label = '每日记录（$date）';
      if (!episodeMetaPattern.hasMatch(contents) &&
          !episodeEntryMarkerPattern.hasMatch(contents)) {
        continue;
      }
      final matchedMarkers =
          episodeEntryMarkerPattern.allMatches(contents).length;
      final truncated =
          _countOccurrences(contents, '<!-- qiyu-episode-entry:') >
              matchedMarkers;
      if (day.readable && !truncated) {
        continue;
      }

      Map<String, Object?>? metadata;
      final metadataMatch = episodeMetaPattern.firstMatch(contents);
      if (metadataMatch != null) {
        try {
          metadata = decodeMarkerPayload(metadataMatch.group(1)!);
        } on Object {
          metadata = null;
        }
      }
      final markers = episodeEntryMarkerPattern.allMatches(contents).toList();
      final entries = <EpisodeEntry>[];
      var failedMarkers = 0;
      for (final marker in markers) {
        try {
          entries.add(EpisodeEntry.fromJson(decodeMarkerPayload(marker.group(1)!)));
        } on Object {
          failedMarkers += 1;
        }
      }

      damaged.add((
        file: file,
        date: date,
        label: label,
        truncated: truncated,
        metadata: metadata,
        entries: entries,
        failedMarkers: failedMarkers,
      ));
    }
    return damaged.isEmpty ? null : damaged;
  }

  /// 恢复动作：无任何可验证内容时隔离原件、原位删除，等待语义恢复；
  /// 有完整条目时复用正常写入路径重写当日文件（抢救）。
  Future<void> _recoverEpisodeDays(
    List<_EpisodeDayDamage> damaged,
    MemoryRecoveryRun run,
  ) async {
    for (final damage in damaged) {
      final file = damage.file;
      if (damage.entries.isEmpty && damage.metadata == null) {
        try {
          await run.quarantineMove(file, 'episode-day');
        } on Object catch (error) {
          _diagnosticsSink('episode quarantine deferred [$error]');
          continue;
        }
        run.findings.add(
          MemoryRecoveryFinding(
            layerKey: 'episode-day',
            layer: damage.label,
            kind: MemoryDamageKind.corrupt,
            outcome: MemoryRecoveryOutcome.pending,
            evidence: '同日原始会话仍在，等待语义重建',
            loss: '当日整理内容',
            quarantined: true,
          ),
        );
        continue;
      }

      try {
        final quarantinePath = await run.quarantineCopy(file, 'episode-day');
        await episodePipeline.writeFinalization(
          damage.date,
          entries: damage.entries,
          summary: damage.metadata?['summary'] as String?,
          finalized: damage.metadata?['finalized'] == true,
          finalizedAt: _parseUtc(damage.metadata?['finalizedAt'] as String?),
          understanding: damage.metadata?['understanding'] is Map<String, Object?>
              ? damage.metadata!['understanding']! as Map<String, Object?>
              : null,
        );
        // 元数据与全部条目完整（仅编码等外围损坏）：重写后内容无损。
        final full =
            damage.metadata != null &&
            damage.failedMarkers == 0 &&
            !damage.truncated;
        if (full) {
          await run.deleteIfExists(File(quarantinePath));
        }
        run.findings.add(
          MemoryRecoveryFinding(
            layerKey: 'episode-day',
            layer: damage.label,
            kind: damage.metadata == null
                ? MemoryDamageKind.incomplete
                : MemoryDamageKind.corrupt,
            outcome: full
                ? MemoryRecoveryOutcome.full
                : MemoryRecoveryOutcome.partial,
            evidence: '从文件内完整条目 ${damage.entries.length} 条抢救',
            loss: full
                ? null
                : damage.metadata == null
                      ? '日终摘要与归档标记'
                      : '未完整解析的条目',
            quarantined: !full,
          ),
        );
      } on Object catch (error) {
        _diagnosticsSink('episode salvage deferred [$error]');
      }
    }
  }

  /// 损坏判定：检查点元数据缺失（语法损坏）或指向已不存在的会话
  /// （引用失效）。
  Future<bool?> _detectCheckpointDamage(MemoryRecoveryRun run) async {
    final file = memoryFile(memoryDirectory, 'episodes/checkpoint.md');
    if (!await file.exists()) {
      return null;
    }
    final contents = await readFileIfExists(file);
    Map<String, Object?>? metadata;
    if (contents != null) {
      final match = checkpointMetaPattern.firstMatch(contents);
      if (match != null) {
        try {
          metadata = decodeMarkerPayload(match.group(1)!);
        } on Object {
          metadata = null;
        }
      }
    }
    final sessionId = metadata?['sessionId'];
    final sessionIds = await _validSessionIds();
    final orphaned = metadata != null &&
        sessionId is String &&
        sessionIds.isNotEmpty &&
        !sessionIds.contains(sessionId);
    if (metadata != null && !orphaned) {
      return null;
    }
    return orphaned;
  }

  /// 恢复动作：检查点可从会话完整重推（条目标识去重避免重复整理）：
  /// 完整恢复，隔离副本随之删除。
  Future<void> _recoverCheckpoint(bool orphaned, MemoryRecoveryRun run) async {
    final file = memoryFile(memoryDirectory, 'episodes/checkpoint.md');
    String quarantinePath;
    try {
      quarantinePath = await run.quarantineMove(file, 'checkpoint');
    } on Object catch (error) {
      _diagnosticsSink('checkpoint quarantine deferred [$error]');
      return;
    }
    await run.deleteIfExists(File(quarantinePath));
    run.findings.add(
      MemoryRecoveryFinding(
        layerKey: 'checkpoint',
        layer: '整理检查点',
        kind: orphaned ? MemoryDamageKind.orphaned : MemoryDamageKind.corrupt,
        outcome: MemoryRecoveryOutcome.full,
        evidence: orphaned
            ? '指向的会话已不存在，重置后从未归档会话开头重扫'
            : '重置后从未归档会话开头重扫，按条目标识去重避免重复整理',
      ),
    );
  }

  // ---------- 记忆控制 ----------

  /// 损坏判定：控制文件不可读。
  Future<bool?> _detectControlsDamage(MemoryRecoveryRun run) async {
    final controls = await memoryControls.load();
    return controls.readable ? null : true;
  }

  /// 恢复动作：从 episode 控制事件审计重建（禁提/冻结/解除冻结/
  /// 删除的簿记条目），重建后对封禁范围跑既有派生清除管线，绝不让
  /// 被控制内容随抢救复活。审计无法证明完整性：隔离原件一律保留。
  Future<void> _recoverControls(bool damaged, MemoryRecoveryRun run) async {
    final file = memoryControls.controlsFile;
    String? quarantinePath;
    try {
      quarantinePath = await run.quarantineCopy(file, 'controls');
    } on Object catch (error) {
      _diagnosticsSink('controls quarantine deferred [$error]');
    }
    if (quarantinePath == null) {
      // 隔离保全失败：绝不覆盖唯一原始证据，保持现状等待下轮重试。
      run.findings.add(
        const MemoryRecoveryFinding(
          layerKey: 'controls',
          layer: '记忆控制',
          kind: MemoryDamageKind.corrupt,
          outcome: MemoryRecoveryOutcome.pending,
          loss: '隔离保全失败，控制记录保持现状等待重试',
        ),
      );
      return;
    }

    final events = <({DateTime at, String action, String text})>[];
    for (final date in await episodePipeline.listEpisodeDates()) {
      final day = await episodePipeline.readDay(date);
      if (!day.readable) {
        continue;
      }
      for (final entry in day.entries) {
        if (entry.kind != episodeKindOpenLoopEvent) {
          continue;
        }
        final summary = entry.summary;
        final parsed = _controlEvent(summary);
        if (parsed != null) {
          events.add((at: entry.at, action: parsed.$1, text: parsed.$2));
        }
      }
    }
    events.sort((left, right) => left.at.compareTo(right.at));

    final frozen = <String>{};
    final banned = <String>[];
    final deleted = <String>[];
    final bannedSeen = <String>{};
    final deletedSeen = <String>{};
    for (final event in events) {
      final normalized = normalizeMemoryText(event.text);
      if (normalized.isEmpty) {
        continue;
      }
      switch (event.action) {
        case 'freeze':
          frozen.add(normalized);
        case 'unfreeze':
          frozen.remove(normalized);
        case 'ban':
          if (bannedSeen.add(normalized)) {
            banned.add(event.text);
          }
        case 'delete':
          if (deletedSeen.add(normalized)) {
            deleted.add(event.text);
          }
      }
    }

    var nextId = 1;
    // 审计重建只恢复主摘要：控制时的模型关联扩展找出的别名不写
    // episode 审计（那会让别名原文进入可读记忆文件），损坏重建因此
    // 退回纯文字匹配——主摘要的控制范围不受影响，别名的增强等下次
    // 控制动作自然补上（裁定票 03）。
    MemoryControlEntry entry(String summary) => MemoryControlEntry(
      id: nextId++,
      origin: 'recovery',
      summary: summary,
    );
    final frozenEntries = [
      for (final summary in _originalTexts(events, 'freeze', frozen))
        entry(summary),
    ];
    final rebuilt = MemoryControls(
      readable: true,
      frozen: frozenEntries,
      banned: [for (final text in banned) entry(text)],
      deleted: [for (final text in deleted) entry(text)],
    );
    if (!await memoryControls.replaceForRecovery(rebuilt)) {
      run.findings.add(
        const MemoryRecoveryFinding(
          layerKey: 'controls',
          layer: '记忆控制',
          kind: MemoryDamageKind.corrupt,
          outcome: MemoryRecoveryOutcome.pending,
          loss: '控制记录写入失败，保持现状等待重试',
          quarantined: true,
        ),
      );
      return;
    }

    // 封禁（禁提 ∪ 删除）范围逐条清除派生内容；冻结只停注入不清除。
    for (final text in [...banned, ...deleted]) {
      try {
        await memoryActions.purgeDerivedScopes(
          {normalizeMemoryText(text)},
          text: text,
        );
      } on Object catch (error) {
        _diagnosticsSink('controls recovery purge deferred [$error]');
      }
    }

    final rebuiltCount =
        frozenEntries.length + banned.length + deleted.length;
    run.findings.add(
      MemoryRecoveryFinding(
        layerKey: 'controls',
        layer: '记忆控制',
        kind: MemoryDamageKind.corrupt,
        outcome: MemoryRecoveryOutcome.partial,
        evidence: rebuiltCount == 0
            ? '整理审计中没有控制事件，按空控制重建'
            : '从整理记录的控制事件审计重建 $rebuiltCount 条',
        loss: rebuiltCount == 0
            ? '损坏前的控制记录无法证明，受控内容可能失守'
            : '损坏前是否有更多控制记录无法证明',
        quarantined: true,
      ),
    );
  }

  /// episode 簿记条目的控制事件解析：只认四种前缀（写入端常量见
  /// episode_memory），「不记录」不是控制事件（当时就没有写入任何内容）。
  (String, String)? _controlEvent(String summary) {
    const prefixes = {
      controlAuditPrefixBan: 'ban',
      controlAuditPrefixFreeze: 'freeze',
      controlAuditPrefixUnfreeze: 'unfreeze',
      controlAuditPrefixDelete: 'delete',
    };
    for (final MapEntry(:key, :value) in prefixes.entries) {
      if (summary.startsWith(key)) {
        final text = summary.substring(key.length).trim();
        return text.isEmpty ? null : (value, text);
      }
    }
    return null;
  }

  /// 冻结集合恢复原文：审计重放后仍在冻结中的规范化摘要，找回其
  /// 最近一次冻结事件的原文（落盘格式需要可读摘要）。倒序扫描去重
  /// 后再整体反转，保持事件时间顺序。
  List<String> _originalTexts(
    List<({DateTime at, String action, String text})> events,
    String action,
    Set<String> keptNormalized,
  ) {
    final latestFirst = <String>[];
    final seen = <String>{};
    for (final event in events.reversed) {
      if (event.action != action) {
        continue;
      }
      final normalized = normalizeMemoryText(event.text);
      if (keptNormalized.contains(normalized) && seen.add(normalized)) {
        latestFirst.add(event.text);
      }
    }
    return latestFirst.reversed.toList();
  }

  // ---------- 索引与月摘要 ----------

  /// 损坏判定：索引与现存有效每日记录逐月比对，缺失、语法损坏、
  /// 引用失效或可容忍旧版本即上报并标记重建。
  Future<_IndexDamage?> _detectIndexDamage(MemoryRecoveryRun run) async {
    final dates = await episodePipeline.listEpisodeDates();
    final validMonths = <String>{};
    final validDates = <String>{};
    for (final date in dates) {
      final day = await episodePipeline.readDay(date);
      if (!day.readable ||
          !day.finalized ||
          validEpisodeEntries(day.entries).isEmpty) {
        continue;
      }
      validDates.add(date);
      validMonths.add(date.substring(0, 7));
    }

    final topFile = _indexStore.topIndexFile;
    final topExists = await topFile.exists();
    final top = await _indexStore.readTopIndex();
    var dirty = false;
    final quarantined = <String>[];

    if (validMonths.isEmpty) {
      if (topExists) {
        // 索引指向的世界已不存在（删除清空或整体损坏）：重建即删除。
        dirty = true;
        run.findings.add(
          const MemoryRecoveryFinding(
            layerKey: 'top-index',
            layer: '月份索引',
            kind: MemoryDamageKind.orphaned,
            outcome: MemoryRecoveryOutcome.full,
            evidence: '无有效每日记录，索引清空',
          ),
        );
      }
    } else if (!topExists) {
      dirty = true;
      run.findings.add(
        const MemoryRecoveryFinding(
          layerKey: 'top-index',
          layer: '月份索引',
          kind: MemoryDamageKind.missing,
          outcome: MemoryRecoveryOutcome.full,
          evidence: '从现存有效每日记录重建',
        ),
      );
    } else if (top == null) {
      dirty = true;
      final quarantinePath = await run.quarantineIfExists(topFile, 'top-index');
      if (quarantinePath != null) {
        quarantined.add(quarantinePath);
      }
      run.findings.add(
        const MemoryRecoveryFinding(
          layerKey: 'top-index',
          layer: '月份索引',
          kind: MemoryDamageKind.corrupt,
          outcome: MemoryRecoveryOutcome.full,
          evidence: '从现存有效每日记录重建',
        ),
      );
    } else {
      final indexedMonths = {for (final line in top) line.month};
      if (!validMonths.every(indexedMonths.contains) ||
          !indexedMonths.every(validMonths.contains)) {
        dirty = true;
        run.findings.add(
          MemoryRecoveryFinding(
            layerKey: 'top-index',
            layer: '月份索引',
            kind: validMonths.every(indexedMonths.contains)
                ? MemoryDamageKind.orphaned
                : MemoryDamageKind.stale,
            outcome: MemoryRecoveryOutcome.full,
            evidence: '从现存有效每日记录重建',
          ),
        );
      }
      for (final month in indexedMonths.intersection(validMonths)) {
        final monthFile = _indexStore.monthIndexFile(month);
        final dayLines = await _indexStore.readMonthIndex(month);
        final monthDates = validDates
            .where((date) => date.substring(0, 7) == month)
            .toSet();
        if (dayLines == null) {
          dirty = true;
          final quarantinePath = await run.quarantineIfExists(
            monthFile,
            'month-index',
          );
          if (quarantinePath != null) {
            quarantined.add(quarantinePath);
          }
          run.findings.add(
            MemoryRecoveryFinding(
              layerKey: 'month-index',
              layer: '每日索引（$month）',
              kind: await monthFile.exists()
                  ? MemoryDamageKind.corrupt
                  : MemoryDamageKind.missing,
              outcome: MemoryRecoveryOutcome.full,
              evidence: '从当月有效每日记录重建',
            ),
          );
          continue;
        }
        final indexedDates = {for (final line in dayLines) line.date};
        final orphanRows = indexedDates.difference(monthDates);
        final missingDates = monthDates.difference(indexedDates);
        if (orphanRows.isNotEmpty || missingDates.isNotEmpty) {
          dirty = true;
          run.findings.add(
            MemoryRecoveryFinding(
              layerKey: 'month-index',
              layer: '每日索引（$month）',
              kind: orphanRows.isNotEmpty
                  ? MemoryDamageKind.orphaned
                  : MemoryDamageKind.stale,
              outcome: MemoryRecoveryOutcome.full,
              evidence: '从当月有效每日记录重建',
            ),
          );
        }
      }
    }

    return dirty ? (quarantined: quarantined) : null;
  }

  /// 恢复动作：索引可完全从现存每日记录推导，重建成功后隔离副本
  /// 删除。
  Future<void> _recoverIndexes(
    _IndexDamage damage,
    MemoryRecoveryRun run,
  ) async {
    await _indexStore.rebuild();
    for (final quarantinePath in damage.quarantined) {
      await run.deleteIfExists(File(quarantinePath));
    }
  }

  /// 损坏判定：非当月的已归档月份缺月摘要或摘要不可读。
  Future<_MonthSummaryDamage?> _detectMonthSummaryDamage(
    MemoryRecoveryRun run,
  ) async {
    final now = _clock();
    final currentMonth =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
    final dates = await episodePipeline.listEpisodeDates();
    final months = <String, bool>{
      // 值：该月是否有已 finalized 的日期（摘要只收 finalized 日）。
    };
    for (final date in dates) {
      if (date.substring(0, 7) == currentMonth) {
        continue;
      }
      months.putIfAbsent(date.substring(0, 7), () => false);
    }
    for (final date in dates) {
      final month = date.substring(0, 7);
      if (month == currentMonth || months[month] == true) {
        continue;
      }
      final day = await episodePipeline.readDay(date);
      if (day.readable && day.finalized) {
        months[month] = true;
      }
    }
    final damaged = <({String month, String label, bool existed})>[];
    for (final MapEntry(:key, :value) in months.entries) {
      if (!value) {
        continue;
      }
      final summary = await monthlySummary.readMonthSummary(key);
      if (summary != null && summary.readable) {
        continue;
      }
      damaged.add((month: key, label: '月度摘要（$key）', existed: summary != null));
    }
    return damaged.isEmpty ? null : (dates: dates, months: damaged);
  }

  /// 恢复动作：存在的损坏原件先隔离再删除（重建会覆盖），月摘要可
  /// 完全从同月每日记录重新压缩：隔离副本随之删除。
  Future<void> _recoverMonthlySummaries(
    _MonthSummaryDamage damage,
    MemoryRecoveryRun run,
  ) async {
    for (final month in damage.months) {
      String? quarantinePath;
      if (month.existed) {
        quarantinePath = await run.quarantineIfExists(
          monthlySummary.summaryFile(month.month),
          'month-summary',
        );
        try {
          await episodePipeline.commits.delete(
            monthlySummary.summaryFile(month.month),
          );
        } on Object {
          // 删除失败时压缩会因不可读而跳过，下轮再试。
        }
      }
      try {
        await monthlySummary.compressMonth(month.month, episodeDates: damage.dates);
      } on Object catch (error) {
        _diagnosticsSink('summary recovery deferred [$error] month=${month.month}');
        continue;
      }
      if (quarantinePath != null) {
        await run.deleteIfExists(File(quarantinePath));
      }
      run.findings.add(
        MemoryRecoveryFinding(
          layerKey: 'month-summary',
          layer: month.label,
          kind: month.existed
              ? MemoryDamageKind.corrupt
              : MemoryDamageKind.missing,
          outcome: MemoryRecoveryOutcome.full,
          evidence: '从同月有效每日记录重新压缩',
        ),
      );
    }
  }

  // ---------- 热层 ----------

  /// 简单文本热层文件的损坏判定：编码失败或受管头部下结构解析失败
  /// 即损坏；无受管头部视为其他用途文件，绝不触碰。[parseable] 为
  /// null 时只检测编码失败。
  Future<_PlainFileDamage?> _detectPlainFileDamage({
    required File file,
    required String layerKey,
    required String layer,
    required String managedHeader,
    required bool Function(String contents)? parseable,
    required String loss,
  }) async {
    if (!await file.exists()) {
      return null;
    }
    String? contents;
    var encodingFailed = false;
    try {
      contents = await file.readAsString(encoding: utf8);
    } on Object {
      encodingFailed = true;
    }
    final parser = parseable;
    final damaged = encodingFailed ||
        (contents != null &&
            contents.trimLeft().startsWith(managedHeader) &&
            parser != null &&
            !parser(contents));
    if (!damaged) {
      return null;
    }
    return (file: file, layerKey: layerKey, layer: layer, loss: loss);
  }

  /// 简单文本热层文件的恢复动作：隔离原件并如实上报部分恢复。
  Future<void> _recoverPlainFile(
    _PlainFileDamage damage,
    MemoryRecoveryRun run,
  ) async {
    try {
      await run.quarantineMove(damage.file, damage.layerKey);
    } on Object catch (error) {
      _diagnosticsSink('${damage.layerKey} quarantine deferred [$error]');
      return;
    }
    run.findings.add(
      MemoryRecoveryFinding(
        layerKey: damage.layerKey,
        layer: damage.layer,
        kind: MemoryDamageKind.corrupt,
        outcome: MemoryRecoveryOutcome.partial,
        loss: damage.loss,
        quarantined: true,
      ),
    );
  }

  /// 损坏判定：daily-state.md 编码失败即损坏。
  Future<File?> _detectDailyStateDamage(MemoryRecoveryRun run) async {
    final dailyState = dailyStateMemoryFile(memoryDirectory);
    if (await dailyState.exists() &&
        await readFileIfExists(dailyState) == null) {
      return dailyState;
    }
    return null;
  }

  /// 恢复动作：隔离原件并上报（下次日终归档按近 7 天有效记录重建）。
  Future<void> _recoverDailyState(
    File dailyState,
    MemoryRecoveryRun run,
  ) async {
    try {
      await run.quarantineMove(dailyState, 'daily-state');
      run.findings.add(
        const MemoryRecoveryFinding(
          layerKey: 'daily-state',
          layer: '近日状态',
          kind: MemoryDamageKind.corrupt,
          outcome: MemoryRecoveryOutcome.pending,
          evidence: '下次日终归档按近 7 天有效记录重建',
          loss: '近日状态内容',
          quarantined: true,
        ),
      );
    } on Object catch (error) {
      _diagnosticsSink('daily-state quarantine deferred [$error]');
    }
  }

  /// 损坏判定：relationship.md 编码失败或受管结构解析失败。
  Future<bool?> _detectRelationshipDamage(MemoryRecoveryRun run) async {
    final relationship = memoryFile(memoryDirectory, relationshipFileName);
    if (!await relationship.exists()) {
      return null;
    }
    final contents = await readFileIfExists(relationship);
    final managed =
        contents != null && contents.trimLeft().startsWith('# relationship');
    final broken = contents == null ||
        (managed && parseRelationshipFile(contents) == null);
    return broken ? true : null;
  }

  /// 恢复动作：隔离原件后按幸存日文件里最近一次持久化的阶段判断
  /// 整体重建。
  Future<void> _recoverRelationship(
    bool damaged,
    MemoryRecoveryRun run,
  ) async {
    final relationship = memoryFile(memoryDirectory, relationshipFileName);
    try {
      final quarantinePath = await run.quarantineMove(relationship, 'relationship');
      final dates = await episodePipeline.listEpisodeDates();
      final rebuild = await relationshipLifecycle.rebuildForRecovery(
        episodePipeline,
        dates,
        localSessionDate(_clock()),
      );
      if (rebuild == RelationshipRebuild.restored) {
        // 阶段来自持久化判断，完整恢复：隔离副本随之删除。
        await run.deleteIfExists(File(quarantinePath));
      }
      run.findings.add(
        MemoryRecoveryFinding(
          layerKey: 'relationship',
          layer: '关系记录',
          kind: MemoryDamageKind.corrupt,
          outcome: rebuild == RelationshipRebuild.restored
              ? MemoryRecoveryOutcome.full
              : MemoryRecoveryOutcome.pending,
          evidence: switch (rebuild) {
            RelationshipRebuild.restored =>
              '从幸存日文件里最近一次持久化的阶段判断整体重建（不受日终一级限制）',
            RelationshipRebuild.seeded =>
              '未找到持久化的阶段判断，按初识保守重建，等日终模型追认',
            RelationshipRebuild.skipped => null,
          },
          loss: rebuild == RelationshipRebuild.restored ? null : '关系记录内容',
          quarantined: rebuild != RelationshipRebuild.restored,
        ),
      );
    } on Object catch (error) {
      _diagnosticsSink('relationship recovery deferred [$error]');
    }
  }

  // ---------- PersonaTree、长期印象与 Dream 状态 ----------

  /// 损坏判定：long-memory.md 编码失败或受管结构不可读。
  Future<bool?> _detectLongMemoryDamage(MemoryRecoveryRun run) async {
    final longMemory = memoryFile(memoryDirectory, longMemoryFileName);
    if (!await longMemory.exists()) {
      return null;
    }
    final contents = await readFileIfExists(longMemory);
    final managed =
        contents != null && contents.trimLeft().startsWith('# long-memory');
    final broken = contents == null ||
        (managed && !parseLongMemory(contents).readable);
    return broken ? true : null;
  }

  /// 恢复动作：优先从最近有效 Dream 备份恢复（完成过备份恢复时
  /// 标记运行上下文，供表尾的 controls-reapply 行接力）；没有备份时
  /// 隔离并等待语义恢复，绝不补写无法证明的长期内容。
  Future<void> _recoverLongMemoryFromBackup(
    bool damaged,
    MemoryRecoveryRun run,
  ) async {
    final longMemory = memoryFile(memoryDirectory, longMemoryFileName);
    final backup = await dreamService.readLongMemoryBackup();
    if (backup != null) {
      try {
        final quarantinePath = await run.quarantineCopy(
          longMemory,
          'long-memory',
        );
        await _atomicWriter.replace(longMemory.path, backup);
        await run.deleteIfExists(File(quarantinePath));
        run.markBackupRestored();
        run.findings.add(
          const MemoryRecoveryFinding(
            layerKey: 'long-memory',
            layer: '长期印象',
            kind: MemoryDamageKind.corrupt,
            outcome: MemoryRecoveryOutcome.full,
            evidence: '从最近一次 Dream 备份恢复',
          ),
        );
      } on Object catch (error) {
        _diagnosticsSink('long-memory recovery deferred [$error]');
      }
    } else {
      try {
        await run.quarantineMove(longMemory, 'long-memory');
        run.findings.add(
          const MemoryRecoveryFinding(
            layerKey: 'long-memory',
            layer: '长期印象',
            kind: MemoryDamageKind.corrupt,
            outcome: MemoryRecoveryOutcome.pending,
            evidence: '无有效 Dream 备份',
            loss: '长期印象内容',
            quarantined: true,
          ),
        );
      } on Object catch (error) {
        _diagnosticsSink('long-memory quarantine deferred [$error]');
      }
    }
  }

  /// 损坏判定：任一画像分支或归档不可读。
  Future<_PersonaTreeDamage?> _detectPersonaTreeDamage(
    MemoryRecoveryRun run,
  ) async {
    final snapshot = await personaTree.readSnapshot();
    final damaged = snapshot.branches.values.any(
      (view) => !view.readable || !view.archiveReadable,
    );
    return damaged ? (snapshot: snapshot) : null;
  }

  /// 恢复动作：优先 Dream 备份恢复；无备份时隔离并暂停受影响分支
  /// 的根节点操作（快照 archiveReadable 已驱动拒绝）。恢复前先隔离
  /// 损坏原件：备份落盘成功才删除副本，落盘失败保留。
  Future<void> _recoverPersonaTreeFromBackup(
    _PersonaTreeDamage damage,
    MemoryRecoveryRun run,
  ) async {
    final snapshot = damage.snapshot;
    final backup = await dreamService.readPersonaTreeBackup();
    final restoreSet = <String, String>{};
    // 显式记录每个待恢复项（恢复键 → 层键/标签/隔离路径），结果循环
    // 不再从文件名反推。
    final restoreRecords =
        <({
          String restoreKey,
          String layerKey,
          String label,
          String quarantinePath,
        })>[];
    for (final branch in personaBranches) {
      final view = snapshot.branches[branch.wireName];
      final activeFile = memoryFile(
        memoryDirectory,
        'persona-tree/${branch.fileName}',
      );
      if (view != null && !view.readable && await activeFile.exists()) {
        final layerKey = 'persona-branch-${branch.wireName}';
        final label = '画像分支（${branch.title}）';
        final backupContent = backup[branch.fileName];
        try {
          final quarantinePath = await run.quarantineMove(activeFile, layerKey);
          if (backupContent != null) {
            restoreSet[branch.fileName] = backupContent;
            restoreRecords.add((
              restoreKey: branch.fileName,
              layerKey: layerKey,
              label: label,
              quarantinePath: quarantinePath,
            ));
          } else {
            run.findings.add(
              MemoryRecoveryFinding(
                layerKey: layerKey,
                layer: label,
                kind: MemoryDamageKind.corrupt,
                outcome: MemoryRecoveryOutcome.pending,
                evidence: '无有效 Dream 备份',
                loss: '该分支画像内容',
                quarantined: true,
              ),
            );
          }
        } on Object catch (error) {
          _diagnosticsSink('persona quarantine deferred [$error]');
        }
      }
      final archiveFile = memoryFile(
        memoryDirectory,
        'persona-tree/archive/${branch.fileName}',
      );
      if (view != null && !view.archiveReadable && await archiveFile.exists()) {
        final layerKey = 'persona-archive-${branch.wireName}';
        final label = '画像归档（${branch.title}）';
        final archiveKey = 'archive/${branch.fileName}';
        String? archiveContents;
        try {
          archiveContents = await archiveFile.readAsString(encoding: utf8);
        } on Object {
          archiveContents = null;
        }
        if (archiveContents != null &&
            archiveContents.contains(pausedArchiveMarker)) {
          // 已是墓碑状态：保持暂停，不重复隔离；可见性由隔离清单承担。
          continue;
        }
        final backupContent = backup[archiveKey];
        try {
          final quarantinePath = await run.quarantineMove(archiveFile, layerKey);
          if (backupContent != null) {
            restoreSet[archiveKey] = backupContent;
            restoreRecords.add((
              restoreKey: archiveKey,
              layerKey: layerKey,
              label: label,
              quarantinePath: quarantinePath,
            ));
          } else {
            // 留下墓碑保持「归档不可读」：该分支暂停根节点升降，
            // 直到用户以明确操作恢复归档。
            await _atomicWriter.replace(
              archiveFile.path,
              '$pausedArchiveMarker ${branch.wireName} -->\n',
            );
            run.findings.add(
              MemoryRecoveryFinding(
                layerKey: layerKey,
                layer: label,
                kind: MemoryDamageKind.corrupt,
                outcome: MemoryRecoveryOutcome.pending,
                evidence: '无有效 Dream 备份',
                loss: '该分支归档内容，受影响分支暂停根节点升降',
                quarantined: true,
              ),
            );
          }
        } on Object catch (error) {
          _diagnosticsSink('persona archive quarantine deferred [$error]');
        }
      }
    }
    if (restoreSet.isNotEmpty) {
      var applied = const <String>{};
      try {
        applied = await personaTree.restoreBackupFiles(restoreSet);
      } on Object catch (error) {
        _diagnosticsSink('persona restore deferred [$error]');
      }
      for (final record in restoreRecords) {
        if (applied.contains(record.restoreKey)) {
          // 备份完整落盘：完整恢复，隔离副本删除。
          await run.deleteIfExists(File(record.quarantinePath));
          run.markBackupRestored();
          run.findings.add(
            MemoryRecoveryFinding(
              layerKey: record.layerKey,
              layer: record.label,
              kind: MemoryDamageKind.corrupt,
              outcome: MemoryRecoveryOutcome.full,
              evidence: '从最近一次 Dream 备份恢复',
            ),
          );
        } else {
          // 备份内容校验失败：隔离原件保留，等待语义恢复。
          run.findings.add(
            MemoryRecoveryFinding(
              layerKey: record.layerKey,
              layer: record.label,
              kind: MemoryDamageKind.corrupt,
              outcome: MemoryRecoveryOutcome.pending,
              evidence: 'Dream 备份内容无法通过校验',
              loss: record.restoreKey.startsWith('archive/')
                  ? '该分支归档内容，受影响分支暂停根节点升降'
                  : '该分支画像内容',
              quarantined: true,
            ),
          );
        }
      }
    }
  }

  /// 损坏判定：persona.md 编码失败或投影结构校验失败。
  Future<_PersonaProjectionDamage?> _detectPersonaProjectionDamage(
    MemoryRecoveryRun run,
  ) async {
    final persona = memoryFile(memoryDirectory, personaFileName);
    if (!await persona.exists()) {
      return null;
    }
    final contents = await readFileIfExists(persona);
    if (_personaProjectionValid(contents)) {
      return null;
    }
    return (salvagedAppellation: extractAppellationLine(contents));
  }

  /// 恢复动作：树完整时从活跃根重投影（重投影从仍在原地的原件抢救
  /// 称呼行，隔离副本随后删除）；树不完整时隔离等待，救出的称呼行
  /// 落回最小 persona.md 等下次重投影带上，救不出就退回「未设置」，
  /// 绝不编一个称呼（ADR 0005）。
  Future<void> _recoverPersonaProjection(
    _PersonaProjectionDamage damage,
    MemoryRecoveryRun run,
  ) async {
    final persona = memoryFile(memoryDirectory, personaFileName);
    final salvagedAppellation = damage.salvagedAppellation;
    final freshSnapshot = await personaTree.readSnapshot();
    final allReadable = freshSnapshot.branches.values.every(
      (branchView) => branchView.readable,
    );
    if (allReadable) {
      try {
        final quarantinePath = await run.quarantineCopy(
          persona,
          'persona-projection',
        );
        await personaTree.regeneratePersonaProjection();
        await run.deleteIfExists(File(quarantinePath));
        run.findings.add(
          const MemoryRecoveryFinding(
            layerKey: 'persona-projection',
            layer: '画像投影',
            kind: MemoryDamageKind.corrupt,
            outcome: MemoryRecoveryOutcome.full,
            evidence: '从画像树活跃根重新投影',
          ),
        );
      } on Object catch (error) {
        _diagnosticsSink('persona projection deferred [$error]');
      }
    } else {
      try {
        await run.quarantineMove(persona, 'persona-projection');
        if (salvagedAppellation != null) {
          await _atomicWriter.replace(
            persona.path,
            '# persona\n$salvagedAppellation\n',
          );
        }
        run.findings.add(
          MemoryRecoveryFinding(
            layerKey: 'persona-projection',
            layer: '画像投影',
            kind: MemoryDamageKind.corrupt,
            outcome: MemoryRecoveryOutcome.pending,
            evidence: salvagedAppellation == null
                ? '画像树尚不完整，等待分支恢复后重投影'
                : '画像树尚不完整；称呼行已抢救，等待分支恢复后重投影',
            loss: '画像投影',
            quarantined: true,
          ),
        );
      } on Object catch (error) {
        _diagnosticsSink('persona projection quarantine deferred [$error]');
      }
    }
  }

  /// 损坏判定：dream/state.md 状态标记缺失或解码失败。
  Future<File?> _detectDreamStateDamage(MemoryRecoveryRun run) async {
    final state = memoryFile(memoryDirectory, 'dream/state.md');
    if (!await state.exists()) {
      return null;
    }
    var valid = false;
    final contents = await readFileIfExists(state);
    if (contents != null) {
      final match = dreamStateMarkerPattern.firstMatch(contents);
      if (match != null) {
        try {
          final json = decodeMarkerPayload(match.group(1)!);
          valid = json['schemaVersion'] == 1;
        } on Object {
          valid = false;
        }
      }
    }
    return valid ? null : state;
  }

  /// 恢复动作：隔离原件并上报（重置为空状态）。
  Future<void> _recoverDreamState(File state, MemoryRecoveryRun run) async {
    try {
      await run.quarantineMove(state, 'dream-state');
      run.findings.add(
        const MemoryRecoveryFinding(
          layerKey: 'dream-state',
          layer: 'Dream 状态',
          kind: MemoryDamageKind.corrupt,
          outcome: MemoryRecoveryOutcome.partial,
          evidence: '重置为空状态，晚安后重新评估',
          loss: '上次 Dream 成功时间记录',
          quarantined: true,
        ),
      );
    } on Object catch (error) {
      _diagnosticsSink('dream state quarantine deferred [$error]');
    }
  }

  /// 损坏判定：本轮完成过 Dream 备份恢复——恢复出的旧备份可能带
  /// 回其后被删除/禁提的内容。
  Future<bool?> _detectControlsReapply(MemoryRecoveryRun run) async {
    return run.backupRestored ? true : null;
  }

  /// 恢复动作：对现行控制集合（禁提 ∪ 删除）重跑派生清除。控制
  /// 集合不可读时跳过——此时没有可信范围可比对，控制恢复本身已
  /// 如实上报。
  Future<void> _recoverControlsReapply(
    bool damaged,
    MemoryRecoveryRun run,
  ) async {
    await _reapplyControlsAfterBackupRestore();
  }

  /// Dream 备份恢复后，对现行控制集合（禁提 ∪ 删除）再跑一遍派生
  /// 清除：备份定格在上次 Dream，其后被删除/禁提的内容可能随旧备份
  /// 复活（长期印象与画像分支都会立刻重新注入），必须按现行控制拦下。
  /// 控制集合不可读时跳过——此时没有可信范围可比对，控制恢复本身
  /// 已如实上报。
  Future<void> _reapplyControlsAfterBackupRestore() async {
    try {
      final controls = await memoryControls.load();
      if (!controls.readable) {
        return;
      }
      for (final entry in [...controls.banned, ...controls.deleted]) {
        try {
          await memoryActions.purgeDerivedScopes(
            {normalizeMemoryText(entry.summary)},
            text: entry.summary,
          );
        } on Object catch (error) {
          _diagnosticsSink('backup restore purge deferred [$error]');
        }
      }
    } on Object catch (error) {
      _diagnosticsSink('backup restore purge deferred [$error]');
    }
  }

  bool _personaProjectionValid(String? contents) {
    if (contents == null) {
      return false;
    }
    final titles = {for (final branch in personaBranches) branch.personaTitle};
    var sawHeader = false;
    var sawAppellation = false;
    for (final rawLine in contents.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (!sawHeader) {
        if (line != '# persona') {
          return false;
        }
        sawHeader = true;
        continue;
      }
      // 受保护称呼设定行：只允许出现一次且值通过格式校验；只有设定
      // 行没有投影节的最小文件（恢复抢救落回）同样有效。
      if (line.startsWith(appellationLinePrefix)) {
        if (sawAppellation ||
            extractAppellationLine(line) == null) {
          return false;
        }
        sawAppellation = true;
        continue;
      }
      if (line.startsWith('## ')) {
        if (!titles.contains(line.substring(3).trim())) {
          return false;
        }
        continue;
      }
      if (!line.startsWith('- ')) {
        return false;
      }
    }
    return sawHeader;
  }

  // ---------- 隔离清单合并与持久化 ----------

  /// 隔离区仍有原件的层，如果本轮没有产生新发现，则合成一条持续性
  /// 条目：用户必须始终能看到仍保留的原始证据与未完全恢复的范围。
  Future<void> _appendQuarantineInventory(
    List<MemoryRecoveryFinding> findings,
  ) async {
    final directory = _quarantineDirectory;
    if (!await directory.exists()) {
      return;
    }
    final keys = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final parts = path.basename(entity.path).split('__');
      if (parts.length >= 3) {
        keys.add(parts[1]);
      }
    }
    final covered = {for (final finding in findings) finding.layerKey};
    for (final key in keys.toList()..sort()) {
      if (covered.contains(key)) {
        continue;
      }
      findings.add(
        MemoryRecoveryFinding(
          layerKey: key,
          layer: _quarantineLayerLabel(key),
          kind: MemoryDamageKind.corrupt,
          outcome: MemoryRecoveryOutcome.partial,
          loss: '隔离原件仍保留，内容未完全恢复',
          quarantined: true,
          loggable: false,
        ),
      );
    }
  }

  Future<int> _quarantineCount() async {
    final directory = _quarantineDirectory;
    if (!await directory.exists()) {
      return 0;
    }
    var count = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) {
        count += 1;
      }
    }
    return count;
  }

  /// 按字节复制损坏原件到隔离区（唯一原始证据的保全副本），返回
  /// 隔离路径。先复制到临时名再改名落位：中断不会在隔离区留下被
  /// 误计为保全原件的半成品。
  Future<String> _quarantineCopy(File file, String layerKey) async {
    final directory = _quarantineDirectory;
    await directory.create(recursive: true);
    final stamp = _clock().toUtc().microsecondsSinceEpoch;
    final target = memoryFile(
      directory.path,
      '${stamp}__${layerKey}__${path.basename(file.path)}',
    ).path;
    final temporary = File('$target.$stamp.tmp');
    await file.copy(temporary.path);
    await temporary.rename(target);
    return target;
  }

  /// 先复制保全再移除原位文件：损坏原件退出注入、检索与整理，证据
  /// 保留在隔离区。返回隔离路径；完整恢复后由调用方删除副本。
  Future<String> _quarantineMove(File file, String layerKey) async {
    return episodePipeline.commits.commit(() async {
      final quarantinePath = await _quarantineCopy(file, layerKey);
      await episodePipeline.commits.delete(file);
      return quarantinePath;
    });
  }

  /// 文件存在时复制保全（原位文件随后会被重建覆盖）。返回隔离路径；
  /// 不存在或失败返回 null。
  Future<String?> _quarantineIfExists(File file, String layerKey) async {
    try {
      if (await file.exists()) {
        return await _quarantineCopy(file, layerKey);
      }
    } on Object catch (error) {
      _diagnosticsSink('quarantine deferred [$error] layer=$layerKey');
    }
    return null;
  }

  Future<void> _persist(MemoryRecoveryReport report) async {
    try {
      await _recoveryDirectory.create(recursive: true);
      final loggable = report.findings.where(
        (finding) => finding.loggable,
      );
      if (loggable.isNotEmpty) {
        final buffer = StringBuffer();
        for (final finding in loggable) {
          buffer.writeln(
            '${report.generatedAt.toIso8601String()} | ${finding.layer} | '
            '${finding.outcome.label} | ${finding.loss ?? '无'}',
          );
        }
        // 日志同样走 temp+rename 原子替换（读旧内容拼接后整体写回），
        // 中断不会留下写了一半的追加行。
        final existing = await readFileIfExists(_logFile) ?? '';
        await _atomicWriter.replace(_logFile.path, existing + buffer.toString());
      }
      await _atomicWriter.replace(
        _reportFile.path,
        '# recovery-report\n\n'
            '<!-- qiyu-recovery-report:'
            '${encodeMarkerPayload(report.toJson())} -->\n',
      );
    } on Object catch (error) {
      _diagnosticsSink('recovery persist deferred [$error]');
    }
  }

  /// 委托产出的路径为正斜杠拼装：仅供 File I/O 与 basename 使用，
  /// 禁止对它做字符串等值比较。
  File _episodeDayFile(String date) =>
      memoryFile(memoryDirectory, episodeDayRelativePath(date));

  /// 编码损坏时的宽松解码兜底：宁可带着替换字符抢救正文结构，也
  /// 不因外围编码失败丢弃原始证据。
  Future<String> _readLenient(File file) =>
      file.readAsString(encoding: const Utf8Codec(allowMalformed: true));

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on Object {
      // 隔离副本删除失败只影响占用，不影响恢复结果。
    }
  }

  int _countOccurrences(String contents, String needle) {
    var count = 0;
    var index = 0;
    while (true) {
      index = contents.indexOf(needle, index);
      if (index < 0) {
        return count;
      }
      count += 1;
      index += needle.length;
    }
  }

  DateTime? _parseUtc(String? value) {
    if (value == null) {
      return null;
    }
    try {
      return DateTime.parse(value).toUtc();
    } on Object {
      return null;
    }
  }
}
