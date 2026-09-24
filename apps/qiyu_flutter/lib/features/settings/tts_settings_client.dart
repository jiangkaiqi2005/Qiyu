import 'dart:convert';
import 'dart:typed_data';

import '../baseline/host_api_gateway.dart';
import 'provider_settings_client.dart' show ProviderSettingsGatewayException;

/// 语音合成（TTS）的服务类型：与 Host 的 tts 段 provider 字段对应，
/// 缺省 openai_compatible（存量配置不带该字段）。
enum TtsServiceKind {
  openAiCompatible,
  volcTts,
  /// 千问语音合成：DashScope 多模态接口，同为 HTTP(S) 家族。
  qwenTts,
  /// 自定义语音合成服务：普通 HTTP POST + JSON 请求体，完整地址直填。
  custom;

  /// 与 Host `TtsProviderKind.wireName` 对应的配置 wire 名。
  String get wireName => switch (this) {
    TtsServiceKind.openAiCompatible => 'openai_compatible',
    TtsServiceKind.volcTts => 'volc_tts',
    TtsServiceKind.qwenTts => 'qwen_tts',
    TtsServiceKind.custom => 'custom',
  };
}

/// 自定义语音合成服务的响应形态：与 Host `TtsResponseShape` 的 wire 名
/// 对应，缺省 raw_bytes（裸音频字节）。
enum TtsResponseShape {
  /// 裸音频字节：响应体原样当音频。
  rawBytes('raw_bytes'),

  /// JSON 字段：字段里是 base64 或 http(s) 音频地址。
  jsonField('json_field'),

  /// 逐行 JSON：一行一块 base64 按序拼接。
  jsonLines('json_lines');

  const TtsResponseShape(this.wireName);

  final String wireName;
}

/// 语音合成的传输方式（票三）：与 Host `TtsTransport` 的 wire 名对应，
/// 只对豆包档有意义——HTTP 分块（缺省，逐句合成）或 WebSocket 双向
/// （边出文本边合成）。千问档按型号驱动（型号名以 -realtime 结尾走
/// WebSocket），自定义档不动，两档都恒为缺省值、不上送。
enum TtsTransport {
  httpChunk('http_chunk'),
  wsBidirection('ws_bidirection');

  const TtsTransport(this.wireName);

  final String wireName;
}

/// 千问语音合成的服务地址缺省值：DashScope 多模态完整端点（与千问识别
/// 同端点，地址栏填完整端点、不拼后缀）。
///
/// 与宿主包 `provider_config.dart` 同名常量双源同值（设置层按 HTTP 镜像
/// 防御旧版 Host，不与宿主包编译期耦合）：改动需两边同步。
const qwenTtsDefaultEndpoint =
    'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';

/// 千问语音合成的模型名称缺省值（与宿主包侧同名常量双源同值，改动需
/// 两边同步）。
const qwenTtsDefaultModel = 'qwen3-tts-flash';

/// 千问语音合成的音色缺省值（官方示例音色）：音色是自由输入框，任何
/// 千问音色 ID 都能填。与宿主包侧同名常量双源同值（改动需两边同步）。
const qwenTtsDefaultVoice = 'Cherry';

/// 千问 3.1 新型号（qwen-audio-3.1-tts-flash）的官方新版地址模板
/// （ADR 0020）：地址主机含 maas.aliyuncs.com 时 Host 按官方
/// SpeechSynthesizer 形状合成。`{业务空间ID}` 是给用户看的拼接占位——
/// 用户把它替换成自己的阿里云百炼业务空间 ID 后整条填入地址栏，栖语
/// 不代填、Host 也不做占位符替换。仅作设置页说明文案，不是缺省值。
const qwenTtsMaasAddressTemplate =
    'https://{业务空间ID}.cn-beijing.maas.aliyuncs.com'
    '/api/v1/services/audio/tts/SpeechSynthesizer';

/// 语音合成（TTS）服务设置：与聊天 Provider、语音转写设置同一套读回
/// 口径——永不回明文 Key，只回 keySet 布尔。自定义档另带回显用旋钮
/// （authHeader/responseShape/responseField）与高级参数 extraParams。
final class TtsSettings {
  const TtsSettings({
    required this.configured,
    required this.keySet,
    this.provider = TtsServiceKind.openAiCompatible,
    this.baseUrl,
    this.model,
    this.voice,
    this.speed,
    this.autoSpeak = true,
    this.authHeader,
    this.responseShape = TtsResponseShape.rawBytes,
    this.responseField,
    this.extraParams,
    this.transport = TtsTransport.httpChunk,
  });

  factory TtsSettings.fromJson(Map<String, Object?> json) {
    final rawExtra = json['extraParams'] ?? json['extra_params'];
    final extraParams = rawExtra is Map
        ? Map<String, Object?>.from(
            rawExtra.map((k, v) => MapEntry(k.toString(), v)),
          )
        : null;
    return TtsSettings(
      configured: json['configured']! as bool,
      keySet: json['keySet']! as bool,
      // 快照 provider 字段缺失或未知值一律按缺省协议呈现（Host 只会回
      // 已支持的值，防御旧版 Host 的响应）。
      provider: switch (json['provider']) {
        'volc_tts' => TtsServiceKind.volcTts,
        'qwen_tts' => TtsServiceKind.qwenTts,
        'custom' => TtsServiceKind.custom,
        _ => TtsServiceKind.openAiCompatible,
      },
      baseUrl: json['baseUrl'] as String?,
      model: json['model'] as String?,
      voice: json['voice'] as String?,
      speed: (json['speed'] as num?)?.toDouble(),
      autoSpeak: json['autoSpeak'] == false ? false : true,
      authHeader: json['authHeader'] as String?,
      // 响应形态缺省 raw_bytes；缺失或未知值都按缺省形态呈现。
      responseShape: switch (json['responseShape']) {
        'json_field' => TtsResponseShape.jsonField,
        'json_lines' => TtsResponseShape.jsonLines,
        _ => TtsResponseShape.rawBytes,
      },
      responseField: json['responseField'] as String?,
      extraParams: extraParams,
      // 传输方式缺省 http_chunk；缺失或未知值都按缺省呈现（Host 只会
      // 回已支持的值，防御旧版 Host 的响应）。
      transport: switch (json['transport']) {
        'ws_bidirection' => TtsTransport.wsBidirection,
        _ => TtsTransport.httpChunk,
      },
    );
  }

  final bool configured;
  final bool keySet;
  final TtsServiceKind provider;
  final String? baseUrl;
  final String? model;
  final String? voice;
  final double? speed;
  final bool autoSpeak;

  /// 自定义档的鉴权头（整行头名）：空表示按默认 Bearer 发。
  final String? authHeader;

  /// 自定义档的响应形态。
  final TtsResponseShape responseShape;

  /// 自定义档的响应字段名：空表示缺省 data。
  final String? responseField;

  final Map<String, Object?>? extraParams;

  /// 传输方式（票三）：只对豆包档有意义，其余档恒为缺省值。
  final TtsTransport transport;
}

final class TtsSettingsDraft {
  const TtsSettingsDraft({
    required this.baseUrl,
    required this.model,
    this.provider = TtsServiceKind.openAiCompatible,
    this.apiKey,
    this.voice,
    this.speed,
    this.autoSpeak,
    this.authHeader,
    this.responseShape,
    this.responseField,
    this.extraParams,
    this.transport,
  });

  final TtsServiceKind provider;
  final String baseUrl;
  final String model;
  final String? apiKey;
  final String? voice;
  final double? speed;
  final bool? autoSpeak;

  /// 自定义档旋钮：非自定义档恒为 null，不上送（Host 侧也只对 custom
  /// 档校验与落盘）。
  final String? authHeader;
  final TtsResponseShape? responseShape;
  final String? responseField;

  final Map<String, Object?>? extraParams;

  /// 传输方式（票三）：非豆包档恒为 null，不上送（Host 侧也只对豆包档
  /// 落盘，其余档归一为缺省 HTTP 分块）。
  final TtsTransport? transport;

  Map<String, Object?> toJson() => {
    'provider': provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': ?apiKey,
    if (voice != null && voice!.trim().isNotEmpty) 'voice': voice,
    'speed': ?speed,
    'autoSpeak': ?autoSpeak,
    if (provider == TtsServiceKind.custom) ...{
      if (authHeader != null && authHeader!.trim().isNotEmpty)
        'authHeader': authHeader,
      if (responseShape != null) 'responseShape': responseShape!.wireName,
      if (responseField != null && responseField!.trim().isNotEmpty)
        'responseField': responseField,
    },
    if (provider == TtsServiceKind.volcTts && transport != null)
      'transport': transport!.wireName,
    if (extraParams != null && extraParams!.isNotEmpty)
      'extraParams': extraParams,
  };
}

/// TTS 连接测试结果：成功时附带试听音频（内存字节，随页面丢弃）。
final class TtsConnectionTest {
  const TtsConnectionTest({
    required this.succeeded,
    required this.message,
    this.audio,
  });

  factory TtsConnectionTest.fromJson(Map<String, Object?> json) {
    final audioBase64 = json['audioBase64'] as String?;
    return TtsConnectionTest(
      succeeded: json['ok'] == true,
      message: json['message']! as String,
      audio: audioBase64 == null ? null : base64Decode(audioBase64),
    );
  }

  final bool succeeded;
  final String message;
  final Uint8List? audio;
}

/// 独立小接口：不往聊天 ProviderSettingsGateway 塞方法，TTS 设置可
/// 单独注入与测试。
abstract interface class TtsSettingsGateway {
  Future<TtsSettings> read();

  Future<TtsSettings> save(TtsSettingsDraft draft);

  /// 聊天页朗读开关：只写 autoSpeak 位（Host 独立路由，不动协议、
  /// 地址、音色与 Key）。
  Future<TtsSettings> setAutoSpeak(bool enabled);

  Future<TtsSettings> forgetApiKey();

  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft);
}

final class HttpTtsSettingsGateway extends HostApiGateway
    implements TtsSettingsGateway {
  HttpTtsSettingsGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => ProviderSettingsGatewayException(message);

  @override
  String get unavailableMessage => '语音朗读设置暂时不可用，请稍后重试。';

  @override
  Future<TtsSettings> read() =>
      getJson('/api/provider/tts', TtsSettings.fromJson);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) =>
      putJson('/api/provider/tts', draft.toJson(), TtsSettings.fromJson);

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) => putJson(
    '/api/provider/tts/auto-speak',
    {'enabled': enabled},
    TtsSettings.fromJson,
  );

  @override
  Future<TtsSettings> forgetApiKey() =>
      deleteJson('/api/provider/tts/key', TtsSettings.fromJson);

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) => postJson(
    '/api/provider/tts/test',
    draft.toJson(),
    TtsConnectionTest.fromJson,
  );
}
