import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  const config = SttConfig(
    baseUrl: 'https://stt.example.com/v1',
    model: 'whisper-test',
  );

  test('multipart 请求形状：端点拼接、鉴权头、model/language 与文件名', () async {
    final client = _RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('{"text":"今天有点累"}'),
      ),
    );

    final text = await SttModelGateway(client).transcribe(
      config: config,
      apiKey: ' stt-test-key ',
      audio: [1, 2, 3, 4],
      mimeType: 'audio/webm',
    );

    expect(text, '今天有点累');
    expect(client.uri.toString(), 'https://stt.example.com/v1/audio/transcriptions');
    expect(client.headers['authorization'], 'Bearer stt-test-key');
    final contentType = client.headers['content-type']!;
    expect(contentType, startsWith('multipart/form-data; boundary='));
    final boundary = contentType.split('boundary=').last;
    final body = latin1.decode(client.bytesBody);
    expect(body, contains('--$boundary\r\n'));
    expect(
      body,
      contains('content-disposition: form-data; name="model"\r\n\r\nwhisper-test'),
    );
    expect(body, contains('content-disposition: form-data; name="language"\r\n\r\nzh'));
    expect(
      body,
      contains(
        'content-disposition: form-data; name="file"; filename="recording.webm"',
      ),
    );
    expect(body, contains('content-type: audio/webm\r\n\r\n'));
    expect(body, endsWith('\r\n--$boundary--\r\n'));
  });

  test('已写完整端点的地址原样使用；mp4 给出对应文件名', () async {
    final client = _RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('{"text":"嗯"}'),
      ),
    );

    await SttModelGateway(client).transcribe(
      config: const SttConfig(
        baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
        model: 'whisper-test',
      ),
      apiKey: 'stt-test-key',
      audio: [9],
      mimeType: 'audio/mp4',
    );

    expect(
      client.uri.toString(),
      'https://stt.example.com/v1/audio/transcriptions',
    );
    expect(
      latin1.decode(client.bytesBody),
      contains('filename="recording.mp4"'),
    );
  });

  test('空文本照实返回：空与失败的语义区分交给调用方', () async {
    final client = _RecordingHttpClient(
      response: ProviderHttpResponse(statusCode: 200, body: Stream.value('{"text":""}')),
    );

    final text = await SttModelGateway(client).transcribe(
      config: config,
      apiKey: 'stt-test-key',
      audio: [0],
      mimeType: 'audio/webm',
    );

    expect(text, isEmpty);
  });

  test('缺 Key 直接按鉴权失败拒绝，不出网', () async {
    final client = _RecordingHttpClient();

    await expectLater(
      SttModelGateway(client).transcribe(
        config: config,
        apiKey: '  ',
        audio: [0],
        mimeType: 'audio/webm',
      ),
      throwsA(
        isA<SttGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.authentication),
      ),
    );
    expect(client.called, isFalse);
  });

  test('非 2xx 与出网异常按语音服务文案分类且不回传服务商原文', () async {
    final scenarios = [
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 401,
            body: Stream.value('{"error":{"message":"bad stt-test-key"}}'),
          ),
        ),
        kind: ModelFailureKind.authentication,
        message: 'API Key 未通过语音服务验证。',
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 404,
            body: Stream.value('{"error":{"message":"model not found"}}'),
          ),
        ),
        kind: ModelFailureKind.modelNotFound,
        message: '模型名称不存在或当前账号不可用。',
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 429,
            body: Stream.value('{}'),
          ),
        ),
        kind: ModelFailureKind.rateLimited,
        message: '语音服务请求过于频繁。',
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 500,
            body: Stream.value('{"error":"internal secret detail"}'),
          ),
        ),
        kind: ModelFailureKind.provider,
        message: '语音服务拒绝了这次请求。',
      ),
      (
        client: _RecordingHttpClient(
          error: const SocketException(
            'Failed host lookup',
            osError: OSError('host not found', 11001),
          ),
        ),
        kind: ModelFailureKind.dns,
        message: '找不到语音服务域名。',
      ),
      (
        client: _RecordingHttpClient(error: HandshakeException('bad tls')),
        kind: ModelFailureKind.tls,
        message: '语音服务的 TLS 安全连接失败。',
      ),
      (
        client: _RecordingHttpClient(error: TimeoutException('slow')),
        kind: ModelFailureKind.timeout,
        message: '连接语音服务超时。',
      ),
      (
        client: _RecordingHttpClient(error: const SocketException('offline')),
        kind: ModelFailureKind.network,
        message: '无法连接语音服务。',
      ),
      (
        client: _RecordingHttpClient(
          response: ProviderHttpResponse(statusCode: 200, body: Stream.value('oops')),
        ),
        kind: ModelFailureKind.contentParsing,
        message: '语音服务返回的内容无法解析。',
      ),
    ];
    for (final scenario in scenarios) {
      await expectLater(
        SttModelGateway(scenario.client).transcribe(
          config: config,
          apiKey: 'stt-test-key',
          audio: [0],
          mimeType: 'audio/webm',
        ),
        throwsA(
          isA<SttGatewayException>()
              .having((error) => error.kind, 'kind', scenario.kind)
              .having((error) => error.message, 'message', scenario.message)
              .having(
                (error) => error.toString(),
                'redacted message',
                isNot(contains('secret')),
              ),
        ),
        reason: scenario.kind.name,
      );
    }
  });

  test('真实 HTTP 客户端发送 multipart 并解析 JSON 响应', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<List<int>>();
    server.listen((request) async {
      final body = <int>[];
      await for (final chunk in request) {
        body.addAll(chunk);
      }
      if (!received.isCompleted) {
        received.complete(body);
      }
      request.response.headers.contentType = ContentType.json;
      request.response.add(utf8.encode('{"text":"还醒着"}'));
      await request.response.close();
    });

    final text = await SttModelGateway(const DartIoProviderHttpClient()).transcribe(
      config: SttConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'whisper-test',
      ),
      apiKey: 'stt-test-key',
      audio: utf8.encode('fake-opus-bytes'),
      mimeType: 'audio/webm',
    );

    expect(text, '还醒着');
    final sent = latin1.decode(await received.future);
    expect(sent, contains('name="model"'));
    expect(sent, contains('whisper-test'));
    expect(sent, contains('name="language"'));
    expect(sent, contains('zh'));
    expect(sent, contains('filename="recording.webm"'));
    expect(sent, contains('fake-opus-bytes'));
  });
}

final class _RecordingHttpClient implements ProviderHttpClient {
  _RecordingHttpClient({this.response, this.error});

  final ProviderHttpResponse? response;
  final Object? error;
  bool called = false;
  late Uri uri;
  late Map<String, String> headers;
  late List<int> bytesBody;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    called = true;
    this.uri = uri;
    this.headers = headers;
    bytesBody = body;
    if (error case final failure?) {
      throw failure;
    }
    return response!;
  }

  @override
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) {
    throw UnsupportedError('STT 网关只使用非流式 POST');
  }
}
