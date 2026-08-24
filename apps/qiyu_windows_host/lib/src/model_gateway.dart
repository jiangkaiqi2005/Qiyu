import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'provider_config.dart';
import 'web_search.dart';

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

abstract interface class WebSearchStreamingModelGateway {
  Stream<ModelStreamEvent> streamWithWebSearch({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    required String webSearchApiKey,
    required WebSearchClient webSearchClient,
    Future<void>? whenCancelled,
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

abstract interface class CancellableProviderHttpClient
    implements ProviderHttpClient {
  Future<ProviderHttpResponse> postStreamCancellable({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    required Future<void> whenCancelled,
  });

  Future<ProviderHttpResponse> postCancellable({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    required Future<void> whenCancelled,
  });
}

final class ProviderRequestCancelled implements Exception {
  const ProviderRequestCancelled();
}

final class DartIoProviderHttpClient
    implements
        ProviderHttpClient,
        CancellableProviderHttpClient,
        ProviderBytesHttpClient {
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
  Future<ProviderHttpResponse> postStreamCancellable({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    required Future<void> whenCancelled,
  }) => _postBytes(
    uri: uri,
    headers: headers,
    body: utf8.encode(body),
    timeout: timeout,
    whenCancelled: whenCancelled,
  );

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
  Future<ProviderHttpResponse> postCancellable({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    required Future<void> whenCancelled,
  }) => _postBytes(
    uri: uri,
    headers: headers,
    body: body,
    timeout: timeout,
    whenCancelled: whenCancelled,
  );

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
    Future<void>? whenCancelled,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    var cancelled = false;
    whenCancelled?.then((_) {
      cancelled = true;
      client.close(force: true);
    });
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
      if (cancelled) {
        throw const ProviderRequestCancelled();
      }
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

final class ProviderModelGateway
    implements StreamingModelGateway, WebSearchStreamingModelGateway {
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

  @override
  Stream<ModelStreamEvent> streamWithWebSearch({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    required String webSearchApiKey,
    required WebSearchClient webSearchClient,
    Future<void>? whenCancelled,
    int? maxTokens,
  }) async* {
    if (config.kind != ProviderKind.anthropic) {
      yield* stream(
        config: config,
        apiKey: apiKey,
        messages: messages,
        maxTokens: maxTokens,
      );
      return;
    }
    config.validate();
    if (apiKey == null || apiKey.trim().isEmpty) {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.authentication,
        '还没有保存 API Key。',
      );
      return;
    }
    final protocol = const _AnthropicProtocol();
    final request = protocol.buildRequest(
      config,
      apiKey,
      messages,
      maxTokens ?? _maxModelReplyTokens,
    );
    final firstBody = <String, Object?>{
      ...request.body,
      'tools': const [
        {
          'name': 'web_search',
          'description': '搜索当前互联网信息。',
          'input_schema': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
            },
            'required': ['query'],
            'additionalProperties': false,
          },
        },
      ],
      'tool_choice': const {'type': 'auto'},
    };
    try {
      final first = await _readAnthropicTurn(
        request: request,
        body: firstBody,
        timeout: Duration(seconds: config.timeoutSeconds),
        whenCancelled: whenCancelled,
      );
      if (first.toolUses.isEmpty) {
        if (first.text.trim().isEmpty) {
          throw const ModelGatewayException(
            kind: ModelFailureKind.contentParsing,
            message: '模型服务返回的内容无法解析。',
          );
        }
        yield ModelStreamEvent.delta(first.text);
        yield const ModelStreamEvent.done();
        return;
      }
      // 同一响应可能携带多个并行工具调用：先整体校验全部调用（名称与
      // 输入 schema），任何一个不合法都失败关闭，不执行任何搜索。
      final validated = [
        for (final toolUse in first.toolUses) _validatedWebSearchCall(toolUse),
      ];
      // 串行执行各次搜索，复用现有超时与取消信号；单个搜索失败只生成
      // 对应 id 的 is_error 结果，不中断其余调用。id、query、结果内容与
      // 错误标记合并在同一条记录里，后续不再按下标平行配对。
      final calls =
          <({String id, String query, String content, bool isError})>[];
      for (final call in validated) {
        String content;
        var isError = false;
        try {
          final results = await webSearchClient.search(
            apiKey: webSearchApiKey,
            query: call.query,
            whenCancelled: whenCancelled,
          );
          content = jsonEncode([
            for (final result in results) result.toJson(),
          ]);
        } on ProviderRequestCancelled {
          rethrow;
        } on Object {
          isError = true;
          content = '这次联网搜索失败，无法取得可靠结果。';
        }
        calls.add((
          id: call.id,
          query: call.query,
          content: content,
          isError: isError,
        ));
      }
      final secondMessages = <Object?>[
        ...request.body['messages']! as List<Object?>,
        {
          'role': 'assistant',
          'content': [
            for (final call in calls)
              {
                'type': 'tool_use',
                'id': call.id,
                'name': 'web_search',
                'input': {'query': call.query},
              },
          ],
        },
        {
          'role': 'user',
          'content': [
            for (final call in calls)
              {
                'type': 'tool_result',
                'tool_use_id': call.id,
                'content': call.content,
                if (call.isError) 'is_error': true,
              },
          ],
        },
      ];
      final second = await _readAnthropicTurn(
        request: request,
        body: {...request.body, 'messages': secondMessages},
        timeout: Duration(seconds: config.timeoutSeconds),
        whenCancelled: whenCancelled,
      );
      if (second.toolUses.isNotEmpty || second.text.trim().isEmpty) {
        throw const ModelGatewayException(
          kind: ModelFailureKind.incompatibleResponse,
          message: '模型服务返回了不兼容的响应格式。',
        );
      }
      yield ModelStreamEvent.delta(second.text);
      yield const ModelStreamEvent.done();
    } on ProviderRequestCancelled {
      return;
    } on TimeoutException {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.timeout,
        '模型服务响应超时。',
      );
    } on HandshakeException {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.tls,
        '模型服务的 TLS 安全连接失败。',
      );
    } on SocketException catch (error) {
      final failure = _socketFailure(error);
      yield ModelStreamEvent.failure(failure.kind, failure.message);
    } on HttpException {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.network,
        '模型服务连接中断。',
      );
    } on ModelGatewayException catch (error) {
      yield ModelStreamEvent.failure(error.kind, error.message);
    } on Object {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.incompatibleResponse,
        '模型服务返回了不兼容的响应格式。',
      );
    }
  }

  /// 校验单个工具调用的名称与输入 schema（`{query: string}` 单键），
  /// 返回脱敏后的搜索词；未知工具报 incompatibleResponse 失败关闭；
  /// 参数 JSON 无法解码时由外层兜底为 incompatibleResponse，可解码
  /// 但结构不符或脱敏后为空的输入才报 contentParsing。
  ({String id, String query}) _validatedWebSearchCall(
    _AnthropicToolUse toolUse,
  ) {
    if (toolUse.name != 'web_search') {
      throw const ModelGatewayException(
        kind: ModelFailureKind.incompatibleResponse,
        message: '模型服务请求了不支持的工具。',
      );
    }
    final decodedInput = jsonDecode(toolUse.inputJson);
    if (decodedInput is! Map<String, Object?> ||
        decodedInput.length != 1 ||
        decodedInput['query'] is! String) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的搜索参数无法解析。',
      );
    }
    final safeQuery = sanitizeWebSearchQuery(decodedInput['query']! as String);
    if (safeQuery.isEmpty) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的搜索参数无法解析。',
      );
    }
    return (id: toolUse.id, query: safeQuery);
  }

  Future<_AnthropicTurn> _readAnthropicTurn({
    required _ProviderRequest request,
    required Map<String, Object?> body,
    required Duration timeout,
    Future<void>? whenCancelled,
  }) async {
    var cancelled = false;
    whenCancelled?.then((_) => cancelled = true);
    final encodedBody = jsonEncode(body);
    final response =
        whenCancelled != null && httpClient is CancellableProviderHttpClient
        ? await (httpClient as CancellableProviderHttpClient)
              .postStreamCancellable(
                uri: request.uri,
                headers: request.headers,
                body: encodedBody,
                timeout: timeout,
                whenCancelled: whenCancelled,
              )
        : await httpClient.postStream(
            uri: request.uri,
            headers: request.headers,
            body: encodedBody,
            timeout: timeout,
          );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String responseBody;
      try {
        responseBody = await response.body.join();
      } on Object {
        if (cancelled) {
          throw const ProviderRequestCancelled();
        }
        rethrow;
      }
      if (cancelled) {
        throw const ProviderRequestCancelled();
      }
      throw _statusFailure(response.statusCode, responseBody);
    }
    final text = StringBuffer();
    // 同一 turn 可包含多个工具块：每个 content_block 一组独立缓冲，参数
    // 增量按 index 归位；个别兼容服务省略 index 时退化为追加到最近开始
    // 的工具块，绝不跨块拼接不同工具的增量，thinking 与可见文本不进任何
    // 工具缓冲。
    final toolBuffers = <_AnthropicToolBuffer>[];
    final toolBuffersByIndex = <int, _AnthropicToolBuffer>{};
    _AnthropicToolBuffer? latestToolBuffer;
    var stopped = false;
    try {
      await for (final line in response.body.transform(const LineSplitter())) {
        if (cancelled) {
          throw const ProviderRequestCancelled();
        }
        final event = _readAnthropicEvent(line);
        if (event == null) {
          continue;
        }
        text.write(event.delta);
        if (event.toolName != null) {
          final buffer = _AnthropicToolBuffer(
            id: event.toolId,
            name: event.toolName!,
          );
          toolBuffers.add(buffer);
          final blockIndex = event.blockIndex;
          if (blockIndex != null) {
            toolBuffersByIndex[blockIndex] = buffer;
          }
          latestToolBuffer = buffer;
          buffer.input.write(event.toolInputDelta);
        } else if (event.toolInputDelta.isNotEmpty) {
          final buffer = event.blockIndex == null
              ? latestToolBuffer
              : toolBuffersByIndex[event.blockIndex];
          buffer?.input.write(event.toolInputDelta);
        }
        stopped = event.done || stopped;
      }
    } on Object {
      if (cancelled) {
        throw const ProviderRequestCancelled();
      }
      rethrow;
    }
    if (cancelled) {
      throw const ProviderRequestCancelled();
    }
    if (!stopped) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.network,
        message: '模型服务连接在回复完成前中断。',
      );
    }
    final toolUses = <_AnthropicToolUse>[
      for (final buffer in toolBuffers)
        if (buffer.id != null)
          _AnthropicToolUse(
            id: buffer.id!,
            name: buffer.name,
            inputJson: buffer.input.toString(),
          ),
    ];
    return _AnthropicTurn(text: text.toString(), toolUses: toolUses);
  }
}

final class _AnthropicToolUse {
  const _AnthropicToolUse({
    required this.id,
    required this.name,
    required this.inputJson,
  });

  final String id;
  final String name;
  final String inputJson;
}

/// 单个工具内容块的流式参数缓冲：id/name 来自 content_block_start，
/// input 累加属于同一块的 input_json_delta。
final class _AnthropicToolBuffer {
  _AnthropicToolBuffer({required this.id, required this.name});

  final String? id;
  final String name;

  final input = StringBuffer();
}

final class _AnthropicTurn {
  const _AnthropicTurn({required this.text, required this.toolUses});

  final String text;
  final List<_AnthropicToolUse> toolUses;
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

typedef _AnthropicStreamPart = ({
  String delta,
  bool done,
  int? blockIndex,
  String? toolId,
  String? toolName,
  String toolInputDelta,
});

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
    final event = _readAnthropicEvent(line);
    return event == null ? null : (delta: event.delta, done: event.done);
  }
}

_AnthropicStreamPart? _readAnthropicEvent(String line) {
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
  switch (payload['type']) {
    case 'error':
      throw const ModelGatewayException(
        kind: ModelFailureKind.provider,
        message: '模型服务返回了错误。',
      );
    case 'message_stop':
      return (
        delta: '',
        done: true,
        blockIndex: null,
        toolId: null,
        toolName: null,
        toolInputDelta: '',
      );
    case 'content_block_start':
      final block = payload['content_block'];
      if (block is Map<String, Object?> && block['type'] == 'tool_use') {
        final input = block['input'];
        return (
          delta: '',
          done: false,
          blockIndex: _contentBlockIndex(payload),
          toolId: block['id'] as String?,
          toolName: block['name'] as String?,
          toolInputDelta: input is Map && input.isNotEmpty
              ? jsonEncode(input)
              : '',
        );
      }
      return null;
    case 'content_block_delta':
      final delta = payload['delta'];
      if (delta is! Map<String, Object?>) {
        throw const ModelGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '模型服务返回的内容无法解析。',
        );
      }
      return (
        delta: delta['type'] == 'input_json_delta'
            ? ''
            : delta['text'] as String? ?? '',
        done: false,
        blockIndex: _contentBlockIndex(payload),
        toolId: null,
        toolName: null,
        toolInputDelta: delta['type'] == 'input_json_delta'
            ? delta['partial_json'] as String? ?? ''
            : '',
      );
    default:
      return null;
  }
}

/// Anthropic SSE 的内容块序号：个别兼容服务可能省略 index，此时返回
/// null，由累计方退化为「追加到最近开始的工具块」。
int? _contentBlockIndex(Map<String, Object?> payload) {
  final index = payload['index'];
  return index is int ? index : null;
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
