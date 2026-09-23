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
/// 按序拼接为完整音频，`code==20000000` 为正常结束标记，行内 `code>0`
/// 为错误（官方未给码表，统一按服务拒绝分类，HTTP 状态码错误仍走
/// 既有分类）。
///
/// 音频格式统一 PCM（票二）：官方明示流式推荐 pcm、禁 wav（wav 流式会
/// 重复返回 header）。整段路径把 PCM 包成 WAV 头后返回（现有整段播放器
/// 零改动）；流式路径逐行直接转音频块事件，不再聚合成整段（ADR 0018
/// 推翻 ADR 0002「完整交付后整段合成」的结论）。
final class VolcTtsGateway
    implements TtsSynthesisGateway, TtsStreamSynthesisGateway {
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
    final request = await _postRequest(
      config: config,
      apiKey: apiKey,
      text: text,
    );
    final bytes = await _collectChunkedAudio(request.response.body);
    // 仅当确实是裸 PCM 单声道 16-bit 才包 WAV 头：用户经高级参数把
    // format 覆盖成 mp3/ogg_opus、或 channel/位深不是单声道 16-bit 时
    // 原样返回——那些配置在统一 PCM 之前就能播（现有配置全部保留）。
    return wholeResponseAudio(
      bytes,
      format: request.format,
      channels: request.channels,
      bitsPerSample: request.bitsPerSample,
      sampleRate: request.sampleRate,
    );
  }

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) {
    // 生效格式不是裸 PCM 单声道 16-bit 时走不了块流（服务返回压缩字节
    // 或多声道，PCM 播放器会播成噪音）——按 E1 降级成整响应当一块，
    // 容器原样。
    final negotiated = _effectiveAudioParams(config);
    if (!_isStreamablePcm(negotiated)) {
      return guardTtsAudioStream(
        () => _streamWholeResponse(config: config, apiKey: apiKey, text: text),
      );
    }
    return guardTtsAudioStream(() async* {
      final request = await _postRequest(
        config: config,
        apiKey: apiKey,
        text: text,
      );
      // 逐行 JSON 边到达边转块：结束码行收束，行内错误即失败，没等到
      // 结束码断流按音频不完整拒绝（半截音频不能当完整回复）。
      var produced = false;
      var finished = false;
      await for (final line in request.response.body
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        final decoded = _decodeLine(trimmed);
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
        if (data is! String || data.isEmpty) {
          continue;
        }
        final audio = _decodeBase64(data);
        if (audio.isEmpty) {
          continue;
        }
        produced = true;
        yield VoiceAudioChunk(bytes: audio, sampleRate: request.sampleRate);
      }
      if (!finished) {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务返回的音频不完整。',
        );
      }
      if (!produced) {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务没有返回音频。',
        );
      }
    });
  }

  /// E1 降级（票二）：整响应当一块。与整段路径同一请求、同一解析，
  /// 容器原样（PCM 档由整段路径包 WAV 头，其余档服务自定义）。
  Stream<VoiceAudioChunk> _streamWholeResponse({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async* {
    final audio = await synthesize(
      config: config,
      apiKey: apiKey,
      text: text,
    );
    yield VoiceAudioChunk(
      bytes: Uint8List.fromList(audio),
      mimeType: voiceWholeContainerMime,
    );
  }

  /// 生效的 audio_params（含用户经高级参数的覆盖）：流式路径据此判断
  /// 能不能走块流，整段路径据此决定要不要包 WAV 头。
  static Map<String, Object?> _effectiveAudioParams(TtsConfig config) {
    final params = <String, Object?>{
      'format': 'pcm',
      'sample_rate': volcTtsDefaultSampleRate,
      'channel': 1,
      'bit_depth': 16,
    };
    final extra = config.extraParams;
    if (extra != null && extra['audio_params'] is Map) {
      params.addAll((extra['audio_params'] as Map).cast<String, Object?>());
    }
    return params;
  }

  /// 是否是流式块可用的裸 PCM 单声道 16-bit。
  static bool _isStreamablePcm(Map<String, Object?> audioParams) {
    final format = switch (audioParams['format']) {
      final String value => value.trim().toLowerCase(),
      _ => 'pcm',
    };
    final channels = switch (audioParams['channel']) {
      final num value => value.toInt(),
      _ => 1,
    };
    final bits = switch (audioParams['bit_depth']) {
      final num value => value.toInt(),
      _ => 16,
    };
    return format == 'pcm' && channels == 1 && bits == 16;
  }

  /// 一次出网请求：构造并 POST 请求体，返回响应与本次协商的音频参数
  /// （整段 WAV 头与流式块都要用它们）。两条路共用同一请求形状。
  Future<({ProviderBytesHttpResponse response, int sampleRate, String format, int channels, int bitsPerSample})>
  _postRequest({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = Uri.parse(config.baseUrl.trim());
    ensureTtsOutboundAllowed(uri);
    final rawSpeaker = config.voice?.trim();
    final detectedDialect =
        (rawSpeaker == null || rawSpeaker.isEmpty) ? null : _detectDialect(rawSpeaker);
    final effectiveSpeaker =
        (detectedDialect != null || rawSpeaker == null || rawSpeaker.isEmpty)
            ? defaultSpeaker
            : rawSpeaker;

    final audioParams = <String, Object?>{
      // 流式推荐 pcm：块直接转事件，容器头无处安放（官方明示禁 wav）。
      // 只送官方文档有的字段——channel/bit_depth 仅作用户覆盖回读，
      // 不臆造进请求体（严格服务端会因未知字段 400）。
      'format': 'pcm',
      'sample_rate': volcTtsDefaultSampleRate,
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
    final sampleRate = switch (audioParams['sample_rate']) {
      final num rate => rate.toInt(),
      _ => volcTtsDefaultSampleRate,
    };
    final format = switch (audioParams['format']) {
      final String value => value,
      _ => 'pcm',
    };
    final channels = switch (audioParams['channel']) {
      final num value => value.toInt(),
      _ => 1,
    };
    final bitsPerSample = switch (audioParams['bit_depth']) {
      final num value => value.toInt(),
      _ => 16,
    };

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
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorBytes = await consumeTtsBytesResponse(response);
      throw _fromModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(errorBytes, allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    return (
      response: response,
      sampleRate: sampleRate,
      format: format,
      channels: channels,
      bitsPerSample: bitsPerSample,
    );
  }

  /// 聚合 chunked 逐行 JSON 响应为完整音频字节（整段路径）。
  Future<Uint8List> _collectChunkedAudio(Stream<List<int>> body) async {
    final audio = BytesBuilder(copy: false);
    var finished = false;
    await for (final line in body
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final decoded = _decodeLine(trimmed);
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
        audio.add(_decodeBase64(data));
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

  /// 逐行 JSON 协议的正常结束标记码。
  static Map<String, Object?> _decodeLine(String line) {
    try {
      final parsed = jsonDecode(line);
      if (parsed is! Map<String, Object?>) {
        throw const FormatException('tts line must be an object');
      }
      return parsed;
    } on Object {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
  }

  static Uint8List _decodeBase64(String data) {
    try {
      return base64.decode(data);
    } on Object {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
  }

  /// 检测预设方言音色 ID，并返回对应的方言代码（如 sichuan, dongbei 等）。
  /// 仅精准匹配预设音色库已定义的方言，避免误劫持用户自定义音色。
  static String? _detectDialect(String voice) => _dialectVoiceMap[voice.trim()];

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
  };

  /// 火山方舟 Go 服务端中 `additions` 字段类型是 `string`。
  /// 自动注入方言参数或 extraParams 传入的对象统一序列化为 JSON 字符串，
  /// 非空字符串直接保留。
  static String? _resolveAdditions({
    required Map<String, Object?>? extra,
    required String? detectedDialect,
  }) {
    final rawAdditions = extra?['additions'];
    if (rawAdditions is Map) {
      final map = Map<String, Object?>.from(rawAdditions);
      if (detectedDialect != null) {
        map.putIfAbsent('explicit_dialect', () => detectedDialect);
      }
      return jsonEncode(map);
    }

    if (rawAdditions is String && rawAdditions.isNotEmpty) {
      return rawAdditions;
    }

    if (detectedDialect != null) {
      return jsonEncode({'explicit_dialect': detectedDialect});
    }

    return null;
  }
}

/// 官方逐行 JSON 协议的正常结束标记码。
const volcTtsFinishedCode = 20000000;

/// 豆包 PCM 的协商采样率：官方 audio_params 缺省 24000（8000–48000
/// 可调），高级参数可覆盖；WAV 头与流式块都以生效值为准。
const volcTtsDefaultSampleRate = 24000;

TtsGatewayException _fromModelFailure(ModelGatewayException failure) =>
    TtsGatewayException(
      kind: failure.kind, message: failure.message,
      serviceError: failure.serviceError,
    );
