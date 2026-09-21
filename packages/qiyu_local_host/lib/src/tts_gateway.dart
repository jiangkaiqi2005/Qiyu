import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'qwen_tts_gateway.dart';
import 'volc_tts_gateway.dart';

/// TTS 出网异常：kind 与聊天 Provider、STT 出网错误共用同一套分类
/// （域名解析/TLS/超时/鉴权/网络/模型不存在/限流/响应不兼容/解析
/// 失败/服务拒绝/内部错误），文案说「语音合成服务」。
final class TtsGatewayException implements Exception {
  const TtsGatewayException({
    required this.kind, required this.message, this.serviceError,
  });

  final ModelFailureKind kind;
  final String message;
  final ServiceErrorCategory? serviceError;

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
    final key = requireTtsApiKey(apiKey);
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
    final response = await postTtsBytes(
      httpClient: httpClient,
      uri: uri,
      headers: {
        'authorization': 'Bearer $key',
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
    TtsProviderKind.qwenTts => QwenTtsGateway(
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

/// 把 ModelGatewayException 转写成本通道的 TtsGatewayException（kind、
/// message、serviceError 原样搬运）。合成 POST 的非 2xx 与音频地址下载跳
/// 两条路径都要用它，故公开共享；各网关文件里曾逐份私抄，新增路径直接
/// 复用本函数，不要再复制。
TtsGatewayException fromTtsModelFailure(ModelGatewayException failure) =>
    TtsGatewayException(
      kind: failure.kind, message: failure.message,
      serviceError: failure.serviceError,
    );

/// TTS 家族（OpenAI 兼容与豆包）共用的 Key 前置校验：返回 trim 后的
/// Key。空按未保存鉴权失败；脏字符（粘贴进表单常带零宽空格/中文，会
/// 让 dart:io 写头时抛未分类异常，STT 联调踩过的黑盒坑）按本通道人话
/// 文案拦截。
String requireTtsApiKey(String? apiKey) {
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
  return key;
}

/// TTS 家族共用的出网调用包装：合成 POST 与音频地址下载（GET）两条出网
/// 路径的异常映射链逐字一致（含 unclassified 诊断标签），在这里收口。
/// 仅限 TTS 家族内部使用。
Future<T> guardTtsOutbound<T>(Future<T> Function() call) async {
  try {
    return await call();
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
    throw fromTtsModelFailure(
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
}

/// TTS 家族共用的出网 POST：两协议网关的调用形状一致，在这里收口。
/// 仅限 TTS 家族内部使用。
Future<ProviderBytesHttpResponse> postTtsBytes({
  required ProviderBytesHttpClient httpClient,
  required Uri uri,
  required Map<String, String> headers,
  required List<int> body,
}) => guardTtsOutbound(
  () => httpClient.postBytes(
    uri: uri,
    headers: headers,
    body: body,
    timeout: ttsRequestTimeout,
  ),
);

/// TTS 家族共用的响应字节消费：读完全量音频字节再返回，响应期超时与
/// 连接中断按本通道文案映射。
Future<Uint8List> consumeTtsBytesResponse(ProviderBytesHttpResponse response) async {
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
  return buffer.takeBytes();
}
