import 'dart:convert';

import 'package:http/http.dart' as http;

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
  authentication,
  network,
  modelNotFound,
  invalidResponse,
  provider,
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

final class ProviderSettingsException implements Exception {
  const ProviderSettingsException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class ProviderSettingsGateway {
  Future<ProviderSettings> read();

  Future<ProviderSettings> save(ProviderSettingsDraft draft);

  Future<ProviderSettings> forgetApiKey();

  Future<ProviderTestResult> testConnection();
}

final class HttpProviderSettingsGateway implements ProviderSettingsGateway {
  HttpProviderSettingsGateway({http.Client? client, Uri? baseUri})
    : _client = client ?? http.Client(),
      _baseUri = baseUri ?? Uri.base;

  final http.Client _client;
  final Uri _baseUri;
  String? _csrfToken;

  @override
  Future<ProviderSettings> read() async {
    await _ensureBootstrap();
    final response = await _client.get(_baseUri.resolve('/api/provider'));
    return ProviderSettings.fromJson(_decodeSuccess(response));
  }

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async {
    await _ensureBootstrap();
    final response = await _client.put(
      _baseUri.resolve('/api/provider'),
      headers: _modifyingHeaders,
      body: jsonEncode(draft.toJson()),
    );
    return ProviderSettings.fromJson(_decodeSuccess(response));
  }

  @override
  Future<ProviderSettings> forgetApiKey() async {
    await _ensureBootstrap();
    final response = await _client.delete(
      _baseUri.resolve('/api/provider/key'),
      headers: _modifyingHeaders,
    );
    return ProviderSettings.fromJson(_decodeSuccess(response));
  }

  @override
  Future<ProviderTestResult> testConnection() async {
    await _ensureBootstrap();
    final response = await _client.post(
      _baseUri.resolve('/api/provider/test'),
      headers: _modifyingHeaders,
    );
    return ProviderTestResult.fromJson(_decodeSuccess(response));
  }

  Map<String, String> get _modifyingHeaders => {
    'content-type': 'application/json',
    'x-qiyu-csrf': _csrfToken!,
  };

  Future<void> _ensureBootstrap() async {
    if (_csrfToken != null) {
      return;
    }
    final response = await _client.get(_baseUri.resolve('/api/bootstrap'));
    final json = _decodeSuccess(response);
    _csrfToken = json['csrfToken']! as String;
  }
}

Map<String, Object?> _decodeSuccess(http.Response response) {
  Map<String, Object?>? json;
  try {
    json = jsonDecode(response.body) as Map<String, Object?>;
  } on Object {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      throw const ProviderSettingsException('本机程序返回了无法读取的内容。');
    }
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw ProviderSettingsException(
      json?['message'] as String? ?? '模型设置暂时不可用，请稍后重试。',
    );
  }
  return json!;
}
