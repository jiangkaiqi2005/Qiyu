import 'dart:convert';

import 'package:http/http.dart' as http;

/// 条目来源的用户语言标签（与 Host 侧 wire 取值一一对应）。
String memoryKindLabel(String kind) => switch (kind) {
  'concern' => '关注的事',
  'relationship' => '关系变化',
  _ => '记忆',
};

/// wire 数组统一解码为 DTO 列表：数组缺失即抛错，条目必须是对象，
/// 与各处手写的 `as` 链同语义。
List<T> _listFromJson<T>(
  Object? value,
  T Function(Map<String, Object?> json) fromJson,
) => (value! as List<Object?>)
    .map((entry) => fromJson(entry! as Map<String, Object?>))
    .toList();

/// 记忆控制状态的用户语言：冻结 = 暂停使用，禁提 = 不再提起。
enum MemoryControlStatus {
  frozen('已冻结'),
  banned('已禁提');

  const MemoryControlStatus(this.label);

  final String label;

  static MemoryControlStatus? fromWire(Object? value) => switch (value) {
    'frozen' => MemoryControlStatus.frozen,
    'banned' => MemoryControlStatus.banned,
    _ => null,
  };
}

final class MemoryEntryCard {
  const MemoryEntryCard({
    required this.id,
    required this.kind,
    required this.content,
    required this.masked,
    required this.control,
    required this.at,
    required this.hasEvidence,
    this.userEdited = false,
  });

  factory MemoryEntryCard.fromJson(Map<String, Object?> json) =>
      MemoryEntryCard(
        id: json['id']! as String,
        kind: json['kind']! as String,
        content: json['content'] as String?,
        masked: json['masked']! as bool,
        control: MemoryControlStatus.fromWire(json['control']),
        at: DateTime.parse(json['at']! as String),
        hasEvidence: json['hasEvidence']! as bool,
        userEdited: json['userEdited'] as bool? ?? false,
      );

  final String id;
  final String kind;
  final String? content;
  final bool masked;
  final MemoryControlStatus? control;
  final DateTime at;
  final bool hasEvidence;

  /// 用户修正过的条目（ticket 20）：按用户声明呈现，不与自动整理
  /// 的证据混同。
  final bool userEdited;

  String get kindLabel => memoryKindLabel(kind);
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

  factory MemoryDayCard.fromJson(Map<String, Object?> json) => MemoryDayCard(
    id: json['id']! as String,
    date: json['date']! as String,
    summary: json['summary'] as String?,
    summaryMasked: json['summaryMasked']! as bool,
    finalized: json['finalized']! as bool,
    finalizedAt: json['finalizedAt'] == null
        ? null
        : DateTime.parse(json['finalizedAt']! as String),
    entries: _listFromJson(json['entries'], MemoryEntryCard.fromJson),
  );

  final String id;
  final String date;
  final String? summary;
  final bool summaryMasked;
  final bool finalized;
  final DateTime? finalizedAt;
  final List<MemoryEntryCard> entries;
}

final class MemoryRecentSection {
  const MemoryRecentSection({required this.days});

  factory MemoryRecentSection.fromJson(Map<String, Object?> json) =>
      MemoryRecentSection(
        days: _listFromJson(json['days'], MemoryDayCard.fromJson),
      );

  final List<MemoryDayCard> days;
}

final class MemoryLongTermItem {
  const MemoryLongTermItem({
    required this.id,
    required this.content,
    required this.masked,
    required this.control,
  });

  factory MemoryLongTermItem.fromJson(Map<String, Object?> json) =>
      MemoryLongTermItem(
        id: json['id']! as String,
        content: json['content'] as String?,
        masked: json['masked']! as bool,
        control: MemoryControlStatus.fromWire(json['control']),
      );

  /// 不透明引用（ticket 20）：编辑、控制与删除动作的目标。
  final String id;
  final String? content;
  final bool masked;
  final MemoryControlStatus? control;
}

final class MemoryLongTermGroup {
  const MemoryLongTermGroup({required this.section, required this.items});

  factory MemoryLongTermGroup.fromJson(Map<String, Object?> json) =>
      MemoryLongTermGroup(
        section: json['section']! as String,
        items: _listFromJson(json['items'], MemoryLongTermItem.fromJson),
      );

  final String section;
  final List<MemoryLongTermItem> items;
}

final class MemoryLongTermSection {
  const MemoryLongTermSection({
    required this.present,
    required this.readable,
    required this.organizedAt,
    required this.groups,
  });

  factory MemoryLongTermSection.fromJson(Map<String, Object?> json) =>
      MemoryLongTermSection(
        present: json['present']! as bool,
        readable: json['readable']! as bool,
        organizedAt: json['organizedAt'] == null
            ? null
            : DateTime.parse(json['organizedAt']! as String),
        groups: _listFromJson(json['groups'], MemoryLongTermGroup.fromJson),
      );

  final bool present;
  final bool readable;
  final DateTime? organizedAt;
  final List<MemoryLongTermGroup> groups;
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

  factory MemoryPersonaRootCard.fromJson(Map<String, Object?> json) =>
      MemoryPersonaRootCard(
        id: json['id']! as String,
        claim: json['claim'] as String?,
        masked: json['masked']! as bool,
        control: MemoryControlStatus.fromWire(json['control']),
        middleCount: json['middleCount']! as int,
        leafCount: json['leafCount']! as int,
        earliestEvidence: json['earliestEvidence'] as String?,
        latestEvidence: json['latestEvidence'] as String?,
      );

  final String id;
  final String? claim;
  final bool masked;
  final MemoryControlStatus? control;
  final int middleCount;
  final int leafCount;
  final String? earliestEvidence;
  final String? latestEvidence;
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

  factory MemoryPersonaMiddleCard.fromJson(Map<String, Object?> json) =>
      MemoryPersonaMiddleCard(
        id: json['id']! as String,
        type: json['type']! as String,
        claim: json['claim'] as String?,
        masked: json['masked']! as bool,
        control: MemoryControlStatus.fromWire(json['control']),
        formedOn: json['formedOn']! as String,
        reviewedOn: json['reviewedOn']! as String,
        leafCount: json['leafCount']! as int,
        hasConflict: json['hasConflict']! as bool,
      );

  final String id;
  final String type;
  final String? claim;
  final bool masked;
  final MemoryControlStatus? control;
  final String formedOn;
  final String reviewedOn;
  final int leafCount;
  final bool hasConflict;
}

final class MemoryPersonaBranchCard {
  const MemoryPersonaBranchCard({
    required this.wire,
    required this.title,
    required this.readable,
    required this.roots,
    required this.unrooted,
  });

  factory MemoryPersonaBranchCard.fromJson(Map<String, Object?> json) =>
      MemoryPersonaBranchCard(
        wire: json['wire']! as String,
        title: json['title']! as String,
        readable: json['readable']! as bool,
        roots: _listFromJson(json['roots'], MemoryPersonaRootCard.fromJson),
        unrooted: _listFromJson(
          json['unrooted'],
          MemoryPersonaMiddleCard.fromJson,
        ),
      );

  final String wire;
  final String title;
  final bool readable;
  final List<MemoryPersonaRootCard> roots;
  final List<MemoryPersonaMiddleCard> unrooted;

  bool get isEmpty => roots.isEmpty && unrooted.isEmpty;
}

final class MemoryPersonaSection {
  const MemoryPersonaSection({required this.branches});

  factory MemoryPersonaSection.fromJson(Map<String, Object?> json) =>
      MemoryPersonaSection(
        branches: _listFromJson(
          json['branches'],
          MemoryPersonaBranchCard.fromJson,
        ),
      );

  final List<MemoryPersonaBranchCard> branches;

  bool get isEmpty => branches.every((branch) => branch.isEmpty);
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

  factory MemoryRelationshipSection.fromJson(
    Map<String, Object?> json,
  ) => MemoryRelationshipSection(
    present: json['present']! as bool,
    stage: json['stage'] as String?,
    since: json['since'] as String?,
    confirmed: _listFromJson(json['confirmed'], MemoryLongTermItem.fromJson),
    probes: _listFromJson(json['probes'], MemoryLongTermItem.fromJson),
    recentChanges: _listFromJson(
      json['recentChanges'],
      MemoryLongTermItem.fromJson,
    ),
    sharedPast: _listFromJson(json['sharedPast'], MemoryLongTermItem.fromJson),
  );

  final bool present;
  final String? stage;
  final String? since;
  final List<MemoryLongTermItem> confirmed;
  final List<MemoryLongTermItem> probes;
  final List<MemoryLongTermItem> recentChanges;
  final List<MemoryLongTermItem> sharedPast;

  bool get isEmpty => !present && sharedPast.isEmpty;
}

/// 恢复状态区的一条发现（ticket 21）：受影响层、损坏类型、恢复结果、
/// 采用的证据与仍无法恢复的内容，全部是用户语言的抽象描述。
final class MemoryRecoveryFindingCard {
  const MemoryRecoveryFindingCard({
    required this.layer,
    required this.kind,
    required this.outcome,
    required this.evidence,
    required this.loss,
    required this.quarantined,
  });

  factory MemoryRecoveryFindingCard.fromJson(Map<String, Object?> json) =>
      MemoryRecoveryFindingCard(
        layer: json['layer']! as String,
        kind: json['kind']! as String,
        outcome: json['outcome']! as String,
        evidence: json['evidence'] as String?,
        loss: json['loss'] as String?,
        quarantined: json['quarantined'] == true,
      );

  final String layer;
  final String kind;
  final String outcome;
  final String? evidence;
  final String? loss;
  final bool quarantined;

  String get kindLabel => switch (kind) {
    'missing' => '缺失',
    'stale' => '旧版本',
    'corrupt' => '语法损坏',
    'incomplete' => '内容不完整',
    'orphaned' => '引用失效',
    _ => '异常',
  };

  String get outcomeLabel => switch (outcome) {
    'full' => '已完整恢复',
    'partial' => '部分恢复',
    'pending' => '待恢复',
    _ => '未知',
  };
}

/// 恢复状态区：健康时 [healthy] 为 true 且不展示；有发现时逐条呈现
/// 受影响范围、采用证据、恢复结果与仍无法恢复的内容，绝不显示虚假成功。
final class MemoryRecoverySection {
  const MemoryRecoverySection({
    required this.healthy,
    required this.quarantinedFiles,
    required this.findings,
  });

  factory MemoryRecoverySection.fromJson(Map<String, Object?> json) =>
      MemoryRecoverySection(
        healthy: json['healthy'] == true,
        quarantinedFiles: json['quarantinedFiles'] as int? ?? 0,
        findings: (json['findings'] as List<Object?>? ?? const [])
            .whereType<Map<String, Object?>>()
            .map(MemoryRecoveryFindingCard.fromJson)
            .toList(),
      );

  final bool healthy;
  final int quarantinedFiles;
  final List<MemoryRecoveryFindingCard> findings;
}

final class MemoryOverview {
  const MemoryOverview({
    required this.generatedAt,
    required this.recent,
    required this.longTerm,
    required this.persona,
    required this.relationship,
    this.recovery,
  });

  factory MemoryOverview.fromJson(Map<String, Object?> json) => MemoryOverview(
    generatedAt: DateTime.parse(json['generatedAt']! as String),
    recent: MemoryRecentSection.fromJson(
      json['recent']! as Map<String, Object?>,
    ),
    longTerm: MemoryLongTermSection.fromJson(
      json['longTerm']! as Map<String, Object?>,
    ),
    persona: MemoryPersonaSection.fromJson(
      json['persona']! as Map<String, Object?>,
    ),
    relationship: MemoryRelationshipSection.fromJson(
      json['relationship']! as Map<String, Object?>,
    ),
    recovery: json['recovery'] is Map<String, Object?>
        ? MemoryRecoverySection.fromJson(
            json['recovery']! as Map<String, Object?>,
          )
        : null,
  );

  final DateTime generatedAt;
  final MemoryRecentSection recent;
  final MemoryLongTermSection longTerm;
  final MemoryPersonaSection persona;
  final MemoryRelationshipSection relationship;

  /// 恢复状态；旧 Host 未提供时为 null，按健康呈现。
  final MemoryRecoverySection? recovery;
}

/// 条目详情：按 kind 分派为 episode 条目、画像根路径、画像中间理解
/// （含叶证据）或某一天的完整记录。
sealed class MemoryItemDetail {
  const MemoryItemDetail();

  static MemoryItemDetail fromJson(Map<String, Object?> json) =>
      switch (json['kind']) {
        'episode-entry' => EpisodeEntryDetail.fromJson(json),
        'persona-root' => PersonaRootDetail.fromJson(json),
        'persona-middle' => PersonaMiddleDetail.fromJson(json),
        _ => MemoryDayDetail.fromJson(json),
      };
}

final class EpisodeEntryDetail extends MemoryItemDetail {
  const EpisodeEntryDetail({
    required this.date,
    required this.dayId,
    required this.entryKind,
    required this.content,
    required this.masked,
    required this.control,
    required this.at,
    required this.evidence,
    required this.evidenceMasked,
    required this.sessionId,
    required this.daySummary,
    required this.finalized,
    this.userEdited = false,
  });

  factory EpisodeEntryDetail.fromJson(Map<String, Object?> json) =>
      EpisodeEntryDetail(
        date: json['date']! as String,
        dayId: json['dayId']! as String,
        entryKind: json['entryKind']! as String,
        content: json['content'] as String?,
        masked: json['masked']! as bool,
        control: MemoryControlStatus.fromWire(json['control']),
        at: DateTime.parse(json['at']! as String),
        evidence: json['evidence'] as String?,
        evidenceMasked: json['evidenceMasked']! as bool,
        sessionId: json['sessionId'] as String?,
        daySummary: json['daySummary'] as String?,
        finalized: json['finalized']! as bool,
        userEdited: json['userEdited'] as bool? ?? false,
      );

  final String date;
  final String dayId;
  final String entryKind;
  final String? content;
  final bool masked;
  final MemoryControlStatus? control;
  final DateTime at;
  final String? evidence;
  final bool evidenceMasked;
  final String? sessionId;
  final String? daySummary;
  final bool finalized;

  /// 是否由用户修正过（ticket 20）。
  final bool userEdited;

  String get kindLabel => memoryKindLabel(entryKind);
}

final class PersonaRootDetail extends MemoryItemDetail {
  const PersonaRootDetail({
    required this.branch,
    required this.branchTitle,
    required this.claim,
    required this.masked,
    required this.control,
    required this.middles,
  });

  factory PersonaRootDetail.fromJson(Map<String, Object?> json) =>
      PersonaRootDetail(
        branch: json['branch']! as String,
        branchTitle: json['branchTitle']! as String,
        claim: json['claim'] as String?,
        masked: json['masked']! as bool,
        control: MemoryControlStatus.fromWire(json['control']),
        middles: _listFromJson(
          json['middles'],
          MemoryPersonaMiddleCard.fromJson,
        ),
      );

  final String branch;
  final String branchTitle;
  final String? claim;
  final bool masked;
  final MemoryControlStatus? control;
  final List<MemoryPersonaMiddleCard> middles;
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

  factory MemoryPersonaLeafCard.fromJson(Map<String, Object?> json) =>
      MemoryPersonaLeafCard(
        dayId: json['dayId']! as String,
        date: json['date']! as String,
        nature: json['nature']! as String,
        relation: json['relation']! as String,
        summary: json['summary'] as String?,
        masked: json['masked']! as bool,
        control: MemoryControlStatus.fromWire(json['control']),
      );

  final String dayId;
  final String date;
  final String nature;
  final String relation;
  final String? summary;
  final bool masked;
  final MemoryControlStatus? control;
}

final class PersonaMiddleDetail extends MemoryItemDetail {
  const PersonaMiddleDetail({
    required this.branch,
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

  factory PersonaMiddleDetail.fromJson(Map<String, Object?> json) =>
      PersonaMiddleDetail(
        branch: json['branch']! as String,
        branchTitle: json['branchTitle']! as String,
        type: json['type']! as String,
        claim: json['claim'] as String?,
        masked: json['masked']! as bool,
        control: MemoryControlStatus.fromWire(json['control']),
        formedOn: json['formedOn']! as String,
        reviewedOn: json['reviewedOn']! as String,
        rootClaim: json['rootClaim'] as String?,
        leaves: _listFromJson(json['leaves'], MemoryPersonaLeafCard.fromJson),
      );

  final String branch;
  final String branchTitle;
  final String type;
  final String? claim;
  final bool masked;
  final MemoryControlStatus? control;
  final String formedOn;
  final String reviewedOn;
  final String? rootClaim;
  final List<MemoryPersonaLeafCard> leaves;
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

  factory MemoryDayDetail.fromJson(Map<String, Object?> json) =>
      MemoryDayDetail(
        date: json['date']! as String,
        summary: json['summary'] as String?,
        summaryMasked: json['summaryMasked']! as bool,
        finalized: json['finalized']! as bool,
        finalizedAt: json['finalizedAt'] == null
            ? null
            : DateTime.parse(json['finalizedAt']! as String),
        entries: _listFromJson(json['entries'], MemoryEntryCard.fromJson),
      );

  final String date;
  final String? summary;
  final bool summaryMasked;
  final bool finalized;
  final DateTime? finalizedAt;
  final List<MemoryEntryCard> entries;
}

/// 记忆动作结果三态（ticket 20）：成功、部分失败（控制已生效，
/// 个别派生清理推迟）与可恢复失败（什么都没改变，可重试）。
enum MemoryActionStatus {
  success,
  partial,
  failed;

  /// 只认显式的三态字段：缺失或未知值一律按失败处理，绝不把
  /// 错误响应误读为成功。
  static MemoryActionStatus fromWire(Object? value) => switch (value) {
    'success' => MemoryActionStatus.success,
    'partial' => MemoryActionStatus.partial,
    _ => MemoryActionStatus.failed,
  };
}

final class MemoryActionResult {
  const MemoryActionResult({
    required this.status,
    required this.message,
    this.retryable = false,
    this.deferred = const [],
    this.text,
  });

  factory MemoryActionResult.fromJson(Map<String, Object?> json) =>
      MemoryActionResult(
        status: MemoryActionStatus.fromWire(json['status']),
        message: json['message']! as String,
        retryable: json['retryable'] as bool? ?? false,
        deferred: (json['deferred'] as List<Object?>? ?? const [])
            .whereType<String>()
            .toList(),
        text: json['text'] as String?,
      );

  final MemoryActionStatus status;
  final String message;
  final bool retryable;
  final List<String> deferred;

  /// 揭示动作返回的原文；只在揭示成功时出现。
  final String? text;
}

/// 删除影响范围（删除前展示）：每一项都是准确计数与用户语言说明。
final class MemoryDeleteImpact {
  const MemoryDeleteImpact({required this.lines, required this.sessionsKept});

  factory MemoryDeleteImpact.fromJson(Map<String, Object?> json) =>
      MemoryDeleteImpact(
        lines: (json['lines']! as List<Object?>).whereType<String>().toList(),
        sessionsKept: json['sessionsKept']! as bool,
      );

  final List<String> lines;
  final bool sessionsKept;
}

final class MemoryGatewayException implements Exception {
  const MemoryGatewayException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 记忆中心网关：读取 + 经过确认的写入动作（ticket 20）。所有写入
/// 都走统一动作端点，携带会话 Cookie 与 CSRF；揭示结果只取一次，
/// 不做任何本地持久化。
abstract interface class MemoryGateway {
  Future<MemoryOverview> fetchOverview();

  /// ID 对应条目已不存在或已变化时返回 null。
  Future<MemoryItemDetail?> fetchItemDetail(String id);

  Future<MemoryActionResult> editItem(String id, String text);

  Future<MemoryActionResult> freezeItem(String id);

  Future<MemoryActionResult> unfreezeItem(String id);

  Future<MemoryActionResult> banItem(String id);

  Future<MemoryActionResult> unbanItem(String id);

  /// 删除影响范围预览；条目已不存在或已变化时返回 null。
  Future<MemoryDeleteImpact?> previewDelete(String id);

  Future<MemoryActionResult> deleteItem(String id);

  /// 敏感内容的临时揭示；不需要揭示时返回 failed 结果。
  Future<MemoryActionResult> revealItem(String id, {String field = 'content'});
}

final class HttpMemoryGateway implements MemoryGateway {
  HttpMemoryGateway({http.Client? client, Uri? baseUri})
    : _client = client ?? http.Client(),
      _baseUri = baseUri ?? Uri.base;

  final http.Client _client;
  final Uri _baseUri;
  String? _csrfToken;

  @override
  Future<MemoryOverview> fetchOverview() async {
    final response = await _client.get(_baseUri.resolve('/api/memory'));
    return MemoryOverview.fromJson(_decodeSuccess(response));
  }

  @override
  Future<MemoryItemDetail?> fetchItemDetail(String id) async {
    final response = await _client.get(
      _baseUri.resolve('/api/memory/items/$id'),
    );
    if (response.statusCode == 404) {
      return null;
    }
    return MemoryItemDetail.fromJson(_decodeSuccess(response));
  }

  @override
  Future<MemoryActionResult> editItem(String id, String text) =>
      _action({'action': 'edit', 'id': id, 'text': text});

  @override
  Future<MemoryActionResult> freezeItem(String id) =>
      _action({'action': 'freeze', 'id': id});

  @override
  Future<MemoryActionResult> unfreezeItem(String id) =>
      _action({'action': 'unfreeze', 'id': id});

  @override
  Future<MemoryActionResult> banItem(String id) =>
      _action({'action': 'ban', 'id': id});

  @override
  Future<MemoryActionResult> unbanItem(String id) =>
      _action({'action': 'unban', 'id': id});

  @override
  Future<MemoryDeleteImpact?> previewDelete(String id) async {
    await _ensureBootstrap();
    final response = await _client.post(
      _baseUri.resolve('/api/memory/action'),
      headers: {'content-type': 'application/json', 'x-qiyu-csrf': _csrfToken!},
      body: jsonEncode({'action': 'delete-preview', 'id': id}),
    );
    if (response.statusCode == 404) {
      return null;
    }
    return MemoryDeleteImpact.fromJson(_decodeSuccess(response));
  }

  @override
  Future<MemoryActionResult> deleteItem(String id) =>
      _action({'action': 'delete', 'id': id});

  @override
  Future<MemoryActionResult> revealItem(
    String id, {
    String field = 'content',
  }) => _action({'action': 'reveal', 'id': id, 'field': field});

  Future<MemoryActionResult> _action(Map<String, Object?> payload) async {
    await _ensureBootstrap();
    final response = await _client.post(
      _baseUri.resolve('/api/memory/action'),
      headers: {'content-type': 'application/json', 'x-qiyu-csrf': _csrfToken!},
      body: jsonEncode(payload),
    );
    final json = _decodePayload(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 错误响应体可能没有 status 字段：不信任解析结果，一律按
      // 可重试失败呈现，旧有效数据保持可用。
      return MemoryActionResult(
        status: MemoryActionStatus.failed,
        message: json['message'] as String? ?? '记忆操作没有生效，可稍后重试。',
        retryable: json['retryable'] as bool? ?? true,
      );
    }
    return MemoryActionResult.fromJson(json);
  }

  Future<void> _ensureBootstrap() async {
    if (_csrfToken != null) {
      return;
    }
    final response = await _client.get(_baseUri.resolve('/api/bootstrap'));
    final json = jsonDecode(response.body) as Map<String, Object?>;
    _csrfToken = json['csrfToken']! as String;
  }

  Map<String, Object?> _decodeSuccess(http.Response response) {
    final json = _decodePayload(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MemoryGatewayException(
        json['message'] as String? ?? '记忆中心暂时不可用，请稍后重试。',
      );
    }
    return json;
  }

  /// 动作端点在 4xx 上也返回结构化结果（三态与错误码），解析
  /// 失败才抛异常。
  Map<String, Object?> _decodePayload(http.Response response) {
    try {
      return jsonDecode(response.body) as Map<String, Object?>;
    } on Object {
      throw const MemoryGatewayException('本机程序返回了无法读取的内容。');
    }
  }
}
