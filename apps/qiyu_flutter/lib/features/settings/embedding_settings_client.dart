import '../baseline/host_api_gateway.dart';
import 'provider_settings_client.dart'
    show ProviderTestResult, ProviderSettingsGatewayException;

/// 记忆召回（Episode RAG）embedding 服务设置：与聊天 Provider 设置同一
/// 套读回口径——永不回明文 Key，只回 keySet 布尔。保存／测试／忘记 Key
/// 不启用 RAG、不建索引、不发送 episode；启用与召回由后续票接入。
final class EmbeddingSettings {
  const EmbeddingSettings({
    required this.configured,
    required this.keySet,
    this.baseUrl,
    this.model,
  });

  factory EmbeddingSettings.fromJson(Map<String, Object?> json) =>
      EmbeddingSettings(
        configured: json['configured']! as bool,
        keySet: json['keySet']! as bool,
        baseUrl: json['baseUrl'] as String?,
        model: json['model'] as String?,
      );

  final bool configured;
  final bool keySet;
  final String? baseUrl;
  final String? model;
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
}

final class HttpEmbeddingSettingsGateway extends HostApiGateway
    implements EmbeddingSettingsGateway {
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
}
