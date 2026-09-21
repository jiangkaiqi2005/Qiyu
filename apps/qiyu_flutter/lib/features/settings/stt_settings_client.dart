import '../baseline/host_api_gateway.dart';
import 'provider_settings_client.dart'
    show ProviderTestResult, ProviderSettingsGatewayException;

/// 语音转写（STT）的服务类型：与 Host 的 stt 段 provider 字段对应，
/// 缺省 openai_compatible（存量配置不带该字段）。
enum SttServiceKind {
  openaiCompatible,
  volcSeedAsr,
  /// 千问语音识别：DashScope 多模态接口，同为 HTTP(S) 家族。
  qwenAsr;

  /// 与 Host `SttProviderKind.wireName` 对应的配置 wire 名。
  String get wireName => switch (this) {
    SttServiceKind.openaiCompatible => 'openai_compatible',
    SttServiceKind.volcSeedAsr => 'volc_seed_asr',
    SttServiceKind.qwenAsr => 'qwen_asr',
  };
}

/// 千问语音识别的服务地址缺省值：DashScope 多模态完整端点。
const qwenAsrDefaultEndpoint =
    'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';

/// 千问语音识别的模型名称缺省值。
const qwenAsrDefaultModel = 'qwen3-asr-flash';

/// 语音转写（STT）服务设置：与聊天 Provider 设置同一套读回口径——
/// 永不回明文 Key，只回 keySet 布尔。
final class SttSettings {
  const SttSettings({
    required this.configured,
    required this.keySet,
    this.provider = SttServiceKind.openaiCompatible,
    this.baseUrl,
    this.model,
  });

  factory SttSettings.fromJson(Map<String, Object?> json) => SttSettings(
    configured: json['configured']! as bool,
    keySet: json['keySet']! as bool,
    // 快照 provider 字段缺失或未知值一律按缺省协议呈现（Host 只会回
    // 这三种 wire 名，未知值只可能是旧版 Host 的响应，防御性回落）。
    provider: switch (json['provider']) {
      'volc_seed_asr' => SttServiceKind.volcSeedAsr,
      'qwen_asr' => SttServiceKind.qwenAsr,
      _ => SttServiceKind.openaiCompatible,
    },
    baseUrl: json['baseUrl'] as String?,
    model: json['model'] as String?,
  );

  final bool configured;
  final bool keySet;
  final SttServiceKind provider;
  final String? baseUrl;
  final String? model;

  /// 豆包与千问协议只吃 16kHz/16-bit 单声道 WAV：聊天页据此决定录音是否
  /// 要在浏览器端转换后再上送。
  bool get wantsWavAudio =>
      provider == SttServiceKind.volcSeedAsr ||
      provider == SttServiceKind.qwenAsr;
}

final class SttSettingsDraft {
  const SttSettingsDraft({
    required this.baseUrl,
    required this.model,
    this.provider = SttServiceKind.openaiCompatible,
    this.apiKey,
  });

  final SttServiceKind provider;
  final String baseUrl;
  final String model;
  final String? apiKey;

  Map<String, Object?> toJson() => {
    'provider': provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': ?apiKey,
  };
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
  Object errorFor(String message) => ProviderSettingsGatewayException(message);

  @override
  String get unavailableMessage => '语音设置暂时不可用，请稍后重试。';

  @override
  Future<SttSettings> read() =>
      getJson('/api/provider/stt', SttSettings.fromJson);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) =>
      putJson('/api/provider/stt', draft.toJson(), SttSettings.fromJson);

  @override
  Future<SttSettings> forgetApiKey() =>
      deleteJson('/api/provider/stt/key', SttSettings.fromJson);

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) => postJson(
    '/api/provider/stt/test',
    draft.toJson(),
    ProviderTestResult.fromJson,
  );
}
