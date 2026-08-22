import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'model_gateway.dart';
import 'provider_config.dart';

/// STT 出网异常：kind 与聊天 Provider 出网错误共用同一套分类
/// （域名解析/TLS/超时/鉴权/网络/模型不存在/限流/响应不兼容/解析
/// 失败/服务拒绝/内部错误），文案换成「语音服务」。
final class SttGatewayException implements Exception {
  const SttGatewayException({required this.kind, required this.message});

  final ModelFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// OpenAI-compatible `/audio/transcriptions` 的 Host 中介客户端。
/// 浏览器录音字节原样上送（云端负责解码），不做重采样或规范化。
final class SttModelGateway {
  const SttModelGateway(this.httpClient);

  final ProviderHttpClient httpClient;

  /// 转写一段完整录音。返回识别文本，可能为空（空与失败的语义区分
  /// 由调用方决定：连接测试视为成功，正式转写视为失败）。
  Future<String> transcribe({
    required SttConfig config,
    required String? apiKey,
    required List<int> audio,
    required String mimeType,
  }) async {
    config.validate();
    final key = apiKey?.trim();
    if (key == null || key.isEmpty) {
      throw const SttGatewayException(
        kind: ModelFailureKind.authentication,
        message: '还没有保存语音服务的 API Key。',
      );
    }
    final boundary = _newBoundary();
    final uri = appendProviderEndpoint(config.baseUrl, 'audio/transcriptions');
    final ProviderHttpResponse response;
    try {
      response = await httpClient.post(
        uri: uri,
        headers: {
          'authorization': 'Bearer $key',
          'content-type': 'multipart/form-data; boundary=$boundary',
        },
        body: _multipartBody(
          boundary: boundary,
          config: config,
          audio: audio,
          mimeType: mimeType,
        ),
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
      throw _fromModelFailure(
        providerSocketFailure(error, serviceLabel: '语音服务'),
      );
    } on HttpException {
      throw const SttGatewayException(
        kind: ModelFailureKind.network,
        message: '语音服务连接中断。',
      );
    } on Object {
      throw const SttGatewayException(
        kind: ModelFailureKind.internal,
        message: '本机程序内部出错。',
      );
    }

    String body;
    try {
      body = await response.body.join();
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
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _fromModelFailure(
        providerStatusFailure(response.statusCode, body, serviceLabel: '语音服务'),
      );
    }
    return _parseTranscriptionText(body);
  }
}

/// 语音转写的出网预算：一次性完整上传 + 等待整段文本，显著长于聊天
/// 首响预算，但仍要有界。
const sttRequestTimeout = Duration(seconds: 60);

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

String _newBoundary() =>
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

Uint8List _multipartBody({
  required String boundary,
  required SttConfig config,
  required List<int> audio,
  required String mimeType,
}) {
  final builder = BytesBuilder(copy: false);
  void addField(String name, String value) {
    builder
      ..add(utf8.encode('--$boundary\r\n'))
      ..add(
        utf8.encode('content-disposition: form-data; name="$name"\r\n\r\n'),
      )
      ..add(utf8.encode(value))
      ..add(utf8.encode('\r\n'));
  }

  // language 固定 zh：产品只面向中文睡前场景，避免服务端自动检测摇摆。
  addField('model', config.model.trim());
  addField('language', 'zh');
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

SttGatewayException _fromModelFailure(ModelGatewayException failure) =>
    SttGatewayException(kind: failure.kind, message: failure.message);
