import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'tts_gateway.dart';

/// 豆包语音合成 2.0（火山方舟 Agent Plan）的 Host 中介客户端。按官方
/// 文档（2026-08-23 用户提供）走订阅专属 HTTP 单向端点：一次性 POST
/// 全文，响应是 chunked 逐行 JSON——每行的 `data` 是 base64 音频块，
/// 按序拼接为完整 mp3，`code==20000000` 为正常结束标记，行内 `code>0`
/// 为错误（官方未给码表，统一按服务拒绝分类，HTTP 状态码错误仍走
/// 既有分类）。
final class VolcTtsGateway implements TtsSynthesisGateway {
  const VolcTtsGateway(this.httpClient);

  final ProviderBytesHttpClient httpClient;

  /// 官方 HTTP 示例用的音色：设置页的缺省占位，用户可改。
  static const defaultSpeaker = 'zh_female_vv_uranus_bigtts';

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = Uri.parse(config.baseUrl.trim());
    ensureTtsOutboundAllowed(uri);
    final rawSpeaker = config.voice?.trim();
    final String effectiveSpeaker;
    final String? detectedDialect;
    if (rawSpeaker != null && rawSpeaker.isNotEmpty) {
      final dialect = _detectDialect(rawSpeaker);
      if (dialect != null) {
        effectiveSpeaker = defaultSpeaker;
        detectedDialect = dialect;
      } else {
        effectiveSpeaker = rawSpeaker;
        detectedDialect = null;
      }
    } else {
      effectiveSpeaker = defaultSpeaker;
      detectedDialect = null;
    }

    final audioParams = <String, Object?>{
      'format': 'mp3',
      'sample_rate': 24000,
    };
    final extra = config.extraParams;
    if (extra != null && extra['audio_params'] is Map) {
      audioParams.addAll(
        (extra['audio_params'] as Map).cast<String, Object?>(),
      );
    }
    // 火山方舟 seed-tts-2.0 语速字段在 audio_params 下的 speech_rate（[-50, 100]，0 为 1.0x）。
    if (config.speed != null) {
      audioParams['speech_rate'] =
          ((config.speed! - 1.0) * 100).round().clamp(-50, 100);
    }

    final effectiveAdditions = _resolveAdditions(
      extra: extra,
      detectedDialect: detectedDialect,
    );

    final reqParams = <String, Object?>{
      if (extra != null)
        for (final entry in extra.entries)
          if (entry.key != 'audio_params' && entry.key != 'additions')
            entry.key: entry.value,
      'text': text,
      'speaker': effectiveSpeaker,
      'audio_params': audioParams,
      'additions': ?effectiveAdditions,
    };
    final body = jsonEncode({'req_params': reqParams});
    final response = await postTtsBytes(
      httpClient: httpClient,
      uri: uri,
      headers: {
        'X-Api-Key': key,
        // 模型名称字段填的就是 Resource-Id（如 seed-tts-2.0）。
        'X-Api-Resource-Id': config.model.trim(),
        'X-Control-Require-Usage-Tokens-Return': '*',
        'content-type': 'application/json',
      },
      body: utf8.encode(body),
    );
    // 官方接入建议：记录 X-Tt-Logid 便于排查（只进本机诊断）。
    if (response.headers['x-tt-logid'] case final logid?) {
      stderrDiagnostics('tts volc logid: $logid');
    }

    final bytes = await consumeTtsBytesResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _fromModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(bytes, allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    return _parseChunkedAudio(bytes);
  }

  /// 聚合 chunked 逐行 JSON 响应为完整音频字节。
  List<int> _parseChunkedAudio(Uint8List body) {
    final audio = BytesBuilder(copy: false);
    var finished = false;
    for (final rawLine in utf8.decode(body, allowMalformed: true).split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      final Map<String, Object?> decoded;
      try {
        final parsed = jsonDecode(line);
        if (parsed is! Map<String, Object?>) {
          throw const FormatException('tts line must be an object');
        }
        decoded = parsed;
      } on Object {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务返回的内容无法解析。',
        );
      }
      final code = decoded['code'];
      if (code is! num) {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务返回的内容无法解析。',
        );
      }
      if (code.toInt() == volcTtsFinishedCode) {
        finished = true;
        break;
      }
      if (code.toInt() > 0) {
        // 行内错误（码表官方未给）：统一按服务拒绝，不透出原始行。
        throw const TtsGatewayException(
          kind: ModelFailureKind.provider,
          message: '语音合成服务拒绝了这次请求。',
        );
      }
      final data = decoded['data'];
      if (data is String && data.isNotEmpty) {
        try {
          audio.add(base64.decode(data));
        } on Object {
          throw const TtsGatewayException(
            kind: ModelFailureKind.contentParsing,
            message: '语音合成服务返回的内容无法解析。',
          );
        }
      }
    }
    if (!finished) {
      // 没等到结束标记就断流：半截音频不能用。
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的音频不完整。',
      );
    }
    final bytes = audio.takeBytes();
    if (bytes.isEmpty) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务没有返回音频。',
      );
    }
    return bytes;
  }

  /// 检测音色是否代表方言，并返回对应的方言代码（如 sichuan, dongbei 等）。
  static String? _detectDialect(String voice) {
    final normalized = voice.toLowerCase().trim();
    if (_dialectVoiceMap.containsKey(normalized)) {
      return _dialectVoiceMap[normalized];
    }
    if (normalized.contains('sichuan')) return 'sichuan';
    if (normalized.contains('cantonese') ||
        normalized.contains('guangdong') ||
        normalized.contains('yue')) {
      return 'guangdong';
    }
    if (normalized.contains('dongbei')) return 'dongbei';
    if (normalized.contains('henan')) return 'henan';
    if (normalized.contains('shaanxi') || normalized.contains('shanxi')) {
      return 'shaanxi';
    }
    if (normalized.contains('tianjin')) return 'tianjin';
    if (normalized.contains('shandong')) return 'shandong';
    if (normalized.contains('minnan')) return 'minnan';
    if (normalized.contains('wanwan') || normalized.contains('taiwan')) {
      return 'taiwan';
    }
    if (normalized.contains('beijing')) return 'beijing';
    return null;
  }

  static const _dialectVoiceMap = <String, String>{
    'zh_female_sichuan_uranus_bigtts': 'sichuan',
    'zh_female_cantonese_uranus_bigtts': 'guangdong',
    'zh_female_dongbei_uranus_bigtts': 'dongbei',
    'zh_female_henan_uranus_bigtts': 'henan',
    'zh_female_shanxi_uranus_bigtts': 'shaanxi',
    'zh_female_tianjin_uranus_bigtts': 'tianjin',
    'zh_female_shandong_uranus_bigtts': 'shandong',
    'zh_female_minnan_uranus_bigtts': 'minnan',
    'zh_female_wanwanxiaohe_moon_bigtts': 'taiwan',
    'zh_female_beijing_uranus_bigtts': 'beijing',
  };

  /// 火山方舟 Go 服务端中 `additions` 字段类型是 `string`。
  /// 无论是自动注入方言参数，还是用户通过 extraParams 传入的对象，
  /// 统一序列化为 JSON 字符串（若已经是字符串则保持）。
  static String? _resolveAdditions({
    required Map<String, Object?>? extra,
    required String? detectedDialect,
  }) {
    final rawAdditions = extra?['additions'];
    if (rawAdditions == null) {
      if (detectedDialect == null) {
        return null;
      }
      return jsonEncode({'explicit_dialect': detectedDialect});
    }

    if (rawAdditions is Map) {
      final map = Map<String, Object?>.from(rawAdditions);
      if (detectedDialect != null) {
        map.putIfAbsent('explicit_dialect', () => detectedDialect);
      }
      return jsonEncode(map);
    }

    if (rawAdditions is String) {
      if (detectedDialect == null) {
        return rawAdditions;
      }
      try {
        final decoded = jsonDecode(rawAdditions);
        if (decoded is Map) {
          final map = Map<String, Object?>.from(decoded);
          map.putIfAbsent('explicit_dialect', () => detectedDialect);
          return jsonEncode(map);
        }
      } on FormatException {
        // 非 JSON 对象字符串，保持原样。
      }
      return rawAdditions;
    }

    return jsonEncode(rawAdditions);
  }
}

/// 官方逐行 JSON 协议的正常结束标记码。
const volcTtsFinishedCode = 20000000;

TtsGatewayException _fromModelFailure(ModelGatewayException failure) =>
    TtsGatewayException(kind: failure.kind, message: failure.message);
