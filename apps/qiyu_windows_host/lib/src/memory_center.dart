import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'dream.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_controls.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'relationship_lifecycle.dart';

/// 「最近发生」区回看的窗口（天）：只展示近期整理记录，更早的内容
/// 由月摘要与长期印象覆盖，不在本区重复。
const memoryCenterRecentWindowDays = 31;

/// 不透明 ID 注册表容量：记忆中心每次打开都会重新拉取总览并重新
/// 注册引用，旧 ID 只在同一进程生命周期内有意义；超容量按先进先出
/// 淘汰，杜绝无界增长。
const _memoryCenterRegistryCapacity = 4096;

/// 私密标识（T25 定稿：UI 层敏感 = 私密标识/敏感经历摘要）。密钥类
/// 内容在写入时已脱敏，这里补检写入脱敏不覆盖的手机号与邮箱。
final _phoneNumberPattern = RegExp(r'(?<!\d)1[3-9]\d{9}(?!\d)');
final _emailPattern = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

/// 敏感判定由本机服务读取时生成，绝不写回 md（T25 定稿）：密钥类
/// 脱敏规则命中后仍有残留，或含手机号、邮箱等私密标识，即视为敏感。
/// 记忆动作（ticket 20）的揭示判定共用同一标准。
bool isSensitiveMemoryText(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  return redactSessionText(trimmed) != trimmed ||
      _phoneNumberPattern.hasMatch(trimmed) ||
      _emailPattern.hasMatch(trimmed);
}

/// 条目的记忆控制状态：冻结（暂停使用）或封禁（禁提 ∪ 删除）。
/// 与注入侧同一套匹配规则（包含关系），只读展示，不改写任何文件。
enum MemoryControlStatus {
  frozen,
  banned;

  String get wireName => name;
}

/// 「最近发生」条目来源的用户语言标签；簿记条目（open_loop_event，
/// 含受控标题文字）不进记忆中心，与投影侧纪律一致。
String _kindLabelFor(String kind) => switch (kind) {
  episodeKindMemory => 'memory',
  episodeKindOpenLoopCandidate => 'concern',
  episodeKindRelationshipSignal => 'relationship',
  _ => 'memory',
};

final class MemoryEntryCard {
  const MemoryEntryCard({
    required this.id,
    required this.kind,
    required this.content,
    required this.masked,
    required this.control,
    required this.at,
    required this.hasEvidence,
    required this.userEdited,
  });

  final String id;
  final String kind;

  /// 敏感条目为 null，列表与详情都不返回原文。
  final String? content;
  final bool masked;
  final MemoryControlStatus? control;
  final DateTime at;
  final bool hasEvidence;

  /// 用户修正过的条目（ticket 20）：摘要按用户声明呈现，UI 标注
  /// 「由你修正」，绝不与自动整理的证据混同。
  final bool userEdited;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    if (content != null) 'content': content,
    'masked': masked,
    if (control != null) 'control': control!.wireName,
    'at': at.toUtc().toIso8601String(),
    'hasEvidence': hasEvidence,
    'userEdited': userEdited,
  };
}

final class MemoryDayCard {
  const MemoryDayCard({
    required this.id,
    required this.date,
    required this.summary,
    required this.summaryMasked,
    required this.finalized,
    required this.finalizedAt,
    required this.entries,
  });

  final String id;
  final String date;
  final String? summary;
  final bool summaryMasked;

  /// 当日是否已完成日终归档；未归档在 UI 上呈现「整理中」。
  final bool finalized;
  final DateTime? finalizedAt;
  final List<MemoryEntryCard> entries;

  Map<String, Object?> toJson() => {
    'id': id,
    'date': date,
    if (summary != null) 'summary': summary,
    'summaryMasked': summaryMasked,
    'finalized': finalized,
    if (finalizedAt != null)
      'finalizedAt': finalizedAt!.toUtc().toIso8601String(),
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };
}

final class MemoryRecentSection {
  const MemoryRecentSection({required this.days});

  final List<MemoryDayCard> days;

  Map<String, Object?> toJson() => {
    'days': days.map((day) => day.toJson()).toList(),
  };
}

final class MemoryLongTermItem {
  const MemoryLongTermItem({
    required this.id,
    required this.content,
    required this.masked,
    required this.control,
  });

  /// 不透明引用（ticket 20）：编辑、控制与删除动作的目标。
  final String id;
  final String? content;
  final bool masked;
  final MemoryControlStatus? control;

  Map<String, Object?> toJson() => {
    'id': id,
    if (content != null) 'content': content,
    'masked': masked,
    if (control != null) 'control': control!.wireName,
  };
}

final class MemoryLongTermGroup {
  const MemoryLongTermGroup({required this.section, required this.items});

  final String section;
  final List<MemoryLongTermItem> items;

  Map<String, Object?> toJson() => {
    'section': section,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

final class MemoryLongTermSection {
  const MemoryLongTermSection({
    required this.present,
    required this.readable,
    required this.organizedAt,
    required this.groups,
  });

  /// long-memory.md 是否存在且非空。
  final bool present;

  /// 存在但结构不可识别：等待恢复流程， UI 呈现诚实的不可用说明。
  final bool readable;

  /// 最近一次成功 Dream 的时间（长期印象的唯一整理来源）。
  final DateTime? organizedAt;
  final List<MemoryLongTermGroup> groups;

  Map<String, Object?> toJson() => {
    'present': present,
    'readable': readable,
    if (organizedAt != null)
      'organizedAt': organizedAt!.toUtc().toIso8601String(),
    'groups': groups.map((group) => group.toJson()).toList(),
  };
}

final class MemoryPersonaRootCard {
  const MemoryPersonaRootCard({
    required this.id,
    required this.claim,
    required this.masked,
    required this.control,
    required this.middleCount,
    required this.leafCount,
    required this.earliestEvidence,
    required this.latestEvidence,
  });

  final String id;
  final String? claim;
  final bool masked;
  final MemoryControlStatus? control;
  final int middleCount;
  final int leafCount;
  final String? earliestEvidence;
  final String? latestEvidence;

  Map<String, Object?> toJson() => {
    'id': id,
    if (claim != null) 'claim': claim,
    'masked': masked,
    if (control != null) 'control': control!.wireName,
    'middleCount': middleCount,
    'leafCount': leafCount,
    if (earliestEvidence != null) 'earliestEvidence': earliestEvidence,
    if (latestEvidence != null) 'latestEvidence': latestEvidence,
  };
}

final class MemoryPersonaMiddleCard {
  const MemoryPersonaMiddleCard({
    required this.id,
    required this.type,
    required this.claim,
    required this.masked,
    required this.control,
    required this.formedOn,
    required this.reviewedOn,
    required this.leafCount,
    required this.hasConflict,
  });

  final String id;
  final String type;
  final String? claim;
  final bool masked;
  final MemoryControlStatus? control;

  /// 形成与最近复核日期（YYYY-MM-DD），即条目的形成/最近更新时间。
  final String formedOn;
  final String reviewedOn;
  final int leafCount;

  /// 是否存在 conflict 叶：「有冲突证据，待复核」的展示依据。
  final bool hasConflict;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    if (claim != null) 'claim': claim,
    'masked': masked,
    if (control != null) 'control': control!.wireName,
    'formedOn': formedOn,
    'reviewedOn': reviewedOn,
    'leafCount': leafCount,
    'hasConflict': hasConflict,
  };
}

final class MemoryPersonaBranchCard {
  const MemoryPersonaBranchCard({
    required this.wire,
    required this.title,
    required this.readable,
    required this.roots,
    required this.unrooted,
  });

  final String wire;
  final String title;

  /// 分支文件存在但无法解析：等待恢复流程，其余分支照常展示。
  final bool readable;
  final List<MemoryPersonaRootCard> roots;
  final List<MemoryPersonaMiddleCard> unrooted;

  Map<String, Object?> toJson() => {
    'wire': wire,
    'title': title,
    'readable': readable,
    'roots': roots.map((root) => root.toJson()).toList(),
    'unrooted': unrooted.map((middle) => middle.toJson()).toList(),
  };
}

final class MemoryPersonaSection {
  const MemoryPersonaSection({required this.branches});

  final List<MemoryPersonaBranchCard> branches;

  Map<String, Object?> toJson() => {
    'branches': branches.map((branch) => branch.toJson()).toList(),
  };
}

final class MemoryRelationshipSection {
  const MemoryRelationshipSection({
    required this.present,
    required this.stage,
    required this.since,
    required this.confirmed,
    required this.probes,
    required this.recentChanges,
    required this.sharedPast,
  });

  /// relationship.md 是否已是受管结构；手写或用户自改文件一律视为
  /// 未形成，只呈现诚实空状态，绝不展示不受控内容。
  final bool present;
  final String? stage;
  final String? since;

  /// 相处方式/试探/近期变化各行同样走读取时纪律：敏感遮罩、
  /// 冻结/禁提标识，与长期印象条目同一套规则（T25 定稿）。
  final List<MemoryLongTermItem> confirmed;
  final List<MemoryLongTermItem> probes;
  final List<MemoryLongTermItem> recentChanges;

  /// long-memory「共同过往」分区的条目：属于「我们的关系」区。
  final List<MemoryLongTermItem> sharedPast;

  Map<String, Object?> toJson() => {
    'present': present,
    if (stage != null) 'stage': stage,
    if (since != null) 'since': since,
    'confirmed': confirmed.map((item) => item.toJson()).toList(),
    'probes': probes.map((item) => item.toJson()).toList(),
    'recentChanges': recentChanges.map((item) => item.toJson()).toList(),
    'sharedPast': sharedPast.map((item) => item.toJson()).toList(),
  };
}

final class MemoryCenterOverview {
  const MemoryCenterOverview({
    required this.generatedAt,
    required this.recent,
    required this.longTerm,
    required this.persona,
    required this.relationship,
  });

  final DateTime generatedAt;
  final MemoryRecentSection recent;
  final MemoryLongTermSection longTerm;
  final MemoryPersonaSection persona;
  final MemoryRelationshipSection relationship;

  Map<String, Object?> toJson() => {
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'recent': recent.toJson(),
    'longTerm': longTerm.toJson(),
    'persona': persona.toJson(),
    'relationship': relationship.toJson(),
  };
}

/// 条目详情：episode 证据（含当时对话入口）、画像根路径、画像中间
/// 理解（含叶证据）或某一天的完整记录。全部字段读取时重新计算，
/// 绝不缓存正文。
sealed class MemoryItemDetail {
  const MemoryItemDetail();

  Map<String, Object?> toJson();
}

final class EpisodeEntryDetail extends MemoryItemDetail {
  const EpisodeEntryDetail({
    required this.date,
    required this.dayId,
    required this.kind,
    required this.content,
    required this.masked,
    required this.control,
    required this.at,
    required this.evidence,
    required this.evidenceMasked,
    required this.sessionId,
    required this.daySummary,
    required this.finalized,
    required this.userEdited,
  });

  final String date;
  final String dayId;
  final String kind;
  final String? content;
  final bool masked;
  final MemoryControlStatus? control;
  final DateTime at;

  /// 证据原话摘录；敏感时整体遮罩。用户修正过的条目没有摘录
  /// （修正不伪装原始会话证据）。
  final String? evidence;
  final bool evidenceMasked;

  /// 当时对话的会话 ID；会话已被删除时为 null，UI 不提供入口。
  final String? sessionId;
  final String? daySummary;
  final bool finalized;

  /// 是否由用户修正过（ticket 20）。
  final bool userEdited;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'episode-entry',
    'date': date,
    'dayId': dayId,
    'entryKind': kind,
    if (content != null) 'content': content,
    'masked': masked,
    if (control != null) 'control': control!.wireName,
    'at': at.toUtc().toIso8601String(),
    if (evidence != null) 'evidence': evidence,
    'evidenceMasked': evidenceMasked,
    if (sessionId != null) 'sessionId': sessionId,
    if (daySummary != null) 'daySummary': daySummary,
    'finalized': finalized,
    'userEdited': userEdited,
  };
}

final class PersonaRootDetail extends MemoryItemDetail {
  const PersonaRootDetail({
    required this.branchWire,
    required this.branchTitle,
    required this.claim,
    required this.masked,
    required this.control,
    required this.middles,
  });

  final String branchWire;
  final String branchTitle;
  final String? claim;
  final bool masked;
  final MemoryControlStatus? control;

  /// 支持该根主张的中间理解（含各自的 opaque ID 供继续下钻）。
  final List<MemoryPersonaMiddleCard> middles;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'persona-root',
    'branch': branchWire,
    'branchTitle': branchTitle,
    if (claim != null) 'claim': claim,
    'masked': masked,
    if (control != null) 'control': control!.wireName,
    'middles': middles.map((middle) => middle.toJson()).toList(),
  };
}

final class MemoryPersonaLeafCard {
  const MemoryPersonaLeafCard({
    required this.dayId,
    required this.date,
    required this.nature,
    required this.relation,
    required this.summary,
    required this.masked,
    required this.control,
  });

  /// 证据所在日期的不透明引用，供 UI 继续下钻到当日记录。
  final String dayId;
  final String date;

  /// 来源性质（明确自述/行为观察）：画像唯一的置信维度。
  final String nature;

  /// support / conflict。
  final String relation;
  final String? summary;
  final bool masked;
  final MemoryControlStatus? control;

  Map<String, Object?> toJson() => {
    'dayId': dayId,
    'date': date,
    'nature': nature,
    'relation': relation,
    if (summary != null) 'summary': summary,
    'masked': masked,
    if (control != null) 'control': control!.wireName,
  };
}

final class PersonaMiddleDetail extends MemoryItemDetail {
  const PersonaMiddleDetail({
    required this.branchWire,
    required this.branchTitle,
    required this.type,
    required this.claim,
    required this.masked,
    required this.control,
    required this.formedOn,
    required this.reviewedOn,
    required this.rootClaim,
    required this.leaves,
  });

  final String branchWire;
  final String branchTitle;
  final String type;
  final String? claim;
  final bool masked;
  final MemoryControlStatus? control;
  final String formedOn;
  final String reviewedOn;

  /// 已归根时所属根的主张；未归根为 null。
  final String? rootClaim;
  final List<MemoryPersonaLeafCard> leaves;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'persona-middle',
    'branch': branchWire,
    'branchTitle': branchTitle,
    'type': type,
    if (claim != null) 'claim': claim,
    'masked': masked,
    if (control != null) 'control': control!.wireName,
    'formedOn': formedOn,
    'reviewedOn': reviewedOn,
    if (rootClaim != null) 'rootClaim': rootClaim,
    'leaves': leaves.map((leaf) => leaf.toJson()).toList(),
  };
}

final class MemoryDayDetail extends MemoryItemDetail {
  const MemoryDayDetail({
    required this.date,
    required this.summary,
    required this.summaryMasked,
    required this.finalized,
    required this.finalizedAt,
    required this.entries,
  });

  final String date;
  final String? summary;
  final bool summaryMasked;
  final bool finalized;
  final DateTime? finalizedAt;
  final List<MemoryEntryCard> entries;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'day',
    'date': date,
    if (summary != null) 'summary': summary,
    'summaryMasked': summaryMasked,
    'finalized': finalized,
    if (finalizedAt != null)
      'finalizedAt': finalizedAt!.toUtc().toIso8601String(),
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };
}

/// 不透明 ID 背后的引用类型；只在本进程内有效，绝不落盘、绝不含
/// 文件路径。记忆中心的读取与动作（ticket 20）共用同一套解析。
sealed class MemoryItemRef {
  const MemoryItemRef();
}

final class MemoryEntryRef extends MemoryItemRef {
  const MemoryEntryRef(this.date, this.entryId);

  final String date;
  final String entryId;
}

final class MemoryRootRef extends MemoryItemRef {
  const MemoryRootRef(this.branchWire, this.rootId);

  final String branchWire;
  final String rootId;
}

final class MemoryMiddleRef extends MemoryItemRef {
  const MemoryMiddleRef(this.branchWire, this.middleId);

  final String branchWire;
  final String middleId;
}

final class MemoryDayRef extends MemoryItemRef {
  const MemoryDayRef(this.date);

  final String date;
}

/// long-memory 条目引用：四分区之一 + 注册时的条目原文。动作执行时
/// 以原文在分区内定位（条目顺序可能被后台整理改写，原文校验失败即
/// 视为「不存在或已变化」）。
final class MemoryLongTermRef extends MemoryItemRef {
  const MemoryLongTermRef(this.section, this.text);

  final String section;
  final String text;
}

/// relationship.md 各行引用（相处方式/试探/近期变化）或 long-memory
/// 「共同过往」条目。状态包各行不是控制对象（T24 定稿），只允许
/// 揭示查看；[list] 为 `sharedPast` 时指向 long-memory 文件，允许
/// 全部条目动作。
final class MemoryRelationshipRef extends MemoryItemRef {
  const MemoryRelationshipRef(this.list, this.text);

  final String list;
  final String text;
}

/// 四区记忆中心（ticket 19）：把本机 md 记忆聚合为用户可理解的
/// 四个区域——最近发生、长期印象、关于你、我们的关系。
///
/// 读取纪律（验收红线）：
/// - 本服务不持有模型客户端、不持有任何写入器，构造上杜绝模型调用
///   与隐式写入；全部数据来自各存储的只读接口与文件读取。编辑、
///   控制与删除动作归 [MemoryActionService]（ticket 20），只共用
///   opaque ID 注册表。
/// - 条目使用进程内随机 opaque ID，详情与动作按注册表解析；ID 不含
///   路径，解析失败返回 null，调用方以「不存在或已变化」呈现。
/// - 敏感内容读取时判定并遮罩，绝不写回 md；冻结/禁提状态只展示
///   标识，本服务不执行控制动作。
/// - 局部损坏（某日文件、某画像分支、long-memory 或 relationship
///   不可读）只影响对应条块，其余区域照常返回。
final class MemoryCenterService {
  MemoryCenterService({
    required this.memoryDirectory,
    required this.episodePipeline,
    required this.personaTree,
    required this.memoryControls,
    required this.dreamService,
    Clock? clock,
    void Function(String message)? diagnosticsSink,
  }) : _clock = clock ?? DateTime.now,
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final PersonaTreeStore personaTree;
  final MemoryControlsStore memoryControls;
  final DreamService dreamService;
  final Clock _clock;
  final void Function(String) _diagnosticsSink;

  final LinkedHashMap<String, MemoryItemRef> _registry = LinkedHashMap();

  File get _longMemoryFile =>
      File(path.join(memoryDirectory, 'long-memory.md'));
  File get _relationshipFile =>
      File(path.join(memoryDirectory, 'relationship.md'));

  /// 四区总览。每次调用都从磁盘重新读取，不缓存正文。
  Future<MemoryCenterOverview> overview() async {
    final controls = await memoryControls.load();
    final frozen = controls.frozenSummaries;
    final blocked = controls.blockedSummaries;
    return MemoryCenterOverview(
      generatedAt: _clock().toUtc(),
      recent: await _recentSection(frozen, blocked),
      longTerm: await _longTermSection(frozen, blocked),
      persona: await _personaSection(frozen, blocked),
      relationship: await _relationshipSection(frozen, blocked),
    );
  }

  /// 按 opaque ID 解析详情；ID 未知、已淘汰或指向的内容已不存在时
  /// 返回 null。
  Future<MemoryItemDetail?> itemDetail(String id) async {
    final ref = _registry[id];
    if (ref == null) {
      return null;
    }
    final controls = await memoryControls.load();
    final frozen = controls.frozenSummaries;
    final blocked = controls.blockedSummaries;
    switch (ref) {
      case MemoryEntryRef():
        return _entryDetail(ref, frozen, blocked);
      case MemoryRootRef():
        return _rootDetail(ref, frozen, blocked);
      case MemoryMiddleRef():
        return _middleDetail(ref, frozen, blocked);
      case MemoryDayRef():
        return _dayDetail(ref.date, frozen, blocked);
      case MemoryLongTermRef():
      case MemoryRelationshipRef():
        // 长期印象与关系条目没有独立详情页，动作直接作用于总览卡片。
        return null;
    }
  }

  /// 按 opaque ID 解析条目引用，供记忆动作（ticket 20）定位目标；
  /// ID 未知或已淘汰时返回 null。
  MemoryItemRef? resolveRef(String id) => _registry[id];

  // ---------- 总览分区 ----------

  Future<MemoryRecentSection> _recentSection(
    Set<String> frozen,
    Set<String> blocked,
  ) async {
    final cutoff = localSessionDate(
      _clock().subtract(const Duration(days: memoryCenterRecentWindowDays)),
    );
    final dates = await episodePipeline.listEpisodeDates();
    final days = <MemoryDayCard>[];
    for (final date in dates.reversed) {
      if (date.compareTo(cutoff) < 0) {
        break;
      }
      final day = await episodePipeline.readDay(date);
      if (!day.readable) {
        _diagnosticsSink('memory center day skipped reason=$date-unreadable');
        continue;
      }
      final cards = _entryCards(date, day.entries, frozen, blocked);
      if (cards.isEmpty &&
          (day.summary == null || day.summary!.trim().isEmpty)) {
        continue;
      }
      days.add(
        MemoryDayCard(
          id: _register(MemoryDayRef(date)),
          date: date,
          summary: _visible(day.summary),
          summaryMasked: _isMasked(day.summary),
          finalized: day.finalized,
          finalizedAt: day.finalizedAt,
          entries: cards,
        ),
      );
    }
    return MemoryRecentSection(days: days);
  }

  Future<MemoryLongTermSection> _longTermSection(
    Set<String> frozen,
    Set<String> blocked,
  ) async {
    final state = await dreamService.readState();
    final contents = await _readIfExists(_longMemoryFile);
    final trimmed = contents?.trim() ?? '';
    if (trimmed.isEmpty) {
      return MemoryLongTermSection(
        present: false,
        readable: true,
        organizedAt: state.lastSuccess,
        groups: const [],
      );
    }
    final parsed = parseLongMemory(trimmed);
    if (!parsed.readable) {
      return MemoryLongTermSection(
        present: true,
        readable: false,
        organizedAt: state.lastSuccess,
        groups: const [],
      );
    }
    // 「共同过往」归入「我们的关系」区，长期印象只展示其余三分区；
    // 空分区不出现，没有内容的分区由诚实空状态承担。
    final groups = [
      for (final section in longMemorySections)
        if (section != '共同过往' &&
            (parsed.sections[section] ?? const <String>[]).isNotEmpty)
          MemoryLongTermGroup(
            section: section,
            items: (parsed.sections[section] ?? const <String>[])
                .map(
                  (item) => _longTermItem(
                    MemoryLongTermRef(section, item),
                    item,
                    frozen,
                    blocked,
                  ),
                )
                .toList(),
          ),
    ];
    return MemoryLongTermSection(
      present: true,
      readable: true,
      organizedAt: state.lastSuccess,
      groups: groups,
    );
  }

  Future<MemoryPersonaSection> _personaSection(
    Set<String> frozen,
    Set<String> blocked,
  ) async {
    final snapshot = await personaTree.readSnapshot();
    final branches = <MemoryPersonaBranchCard>[];
    for (final branch in personaBranches) {
      final view = snapshot.branches[branch.wireName];
      if (view == null || !view.readable) {
        branches.add(
          MemoryPersonaBranchCard(
            wire: branch.wireName,
            title: branch.title,
            readable: false,
            roots: const [],
            unrooted: const [],
          ),
        );
        continue;
      }
      branches.add(
        MemoryPersonaBranchCard(
          wire: branch.wireName,
          title: branch.title,
          readable: true,
          roots: [
            for (final root in view.roots)
              MemoryPersonaRootCard(
                id: _register(MemoryRootRef(branch.wireName, root.id)),
                claim: _visible(root.claim),
                masked: _isMasked(root.claim),
                control: _controlFor(root.claim, frozen, blocked),
                middleCount: root.middles.length,
                leafCount: root.allLeaves.length,
                earliestEvidence: _earliestDate(root.allLeaves),
                latestEvidence: _latestDate(root.allLeaves),
              ),
          ],
          unrooted: [
            for (final middle in view.unrooted)
              _middleCard(branch.wireName, middle, frozen, blocked),
          ],
        ),
      );
    }
    return MemoryPersonaSection(branches: branches);
  }

  Future<MemoryRelationshipSection> _relationshipSection(
    Set<String> frozen,
    Set<String> blocked,
  ) async {
    final sharedPast = await _sharedPastItems(frozen, blocked);
    final contents = await _readIfExists(_relationshipFile);
    final parsed = contents == null ? null : parseRelationshipFile(contents);
    if (parsed == null) {
      return MemoryRelationshipSection(
        present: false,
        stage: null,
        since: null,
        confirmed: const [],
        probes: const [],
        recentChanges: const [],
        sharedPast: sharedPast,
      );
    }
    return MemoryRelationshipSection(
      present: true,
      stage: parsed.stage.wireName,
      since: parsed.since,
      confirmed: _relationshipItems(
        'confirmed',
        parsed.confirmed,
        frozen,
        blocked,
      ),
      probes: _relationshipItems('probes', parsed.probes, frozen, blocked),
      recentChanges: _relationshipItems(
        'recentChanges',
        parsed.recentChanges,
        frozen,
        blocked,
      ),
      sharedPast: sharedPast,
    );
  }

  Future<List<MemoryLongTermItem>> _sharedPastItems(
    Set<String> frozen,
    Set<String> blocked,
  ) async {
    final contents = await _readIfExists(_longMemoryFile);
    final trimmed = contents?.trim() ?? '';
    if (trimmed.isEmpty) {
      return const [];
    }
    final parsed = parseLongMemory(trimmed);
    if (!parsed.readable) {
      return const [];
    }
    return (parsed.sections['共同过往'] ?? const <String>[])
        .map(
          (item) => _longTermItem(
            MemoryLongTermRef('共同过往', item),
            item,
            frozen,
            blocked,
          ),
        )
        .toList();
  }

  // ---------- 详情 ----------

  Future<EpisodeEntryDetail?> _entryDetail(
    MemoryEntryRef ref,
    Set<String> frozen,
    Set<String> blocked,
  ) async {
    final day = await episodePipeline.readDay(ref.date);
    if (!day.readable) {
      return null;
    }
    final entry = day.entries
        .where((candidate) => candidate.id == ref.entryId)
        .firstOrNull;
    if (entry == null || !_showsInRecent(entry)) {
      return null;
    }
    return EpisodeEntryDetail(
      date: ref.date,
      dayId: _register(MemoryDayRef(ref.date)),
      kind: _kindLabelFor(entry.kind),
      content: _visible(entry.summary),
      masked: _isMasked(entry.summary),
      control: _controlFor(entry.summary, frozen, blocked),
      at: entry.at,
      evidence: _visible(entry.evidence),
      evidenceMasked: _isMasked(entry.evidence),
      sessionId: entry.sessionId,
      daySummary: _visible(day.summary),
      finalized: day.finalized,
      userEdited: entry.userEdited,
    );
  }

  Future<PersonaRootDetail?> _rootDetail(
    MemoryRootRef ref,
    Set<String> frozen,
    Set<String> blocked,
  ) async {
    final branch = personaBranchForWire(ref.branchWire);
    if (branch == null) {
      return null;
    }
    final snapshot = await personaTree.readSnapshot();
    final view = snapshot.branches[ref.branchWire];
    if (view == null || !view.readable) {
      return null;
    }
    final root = view.roots
        .where((candidate) => candidate.id == ref.rootId)
        .firstOrNull;
    if (root == null) {
      return null;
    }
    return PersonaRootDetail(
      branchWire: branch.wireName,
      branchTitle: branch.title,
      claim: _visible(root.claim),
      masked: _isMasked(root.claim),
      control: _controlFor(root.claim, frozen, blocked),
      middles: [
        for (final middle in root.middles)
          _middleCard(branch.wireName, middle, frozen, blocked),
      ],
    );
  }

  Future<PersonaMiddleDetail?> _middleDetail(
    MemoryMiddleRef ref,
    Set<String> frozen,
    Set<String> blocked,
  ) async {
    final branch = personaBranchForWire(ref.branchWire);
    if (branch == null) {
      return null;
    }
    final snapshot = await personaTree.readSnapshot();
    final view = snapshot.branches[ref.branchWire];
    if (view == null || !view.readable) {
      return null;
    }
    PersonaMiddle? middle;
    String? rootClaim;
    for (final root in view.roots) {
      final hit = root.middles
          .where((candidate) => candidate.id == ref.middleId)
          .firstOrNull;
      if (hit != null) {
        middle = hit;
        rootClaim = root.claim;
        break;
      }
    }
    middle ??= view.unrooted
        .where((candidate) => candidate.id == ref.middleId)
        .firstOrNull;
    if (middle == null) {
      return null;
    }
    return PersonaMiddleDetail(
      branchWire: branch.wireName,
      branchTitle: branch.title,
      type: middle.type,
      claim: _visible(middle.claim),
      masked: _isMasked(middle.claim),
      control: _controlFor(middle.claim, frozen, blocked),
      formedOn: middle.formedOn,
      reviewedOn: middle.reviewedOn,
      rootClaim: rootClaim == null ? null : _visible(rootClaim),
      leaves: [
        for (final leaf in middle.leaves)
          MemoryPersonaLeafCard(
            dayId: _register(MemoryDayRef(leaf.date)),
            date: leaf.date,
            nature: leaf.nature,
            relation: leaf.relation,
            summary: _visible(leaf.summary),
            masked: _isMasked(leaf.summary),
            control: _controlFor(leaf.summary, frozen, blocked),
          ),
      ],
    );
  }

  Future<MemoryDayDetail?> _dayDetail(
    String date,
    Set<String> frozen,
    Set<String> blocked,
  ) async {
    final day = await episodePipeline.readDay(date);
    if (!day.readable || !day.exists) {
      return null;
    }
    return MemoryDayDetail(
      date: date,
      summary: _visible(day.summary),
      summaryMasked: _isMasked(day.summary),
      finalized: day.finalized,
      finalizedAt: day.finalizedAt,
      entries: _entryCards(date, day.entries, frozen, blocked),
    );
  }

  // ---------- 共用构件 ----------

  List<MemoryEntryCard> _entryCards(
    String date,
    List<EpisodeEntry> entries,
    Set<String> frozen,
    Set<String> blocked,
  ) {
    final cards = <MemoryEntryCard>[];
    for (final entry in entries) {
      if (!_showsInRecent(entry)) {
        continue;
      }
      cards.add(
        MemoryEntryCard(
          id: _register(MemoryEntryRef(date, entry.id)),
          kind: _kindLabelFor(entry.kind),
          content: _visible(entry.summary),
          masked: _isMasked(entry.summary),
          control: _controlFor(entry.summary, frozen, blocked),
          at: entry.at,
          hasEvidence: (entry.evidence ?? '').trim().isNotEmpty,
          userEdited: entry.userEdited,
        ),
      );
    }
    cards.sort((left, right) => right.at.compareTo(left.at));
    return cards;
  }

  MemoryPersonaMiddleCard _middleCard(
    String branchWire,
    PersonaMiddle middle,
    Set<String> frozen,
    Set<String> blocked,
  ) => MemoryPersonaMiddleCard(
    id: _register(MemoryMiddleRef(branchWire, middle.id)),
    type: middle.type,
    claim: _visible(middle.claim),
    masked: _isMasked(middle.claim),
    control: _controlFor(middle.claim, frozen, blocked),
    formedOn: middle.formedOn,
    reviewedOn: middle.reviewedOn,
    leafCount: middle.leaves.length,
    hasConflict: middle.leaves.any((leaf) => leaf.relation == 'conflict'),
  );

  MemoryLongTermItem _longTermItem(
    MemoryItemRef ref,
    String item,
    Set<String> frozen,
    Set<String> blocked,
  ) => MemoryLongTermItem(
    id: _register(ref),
    content: _visible(item),
    masked: _isMasked(item),
    control: _controlFor(item, frozen, blocked),
  );

  /// relationship 各行（解析器保证 `- ` 前缀）走读取时纪律后成为
  /// 条目：敏感遮罩、控制标识，空行丢弃。条目引用供揭示查看
  /// （ticket 20）；状态包各行不是控制对象（T24 定稿）。
  List<MemoryLongTermItem> _relationshipItems(
    String list,
    List<String> lines,
    Set<String> frozen,
    Set<String> blocked,
  ) {
    final items = <MemoryLongTermItem>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('- ')) {
        continue;
      }
      final text = trimmed.substring(2).trim();
      if (text.isEmpty) {
        continue;
      }
      items.add(
        _longTermItem(MemoryRelationshipRef(list, text), text, frozen, blocked),
      );
    }
    return items;
  }

  /// 只展示用户可理解的条目；簿记条目（open_loop_event）含受控标题
  /// 文字，绝不进记忆中心（与投影侧纪律一致）。
  bool _showsInRecent(EpisodeEntry entry) =>
      entry.summary.trim().isNotEmpty &&
      (entry.kind == episodeKindMemory ||
          entry.kind == episodeKindOpenLoopCandidate ||
          entry.kind == episodeKindRelationshipSignal);

  String? _visible(String? text) {
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty || isSensitiveMemoryText(trimmed)) {
      return null;
    }
    return trimmed;
  }

  bool _isMasked(String? text) {
    final trimmed = text?.trim() ?? '';
    return trimmed.isNotEmpty && isSensitiveMemoryText(trimmed);
  }

  MemoryControlStatus? _controlFor(
    String text,
    Set<String> frozen,
    Set<String> blocked,
  ) {
    final normalized = normalizeMemoryText(text);
    if (normalized.isEmpty) {
      return null;
    }
    if (bannedTitleMatches(normalized, blocked)) {
      return MemoryControlStatus.banned;
    }
    if (bannedTitleMatches(normalized, frozen)) {
      return MemoryControlStatus.frozen;
    }
    return null;
  }

  String? _earliestDate(Iterable<PersonaLeaf> leaves) {
    String? earliest;
    for (final leaf in leaves) {
      if (earliest == null || leaf.date.compareTo(earliest) < 0) {
        earliest = leaf.date;
      }
    }
    return earliest;
  }

  String? _latestDate(Iterable<PersonaLeaf> leaves) {
    String? latest;
    for (final leaf in leaves) {
      if (latest == null || leaf.date.compareTo(latest) > 0) {
        latest = leaf.date;
      }
    }
    return latest;
  }

  Future<String?> _readIfExists(File file) async {
    if (!await file.exists()) {
      return null;
    }
    try {
      return await file.readAsString(encoding: utf8);
    } on Object {
      return null;
    }
  }

  String _register(MemoryItemRef ref) {
    final id = _newOpaqueId();
    _registry[id] = ref;
    while (_registry.length > _memoryCenterRegistryCapacity) {
      _registry.remove(_registry.keys.first);
    }
    return id;
  }
}

String _newOpaqueId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
