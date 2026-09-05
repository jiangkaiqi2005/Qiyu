import '../baseline/host_api_gateway.dart';

final class SettingsException implements Exception {
  const SettingsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 体验与开发者选项：目前只有开发者模式（ticket 23）。
final class ExperiencePreferences {
  const ExperiencePreferences({required this.developerMode});

  factory ExperiencePreferences.fromJson(Map<String, Object?> json) =>
      ExperiencePreferences(developerMode: json['developerMode'] == true);

  final bool developerMode;
}

/// 记忆控制总览条目：安全摘要，不含原始内容。
final class MemoryControlRecord {
  const MemoryControlRecord({
    required this.id,
    required this.origin,
    required this.summary,
  });

  factory MemoryControlRecord.fromJson(Map<String, Object?> json) =>
      MemoryControlRecord(
        id: json['id']! as int,
        origin: json['origin']! as String,
        summary: json['summary']! as String,
      );

  final int id;
  final String origin;
  final String summary;
}

final class MemoryControlsOverview {
  const MemoryControlsOverview({
    required this.readable,
    required this.frozen,
    required this.banned,
    required this.deletedCount,
  });

  factory MemoryControlsOverview.fromJson(Map<String, Object?> json) =>
      MemoryControlsOverview(
        readable: json['readable']! as bool,
        frozen: (json['frozen']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map(MemoryControlRecord.fromJson)
            .toList(),
        banned: (json['banned']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map(MemoryControlRecord.fromJson)
            .toList(),
        deletedCount: json['deletedCount']! as int,
      );

  final bool readable;
  final List<MemoryControlRecord> frozen;
  final List<MemoryControlRecord> banned;
  final int deletedCount;
}

/// 清除产品数据前的影响概览，同时提供本地数据位置。
final class ClearPreview {
  const ClearPreview({
    required this.memoryDirectory,
    required this.sessionCount,
    required this.episodeDayCount,
    required this.frozenCount,
    required this.bannedCount,
    required this.deletedCount,
    required this.snapshotCount,
    required this.providerConfigured,
    required this.keySet,
  });

  factory ClearPreview.fromJson(Map<String, Object?> json) => ClearPreview(
    memoryDirectory: json['memoryDirectory']! as String,
    sessionCount: json['sessionCount']! as int,
    episodeDayCount: json['episodeDayCount']! as int,
    frozenCount: json['frozenCount']! as int,
    bannedCount: json['bannedCount']! as int,
    deletedCount: json['deletedCount']! as int,
    snapshotCount: json['snapshotCount']! as int,
    providerConfigured: json['providerConfigured']! as bool,
    keySet: json['keySet']! as bool,
  );

  final String memoryDirectory;
  final int sessionCount;
  final int episodeDayCount;
  final int frozenCount;
  final int bannedCount;
  final int deletedCount;
  final int snapshotCount;
  final bool providerConfigured;
  final bool keySet;
}

final class RecentRequest {
  const RecentRequest({
    required this.at,
    required this.source,
    required this.result,
    this.replySource,
    this.fallbackReason,
    this.detail,
  });

  factory RecentRequest.fromJson(Map<String, Object?> json) => RecentRequest(
    at: DateTime.parse(json['at']! as String),
    source: json['source']! as String,
    result: json['result']! as String,
    replySource: json['replySource'] as String?,
    fallbackReason: json['fallbackReason'] as String?,
    detail: json['detail'] as String?,
  );

  final DateTime at;
  final String source;
  final String result;
  final String? replySource;
  final String? fallbackReason;
  final String? detail;
}

final class FinalizationHealth {
  const FinalizationHealth({
    required this.today,
    required this.todayFinalized,
    required this.pendingDays,
    required this.unreadableDays,
  });

  factory FinalizationHealth.fromJson(Map<String, Object?> json) =>
      FinalizationHealth(
        today: json['today']! as String,
        todayFinalized: json['todayFinalized'] as bool?,
        pendingDays: json['pendingDays']! as int,
        unreadableDays: json['unreadableDays']! as int,
      );

  final String today;
  final bool? todayFinalized;
  final int pendingDays;
  final int unreadableDays;
}

final class DreamHealth {
  const DreamHealth({
    this.lastSuccessAt,
    this.daysSinceLastSuccess,
    this.pending = false,
    this.minIntervalDays,
    this.intervalSatisfied,
    this.providerConfigured,
    this.eligible,
  });

  factory DreamHealth.fromJson(Map<String, Object?> json) => DreamHealth(
    lastSuccessAt: json['lastSuccessAt'] == null
        ? null
        : DateTime.parse(json['lastSuccessAt']! as String),
    daysSinceLastSuccess: json['daysSinceLastSuccess'] as int?,
    pending: json['pending'] as bool? ?? false,
    minIntervalDays: json['minIntervalDays'] as int?,
    intervalSatisfied: json['intervalSatisfied'] as bool?,
    providerConfigured: json['providerConfigured'] as bool?,
    eligible: json['eligible'] as bool?,
  );

  final DateTime? lastSuccessAt;
  final int? daysSinceLastSuccess;
  final bool pending;
  final int? minIntervalDays;
  final bool? intervalSatisfied;
  final bool? providerConfigured;
  final bool? eligible;
}

/// 开发者诊断快照：文件健康保留原始结构供展示层逐项读取。
final class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.generatedAt,
    required this.memoryDirectory,
    required this.recentRequests,
    required this.finalization,
    required this.dream,
    required this.fileHealth,
  });

  factory DiagnosticsSnapshot.fromJson(Map<String, Object?> json) =>
      DiagnosticsSnapshot(
        generatedAt: DateTime.parse(json['generatedAt']! as String),
        memoryDirectory: json['memoryDirectory']! as String,
        recentRequests: (json['recentRequests']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map(RecentRequest.fromJson)
            .toList(),
        finalization: json['finalization'] == null
            ? null
            : FinalizationHealth.fromJson(
                json['finalization']! as Map<String, Object?>,
              ),
        dream: json['dream'] == null
            ? null
            : DreamHealth.fromJson(json['dream']! as Map<String, Object?>),
        fileHealth: (json['fileHealth'] ?? const {}) as Map<String, Object?>,
      );

  final DateTime generatedAt;
  final String memoryDirectory;
  final List<RecentRequest> recentRequests;
  final FinalizationHealth? finalization;
  final DreamHealth? dream;
  final Map<String, Object?> fileHealth;
}

abstract interface class SettingsGateway {
  Future<ExperiencePreferences> readPreferences();

  Future<ExperiencePreferences> savePreferences({required bool developerMode});

  Future<MemoryControlsOverview> readMemoryControls();

  Future<ClearPreview> readClearPreview();

  Future<void> clearData();

  Future<DiagnosticsSnapshot> readDiagnostics();
}

final class HttpSettingsGateway extends HostApiGateway
    implements SettingsGateway {
  HttpSettingsGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => SettingsException(message);

  @override
  String get unavailableMessage => '设置服务暂时不可用，请稍后重试。';

  @override
  Future<ExperiencePreferences> readPreferences() =>
      getJson('/api/preferences', ExperiencePreferences.fromJson);

  @override
  Future<ExperiencePreferences> savePreferences({
    required bool developerMode,
  }) => putJson('/api/preferences', {
    'developerMode': developerMode,
  }, ExperiencePreferences.fromJson);

  @override
  Future<MemoryControlsOverview> readMemoryControls() =>
      getJson('/api/memory/controls', MemoryControlsOverview.fromJson);

  @override
  Future<ClearPreview> readClearPreview() =>
      getJson('/api/data/clear-preview', ClearPreview.fromJson);

  @override
  Future<void> clearData() =>
      postJson<void>('/api/data/clear', {'confirm': true}, (_) {});

  @override
  Future<DiagnosticsSnapshot> readDiagnostics() =>
      getJson('/api/dev/diagnostics', DiagnosticsSnapshot.fromJson);
}
