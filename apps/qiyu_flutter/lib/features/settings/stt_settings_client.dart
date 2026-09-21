import '../baseline/host_api_gateway.dart';
import 'provider_settings_client.dart'
    show ProviderTestResult, ProviderSettingsGatewayException;

/// 语音转写（STT）的服务类型：与 Host 的 stt 段 provider 字段对应，
/// 缺省 openai_compatible（存量配置不带该字段）。
enum SttServiceKind {
  openaiCompatible,
  volcSeedAsr,
  /// 千问语音识别：DashScope 多模态接口，同为 HTTP(S) 家族。
  qwenAsr,
  /// 自定义转写服务：普通 HTTP POST + multipart 表单，完整地址直填。
  custom;

  /// 与 Host `SttProviderKind.wireName` 对应的配置 wire 名。
  String get wireName => switch (this) {
    SttServiceKind.openaiCompatible => 'openai_compatible',
    SttServiceKind.volcSeedAsr => 'volc_seed_asr',
    SttServiceKind.qwenAsr => 'qwen_asr',
    SttServiceKind.custom => 'custom',
  };
}

/// 自定义转写服务的响应形态：与 Host `SttResponseShape` 的 wire 名对应，
/// 缺省 json_path。
enum SttResponseShape {
  /// JSON 字段路径：整段响应按点号路径取文本（缺省 text）。
  jsonPath('json_path'),

  /// SSE 流式：逐行 data 事件拼字。
  sse('sse');

  const SttResponseShape(this.wireName);

  final String wireName;
}

/// 千问语音识别的服务地址缺省值：DashScope 多模态完整端点。
const qwenAsrDefaultEndpoint =
    'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';

/// 千问语音识别的模型名称缺省值。
const qwenAsrDefaultModel = 'qwen3-asr-flash';

/// 语音转写（STT）服务设置：与聊天 Provider 设置同一套读回口径——
/// 永不回明文 Key，只回 keySet 布尔。自定义档另带回显用旋钮
/// （authHeader/responseShape/responseField）与高级参数 extraParams。
final class SttSettings {
  const SttSettings({
    required this.configured,
    required this.keySet,
    this.provider = SttServiceKind.openaiCompatible,
    this.baseUrl,
    this.model,
    this.authHeader,
    this.responseShape = SttResponseShape.jsonPath,
    this.responseField,
    this.extraParams,
  });

  factory SttSettings.fromJson(Map<String, Object?> json) {
    final rawExtra = json['extraParams'] ?? json['extra_params'];
    final extraParams = rawExtra is Map
        ? Map<String, Object?>.from(
            rawExtra.map((k, v) => MapEntry(k.toString(), v)),
          )
        : null;
    return SttSettings(
      configured: json['configured']! as bool,
      keySet: json['keySet']! as bool,
      // 快照 provider 字段缺失或未知值一律按缺省协议呈现（Host 只会回
      // 这四种 wire 名，未知值只可能是旧版 Host 的响应，防御性回落）。
      provider: switch (json['provider']) {
        'volc_seed_asr' => SttServiceKind.volcSeedAsr,
        'qwen_asr' => SttServiceKind.qwenAsr,
        'custom' => SttServiceKind.custom,
        _ => SttServiceKind.openaiCompatible,
      },
      baseUrl: json['baseUrl'] as String?,
      model: json['model'] as String?,
      authHeader: json['authHeader'] as String?,
      // 响应形态缺省 json_path；缺失或未知值都按缺省形态呈现。
      responseShape: switch (json['responseShape']) {
        'sse' => SttResponseShape.sse,
        _ => SttResponseShape.jsonPath,
      },
      responseField: json['responseField'] as String?,
      extraParams: extraParams,
    );
  }

  final bool configured;
  final bool keySet;
  final SttServiceKind provider;
  final String? baseUrl;
  final String? model;

  /// 自定义档的鉴权头（整行头名）：空表示按默认 Bearer 发。
  final String? authHeader;

  /// 自定义档的响应形态。
  final SttResponseShape responseShape;

  /// 自定义档的响应字段名/路径（点号路径）：空表示缺省 text。
  final String? responseField;

  /// 自定义档的高级参数（multipart 额外表单字段）。
  final Map<String, Object?>? extraParams;

  /// 豆包与千问协议只吃 16kHz/16-bit 单声道 WAV：聊天页据此决定录音是否
  /// 要在浏览器端转换后再上送。自定义档录音原样上送（服务端解码）。
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
    this.authHeader,
    this.responseShape,
    this.responseField,
    this.extraParams,
  });

  final SttServiceKind provider;
  final String baseUrl;
  final String model;
  final String? apiKey;

  /// 自定义档旋钮：非自定义档恒为 null，不上送（Host 侧也只对 custom
  /// 档校验与落盘）。
  final String? authHeader;
  final SttResponseShape? responseShape;
  final String? responseField;
  final Map<String, Object?>? extraParams;

  Map<String, Object?> toJson() => {
    'provider': provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': ?apiKey,
    if (provider == SttServiceKind.custom) ...{
      if (authHeader != null && authHeader!.trim().isNotEmpty)
        'authHeader': authHeader,
      if (responseShape != null) 'responseShape': responseShape!.wireName,
      if (responseField != null && responseField!.trim().isNotEmpty)
        'responseField': responseField,
      if (extraParams != null && extraParams!.isNotEmpty)
        'extraParams': extraParams,
    },
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
