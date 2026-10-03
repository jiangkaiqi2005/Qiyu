import '../baseline/host_api_gateway.dart';
import 'voice_tier_suggestion.dart';

enum ProviderKind {
  openAiCompatible('openai_compatible', 'OpenAI 兼容'),
  anthropic('anthropic', 'Anthropic'),
  ollama('ollama', 'Ollama'),
  // Omni 实时对话档（ADR 0026）：DashScope Realtime WebSocket，与
  // Chat Completions 协议互斥。Host 侧快照可能回显该 wire 名（本机
  // provider.json 可直接编辑），枚举必须能解析，避免设置页读崩。
  qwenOmniRealtime('qwen_omni_realtime', 'Omni 实时');

  const ProviderKind(this.wireName, this.label);

  final String wireName;
  final String label;

  static ProviderKind fromWireName(String value) => values.firstWhere(
    (provider) => provider.wireName == value,
    orElse: () =>
        throw const ProviderSettingsGatewayException('本机程序返回了未知的模型服务。'),
  );
}

enum CallStartupMode {
  manual('manual'),
  autoOnChatEntry('auto_on_chat_entry');

  const CallStartupMode(this.wireName);

  final String wireName;

  static CallStartupMode fromWireName(Object? value) => values.firstWhere(
    (mode) => mode.wireName == value,
    orElse: () =>
        throw const ProviderSettingsGatewayException('本机程序返回了未知的通话启动方式。'),
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
    this.callStartupMode = CallStartupMode.manual,
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
      callStartupMode: json.containsKey('callStartupMode')
          ? CallStartupMode.fromWireName(json['callStartupMode'])
          : CallStartupMode.manual,
    );
  }

  final bool configured;
  final bool keySet;
  final ProviderKind? provider;
  final String? baseUrl;
  final String? model;
  final double? temperature;
  final int? timeoutSeconds;
  final CallStartupMode callStartupMode;
}

final class ProviderSettingsDraft {
  const ProviderSettingsDraft({
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.temperature,
    required this.timeoutSeconds,
    this.apiKey,
    this.callStartupMode,
  });

  final ProviderKind provider;
  final String baseUrl;
  final String model;
  final double temperature;
  final int timeoutSeconds;
  final String? apiKey;
  // 未携带时只改其他设置，Host 在事务内保留现有偏好。
  final CallStartupMode? callStartupMode;

  Map<String, Object?> toJson() => {
    'provider': provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
    'temperature': temperature,
    'timeoutSeconds': timeoutSeconds,
    'apiKey': ?apiKey,
    'callStartupMode': ?callStartupMode?.wireName,
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
  modelInterfaceMismatch,
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
    this.tierSuggestion,
  });

  factory ProviderTestResult.fromJson(Map<String, Object?> json) {
    final rawSuggestion = json['suggestion'];
    return ProviderTestResult(
      succeeded: json['ok']! as bool,
      status: ProviderTestStatus.values.byName(json['status']! as String),
      message: json['message']! as String,
      // 档位映射建议（ADR 0020）：只有语音设置域的连接测试在命中时下发；
      // 聊天域的测试响应从不带该字段，解析恒为 null。
      tierSuggestion: rawSuggestion is Map
          ? VoiceTierSuggestionData.fromJson(
              Map<String, Object?>.from(
                rawSuggestion.map((k, v) => MapEntry(k.toString(), v)),
              ),
            )
          : null,
    );
  }

  final bool succeeded;
  final ProviderTestStatus status;
  final String message;

  /// 档位映射建议（应换档／不支持）：表 miss 或成功时为 null。
  final VoiceTierSuggestionData? tierSuggestion;
}

final class ProviderSettingsGatewayException
    implements Exception, UserFacingException {
  const ProviderSettingsGatewayException(this.message);

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
  Object errorFor(String message) => ProviderSettingsGatewayException(message);

  @override
  String get unavailableMessage => '模型设置暂时不可用，请稍后重试。';

  @override
  Future<ProviderSettings> read() =>
      getJson('/api/provider', ProviderSettings.fromJson);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      putJson('/api/provider', draft.toJson(), ProviderSettings.fromJson);

  @override
  Future<ProviderSettings> forgetApiKey() =>
      deleteJson('/api/provider/key', ProviderSettings.fromJson);

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      postJson(
        '/api/provider/test',
        draft.toJson(),
        ProviderTestResult.fromJson,
      );
}
