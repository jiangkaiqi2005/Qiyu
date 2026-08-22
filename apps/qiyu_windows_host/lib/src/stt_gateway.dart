import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'volc_seed_asr_gateway.dart';

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
    final key = apiKey?.trim();
    if (key == null || key.isEmpty) {
      throw const SttGatewayException(
        kind: ModelFailureKind.authentication,
        message: '还没有保存语音服务的 API Key。',
      );
    }
    final boundary = _newBoundary();
    final uri = appendProviderEndpoint(config.baseUrl, 'audio/transcriptions');
    // STT 是新增出网路径：出网前统一过 SSRF 校验（聊天 Provider 不走）。
    ensureSttOutboundAllowed(uri);
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

/// 语音转写的出网入口：按 stt 配置的协议分派到具体网关。
/// [httpClient] 供 OpenAI 兼容协议使用，[webSocketConnector] 供豆包
/// 流式协议使用；调用面（transcribe 形状）与 v1 保持一致。
final class SttModelGateway implements SttTranscriptionGateway {
  SttModelGateway(this.httpClient, {ProviderWebSocketConnector? webSocketConnector})
    : _volcSeedAsr = VolcSeedAsrGateway(
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
    SttProviderKind.openAiCompatible => OpenAiTranscriptionGateway(
      httpClient,
    ).transcribe(config: config, apiKey: apiKey, audio: audio, mimeType: mimeType),
    SttProviderKind.volcSeedAsr => _volcSeedAsr.transcribe(
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

/// STT 出网前的统一 SSRF 校验（OpenAI HTTP 与豆包 WS 共用）：scheme 限
/// ws/wss/http/https；host 拒绝环回、私有、保留、组播与链路本地地址。
/// 边界：聊天 Provider（模型对话）出网不走这条校验——Ollama 本机部署
/// （如 localhost:11434）是 AGENTS 明确支持的产品功能，而 STT 服务始终
/// 是云端第三方，不允许被指向内网。
void ensureSttOutboundAllowed(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' &&
      scheme != 'https' &&
      scheme != 'ws' &&
      scheme != 'wss') {
    throw const SttGatewayException(
      kind: ModelFailureKind.provider,
      message: '语音服务地址必须是有效的 HTTP 或 WebSocket 地址。',
    );
  }
  final host = uri.host.toLowerCase();
  const refused = SttGatewayException(
    kind: ModelFailureKind.provider,
    message: '语音服务地址不允许指向本机或内网。',
  );
  if (host.isEmpty || host == 'localhost' || host.endsWith('.localhost')) {
    throw refused;
  }
  final address = InternetAddress.tryParse(host);
  // 域名字面量无法静态判定（DNS 解析后的内网 IP 由系统网络层路由），
  // 这里只拦字面量形态的内网地址。
  if (address != null && !_isPublicInternetAddress(address.rawAddress)) {
    throw refused;
  }
}

/// 字面量 IP 是否为公网单播地址（按原始网络字节序判断）。
bool _isPublicInternetAddress(Uint8List raw) {
  if (raw.length == 4) {
    return _isPublicIpv4(raw);
  }
  if (raw.length == 16) {
    return _isPublicIpv6(raw);
  }
  return false;
}

bool _isPublicIpv4(Uint8List b) {
  final a0 = b[0];
  final a1 = b[1];
  if (a0 == 0) return false; // 0.0.0.0/8 保留
  if (a0 == 10) return false; // 10/8 私有
  if (a0 == 100 && a1 >= 64 && a1 <= 127) return false; // 100.64/10 CGNAT
  if (a0 == 127) return false; // 环回
  if (a0 == 169 && a1 == 254) return false; // 169.254/16 链路本地
  if (a0 == 172 && a1 >= 16 && a1 <= 31) return false; // 172.16/12 私有
  if (a0 == 192 && a1 == 168) return false; // 192.168/16 私有
  if (a0 >= 224) return false; // 224/4 组播 + 240/4 保留（含广播）
  return true;
}

bool _isPublicIpv6(Uint8List b) {
  var zeroPrefix = 0;
  while (zeroPrefix < 16 && b[zeroPrefix] == 0) {
    zeroPrefix += 1;
  }
  if (zeroPrefix == 16) return false; // :: 未指定
  if (zeroPrefix == 15 && b[15] == 1) return false; // ::1 环回
  // IPv4 映射地址 ::ffff:a.b.c.d：按内嵌 IPv4 再判。
  if (zeroPrefix == 10 && b[10] == 0xFF && b[11] == 0xFF) {
    return _isPublicIpv4(Uint8List.sublistView(b, 12, 16));
  }
  if ((b[0] & 0xFE) == 0xFC) return false; // fc00::/7 唯一本地
  if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return false; // fe80::/10 链路本地
  if (b[0] == 0xFF) return false; // ff00::/8 组播
  return true;
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
