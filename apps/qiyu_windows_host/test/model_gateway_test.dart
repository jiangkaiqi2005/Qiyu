import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  const messages = [
    ModelMessage(ModelMessageRole.system, '你是栖语。'),
    ModelMessage(ModelMessageRole.user, '在吗'),
  ];

  test('OpenAI-compatible 使用 Chat Completions 映射', () async {
    final client = _RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          'data: {"choices":[{"delta":{"content":"嗯"}}]}\n\n',
          'data: {"choices":[{"delta":{"content":"。"},"finish_reason":"stop"}]}\n\n',
        ]),
      ),
    );
    final gateway = ProviderModelGateway(client);

    final reply = await gateway.complete(
      config: _config(ProviderKind.openAiCompatible),
      apiKey: 'test-key',
      messages: messages,
    );

    expect(reply, '嗯。');
    expect(client.uri.path, '/v1/chat/completions');
    expect(client.headers['authorization'], 'Bearer test-key');
    expect(client.jsonBody, {
      'model': 'chat-model',
      'messages': [
        {'role': 'system', 'content': '你是栖语。'},
        {'role': 'user', 'content': '在吗'},
      ],
      'temperature': 0.6,
      'max_tokens': 512,
      'stream': true,
    });
  });

  test('Anthropic 使用 Messages API 的顶层 system 与鉴权头', () async {
    final client = _RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"在。"}}\n\n',
          'data: {"type":"message_stop"}\n\n',
        ]),
      ),
    );
    final gateway = ProviderModelGateway(client);

    final reply = await gateway.complete(
      config: _config(
        ProviderKind.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
      ),
      apiKey: 'anthropic-test-key',
      messages: messages,
    );

    expect(reply, '在。');
    expect(client.uri.path, '/v1/messages');
    expect(client.headers['x-api-key'], 'anthropic-test-key');
    expect(client.headers['anthropic-version'], '2023-06-01');
    expect(client.jsonBody, {
      'model': 'chat-model',
      'system': '你是栖语。',
      'messages': [
        {'role': 'user', 'content': '在吗'},
      ],
      'temperature': 0.6,
      'max_tokens': 512,
      'stream': true,
    });
  });

  test('火山方舟 Agent Plan 使用 Bearer 鉴权', () async {
    final client = _RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"在。"}}\n\n',
          'data: {"type":"message_stop"}\n\n',
        ]),
      ),
    );
    final gateway = ProviderModelGateway(client);

    final reply = await gateway.complete(
      config: _config(
        ProviderKind.anthropic,
        baseUrl: 'https://ark.cn-beijing.volces.com/api/plan',
      ),
      apiKey: 'agent-plan-test-key',
      messages: messages,
    );

    expect(reply, '在。');
    expect(client.uri.path, '/api/plan/v1/messages');
    expect(client.headers['authorization'], 'Bearer agent-plan-test-key');
    expect(client.headers, isNot(contains('x-api-key')));
    expect(client.headers['anthropic-version'], '2023-06-01');
  });

  test('Anthropic 兼容地址会补全 v1/messages', () async {
    final client = _RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"在。"}}\n\n',
          'data: {"type":"message_stop"}\n\n',
        ]),
      ),
    );
    final gateway = ProviderModelGateway(client);

    await gateway.complete(
      config: _config(
        ProviderKind.anthropic,
        baseUrl: 'https://api.deepseek.com/anthropic',
      ),
      apiKey: 'compatible-test-key',
      messages: messages,
    );

    expect(client.uri.path, '/anthropic/v1/messages');
    expect(client.headers['x-api-key'], 'compatible-test-key');
  });

  test('Ollama 使用本机 Chat API 且 temperature 放在 options', () async {
    final client = _RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          '{"message":{"role":"assistant","content":"嗯"},"done":false}\n',
          '{"message":{"role":"assistant","content":"？"},"done":true}\n',
        ]),
      ),
    );
    final gateway = ProviderModelGateway(client);

    final reply = await gateway.complete(
      config: _config(ProviderKind.ollama, baseUrl: 'http://127.0.0.1:11434'),
      apiKey: null,
      messages: messages,
    );

    expect(reply, '嗯？');
    expect(client.uri.path, '/api/chat');
    expect(client.headers, isNot(contains('authorization')));
    expect(client.jsonBody, {
      'model': 'chat-model',
      'messages': [
        {'role': 'system', 'content': '你是栖语。'},
        {'role': 'user', 'content': '在吗'},
      ],
      'options': {'temperature': 0.6},
      'stream': true,
    });
  });

  test('统一事件流按增量、完成顺序输出', () async {
    final gateway = ProviderModelGateway(
      _RecordingHttpClient(
        response: ProviderHttpResponse(
          statusCode: 200,
          body: Stream.fromIterable([
            'data: {"choices":[{"delta":{"content":"还没"}}]}\n\n',
            'data: {"choices":[{"delta":{"content":"睡？"},"finish_reason":"stop"}]}\n\n',
          ]),
        ),
      ),
    );

    final events = await gateway
        .stream(
          config: _config(ProviderKind.openAiCompatible),
          apiKey: 'test-key',
          messages: messages,
        )
        .toList();

    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(
      events
          .where((event) => event.kind == ModelStreamEventKind.delta)
          .map((event) => event.text)
          .join(),
      '还没睡？',
    );
  });

  test('三种 Provider 在终止标记前 EOF 都不能把半句视为完成', () async {
    for (final scenario in [
      (
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://api.example.com/v1',
        body: 'data: {"choices":[{"delta":{"content":"半句"}}]}\n\n',
      ),
      (
        kind: ProviderKind.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
        body:
            'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"半句"}}\n\n',
      ),
      (
        kind: ProviderKind.ollama,
        baseUrl: 'http://127.0.0.1:11434',
        body: '{"message":{"role":"assistant","content":"半句"},"done":false}\n',
      ),
      (
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://api.example.com/v1',
        body:
            'data: {"choices":[{"message":{"content":"半句"},"finish_reason":null}]}\n\n',
      ),
      (
        kind: ProviderKind.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
        body: 'data: {"content":[{"type":"text","text":"半句"}]}\n\n',
      ),
    ]) {
      final events =
          await ProviderModelGateway(
                _RecordingHttpClient(
                  response: ProviderHttpResponse(
                    statusCode: 200,
                    body: Stream.value(scenario.body),
                  ),
                ),
              )
              .stream(
                config: _config(scenario.kind, baseUrl: scenario.baseUrl),
                apiKey: scenario.kind == ProviderKind.ollama
                    ? null
                    : 'test-key',
                messages: messages,
              )
              .toList();

      expect(
        events.map((event) => event.kind),
        isNot(contains(ModelStreamEventKind.done)),
      );
      expect(events.last.kind, ModelStreamEventKind.failure);
      expect(events.last.failure, isNotNull);
    }
  });

  test('Anthropic 原生 error 事件转为安全失败且不回传原文', () async {
    final events =
        await ProviderModelGateway(
              _RecordingHttpClient(
                response: ProviderHttpResponse(
                  statusCode: 200,
                  body: Stream.value(
                    'data: {"type":"error","error":{"message":"Authorization: Bearer leaked-token"}}\n\n',
                  ),
                ),
              ),
            )
            .stream(
              config: _config(
                ProviderKind.anthropic,
                baseUrl: 'https://api.anthropic.com/v1',
              ),
              apiKey: 'test-key',
              messages: messages,
            )
            .toList();

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.provider);
    expect(events.single.message, isNot(contains('leaked-token')));
  });

  test('取消统一事件流会取消底层 HTTP 响应订阅', () async {
    final cancelled = Completer<void>();
    final deltaReceived = Completer<void>();
    final controller = StreamController<String>(
      onCancel: () {
        if (!cancelled.isCompleted) {
          cancelled.complete();
        }
      },
    );
    final subscription =
        ProviderModelGateway(
              _RecordingHttpClient(
                response: ProviderHttpResponse(
                  statusCode: 200,
                  body: controller.stream,
                ),
              ),
            )
            .stream(
              config: _config(ProviderKind.openAiCompatible),
              apiKey: 'test-key',
              messages: messages,
            )
            .listen((event) {
              if (event.kind == ModelStreamEventKind.delta &&
                  !deltaReceived.isCompleted) {
                deltaReceived.complete();
              }
            });

    controller.add('data: {"choices":[{"delta":{"content":"半句"}}]}\n\n');
    await deltaReceived.future;
    final cancellation = subscription.cancel();
    await cancelled.future;
    await controller.close();
    await cancellation;

    expect(cancelled.isCompleted, isTrue);
  });

  test('真实 HTTP 客户端以 UTF-8 发送含中文的请求体', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final receivedBody = Completer<String>();
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      if (!receivedBody.isCompleted) {
        receivedBody.complete(body);
      }
      request.response.headers.set('content-type', 'text/event-stream');
      request.response.add(
        utf8.encode(
          'data: {"choices":[{"delta":{"content":"嗯"},"finish_reason":"stop"}]}\n\n',
        ),
      );
      await request.response.close();
    });

    final reply = await ProviderModelGateway(const DartIoProviderHttpClient())
        .complete(
          config: _config(
            ProviderKind.openAiCompatible,
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
          ),
          apiKey: 'test-key',
          messages: messages,
        );

    expect(reply, '嗯');
    final sent = jsonDecode(await receivedBody.future) as Map<String, Object?>;
    expect(sent['messages'], [
      {'role': 'system', 'content': '你是栖语。'},
      {'role': 'user', 'content': '在吗'},
    ]);
  });

  test('所有连接测试错误可区分且不泄露 Key', () async {
    for (final scenario in [
      (
        client: _RecordingHttpClient(
          error: const SocketException(
            'Failed host lookup',
            osError: OSError('host not found', 11001),
          ),
        ),
        kind: ModelFailureKind.dns,
      ),
      (
        client: _RecordingHttpClient(error: HandshakeException('bad tls')),
        kind: ModelFailureKind.tls,
      ),
      (
        client: _RecordingHttpClient(error: TimeoutException('slow')),
        kind: ModelFailureKind.timeout,
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 401,
            body: Stream.value('{"error":{"message":"bad test-key"}}'),
          ),
        ),
        kind: ModelFailureKind.authentication,
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 404,
            body: Stream.value('{"error":{"message":"model not found"}}'),
          ),
        ),
        kind: ModelFailureKind.modelNotFound,
      ),
      (
        client: _RecordingHttpClient(error: const SocketException('offline')),
        kind: ModelFailureKind.network,
      ),
      (
        client: _RecordingHttpClient(error: ArgumentError('boom')),
        kind: ModelFailureKind.internal,
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 429,
            body: Stream.value('{}'),
          ),
        ),
        kind: ModelFailureKind.rateLimited,
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 200,
            body: Stream.value('oops'),
          ),
        ),
        kind: ModelFailureKind.incompatibleResponse,
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 200,
            body: Stream.value('data: {}\n\n'),
          ),
        ),
        kind: ModelFailureKind.contentParsing,
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 404,
            body: Stream.value('{"error":"route not found"}'),
          ),
        ),
        kind: ModelFailureKind.provider,
      ),
    ]) {
      await expectLater(
        ProviderModelGateway(scenario.client).complete(
          config: _config(ProviderKind.openAiCompatible),
          apiKey: 'test-key',
          messages: messages,
        ),
        throwsA(
          isA<ModelGatewayException>()
              .having((error) => error.kind, 'kind', scenario.kind)
              .having(
                (error) => error.message,
                'redacted message',
                isNot(contains('test-key')),
              ),
        ),
      );
    }
  });
}

ProviderConfig _config(ProviderKind kind, {String? baseUrl}) => ProviderConfig(
  kind: kind,
  baseUrl: baseUrl ?? 'https://api.example.com/v1',
  model: 'chat-model',
  temperature: 0.6,
  timeoutSeconds: 25,
);

final class _RecordingHttpClient implements ProviderHttpClient {
  _RecordingHttpClient({this.response, this.error});

  final ProviderHttpResponse? response;
  final Object? error;
  late Uri uri;
  late Map<String, String> headers;
  late Map<String, Object?> jsonBody;

  @override
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) async {
    this.uri = uri;
    this.headers = headers;
    jsonBody = jsonDecode(body) as Map<String, Object?>;
    if (error case final failure?) {
      throw failure;
    }
    return response!;
  }
}
