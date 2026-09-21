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
final class CustomTtsGateway implements TtsSynthesisGateway {
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
