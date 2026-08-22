import 'dart:convert';


import '../baseline/host_api_gateway.dart';
import 'provider_settings_client.dart'
    show ProviderTestResult, ProviderSettingsException;

/// 语音转写（STT）服务设置：与聊天 Provider 设置同一套读回口径——
/// 永不回明文 Key，只回 keySet 布尔。
final class SttSettings {
  const SttSettings({
    required this.configured,
    required this.keySet,
    this.baseUrl,
    this.model,
  });

  factory SttSettings.fromJson(Map<String, Object?> json) => SttSettings(
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

final class SttSettingsDraft {
  const SttSettingsDraft({required this.baseUrl, required this.model, this.apiKey});

  final String baseUrl;
  final String model;
  final String? apiKey;

  Map<String, Object?> toJson() =>
      {'baseUrl': baseUrl, 'model': model, 'apiKey': ?apiKey};
}

/// 独立小接口：不往聊天 ProviderSettingsGateway 塞方法，STT 设置可
/// 单独注入与测试。
abstract interface class SttSettingsGateway {
  Future<SttSettings> read();

  Future<SttSettings> save(SttSettingsDraft draft);

  Future<SttSettings> forgetApiKey();

  Future<ProviderTestResult> testConnection(SttSettingsDraft draft);
}

final class HttpSttSettingsGateway extends HostApiGateway
    implements SttSettingsGateway {
  HttpSttSettingsGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => ProviderSettingsException(message);

  @override
  String get unavailableMessage => '语音设置暂时不可用，请稍后重试。';

  @override
  Future<SttSettings> read() async {
    await ensureBootstrap();
    final response = await httpClient.get(resolve('/api/provider/stt'));
    return SttSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async {
    final response = await httpClient.put(
      resolve('/api/provider/stt'),
      headers: await modifyingHeaders(),
      body: jsonEncode(draft.toJson()),
    );
    return SttSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<SttSettings> forgetApiKey() async {
    final response = await httpClient.delete(
      resolve('/api/provider/stt/key'),
      headers: await modifyingHeaders(),
    );
    return SttSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async {
    final response = await httpClient.post(
      resolve('/api/provider/stt/test'),
      headers: await modifyingHeaders(),
      body: jsonEncode(draft.toJson()),
    );
    return ProviderTestResult.fromJson(decodeSuccess(response));
  }
}
