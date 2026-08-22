import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  test('Key 带零宽空格按粘贴事故拒绝，不出网', () async {
    final client = _RecordingHttpClient();

    await expectLater(
      SttModelGateway(client).transcribe(
        config: config,
        apiKey: 'stt-test-key\u200B',
        audio: [0],
        mimeType: 'audio/webm',
      ),
      throwsA(
        isA<SttGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.provider)
            .having(
              (error) => error.message,
              'message',
              'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
            ),
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

  test('SSRF 拒绝：STT HTTP 出网指向环回/内网/保留地址时在出网前抛错', () async {
    const targets = [
      'https://localhost/v1',
      'https://127.0.0.1/v1',
      'https://10.1.2.3/v1',
      'https://172.20.0.1/v1',
      'https://192.168.0.2/v1',
      'https://169.254.1.1/v1',
      'https://0.0.0.0/v1',
      'https://100.64.0.1/v1',
      'https://[::1]/v1',
      'https://[fe80::1]/v1',
      'https://[fc00::1]/v1',
    ];
    for (final baseUrl in targets) {
      final client = _RecordingHttpClient();
      await expectLater(
        SttModelGateway(client).transcribe(
          config: SttConfig(baseUrl: baseUrl, model: 'whisper-test'),
          apiKey: 'stt-test-key',
          audio: [0],
          mimeType: 'audio/webm',
        ),
        throwsA(
          isA<SttGatewayException>()
              .having((error) => error.kind, 'kind', ModelFailureKind.provider)
              .having(
                (error) => error.message,
                'message',
                '语音服务地址不允许指向本机或内网。',
              ),
        ),
        reason: baseUrl,
      );
      expect(client.called, isFalse, reason: baseUrl);
    }
  });

  test('OpenAI 协议按 config.provider 分派：豆包配置不再打 HTTP transcriptions', () async {
    // 分派行为在 SttModelGateway 层验证：豆包配置即使配了 HTTP 客户端也
    // 绝不发起 HTTP 调用（HTTP 客户端被调用即失败）。
    final client = _RecordingHttpClient();
    final connector = _StaticWebSocketConnector();
    await expectLater(
      SttModelGateway(client, webSocketConnector: connector).transcribe(
        config: const SttConfig(
          provider: SttProviderKind.volcSeedAsr,
          baseUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
          model: 'volc.seedasr.sauc.duration',
        ),
        apiKey: 'ark-test-key',
        audio: [1, 2, 3],
        mimeType: 'audio/wav',
      ),
      completion('ws-ok'),
    );
    expect(client.called, isFalse);
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

/// 固定回一段豆包最终包响应的假 WS 连接（分派行为验证用）。
final class _StaticWebSocketConnector implements ProviderWebSocketConnector {
  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async => _StaticWebSocketConnection();
}

final class _StaticWebSocketConnection implements ProviderWebSocketConnection {
  @override
  Stream<List<int>> get messages async* {
    final payload = gzip.encode(
      utf8.encode(jsonEncode({'result': {'text': 'ws-ok'}})),
    );
    yield Uint8List.fromList([
      0x11, 0x93, 0x11, 0x00, // server response 最终包（flags 0011）
      0x00, 0x00, 0x00, 0x01, // sequence
      ..._u32(payload.length),
      ...payload,
    ]);
  }

  static List<int> _u32(int value) => [
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];

  @override
  void send(List<int> bytes) {}

  @override
  Future<void> close() async {}
}
