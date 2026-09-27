import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'custom_stt_gateway.dart';
import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'qwen_asr_gateway.dart';
import 'volc_seed_asr_gateway.dart';

/// STT 出网异常：kind 与聊天 Provider 出网错误共用同一套分类
/// （域名解析/TLS/超时/鉴权/网络/模型不存在/限流/响应不兼容/解析
/// 失败/服务拒绝/内部错误），文案换成「语音服务」。
final class SttGatewayException implements Exception {
  const SttGatewayException({
    required this.kind, required this.message, this.serviceError,
  });

  final ModelFailureKind kind;
  final String message;
  final ServiceErrorCategory? serviceError;

  @override
  String toString() => message;
}

/// STT 协议网关的公共调用面：服务层（设置、转写、连接测试）只认这个
/// 形状，协议分支不出 Provider 层。
abstract interface class SttTranscriptionGateway {
  /// 转写一段完整录音。返回识别文本，可能为空（空与失败的语义区分
  /// 由调用方决定：连接测试视为成功，正式转写视为失败）。
  Future<String> transcribe({
    required SttConfig config,
    required String? apiKey,
    required List<int> audio,
    required String mimeType,
  });
}

/// OpenAI-compatible `/audio/transcriptions` 的 Host 中介客户端。
/// 浏览器录音字节原样上送（云端负责解码），不做重采样或规范化。
final class OpenAiTranscriptionGateway implements SttTranscriptionGateway {
  const OpenAiTranscriptionGateway(this.httpClient);

  final ProviderHttpClient httpClient;

  @override
  Future<String> transcribe({
    required SttConfig config,
    required String? apiKey,
    required List<int> audio,
    required String mimeType,
  }) async {
    config.validate();
    final key = requireSttApiKey(apiKey);
    final uri = appendProviderEndpoint(config.baseUrl, 'audio/transcriptions');
    // STT 是新增出网路径：出网前统一过 SSRF 校验（聊天 Provider 不走）。
    ensureSttOutboundAllowed(uri);
    final boundary = newSttBoundary();
    final response = await postSttText(
      httpClient: httpClient,
      uri: uri,
      headers: {
        'authorization': 'Bearer $key',
        'content-type': 'multipart/form-data; boundary=$boundary',
      },
      body: buildSttMultipartBody(
        boundary: boundary,
        config: config,
        audio: audio,
        mimeType: mimeType,
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw fromSttModelFailure(
        providerStatusFailure(
          response.statusCode,
          response.body,
          serviceLabel: '语音服务',
        ),
      );
    }
    return _parseTranscriptionText(response.body);
  }
}

/// 语音转写的出网入口：按 stt 配置的协议分派到具体网关。
/// [httpClient] 供 OpenAI 兼容与千问协议使用，[webSocketConnector] 供豆包
/// 流式协议使用；调用面（transcribe 形状）与 v1 保持一致。
final class SttModelGateway implements SttTranscriptionGateway {
  SttModelGateway(
    this.httpClient, {
    ProviderWebSocketConnector? webSocketConnector,
  }) : _volcSeedAsr = VolcSeedAsrGateway(
         webSocketConnector ?? const DartIoProviderWebSocketConnector(),
       );

  final ProviderHttpClient httpClient;
  final VolcSeedAsrGateway _volcSeedAsr;

  @override
  Future<String> transcribe({
    required SttConfig config,
    required String? apiKey,
    required List<int> audio,
    required String mimeType,
  }) => switch (config.provider) {
    SttProviderKind.openAiCompatible =>
      OpenAiTranscriptionGateway(httpClient).transcribe(
        config: config,
        apiKey: apiKey,
        audio: audio,
        mimeType: mimeType,
      ),
    SttProviderKind.volcSeedAsr => _volcSeedAsr.transcribe(
      config: config,
      apiKey: apiKey,
      audio: audio,
      mimeType: mimeType,
    ),
    SttProviderKind.qwenAsr => QwenAsrGateway(httpClient).transcribe(
      config: config,
      apiKey: apiKey,
      audio: audio,
      mimeType: mimeType,
    ),
    SttProviderKind.custom => CustomSttGateway(httpClient).transcribe(
      config: config,
      apiKey: apiKey,
      audio: audio,
      mimeType: mimeType,
    ),
  };
}

/// 语音转写的出网预算：一次性完整上传 + 等待整段文本，显著长于聊天
/// 首响预算，但仍要有界。
const sttRequestTimeout = Duration(seconds: 60);

/// STT 出网前的统一 SSRF 校验：scheme 与 host 字面量的公共判定在
/// provider_config 的 speechOutboundRefusalReason（与语音合成共用），
/// 这里只负责包装成本通道的异常类型。
void ensureSttOutboundAllowed(Uri uri) {
  if (speechOutboundRefusalReason(uri) case final reason?) {
    throw SttGatewayException(kind: ModelFailureKind.provider, message: reason);
  }
}

/// STT HTTP 出网的统一守护：post 调用与响应体读取包进同一套异常分类
/// 阶梯（超时/TLS/Socket/Http/未分类 + 响应读失败），OpenAI 兼容、千问
/// 与自定义三个 HTTP 网关共用，勿再复制。返回状态码与完整响应体文本，
/// 状态码分类（providerStatusFailure）由各网关按本通道话术自行决定。
Future<({int statusCode, String body})> postSttText({
  required ProviderHttpClient httpClient,
  required Uri uri,
  required Map<String, String> headers,
  required List<int> body,
}) async {
  final ProviderHttpResponse response;
  try {
    response = await httpClient.post(
      uri: uri,
      headers: headers,
      body: body,
      timeout: sttRequestTimeout,
    );
  } on TimeoutException {
    throw const SttGatewayException(
      kind: ModelFailureKind.timeout,
      message: '连接语音服务超时。',
    );
  } on HandshakeException {
    throw const SttGatewayException(
      kind: ModelFailureKind.tls,
      message: '语音服务的 TLS 安全连接失败。',
    );
  } on SocketException catch (error) {
    throw fromSttModelFailure(
      providerSocketFailure(error, serviceLabel: '语音服务'),
    );
  } on HttpException {
    throw const SttGatewayException(
      kind: ModelFailureKind.network,
      message: '语音服务连接中断。',
    );
  } on Object catch (error) {
    // 只打异常类型不打消息：消息可能嵌着用户输入（Key/地址/模型名）。
    stderrDiagnostics('stt unclassified exception: ${error.runtimeType}');
    throw const SttGatewayException(
      kind: ModelFailureKind.internal,
      message: '本机程序内部出错。',
    );
  }
  try {
    return (statusCode: response.statusCode, body: await response.body.join());
  } on TimeoutException {
    throw const SttGatewayException(
      kind: ModelFailureKind.timeout,
      message: '语音服务响应超时。',
    );
  } on Object {
    throw const SttGatewayException(
      kind: ModelFailureKind.network,
      message: '语音服务连接中断。',
    );
  }
}

String _parseTranscriptionText(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('transcription response must be an object');
    }
    final text = decoded['text'];
    if (text != null && text is! String) {
      throw const FormatException('transcription text must be a string');
    }
    return text as String? ?? '';
  } on Object {
    throw const SttGatewayException(
      kind: ModelFailureKind.contentParsing,
      message: '语音服务返回的内容无法解析。',
    );
  }
}

final _boundaryRandom = Random.secure();

/// multipart 边界：OpenAI 兼容与自定义两个 HTTP 转写档共用（各自一次
/// 请求一个，随机源共享无妨）。
String newSttBoundary() =>
    'qiyu-stt-${DateTime.now().microsecondsSinceEpoch}'
    '-${_boundaryRandom.nextInt(1 << 32)}';

/// 依据容器类型给出上传文件名：转写服务普遍按扩展名识别封装格式。
String _fileNameFor(String mimeType) => switch (mimeType) {
  'audio/webm' => 'recording.webm',
  'audio/mp4' => 'recording.mp4',
  'audio/wav' || 'audio/wave' || 'audio/x-wav' => 'recording.wav',
  'audio/mpeg' || 'audio/mp3' => 'recording.mp3',
  _ => 'recording.bin',
};

/// multipart 表单构造：OpenAI 兼容与自定义两个 HTTP 转写档共用同一份
/// 形状（model、language=zh、file 字段带文件名与 content-type），自定义
/// 档的高级参数作额外表单字段插在文件字段之前（文件段带关闭边界，必须
/// 最后）。高级参数值编码：字符串原样，null 跳过（没有表单语义），其余
/// 按 JSON 编（数字/布尔/对象/列表都只能是表单字符串）。
Uint8List buildSttMultipartBody({
  required String boundary,
  required SttConfig config,
  required List<int> audio,
  required String mimeType,
  Map<String, Object?>? extraParams,
}) {
  final builder = BytesBuilder(copy: false);
  void addField(String name, String value) {
    builder
      ..add(utf8.encode('--$boundary\r\n'))
      ..add(utf8.encode('content-disposition: form-data; name="$name"\r\n\r\n'))
      ..add(utf8.encode(value))
      ..add(utf8.encode('\r\n'));
  }

  // language 固定 zh：产品只面向中文睡前场景，避免服务端自动检测摇摆。
  addField('model', config.model.trim());
  addField('language', 'zh');
  if (extraParams != null) {
    for (final entry in extraParams.entries) {
      final value = entry.value;
      if (value == null) {
        continue;
      }
      addField(entry.key, value is String ? value : jsonEncode(value));
    }
  }
  builder
    ..add(utf8.encode('--$boundary\r\n'))
    ..add(
      utf8.encode(
        'content-disposition: form-data; name="file"; '
        'filename="${_fileNameFor(mimeType)}"\r\n',
      ),
    )
    ..add(utf8.encode('content-type: $mimeType\r\n\r\n'))
    ..add(audio)
    ..add(utf8.encode('\r\n--$boundary--\r\n'));
  return builder.takeBytes();
}

/// 模型网关失败到 STT 出网异常的适配：三个 HTTP 转写网关（OpenAI 兼容、
/// 千问、自定义）与共享守护 postSttText 共用，勿再复制（与 TTS 家族的
/// fromTtsModelFailure 同律）。
SttGatewayException fromSttModelFailure(ModelGatewayException failure) =>
    SttGatewayException(
      kind: failure.kind, message: failure.message,
      serviceError: failure.serviceError,
    );

/// STT 家族（OpenAI 兼容与豆包流式）共用的 Key 前置校验：返回 trim 后
/// 的 Key。空按未保存鉴权失败；脏字符按粘贴事故拦截——粘贴进表单的
/// Key 常带零宽空格/中文，HTTP 写头与 WebSocket 建连遇脏字节都会抛
/// 未分类异常，必须在出网前拦成人话。
String requireSttApiKey(String? apiKey) {
  final key = apiKey?.trim();
  if (key == null || key.isEmpty) {
    throw const SttGatewayException(
      kind: ModelFailureKind.authentication,
      message: '还没有保存语音服务的 API Key。',
    );
  }
  if (containsNonVisibleAscii(key)) {
    throw const SttGatewayException(
      kind: ModelFailureKind.provider,
      message: 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
    );
  }
  return key;
}
