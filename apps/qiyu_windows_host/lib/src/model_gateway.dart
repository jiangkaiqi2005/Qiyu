import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'provider_config.dart';

enum ModelMessageRole { system, user, assistant }

final class ModelMessage {
  const ModelMessage(this.role, this.content);

  final ModelMessageRole role;
  final String content;
}

enum ModelFailureKind {
  dns,
  tls,
  timeout,
  authentication,
  network,
  modelNotFound,
  rateLimited,
  incompatibleResponse,
  contentParsing,
  provider,
  internal,
}

final class ModelGatewayException implements Exception {
  const ModelGatewayException({required this.kind, required this.message});

  final ModelFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

abstract interface class ModelGateway {
  /// [maxTokens] 缺省用全局回复上限（聊天护栏）；理解类调用输出的是
  /// 长结构 JSON，必须按调用显式给足预算，否则截断后解析必失败。
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  });
}

abstract interface class StreamingModelGateway implements ModelGateway {
  Stream<ModelStreamEvent> stream({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  });
}

final class ProviderHttpResponse {
  const ProviderHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Stream<String> body;
}

/// 二进制响应形态：响应体不经 utf8 解码（语音合成返回音频字节，
/// 文本解码会破坏二进制数据）。
final class ProviderBytesHttpResponse {
  const ProviderBytesHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final Stream<List<int>> body;

  /// 响应头（小写键，仅透出诊断需要的键）：语音合成网关用它记录
  /// 官方建议的 X-Tt-Logid（只进本机 stderr，不透出浏览器）。
  final Map<String, String> headers;
}

/// 二进制响应出网调用（语音合成等）：与 [ProviderHttpClient.post] 同
/// 一套超时与连接语义，独立成接口避免逼所有既有实现与 fake 改动。
abstract interface class ProviderBytesHttpClient {
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  });
}

abstract interface class ProviderHttpClient {
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  });

  /// 非流式 POST（二进制请求体、整段文本响应）：语音转写等一次性
  /// 出网调用使用；与 postStream 同一套超时语义。
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  });
}

final class DartIoProviderHttpClient
    implements ProviderHttpClient, ProviderBytesHttpClient {
  const DartIoProviderHttpClient();

  @override
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) {
    return _postBytes(
      uri: uri,
      headers: headers,
      body: utf8.encode(body),
      timeout: timeout,
    );
  }

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) {
    return _postBytes(uri: uri, headers: headers, body: body, timeout: timeout);
  }

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.add(body);
      final response = await request.close().timeout(timeout);
      return ProviderBytesHttpResponse(
        statusCode: response.statusCode,
        body: _readBytesResponse(response, client, timeout),
        headers: {'x-tt-logid': ?response.headers.value('x-tt-logid')},
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  Future<ProviderHttpResponse> _postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.add(body);
      final response = await request.close().timeout(timeout);
      return ProviderHttpResponse(
        statusCode: response.statusCode,
        body: _readResponse(response, client, timeout),
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}

Stream<String> _readResponse(
  HttpClientResponse response,
  HttpClient client,
  Duration timeout,
) async* {
  try {
    yield* response.transform(utf8.decoder).timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

Stream<List<int>> _readBytesResponse(
  HttpClientResponse response,
  HttpClient client,
  Duration timeout,
) async* {
  try {
    yield* response.timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

enum ModelStreamEventKind { delta, done, failure }

final class ModelStreamEvent {
  const ModelStreamEvent.delta(String this.text)
    : kind = ModelStreamEventKind.delta,
      failure = null,
      message = null;

  const ModelStreamEvent.done()
    : kind = ModelStreamEventKind.done,
      text = null,
      failure = null,
      message = null;

  const ModelStreamEvent.failure(
    ModelFailureKind this.failure,
    String this.message,
  ) : kind = ModelStreamEventKind.failure,
      text = null;

  final ModelStreamEventKind kind;
  final String? text;
  final ModelFailureKind? failure;
  final String? message;
}

final class ProviderModelGateway implements StreamingModelGateway {
  const ProviderModelGateway(this.httpClient);

  final ProviderHttpClient httpClient;

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) async {
    final buffer = StringBuffer();
    await for (final event in stream(
      config: config,
      apiKey: apiKey,
      messages: messages,
      maxTokens: maxTokens,
    )) {
      if (event.kind == ModelStreamEventKind.delta) {
        buffer.write(event.text);
      } else if (event.kind == ModelStreamEventKind.failure) {
        throw ModelGatewayException(
          kind: event.failure!,
          message: event.message!,
        );
      }
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的内容无法解析。',
      );
    }
    return text;
  }

  @override
  Stream<ModelStreamEvent> stream({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) async* {
    config.validate();
    final protocol = _providerProtocol(config.kind);
    if (protocol.requiresApiKey && (apiKey == null || apiKey.trim().isEmpty)) {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.authentication,
        '还没有保存 API Key。',
      );
      return;
    }

    final request = protocol.buildRequest(
      config,
      apiKey,
      messages,
      maxTokens ?? _maxModelReplyTokens,
    );
    ProviderHttpResponse response;
    try {
      response = await httpClient.postStream(
        uri: request.uri,
        headers: request.headers,
        body: jsonEncode(request.body),
        timeout: Duration(seconds: config.timeoutSeconds),
      );
    } on TimeoutException {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.timeout,
        '连接模型服务超时。',
      );
      return;
    } on HandshakeException {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.tls,
        '模型服务的 TLS 安全连接失败。',
      );
      return;
    } on SocketException catch (error) {
      final failure = _socketFailure(error);
      yield ModelStreamEvent.failure(failure.kind, failure.message);
      return;
    } on HttpException {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.network,
        '模型服务连接中断。',
      );
      return;
    } on ModelGatewayException catch (error) {
      yield ModelStreamEvent.failure(error.kind, error.message);
      return;
    } on Object {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.internal,
        '本机程序内部出错。',
      );
      return;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String body;
      try {
        body = await response.body.join();
      } on TimeoutException {
        yield const ModelStreamEvent.failure(
          ModelFailureKind.timeout,
          '模型服务响应超时。',
        );
        return;
      } on Object {
        yield const ModelStreamEvent.failure(
          ModelFailureKind.network,
          '模型服务连接中断。',
        );
        return;
      }
      final failure = _statusFailure(response.statusCode, body);
      yield ModelStreamEvent.failure(failure.kind, failure.message);
      return;
    }
    var emittedText = false;
    try {
      await for (final line in response.body.transform(const LineSplitter())) {
        final event = protocol.readEvent(line);
        if (event == null) {
          continue;
        }
        if (event.delta.isNotEmpty) {
          emittedText = true;
          yield ModelStreamEvent.delta(event.delta);
        }
        if (event.done) {
          if (!emittedText) {
            yield const ModelStreamEvent.failure(
              ModelFailureKind.contentParsing,
              '模型服务返回的内容无法解析。',
            );
          } else {
            yield const ModelStreamEvent.done();
          }
          return;
        }
      }
    } on TimeoutException {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.timeout,
        '模型服务响应超时。',
      );
      return;
    } on ModelGatewayException catch (error) {
      yield ModelStreamEvent.failure(error.kind, error.message);
      return;
    } on Object {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.incompatibleResponse,
        '模型服务返回了不兼容的响应格式。',
      );
      return;
    }
    if (!emittedText) {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.contentParsing,
        '模型服务返回的内容无法解析。',
      );
      return;
    }
    yield const ModelStreamEvent.failure(
      ModelFailureKind.network,
      '模型服务连接在回复完成前中断。',
    );
  }
}

typedef _ProviderRequest = ({
  Uri uri,
  Map<String, String> headers,
  Map<String, Object?> body,
});

abstract interface class _ProviderProtocol {
  bool get requiresApiKey;

  /// [maxTokens] 已在 gateway 层解析过默认值；是否写入请求体由各
  /// 协议自定（Ollama 历来不设输出上限，见其实现）。
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
    int maxTokens,
  );

  _ProviderStreamPart? readEvent(String line);
}

typedef _ProviderStreamPart = ({String delta, bool done});

/// 发给 Provider 的输出上限，各协议保持一致，防止失控的账单与超长候选。
const _maxModelReplyTokens = 512;

_ProviderProtocol _providerProtocol(ProviderKind kind) => switch (kind) {
  ProviderKind.openAiCompatible => const _OpenAiCompatibleProtocol(),
  ProviderKind.anthropic => const _AnthropicProtocol(),
  ProviderKind.ollama => const _OllamaProtocol(),
};

final class _OpenAiCompatibleProtocol implements _ProviderProtocol {
  const _OpenAiCompatibleProtocol();

  @override
  bool get requiresApiKey => true;

  @override
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
    int maxTokens,
  ) => (
    uri: _appendEndpoint(config.baseUrl, 'chat/completions'),
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer ${apiKey!.trim()}',
    },
    body: {
      'model': config.model.trim(),
      'messages': messages.map(_messageJson).toList(),
      'temperature': config.temperature,
      'max_tokens': maxTokens,
      'stream': true,
    },
  );

  @override
  _ProviderStreamPart? readEvent(String line) {
    final data = _sseData(line);
    if (data == null) {
      if (line.trim().isNotEmpty && !line.trim().startsWith(':')) {
        throw const FormatException('invalid SSE line');
      }
      return null;
    }
    if (data == '[DONE]') {
      return (delta: '', done: true);
    }
    final payload = jsonDecode(data) as Map<String, Object?>;
    try {
      final choices = payload['choices']! as List<Object?>;
      final choice = choices.first! as Map<String, Object?>;
      final delta = choice['delta'] as Map<String, Object?>?;
      final content = delta?['content'];
      final text = content is String
          ? content
          : content is List<Object?>
          ? content
                .map(
                  (part) =>
                      (part! as Map<String, Object?>)['text'] as String? ?? '',
                )
                .join()
          : '';
      return (delta: text, done: choice['finish_reason'] != null);
    } on Object {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的内容无法解析。',
      );
    }
  }
}

final class _AnthropicProtocol implements _ProviderProtocol {
  const _AnthropicProtocol();

  @override
  bool get requiresApiKey => true;

  @override
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
    int maxTokens,
  ) => (
    uri: _anthropicMessagesEndpoint(config.baseUrl),
    headers: {
      'content-type': 'application/json',
      if (_usesArkAgentPlan(config.baseUrl))
        'authorization': 'Bearer ${apiKey!.trim()}'
      else
        'x-api-key': apiKey!.trim(),
      'anthropic-version': '2023-06-01',
    },
    body: {
      'model': config.model.trim(),
      'system': messages
          .where((message) => message.role == ModelMessageRole.system)
          .map((message) => message.content)
          .join('\n'),
      'messages': messages
          .where((message) => message.role != ModelMessageRole.system)
          .map(_messageJson)
          .toList(),
      'temperature': config.temperature,
      'max_tokens': maxTokens,
      'stream': true,
    },
  );

  @override
  _ProviderStreamPart? readEvent(String line) {
    final data = _sseData(line);
    if (data == null) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('event:') &&
          !trimmed.startsWith(':')) {
        throw const FormatException('invalid SSE line');
      }
      return null;
    }
    final payload = jsonDecode(data) as Map<String, Object?>;
    final type = payload['type'];
    if (type == 'error') {
      throw const ModelGatewayException(
        kind: ModelFailureKind.provider,
        message: '模型服务返回了错误。',
      );
    }
    if (type == 'message_stop') {
      return (delta: '', done: true);
    }
    if (type == 'content_block_delta') {
      final delta = payload['delta']! as Map<String, Object?>;
      return (delta: delta['text'] as String? ?? '', done: false);
    }
    return null;
  }
}

bool _usesArkAgentPlan(String baseUrl) {
  final uri = Uri.parse(baseUrl.trim());
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  return uri.host.toLowerCase() == 'ark.cn-beijing.volces.com' &&
      (path == '/api/plan' || path.startsWith('/api/plan/'));
}

final class _OllamaProtocol implements _ProviderProtocol {
  const _OllamaProtocol();

  @override
  bool get requiresApiKey => false;

  @override
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
    int maxTokens,
  ) {
    // Ollama 历来不设输出上限，这里同样不设（num_predict），保持原状。
    final headers = <String, String>{'content-type': 'application/json'};
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      headers['authorization'] = 'Bearer ${apiKey.trim()}';
    }
    return (
      uri: _appendEndpoint(config.baseUrl, 'api/chat', ollama: true),
      headers: headers,
      body: {
        'model': config.model.trim(),
        'messages': messages.map(_messageJson).toList(),
        'options': {'temperature': config.temperature},
        'stream': true,
      },
    );
  }

  @override
  _ProviderStreamPart? readEvent(String line) {
    if (line.trim().isEmpty) {
      return null;
    }
    final payload = jsonDecode(line) as Map<String, Object?>;
    final message = payload['message'] as Map<String, Object?>?;
    return (
      delta: message?['content'] as String? ?? '',
      done: payload['done'] == true,
    );
  }
}

String? _sseData(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('data:')) {
    return null;
  }
  return trimmed.substring(5).trim();
}

Map<String, String> _messageJson(ModelMessage message) => {
  'role': message.role.name,
  'content': message.content,
};

Uri _appendEndpoint(String baseUrl, String suffix, {bool ollama = false}) =>
    appendProviderEndpoint(baseUrl, suffix, ollama: ollama);

/// 把服务地址与端点后缀拼接成完整请求地址：已以该端点结尾的地址原样
/// 使用（用户可能直接填了完整端点）。聊天与语音转写共用。
Uri appendProviderEndpoint(
  String baseUrl,
  String suffix, {
  bool ollama = false,
}) {
  final base = normalizeProviderBaseUri(baseUrl);
  final normalizedPath = base.path;
  if (normalizedPath.endsWith('/$suffix')) {
    return base;
  }
  if (ollama && normalizedPath.endsWith('/api')) {
    return base.replace(path: '$normalizedPath/chat');
  }
  final path = normalizedPath.isEmpty ? '/$suffix' : '$normalizedPath/$suffix';
  return base.replace(path: path);
}

Uri _anthropicMessagesEndpoint(String baseUrl) {
  final base = normalizeProviderBaseUri(baseUrl);
  final normalizedPath = base.path;
  if (normalizedPath.endsWith('/messages')) {
    return base;
  }
  if (normalizedPath.endsWith('/v1')) {
    return base.replace(path: '$normalizedPath/messages');
  }
  final path = normalizedPath.isEmpty
      ? '/v1/messages'
      : '$normalizedPath/v1/messages';
  return base.replace(path: path);
}

ModelGatewayException _statusFailure(int statusCode, String body) =>
    providerStatusFailure(statusCode, body, serviceLabel: '模型服务');

/// 出网 HTTP 非 2xx 的统一分类（带服务名文案）。聊天模型与语音转写
/// 共用同一套错误分类，供连接测试与失败提示使用。
ModelGatewayException providerStatusFailure(
  int statusCode,
  String body, {
  required String serviceLabel,
}) {
  if (statusCode == HttpStatus.unauthorized ||
      statusCode == HttpStatus.forbidden) {
    return ModelGatewayException(
      kind: ModelFailureKind.authentication,
      message: 'API Key 未通过$serviceLabel验证。',
    );
  }
  if (statusCode == HttpStatus.tooManyRequests) {
    return ModelGatewayException(
      kind: ModelFailureKind.rateLimited,
      message: '$serviceLabel请求过于频繁。',
    );
  }
  final lowerBody = body.toLowerCase();
  if (lowerBody.contains('model') &&
      (lowerBody.contains('not found') ||
          lowerBody.contains('does not exist') ||
          lowerBody.contains('unknown model') ||
          lowerBody.contains('no such model'))) {
    return const ModelGatewayException(
      kind: ModelFailureKind.modelNotFound,
      message: '模型名称不存在或当前账号不可用。',
    );
  }
  return ModelGatewayException(
    kind: ModelFailureKind.provider,
    message: '$serviceLabel拒绝了这次请求。',
  );
}

ModelGatewayException _socketFailure(SocketException error) =>
    providerSocketFailure(error, serviceLabel: '模型服务');

/// Socket 异常的统一分类（带服务名文案）：域名解析失败与一般网络故障
/// 分开报告。聊天模型与语音转写共用。
ModelGatewayException providerSocketFailure(
  SocketException error, {
  required String serviceLabel,
}) {
  final message = error.message.toLowerCase();
  final code = error.osError?.errorCode;
  if (message.contains('failed host lookup') || code == 11001) {
    return ModelGatewayException(
      kind: ModelFailureKind.dns,
      message: '找不到$serviceLabel域名。',
    );
  }
  return ModelGatewayException(
    kind: ModelFailureKind.network,
    message: '无法连接$serviceLabel。',
  );
}
