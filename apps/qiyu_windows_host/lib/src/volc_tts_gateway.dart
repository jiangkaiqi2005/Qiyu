import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
    final key = apiKey?.trim();
    if (key == null || key.isEmpty) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.authentication,
        message: '还没有保存语音合成服务的 API Key。',
      );
    }
    if (containsNonVisibleAscii(key)) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.provider,
        message: 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
      );
    }
    final uri = Uri.parse(config.baseUrl.trim());
    ensureTtsOutboundAllowed(uri);
    final speaker = config.voice?.trim();
    final body = jsonEncode({
      'req_params': {
        'text': text,
        'speaker': speaker == null || speaker.isEmpty
            ? defaultSpeaker
            : speaker,
        'audio_params': {'format': 'mp3', 'sample_rate': 24000},
        // 官方说明的示例未出现语速字段：按传统豆包 TTS 参数名 speed_ratio
        // 传入（spec 定稿）；实测拒收则设置页禁用该协议下的语速，不假调节。
        'speed_ratio': ?config.speed,
      },
    });
    final ProviderBytesHttpResponse response;
    try {
      response = await httpClient.postBytes(
        uri: uri,
        headers: {
          'X-Api-Key': key,
          // 模型名称字段填的就是 Resource-Id（如 seed-tts-2.0）。
          'X-Api-Resource-Id': config.model.trim(),
          'X-Control-Require-Usage-Tokens-Return': '*',
          'content-type': 'application/json',
        },
        body: utf8.encode(body),
        timeout: ttsRequestTimeout,
      );
    } on TimeoutException {
      throw const TtsGatewayException(
        kind: ModelFailureKind.timeout,
        message: '连接语音合成服务超时。',
      );
    } on HandshakeException {
      throw const TtsGatewayException(
        kind: ModelFailureKind.tls,
        message: '语音合成服务的 TLS 安全连接失败。',
      );
    } on SocketException catch (error) {
      throw _fromModelFailure(
        providerSocketFailure(error, serviceLabel: '语音合成服务'),
      );
    } on HttpException {
      throw const TtsGatewayException(
        kind: ModelFailureKind.network,
        message: '语音合成服务连接中断。',
      );
    } on Object catch (error) {
      stderrDiagnostics('tts unclassified exception: ${error.runtimeType}');
      throw const TtsGatewayException(
        kind: ModelFailureKind.internal,
        message: '本机程序内部出错。',
      );
    }
    // 官方接入建议：记录 X-Tt-Logid 便于排查（只进本机诊断）。
    if (response.headers['x-tt-logid'] case final logid?) {
      stderrDiagnostics('tts volc logid: $logid');
    }

    final buffer = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.body) {
        buffer.add(chunk);
      }
    } on TimeoutException {
      throw const TtsGatewayException(
        kind: ModelFailureKind.timeout,
        message: '语音合成服务响应超时。',
      );
    } on Object {
      throw const TtsGatewayException(
        kind: ModelFailureKind.network,
        message: '语音合成服务连接中断。',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _fromModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(buffer.takeBytes(), allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    return _parseChunkedAudio(buffer.takeBytes());
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
}

/// 官方逐行 JSON 协议的正常结束标记码。
const volcTtsFinishedCode = 20000000;

TtsGatewayException _fromModelFailure(ModelGatewayException failure) =>
    TtsGatewayException(kind: failure.kind, message: failure.message);
