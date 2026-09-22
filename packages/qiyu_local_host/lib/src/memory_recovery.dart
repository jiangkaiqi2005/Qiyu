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
  }) : _indexStore = indexStore ??
           EpisodeIndexStore(
             memoryDirectory: memoryDirectory,
             episodePipeline: episodePipeline,
           ),
       _clock = clock ?? DateTime.now,
       _atomicWriter = episodePipeline.commits.wrap(atomicWriter),
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

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

  Directory get _recoveryDirectory =>
      Directory(path.join(memoryDirectory, 'recovery'));
  Directory get _quarantineDirectory =>
      Directory(path.join(_recoveryDirectory.path, 'quarantine'));
  File get _logFile => File(path.join(_recoveryDirectory.path, 'recovery.log'));
  File get _reportFile =>
      File(path.join(_recoveryDirectory.path, 'report.md'));

  /// 一次完整的启动恢复扫描。逐层检测五类损坏、隔离原件、自底向上
  /// 重建，最后落日志与报告。任一层失败只记诊断，绝不抛出阻塞启动。
  Future<MemoryRecoveryReport> sweepAndRecover() async {
    final findings = <MemoryRecoveryFinding>[];
    await _step(() => _cleanOrphanedTempFiles(findings), 'temp-files');
    await _step(() => _recoverSessions(findings), 'sessions');

    final sessionIds = await _validSessionIds();
    await _step(
      () => episodePipeline.synchronizedOnDayFiles(() async {
        await _salvageEpisodeDays(findings);
        await _recoverCheckpoint(findings, sessionIds);
      }),
      'episodes',
    );

    // 控制记录必须在索引与月摘要重建之前恢复：后两者的受控过滤依赖
    // 控制集合；恢复后立刻清除可能随抢救复活的被控内容。
    await _step(() => _recoverControls(findings), 'controls');

    await _step(
      () => episodePipeline.synchronizedOnDayFiles(() async {
        await _recoverIndexes(findings);
        await _recoverMonthlySummaries(findings);
      }),
      'indexes',
    );

    await _step(() => _recoverHotLayer(findings), 'hot-layer');
    await _step(() => _recoverLongTerm(findings), 'long-term');
    await _step(() async {
      await _appendQuarantineInventory(findings);
    }, 'inventory');

    final report = MemoryRecoveryReport(
      generatedAt: _clock().toUtc(),
      findings: findings,
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

  Future<void> _step(Future<void> Function() body, String label) async {
    try {
      await body();
    } on Object catch (error) {
      _diagnosticsSink('memory recovery step deferred [$error] step=$label');
    }
  }

  // ---------- 写入中断残留 ----------

  /// 清理原子写中断留下的孤儿临时文件（`*.tmp`）：它们从不参与记忆
  /// 流程，也不是原始证据，直接删除。
  Future<void> _cleanOrphanedTempFiles(
    List<MemoryRecoveryFinding> findings,
  ) async {
    final root = Directory(memoryDirectory);
    if (!await root.exists()) {
      return;
    }
    var removed = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !_tmpFilePattern.hasMatch(entity.path)) {
        continue;
      }
      try {
        await entity.delete();
        removed += 1;
      } on Object {
        // 残留清理失败不影响其余恢复。
      }
    }
    if (removed > 0) {
      findings.add(
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

  Future<void> _recoverSessions(List<MemoryRecoveryFinding> findings) async {
    final directory = Directory(path.join(memoryDirectory, 'sessions'));
    if (!await directory.exists()) {
      return;
    }
    final files = await directory
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File && entity.path.endsWith('.md'))
        .cast<File>()
        .toList();
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
        // 元数据与全部对话块完整：健康（尾部无害内容不影响解析）。
        try {
          RawSession.fromJson(metadata, turns);
          continue;
        } on Object {
          metadata = null; // 元数据字段缺失：按损坏处理。
        }
      }

      final kind = encodingCorrupt ||
              (metadataMatch != null && metadata == null)
          ? MemoryDamageKind.corrupt
          : MemoryDamageKind.incomplete;

      if (metadata != null && turns.isNotEmpty) {
        // 抢救：完整对话块可独立验证，逐块重写干净文件。编码损坏但
        // 全部块完整时同样走这里——重写后内容无损，隔离副本随之删除。
        try {
          final session = RawSession.fromJson(metadata, turns);
          final quarantinePath = await _quarantineCopy(file, 'session');
          await _atomicWriter.replace(
            file.path,
            renderSessionMarkdown(session),
          );
          // 截断在标记中间时残行匹配不了完整正则，健康检查里按前缀
          // 计数的结果同样适用：这类损坏只能部分恢复。
          final full = failedMarkers == 0 && !truncatedTurns;
          if (full) {
            await _deleteIfExists(File(quarantinePath));
          }
          findings.add(
            MemoryRecoveryFinding(
              layerKey: 'session',
              layer: label,
              kind: kind,
              outcome: full
                  ? MemoryRecoveryOutcome.full
                  : MemoryRecoveryOutcome.partial,
              evidence: '从文件内完整对话块 ${turns.length} 段抢救',
              loss: full ? null : '未完整解析的对话块',
              quarantined: !full,
            ),
          );
          continue;
        } on Object catch (error) {
          _diagnosticsSink('session salvage deferred [$error]');
        }
      }

      // 无法抢救：隔离原件（保留唯一证据），原位移除避免继续参与扫描。
      try {
        await _quarantineMove(file, 'session');
      } on Object catch (error) {
        _diagnosticsSink('session quarantine deferred [$error]');
        continue;
      }
      findings.add(
        MemoryRecoveryFinding(
          layerKey: 'session',
          layer: label,
          kind: kind,
          outcome: MemoryRecoveryOutcome.pending,
          loss: metadata == null
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

  Future<void> _salvageEpisodeDays(List<MemoryRecoveryFinding> findings) async {
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
        // 没有栖语元数据标记：可能是用户手写的普通 Markdown，绝不触碰。
        continue;
      }
      // 宽松解析会把尾部截断当成可读：按标记前缀计数找出丢失的块。
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

      if (entries.isEmpty && metadata == null) {
        // 无任何可验证内容：隔离原件，原位删除，等待语义恢复。
        try {
          await _quarantineMove(file, 'episode-day');
        } on Object catch (error) {
          _diagnosticsSink('episode quarantine deferred [$error]');
          continue;
        }
        findings.add(
          MemoryRecoveryFinding(
            layerKey: 'episode-day',
            layer: label,
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
        final quarantinePath = await _quarantineCopy(file, 'episode-day');
        await episodePipeline.writeFinalization(
          date,
          entries: entries,
          summary: metadata?['summary'] as String?,
          finalized: metadata?['finalized'] == true,
          finalizedAt: _parseUtc(metadata?['finalizedAt'] as String?),
          understanding: metadata?['understanding'] is Map<String, Object?>
              ? metadata!['understanding']! as Map<String, Object?>
              : null,
        );
        // 元数据与全部条目完整（仅编码等外围损坏）：重写后内容无损。
        final full = metadata != null && failedMarkers == 0 && !truncated;
        if (full) {
          await _deleteIfExists(File(quarantinePath));
        }
        findings.add(
          MemoryRecoveryFinding(
            layerKey: 'episode-day',
            layer: label,
            kind: metadata == null
                ? MemoryDamageKind.incomplete
                : MemoryDamageKind.corrupt,
            outcome: full
                ? MemoryRecoveryOutcome.full
                : MemoryRecoveryOutcome.partial,
            evidence: '从文件内完整条目 ${entries.length} 条抢救',
            loss: full
                ? null
                : metadata == null
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

  Future<void> _recoverCheckpoint(
    List<MemoryRecoveryFinding> findings,
    Set<String> sessionIds,
  ) async {
    final file = File(
      path.join(memoryDirectory, 'episodes', 'checkpoint.md'),
    );
    if (!await file.exists()) {
      return;
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
    final orphaned = metadata != null &&
        sessionId is String &&
        sessionIds.isNotEmpty &&
        !sessionIds.contains(sessionId);
    if (metadata != null && !orphaned) {
      return;
    }
    String quarantinePath;
    try {
      quarantinePath = await _quarantineMove(file, 'checkpoint');
    } on Object catch (error) {
      _diagnosticsSink('checkpoint quarantine deferred [$error]');
      return;
    }
    // 检查点可从会话完整重推（条目标识去重避免重复整理）：完整恢复，
    // 隔离副本随之删除。
    await _deleteIfExists(File(quarantinePath));
    findings.add(
      MemoryRecoveryFinding(
        layerKey: 'checkpoint',
        layer: '整理检查点',
        kind: orphaned
            ? MemoryDamageKind.orphaned
            : MemoryDamageKind.corrupt,
        outcome: MemoryRecoveryOutcome.full,
        evidence: orphaned
            ? '指向的会话已不存在，重置后从未归档会话开头重扫'
            : '重置后从未归档会话开头重扫，按条目标识去重避免重复整理',
      ),
    );
  }

  // ---------- 记忆控制 ----------

  /// 控制文件损坏时从 episode 控制事件审计重建（禁提/冻结/解除冻结/
  /// 删除的簿记条目），重建后对封禁范围跑既有派生清除管线，绝不让
  /// 被控制内容随抢救复活。审计无法证明完整性：隔离原件一律保留。
  Future<void> _recoverControls(List<MemoryRecoveryFinding> findings) async {
    final controls = await memoryControls.load();
    if (controls.readable) {
      return;
    }
    final file = memoryControls.controlsFile;
    String? quarantinePath;
    try {
      quarantinePath = await _quarantineCopy(file, 'controls');
    } on Object catch (error) {
      _diagnosticsSink('controls quarantine deferred [$error]');
    }
    if (quarantinePath == null) {
      // 隔离保全失败：绝不覆盖唯一原始证据，保持现状等待下轮重试。
      findings.add(
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
      findings.add(
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
    findings.add(
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

  Future<void> _recoverIndexes(List<MemoryRecoveryFinding> findings) async {
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
        findings.add(
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
      findings.add(
        MemoryRecoveryFinding(
          layerKey: 'top-index',
          layer: '月份索引',
          kind: MemoryDamageKind.missing,
          outcome: MemoryRecoveryOutcome.full,
          evidence: '从现存有效每日记录重建',
        ),
      );
    } else if (top == null) {
      dirty = true;
      final quarantinePath = await _quarantineIfExists(topFile, 'top-index');
      if (quarantinePath != null) {
        quarantined.add(quarantinePath);
      }
      findings.add(
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
        findings.add(
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
          final quarantinePath = await _quarantineIfExists(
            monthFile,
            'month-index',
          );
          if (quarantinePath != null) {
            quarantined.add(quarantinePath);
          }
          findings.add(
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
          findings.add(
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

    if (dirty) {
      await _indexStore.rebuild();
      // 索引可完全从现存每日记录推导：重建成功后隔离副本删除。
      for (final quarantinePath in quarantined) {
        await _deleteIfExists(File(quarantinePath));
      }
    }
  }

  Future<void> _recoverMonthlySummaries(
    List<MemoryRecoveryFinding> findings,
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
    for (final MapEntry(:key, :value) in months.entries) {
      if (!value) {
        continue;
      }
      final summary = await monthlySummary.readMonthSummary(key);
      if (summary != null && summary.readable) {
        continue;
      }
      final label = '月度摘要（$key）';
      String? quarantinePath;
      if (summary != null) {
        // 存在但不可读：隔离原件后重新压缩。
        quarantinePath = await _quarantineIfExists(
          monthlySummary.summaryFile(key),
          'month-summary',
        );
        try {
          await episodePipeline.commits.delete(monthlySummary.summaryFile(key));
        } on Object {
          // 删除失败时压缩会因不可读而跳过，下轮再试。
        }
      }
      try {
        await monthlySummary.compressMonth(key, episodeDates: dates);
      } on Object catch (error) {
        _diagnosticsSink('summary recovery deferred [$error] month=$key');
        continue;
      }
      // 月摘要可完全从同月每日记录重新压缩：隔离副本随之删除。
      if (quarantinePath != null) {
        await _deleteIfExists(File(quarantinePath));
      }
      findings.add(
        MemoryRecoveryFinding(
          layerKey: 'month-summary',
          layer: label,
          kind: summary == null
              ? MemoryDamageKind.missing
              : MemoryDamageKind.corrupt,
          outcome: MemoryRecoveryOutcome.full,
          evidence: '从同月有效每日记录重新压缩',
        ),
      );
    }
  }

  // ---------- 热层 ----------

  Future<void> _recoverHotLayer(List<MemoryRecoveryFinding> findings) async {
    // open-loops.md：损坏即隔离；活跃事项无法从现有证据确定性重建，
    // 诚实报部分恢复，等待日终重新整理。
    await _recoverPlainFile(
      file: File(path.join(memoryDirectory, 'open-loops.md')),
      layerKey: 'open-loops',
      layer: '未闭环事项',
      managedHeader: '# open-loops',
      parseable: (contents) => parseOpenLoopItems(contents) != null,
      loss: '未闭环事项内容',
      findings: findings,
    );
    await _recoverPlainFile(
      file: File(path.join(memoryDirectory, 'open-loops.archive.md')),
      layerKey: 'open-loops-archive',
      layer: '未闭环事项归档',
      managedHeader: '# open-loops archive',
      parseable: null, // 归档格式宽松，只处理编码失败。
      loss: '已闭环事项归档',
      findings: findings,
    );

    // daily-state.md：编码失败才算损坏；重建归下一次日终归档。
    final dailyState = File(path.join(memoryDirectory, 'daily-state.md'));
    if (await dailyState.exists() &&
        await readFileIfExists(dailyState) == null) {
      try {
        await _quarantineMove(dailyState, 'daily-state');
        findings.add(
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

    // relationship.md：受管结构损坏时按幸存日文件里最近一次持久化
    // 的阶段判断整体重建；没有判断按初识保守重建，等日终模型追认。
    final relationship = File(path.join(memoryDirectory, 'relationship.md'));
    if (await relationship.exists()) {
      final contents = await readFileIfExists(relationship);
      final managed =
          contents != null && contents.trimLeft().startsWith('# relationship');
      final broken = contents == null ||
          (managed && parseRelationshipFile(contents) == null);
      if (broken) {
        try {
          final quarantinePath = await _quarantineMove(relationship, 'relationship');
          final dates = await episodePipeline.listEpisodeDates();
          final rebuild = await relationshipLifecycle.rebuildForRecovery(
            episodePipeline,
            dates,
            localSessionDate(_clock()),
          );
          if (rebuild == RelationshipRebuild.restored) {
            // 阶段来自持久化判断，完整恢复：隔离副本随之删除。
            await _deleteIfExists(File(quarantinePath));
          }
          findings.add(
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
              loss: rebuild == RelationshipRebuild.restored
                  ? null
                  : '关系记录内容',
              quarantined: rebuild != RelationshipRebuild.restored,
            ),
          );
        } on Object catch (error) {
          _diagnosticsSink('relationship recovery deferred [$error]');
        }
      }
    }
  }

  /// 简单文本热层文件的恢复：编码失败或受管头部下结构解析失败即
  /// 隔离；无受管头部视为其他用途文件，绝不触碰。[parseable] 为 null
  /// 时只检测编码失败。
  Future<void> _recoverPlainFile({
    required File file,
    required String layerKey,
    required String layer,
    required String managedHeader,
    required bool Function(String contents)? parseable,
    required String loss,
    required List<MemoryRecoveryFinding> findings,
  }) async {
    if (!await file.exists()) {
      return;
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
      return;
    }
    try {
      await _quarantineMove(file, layerKey);
    } on Object catch (error) {
      _diagnosticsSink('$layerKey quarantine deferred [$error]');
      return;
    }
    findings.add(
      MemoryRecoveryFinding(
        layerKey: layerKey,
        layer: layer,
        kind: MemoryDamageKind.corrupt,
        outcome: MemoryRecoveryOutcome.partial,
        loss: loss,
        quarantined: true,
      ),
    );
  }

  // ---------- PersonaTree、长期印象与 Dream 状态 ----------

  Future<void> _recoverLongTerm(List<MemoryRecoveryFinding> findings) async {
    // 任何一次 Dream 备份恢复成功后，必须对现行控制集合再跑派生清除
    // （见 _reapplyControlsAfterBackupRestore）。
    var restoredFromBackup = false;

    // long-memory.md：优先从最近有效 Dream 备份恢复；没有备份时隔离
    // 并等待语义恢复，绝不补写无法证明的长期内容。
    if (await _recoverLongMemoryFromBackup(findings)) {
      restoredFromBackup = true;
    }

    // PersonaTree 分支与归档：优先 Dream 备份恢复；无备份时隔离并
    // 暂停受影响分支的根节点操作（快照 archiveReadable 已驱动拒绝）。
    // 恢复前先隔离损坏原件：备份落盘成功才删除副本，落盘失败保留
    // （详见 [_recoverPersonaTreeFromBackup]）。
    if (await _recoverPersonaTreeFromBackup(findings)) {
      restoredFromBackup = true;
    }

    // persona.md：纯投影＋受保护称呼设定行，结构存疑时从活跃根重投
    // 影；树不完整时隔离等待，绝不写出残缺画像（详见
    // [_recoverPersonaProjection]）。
    await _recoverPersonaProjection(findings);

    // dream/state.md：损坏即隔离并重置为空状态（Dream 间隔证据丢失，
    // 下一次晚安重新评估）。
    await _recoverDreamState(findings);

    if (restoredFromBackup) {
      await _reapplyControlsAfterBackupRestore();
    }
  }

  /// long-memory.md 恢复：优先从最近有效 Dream 备份恢复；没有备份时
  /// 隔离并等待语义恢复，绝不补写无法证明的长期内容。返回是否完成过
  /// 备份恢复。
  Future<bool> _recoverLongMemoryFromBackup(
    List<MemoryRecoveryFinding> findings,
  ) async {
    var restoredFromBackup = false;
    final longMemory = File(path.join(memoryDirectory, longMemoryFileName));
    if (await longMemory.exists()) {
      final contents = await readFileIfExists(longMemory);
      final managed =
          contents != null && contents.trimLeft().startsWith('# long-memory');
      final broken = contents == null ||
          (managed && !parseLongMemory(contents).readable);
      if (broken) {
        final backup = await dreamService.readLongMemoryBackup();
        if (backup != null) {
          try {
            final quarantinePath = await _quarantineCopy(
              longMemory,
              'long-memory',
            );
            await _atomicWriter.replace(longMemory.path, backup);
            await _deleteIfExists(File(quarantinePath));
            restoredFromBackup = true;
            findings.add(
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
            await _quarantineMove(longMemory, 'long-memory');
            findings.add(
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
    }
    return restoredFromBackup;
  }

  /// PersonaTree 分支与归档恢复：优先 Dream 备份恢复；无备份时隔离
  /// 并暂停受影响分支的根节点操作（快照 archiveReadable 已驱动拒绝）。
  /// 恢复前先隔离损坏原件：备份落盘成功才删除副本，落盘失败保留。
  /// 返回是否完成过备份恢复。
  Future<bool> _recoverPersonaTreeFromBackup(
    List<MemoryRecoveryFinding> findings,
  ) async {
    var restoredFromBackup = false;
    final snapshot = await personaTree.readSnapshot();
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
      final activeFile = File(
        path.join(memoryDirectory, 'persona-tree', branch.fileName),
      );
      if (view != null && !view.readable && await activeFile.exists()) {
        final layerKey = 'persona-branch-${branch.wireName}';
        final label = '画像分支（${branch.title}）';
        final backupContent = backup[branch.fileName];
        try {
          final quarantinePath = await _quarantineMove(activeFile, layerKey);
          if (backupContent != null) {
            restoreSet[branch.fileName] = backupContent;
            restoreRecords.add((
              restoreKey: branch.fileName,
              layerKey: layerKey,
              label: label,
              quarantinePath: quarantinePath,
            ));
          } else {
            findings.add(
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
      final archiveFile = File(
        path.join(
          memoryDirectory,
          'persona-tree',
          'archive',
          branch.fileName,
        ),
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
          final quarantinePath = await _quarantineMove(archiveFile, layerKey);
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
            findings.add(
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
          await _deleteIfExists(File(record.quarantinePath));
          restoredFromBackup = true;
          findings.add(
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
          findings.add(
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
    return restoredFromBackup;
  }

  /// persona.md 投影恢复：纯投影＋受保护称呼设定行，结构存疑时从
  /// 活跃根重投影；树不完整时隔离等待，绝不写出残缺画像。隔离前先
  /// 从原件抢救称呼行（ADR 0005）：救出就落回最小 persona.md 等下次
  /// 重投影带上，救不出就退回「未设置」，绝不编一个称呼。
  Future<void> _recoverPersonaProjection(
    List<MemoryRecoveryFinding> findings,
  ) async {
    final persona = File(path.join(memoryDirectory, 'persona.md'));
    if (await persona.exists()) {
      final contents = await readFileIfExists(persona);
      final salvagedAppellation = extractAppellationLine(contents);
      if (!_personaProjectionValid(contents)) {
        final freshSnapshot = await personaTree.readSnapshot();
        final allReadable = freshSnapshot.branches.values.every(
          (branchView) => branchView.readable,
        );
        if (allReadable) {
          try {
            final quarantinePath = await _quarantineCopy(
              persona,
              'persona-projection',
            );
            // 重投影从仍在原地的原件抢救称呼行，隔离副本随后删除。
            await personaTree.regeneratePersonaProjection();
            await _deleteIfExists(File(quarantinePath));
            findings.add(
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
            await _quarantineMove(persona, 'persona-projection');
            if (salvagedAppellation != null) {
              await _atomicWriter.replace(
                persona.path,
                '# persona\n$salvagedAppellation\n',
              );
            }
            findings.add(
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
    }
  }

  /// dream/state.md 恢复：损坏即隔离并重置为空状态（Dream 间隔证据
  /// 丢失，下一次晚安重新评估）。
  Future<void> _recoverDreamState(List<MemoryRecoveryFinding> findings) async {
    final state = File(path.join(memoryDirectory, 'dream', 'state.md'));
    if (await state.exists()) {
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
      if (!valid) {
        try {
          await _quarantineMove(state, 'dream-state');
          findings.add(
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
    }
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
    final target = path.join(
      directory.path,
      '${stamp}__${layerKey}__${path.basename(file.path)}',
    );
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
      File(path.join(memoryDirectory, episodeDayRelativePath(date)));

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
