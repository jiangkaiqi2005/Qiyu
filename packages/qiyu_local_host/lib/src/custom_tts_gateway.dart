import 'dart:convert';
import 'dart:typed_data';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'speech_audio_download.dart';
import 'tts_gateway.dart';

/// 自定义语音合成服务（custom）网关：面向「普通 HTTP POST、JSON 请求体、
/// Bearer 类鉴权」的第三方合成服务。POST 用户填写的完整地址（不拼后缀），
/// 请求体固定 `{model, input}`，高级参数深合并进 input。鉴权头可配：配置
/// 存整行头名，留空回落默认 Authorization: Bearer，不允许无鉴权出网。
/// 响应三种形态：raw_bytes（响应体原样当音频）、json_field（字段里是
/// base64 或 http(s) 音频地址——是地址就经下载通道取回）、json_lines
/// （逐行 JSON 的 base64 按序拼接）。失败分类与文案沿用既有合成通道
/// （语音合成服务）。
///
/// 流式合成（票二）：raw_bytes 且用户没把 response_format 覆盖成压缩
/// 格式时，走 OpenAI 兼容的 chunked 传输（`stream_format=audio` +
/// `response_format=pcm`，块即原始 PCM 字节）；其余形态（json_field、
/// json_lines，或覆盖成压缩格式的 raw_bytes）按 E1 降级——每句一整块
/// 完整容器（请求与解析和整段路径完全同一路径），分句层靠「一句一块」
/// 获得句子级顺序播放，容器原样、不包 WAV 头。档位拿不到音频块不否决
/// 分句层：现有配置全部保留、不淘汰在用型号，也不把压缩字节塞进 PCM
/// 播放器。
final class CustomTtsGateway
    implements TtsSynthesisGateway, TtsStreamSynthesisGateway {
  const CustomTtsGateway(this.httpClient);

  final ProviderBytesHttpClient httpClient;

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = Uri.parse(config.baseUrl.trim());
    // 自定义档同属新增出网路径：出网前统一过 SSRF 校验（聊天 Provider 不走）。
    ensureTtsOutboundAllowed(uri);
    final body = jsonEncode({
      'model': config.model.trim(),
      // 高级参数深合并进 input：厂商自有参数（音色、语速字段名各叫各的）
      // 由此兜住，请求体顶层恒为 model/input 两字段。
      'input': mergeTtsExtraIntoInput({'text': text}, config.extraParams ?? const {}),
    });
    final response = await postTtsBytes(
      httpClient: httpClient,
      uri: uri,
      headers: {
        ..._authHeaders(config.authHeader, key),
        'content-type': 'application/json',
      },
      body: utf8.encode(body),
    );
    final bytes = await consumeTtsBytesResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 错误体是文本 JSON：latin1 保留字节可读性，只用于错误分类。
      throw fromTtsModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(bytes, allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    return switch (config.responseShape) {
      TtsResponseShape.rawBytes => _rawAudio(bytes),
      TtsResponseShape.jsonField => _jsonFieldAudio(
        bytes,
        config.responseField,
      ),
      TtsResponseShape.jsonLines => _jsonLinesAudio(
        bytes,
        config.responseField,
      ),
    };
  }

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) {
    // raw_bytes 且协商到 PCM 才走块流；其余形态（json_field/json_lines）
    // 或用户把 response_format 覆盖成压缩格式时按 E1 降级——每句独立
    // 整段合成、按序播放，容器原样（现有配置全部保留、不淘汰在用型号，
    // 也不把压缩字节塞进 PCM 播放器）。
    final negotiatedPcm =
        config.responseShape == TtsResponseShape.rawBytes &&
        (_effectiveTextValue(config.extraParams, 'response_format') ?? 'pcm')
                .toLowerCase() ==
            'pcm';
    if (!negotiatedPcm) {
      return guardTtsAudioStream(
        () => _streamWholeResponse(config: config, apiKey: apiKey, text: text),
      );
    }
    return guardTtsAudioStream(
      () => _streamRawBytes(config: config, apiKey: apiKey, text: text),
    );
  }

  /// raw_bytes 流式：OpenAI 兼容 chunked 传输，响应体边到达边转块。
  Stream<VoiceAudioChunk> _streamRawBytes({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async* {
    final response = await _postStreamRequest(
      config: config,
      apiKey: apiKey,
      text: text,
      // 官方流式开关：chunked 原始音频字节（非 SSE 事件）。
      streamFormat: 'audio',
    );
    var produced = false;
    await for (final chunk in response.body) {
      if (chunk.isEmpty) {
        continue;
      }
      produced = true;
      yield VoiceAudioChunk(
        bytes: Uint8List.fromList(chunk),
        sampleRate: customTtsPcmSampleRate,
      );
    }
    if (!produced) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务没有返回音频。',
      );
    }
  }

  /// E1 降级（票二）：整响应当一块。响应形状与整段路径完全一致
  /// （字段里是 base64 或 http(s) 地址、逐行聚合、或裸字节），分句层
  /// 靠「一句一块」获得句子级顺序播放；容器原样，不包 WAV 头。
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

  /// 流式出网 POST：与整段路径同一请求形状，另带 OpenAI 兼容的流式
  /// 格式参数（[streamFormat] 非空时）。非 2xx 按既有分类拒绝。
  Future<ProviderBytesHttpResponse> _postStreamRequest({
    required TtsConfig config,
    required String? apiKey,
    required String text,
    String? streamFormat,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = Uri.parse(config.baseUrl.trim());
    ensureTtsOutboundAllowed(uri);
    final body = jsonEncode({
      'model': config.model.trim(),
      'input': mergeTtsExtraIntoInput(
        {'text': text},
        config.extraParams ?? const {},
      ),
      'response_format': 'pcm',
      'stream_format': ?streamFormat,
    });
    final response = await postTtsBytes(
      httpClient: httpClient,
      uri: uri,
      headers: {
        ..._authHeaders(config.authHeader, key),
        'content-type': 'application/json',
      },
      body: utf8.encode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorBytes = await consumeTtsBytesResponse(response);
      throw fromTtsModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(errorBytes, allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    return response;
  }

  /// json_field 形态：整段响应按字段名取音频。值是 http(s) 地址 → 经下载
  /// 通道取回（内网校验与下载失败分类都在通道里）；否则按 base64 解。
  /// 非 JSON、形状不符或字段类型不对一律按解析失败给人话——不跨形状猜。
  Future<Uint8List> _jsonFieldAudio(Uint8List body, String field) async {
    final decoded = _decodeJsonObject(body);
    final value = decoded[_effectiveField(field)];
    if (value is! String) {
      throw _contentParsingFailure;
    }
    final trimmed = value.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return downloadSpeechAudioBytes(httpClient: httpClient, url: trimmed);
    }
    return _decodeBase64Audio(trimmed);
  }
}

/// 鉴权头拼接：配置存整行头名（如 `Authorization: Bearer`、`X-Api-Key`），
/// 冒号前是头名、冒号后是 scheme 前缀；无冒号时整行都是头名、Key 直送。
/// 留空（含纯空白）回落缺省 [ttsCustomDefaultAuthHeader]——语音流量不允许
/// 无鉴权出网。缺省与用户填写的值走同一条拼接口径，头名与前缀的字面量
/// 因此只在常量里出现一次。头名统一小写：HTTP 头名大小写不敏感，与既有
/// 网关同口径。与转写自定义档同律。
Map<String, String> _authHeaders(String? authHeader, String key) {
  final line = authHeader?.trim() ?? '';
  return _composeAuthHeader(
    line.isEmpty ? ttsCustomDefaultAuthHeader : line,
    key,
  );
}

Map<String, String> _composeAuthHeader(String line, String key) {
  final separator = line.indexOf(':');
  final name =
      (separator == -1 ? line : line.substring(0, separator)).trim();
  final prefix = separator == -1 ? '' : line.substring(separator + 1).trim();
  return {
    name.toLowerCase(): prefix.isEmpty ? key : '$prefix $key',
  };
}

/// raw_bytes 形态：响应体原样当音频；空体按没有返回音频拒绝（半截音频
/// 比报错更坏）。
Uint8List _rawAudio(Uint8List body) {
  if (body.isEmpty) {
    throw const TtsGatewayException(
      kind: ModelFailureKind.contentParsing,
      message: '语音合成服务没有返回音频。',
    );
  }
  return body;
}

/// json_lines 形态：逐行 JSON 的 base64 按序拼接；空行跳过，任一坏行
/// 按解析失败拒绝（不透出半截音频）。
Uint8List _jsonLinesAudio(Uint8List body, String field) {
  final effectiveField = _effectiveField(field);
  final audio = BytesBuilder(copy: false);
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
      throw _contentParsingFailure;
    }
    final value = decoded[effectiveField];
    if (value is! String) {
      throw _contentParsingFailure;
    }
    audio.add(_decodeBase64(value.trim()));
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

/// 字段名归一：空白回落缺省 [ttsCustomDefaultResponseField]。
String _effectiveField(String field) {
  final trimmed = field.trim();
  return trimmed.isEmpty ? ttsCustomDefaultResponseField : trimmed;
}

/// 整段响应按 JSON 对象解码：非 JSON 或形状不符按解析失败给人话。
Map<String, Object?> _decodeJsonObject(Uint8List body) {
  try {
    final parsed = jsonDecode(utf8.decode(body, allowMalformed: true));
    if (parsed is! Map<String, Object?>) {
      throw const FormatException('response must be an object');
    }
    return parsed;
  } on Object {
    throw _contentParsingFailure;
  }
}

/// base64 解音频：解不出字节或解出空字节都按现有分类说人话。
Uint8List _decodeBase64Audio(String value) {
  final bytes = _decodeBase64(value);
  if (bytes.isEmpty) {
    throw const TtsGatewayException(
      kind: ModelFailureKind.contentParsing,
      message: '语音合成服务没有返回音频。',
    );
  }
  return bytes;
}

Uint8List _decodeBase64(String value) {
  try {
    return base64.decode(value);
  } on Object {
    throw _contentParsingFailure;
  }
}

const _contentParsingFailure = TtsGatewayException(
  kind: ModelFailureKind.contentParsing,
  message: '语音合成服务返回的内容无法解析。',
);

/// 自定义档流式块上的标注采样率：流式请求已带 `response_format=pcm`，
/// 按业界 PCM 基准 24kHz 单声道 16-bit 记录（播放端按块上标注初始化，
/// 服务不遵守时声音会变调——连接测试与真机冒烟负责发现）。
const customTtsPcmSampleRate = 24000;

/// 高级参数里取一个文本值（用户显式覆盖优先）：仅用于流式路径回读用户
/// 覆盖的 response_format，与 tts_gateway 的同名 helper 各按文件自洽。
String? _effectiveTextValue(Map<String, Object?>? extra, String key) {
  final value = extra?[key];
  return value is String ? value : null;
}
