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
      response: const ProviderHttpResponse(
        statusCode: 200,
        body: '{"choices":[{"message":{"content":"嗯。"}}]}',
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
      'stream': false,
    });
  });

  test('Anthropic 使用 Messages API 的顶层 system 与鉴权头', () async {
    final client = _RecordingHttpClient(
      response: const ProviderHttpResponse(
        statusCode: 200,
        body: '{"content":[{"type":"text","text":"在。"}]}',
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
      'stream': false,
    });
  });

  test('Ollama 使用本机 Chat API 且 temperature 放在 options', () async {
    final client = _RecordingHttpClient(
      response: const ProviderHttpResponse(
        statusCode: 200,
        body: '{"message":{"role":"assistant","content":"嗯？"}}',
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
      'stream': false,
    });
  });

  test('鉴权、模型、网络和响应格式错误可区分且不泄露 Key', () async {
    for (final scenario in [
      (
        client: _RecordingHttpClient(
          response: const ProviderHttpResponse(
            statusCode: 401,
            body: '{"error":{"message":"bad test-key"}}',
          ),
        ),
        kind: ModelFailureKind.authentication,
      ),
      (
        client: _RecordingHttpClient(
          response: const ProviderHttpResponse(
            statusCode: 404,
            body: '{"error":{"message":"model not found"}}',
          ),
        ),
        kind: ModelFailureKind.modelNotFound,
      ),
      (
        client: _RecordingHttpClient(error: const SocketException('offline')),
        kind: ModelFailureKind.network,
      ),
      (
        client: _RecordingHttpClient(
          response: const ProviderHttpResponse(statusCode: 200, body: '{}'),
        ),
        kind: ModelFailureKind.invalidResponse,
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
  Future<ProviderHttpResponse> post({
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
