import 'dart:convert';
import 'dart:typed_data';

import '../baseline/host_api_gateway.dart';
import 'provider_settings_client.dart' show ProviderSettingsException;

/// 语音合成（TTS）的服务类型：与 Host 的 tts 段 provider 字段对应，
/// 缺省 openai_compatible（存量配置不带该字段）。
enum TtsServiceKind { openAiCompatible, volcTts }

/// 语音合成（TTS）服务设置：与聊天 Provider、语音转写设置同一套读回
/// 口径——永不回明文 Key，只回 keySet 布尔。
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
    this.extraParams,
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
      provider: json['provider'] == 'volc_tts'
          ? TtsServiceKind.volcTts
          : TtsServiceKind.openAiCompatible,
      baseUrl: json['baseUrl'] as String?,
      model: json['model'] as String?,
      voice: json['voice'] as String?,
      speed: (json['speed'] as num?)?.toDouble(),
      autoSpeak: json['autoSpeak'] == false ? false : true,
      extraParams: extraParams,
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
  final Map<String, Object?>? extraParams;
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
    this.extraParams,
  });

  final TtsServiceKind provider;
  final String baseUrl;
  final String model;
  final String? apiKey;
  final String? voice;
  final double? speed;
  final bool? autoSpeak;
  final Map<String, Object?>? extraParams;

  Map<String, Object?> toJson() => {
    'provider': switch (provider) {
      TtsServiceKind.openAiCompatible => 'openai_compatible',
      TtsServiceKind.volcTts => 'volc_tts',
    },
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': ?apiKey,
    if (voice != null && voice!.trim().isNotEmpty) 'voice': voice,
    'speed': ?speed,
    'autoSpeak': ?autoSpeak,
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
  Object errorFor(String message) => ProviderSettingsException(message);

  @override
  String get unavailableMessage => '语音朗读设置暂时不可用，请稍后重试。';

  @override
  Future<TtsSettings> read() async {
    await ensureBootstrap();
    final response = await httpClient.get(resolve('/api/provider/tts'));
    return TtsSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async {
    final response = await httpClient.put(
      resolve('/api/provider/tts'),
      headers: await modifyingHeaders(),
      body: jsonEncode(draft.toJson()),
    );
    return TtsSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async {
    final response = await httpClient.put(
      resolve('/api/provider/tts/auto-speak'),
      headers: await modifyingHeaders(),
      body: jsonEncode({'enabled': enabled}),
    );
    return TtsSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<TtsSettings> forgetApiKey() async {
    final response = await httpClient.delete(
      resolve('/api/provider/tts/key'),
      headers: await modifyingHeaders(),
    );
    return TtsSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async {
    final response = await httpClient.post(
      resolve('/api/provider/tts/test'),
      headers: await modifyingHeaders(),
      body: jsonEncode(draft.toJson()),
    );
    return TtsConnectionTest.fromJson(decodeSuccess(response));
  }
}
