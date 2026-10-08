import '../baseline/host_api_gateway.dart';
import 'provider_settings_client.dart'
    show ProviderTestResult, ProviderSettingsGatewayException;

/// 记忆召回（Episode RAG）embedding 服务设置：与聊天 Provider 设置同一
/// 套读回口径——永不回明文 Key，只回 keySet 布尔。保存／测试／忘记 Key
/// 不启用 RAG；启用/停用/重建是显式操作（票 03），状态快照随读取一并
/// 返回。
final class EmbeddingSettings {
  const EmbeddingSettings({
    required this.configured,
    required this.keySet,
    required this.enabled,
    this.baseUrl,
    this.model,
    this.rag,
  });

  factory EmbeddingSettings.fromJson(Map<String, Object?> json) =>
      EmbeddingSettings(
        configured: json['configured']! as bool,
        keySet: json['keySet']! as bool,
        // 旧 Host 没有该字段：按未启用解析。
        enabled: json['enabled'] as bool? ?? false,
        baseUrl: json['baseUrl'] as String?,
        model: json['model'] as String?,
        rag: MemoryRecallStatus.fromJsonOrNull(
          json['rag'] as Map<String, Object?>?,
        ),
      );

  final bool configured;
  final bool keySet;

  /// 用户是否显式启用了 Episode RAG。
  final bool enabled;
  final String? baseUrl;
  final String? model;

  /// 召回状态快照（未启用/准备中/已就绪/需重建/暂不可用 + 进度与原因）；
  /// 旧 Host 不返回时为 null。
  final MemoryRecallStatus? rag;
}

/// 记忆召回状态快照（票 03）：只含状态名、准备进度与人话原因。
final class MemoryRecallStatus {
  const MemoryRecallStatus({
    required this.state,
    required this.progressDone,
    required this.progressTotal,
    this.reason,
  });

  factory MemoryRecallStatus.fromJson(Map<String, Object?> json) =>
      MemoryRecallStatus(
        state: json['state']! as String,
        progressDone: json['progressDone'] as int? ?? 0,
        progressTotal: json['progressTotal'] as int? ?? 0,
        reason: json['reason'] as String?,
      );

  static MemoryRecallStatus? fromJsonOrNull(Map<String, Object?>? json) =>
      json == null ? null : MemoryRecallStatus.fromJson(json);

  /// disabled / preparing / ready / rebuildNeeded / unavailable。
  final String state;
  final int progressDone;
  final int progressTotal;
  final String? reason;

  /// 值相等（与 [BackgroundFailureStatus] 同律）：监控轮询按它去重，
  /// 状态未变化不重复通知。
  @override
  bool operator ==(Object other) =>
      other is MemoryRecallStatus &&
      other.state == state &&
      other.progressDone == progressDone &&
      other.progressTotal == progressTotal &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(state, progressDone, progressTotal, reason);
}

/// 聊天页旁路状态的小接口（票 03）：HostStatusMonitor 按既有轮询节拍
/// 读取记忆召回设置快照（状态随读取返回），不复制 Host 网络实现。
abstract interface class MemoryRecallStatusGateway {
  Future<EmbeddingSettings?> read();
}

final class EmbeddingSettingsDraft {
  const EmbeddingSettingsDraft({
    required this.baseUrl,
    required this.model,
    this.apiKey,
  });

  final String baseUrl;
  final String model;
  final String? apiKey;

  Map<String, Object?> toJson() => {
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': ?apiKey,
  };
}

/// 独立小接口：不往聊天 ProviderSettingsGateway 塞方法，记忆召回设置可
/// 单独注入与测试。
abstract interface class EmbeddingSettingsGateway {
  Future<EmbeddingSettings> read();

  Future<EmbeddingSettings> save(EmbeddingSettingsDraft draft);

  Future<EmbeddingSettings> forgetApiKey();

  Future<ProviderTestResult> testConnection(EmbeddingSettingsDraft draft);

  /// 显式启用：触发后台索引构建（缓存有效时直接就绪）。
  Future<EmbeddingSettings> enable();

  /// 显式停用：召回回到旧目录路径。
  Future<EmbeddingSettings> disable();

  /// 明确重建/重试（需重建与暂不可用状态的重试入口）。
  Future<EmbeddingSettings> rebuild();
}

final class HttpEmbeddingSettingsGateway extends HostApiGateway
    implements EmbeddingSettingsGateway, MemoryRecallStatusGateway {
  HttpEmbeddingSettingsGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) =>
      ProviderSettingsGatewayException(message);

  @override
  String get unavailableMessage => '记忆召回设置暂时不可用，请稍后重试。';

  @override
  Future<EmbeddingSettings> read() =>
      getJson('/api/provider/embedding', EmbeddingSettings.fromJson);

  @override
  Future<EmbeddingSettings> save(EmbeddingSettingsDraft draft) => putJson(
    '/api/provider/embedding',
    draft.toJson(),
    EmbeddingSettings.fromJson,
  );

  @override
  Future<EmbeddingSettings> forgetApiKey() =>
      deleteJson('/api/provider/embedding/key', EmbeddingSettings.fromJson);

  @override
  Future<ProviderTestResult> testConnection(EmbeddingSettingsDraft draft) =>
      postJson(
        '/api/provider/embedding/test',
        draft.toJson(),
        ProviderTestResult.fromJson,
      );

  @override
  Future<EmbeddingSettings> enable() =>
      postJson('/api/provider/embedding/enable', <String, Object?>{},
          EmbeddingSettings.fromJson);

  @override
  Future<EmbeddingSettings> disable() =>
      postJson('/api/provider/embedding/disable', <String, Object?>{},
          EmbeddingSettings.fromJson);

  @override
  Future<EmbeddingSettings> rebuild() =>
      postJson('/api/provider/embedding/rebuild', <String, Object?>{},
          EmbeddingSettings.fromJson);
}
