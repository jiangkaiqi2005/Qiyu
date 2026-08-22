import 'dart:convert';


import '../baseline/host_api_gateway.dart';

enum ProviderKind {
  openAiCompatible('openai_compatible', 'OpenAI 兼容'),
  anthropic('anthropic', 'Anthropic'),
  ollama('ollama', 'Ollama');

  const ProviderKind(this.wireName, this.label);

  final String wireName;
  final String label;

  static ProviderKind fromWireName(String value) => values.firstWhere(
    (provider) => provider.wireName == value,
    orElse: () => throw const ProviderSettingsException('本机程序返回了未知的模型服务。'),
  );
}

final class ProviderSettings {
  const ProviderSettings({
    required this.configured,
    required this.keySet,
    this.provider,
    this.baseUrl,
    this.model,
    this.temperature,
    this.timeoutSeconds,
  });

  factory ProviderSettings.fromJson(Map<String, Object?> json) {
    final provider = json['provider'];
    return ProviderSettings(
      configured: json['configured']! as bool,
      keySet: json['keySet']! as bool,
      provider: provider == null
          ? null
          : ProviderKind.fromWireName(provider as String),
      baseUrl: json['baseUrl'] as String?,
      model: json['model'] as String?,
      temperature: (json['temperature'] as num?)?.toDouble(),
      timeoutSeconds: json['timeoutSeconds'] as int?,
    );
  }

  final bool configured;
  final bool keySet;
  final ProviderKind? provider;
  final String? baseUrl;
  final String? model;
  final double? temperature;
  final int? timeoutSeconds;
}

final class ProviderSettingsDraft {
  const ProviderSettingsDraft({
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.temperature,
    required this.timeoutSeconds,
    this.apiKey,
  });

  final ProviderKind provider;
  final String baseUrl;
  final String model;
  final double temperature;
  final int timeoutSeconds;
  final String? apiKey;

  Map<String, Object?> toJson() => {
    'provider': provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
    'temperature': temperature,
    'timeoutSeconds': timeoutSeconds,
    'apiKey': ?apiKey,
  };
}

enum ProviderTestStatus {
  success,
  notConfigured,
  dns,
  tls,
  timeout,
  authentication,
  network,
  modelNotFound,
  rateLimited,
  incompatibleResponse,
  contentParsing,
  provider,
  internal,
}

final class ProviderTestResult {
  const ProviderTestResult({
    required this.succeeded,
    required this.status,
    required this.message,
  });

  factory ProviderTestResult.fromJson(Map<String, Object?> json) =>
      ProviderTestResult(
        succeeded: json['ok']! as bool,
        status: ProviderTestStatus.values.byName(json['status']! as String),
        message: json['message']! as String,
      );

  final bool succeeded;
  final ProviderTestStatus status;
  final String message;
}

final class ProviderSettingsException
    implements Exception, UserFacingException {
  const ProviderSettingsException(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

abstract interface class ProviderSettingsGateway {
  Future<ProviderSettings> read();

  Future<ProviderSettings> save(ProviderSettingsDraft draft);

  Future<ProviderSettings> forgetApiKey();

  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft);
}

final class HttpProviderSettingsGateway extends HostApiGateway
    implements ProviderSettingsGateway {
  HttpProviderSettingsGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => ProviderSettingsException(message);

  @override
  String get unavailableMessage => '模型设置暂时不可用，请稍后重试。';

  @override
  Future<ProviderSettings> read() async {
    await ensureBootstrap();
    final response = await httpClient.get(resolve('/api/provider'));
    return ProviderSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async {
    final response = await httpClient.put(
      resolve('/api/provider'),
      headers: await modifyingHeaders(),
      body: jsonEncode(draft.toJson()),
    );
    return ProviderSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<ProviderSettings> forgetApiKey() async {
    final response = await httpClient.delete(
      resolve('/api/provider/key'),
      headers: await modifyingHeaders(),
    );
    return ProviderSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) async {
    final response = await httpClient.post(
      resolve('/api/provider/test'),
      headers: await modifyingHeaders(),
      body: jsonEncode(draft.toJson()),
    );
    return ProviderTestResult.fromJson(decodeSuccess(response));
  }
}
