import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'volc_tts_gateway.dart';

/// TTS 出网异常：kind 与聊天 Provider、STT 出网错误共用同一套分类
/// （域名解析/TLS/超时/鉴权/网络/模型不存在/限流/响应不兼容/解析
/// 失败/服务拒绝/内部错误），文案说「语音合成服务」。
final class TtsGatewayException implements Exception {
  const TtsGatewayException({required this.kind, required this.message});

  final ModelFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// TTS 协议网关的公共调用面：服务层（设置、朗读、连接测试）只认这个
/// 形状，协议分支不出 Provider 层。ADR 0002：只做「一段已定稿文字 →
/// 一段完整音频」的整段合成，不做流式分句。
abstract interface class TtsSynthesisGateway {
  /// 把一段完整文字合成为完整音频（mp3 字节）。音频只在内存里流转，
  /// Host 不落盘。
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  });
}

/// OpenAI-compatible `/audio/speech` 的 Host 中介客户端：一次性 POST
/// 全文，整段 mp3 响应字节返回（OpenAI、硅基流动等）。
final class OpenAiSpeechGateway implements TtsSynthesisGateway {
  const OpenAiSpeechGateway(this.httpClient);

  final ProviderBytesHttpClient httpClient;

  /// OpenAI 协议的 voice 是必填字段：用户没填音色时用协议通用缺省。
  static const defaultVoice = 'alloy';

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
    // 粘贴进表单的 Key 常带零宽空格/中文：脏字节会让 dart:io 在写头时
    // 抛未分类异常，必须在出网前拦成人话（STT 联调踩过的黑盒坑）。
    if (containsNonVisibleAscii(key)) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.provider,
        message: 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
      );
    }
    final uri = appendProviderEndpoint(config.baseUrl, 'audio/speech');
    // TTS 是新增出网路径：出网前统一过 SSRF 校验（与 STT 共用判定）。
    ensureTtsOutboundAllowed(uri);
    final voice = config.voice?.trim();
    final body = jsonEncode({
      if (config.extraParams != null) ...config.extraParams!,
      'model': config.model.trim(),
      'input': text,
      'voice': voice == null || voice.isEmpty ? defaultVoice : voice,
      'response_format': 'mp3',
      if (config.speed != null) 'speed': config.speed,
    });
    final ProviderBytesHttpResponse response;
    try {
      response = await httpClient.postBytes(
        uri: uri,
        headers: {
          'authorization': 'Bearer $key',
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
      // 只打异常类型不打消息：消息可能嵌着用户输入（Key/地址/模型名）。
      stderrDiagnostics('tts unclassified exception: ${error.runtimeType}');
      throw const TtsGatewayException(
        kind: ModelFailureKind.internal,
        message: '本机程序内部出错。',
      );
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
    final bytes = buffer.takeBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 错误体是文本 JSON：latin1 保留字节可读性，只用于错误分类。
      throw _fromModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(bytes, allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    if (bytes.isEmpty) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务没有返回音频。',
      );
    }
    return bytes;
  }
}

/// 语音朗读的出网入口：按 tts 配置的协议分派到具体网关。
final class TtsModelGateway implements TtsSynthesisGateway {
  const TtsModelGateway(this.httpClient);

  final ProviderBytesHttpClient httpClient;

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) => switch (config.provider) {
    TtsProviderKind.openAiCompatible => OpenAiSpeechGateway(
      httpClient,
    ).synthesize(config: config, apiKey: apiKey, text: text),
    TtsProviderKind.volcTts => VolcTtsGateway(
      httpClient,
    ).synthesize(config: config, apiKey: apiKey, text: text),
  };
}

/// 语音合成的出网预算：整段文字上送 + 等待完整音频下载，与转写同级。
const ttsRequestTimeout = Duration(seconds: 60);

/// TTS 出网前的统一 SSRF 校验：公共判定在 provider_config 的
/// speechOutboundRefusalReason（与 STT 共用），这里只负责包装成本
/// 通道的异常类型。
void ensureTtsOutboundAllowed(Uri uri) {
  if (speechOutboundRefusalReason(uri) case final reason?) {
    throw TtsGatewayException(kind: ModelFailureKind.provider, message: reason);
  }
}

TtsGatewayException _fromModelFailure(ModelGatewayException failure) =>
    TtsGatewayException(kind: failure.kind, message: failure.message);
