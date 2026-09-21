import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  const config = TtsConfig(
    baseUrl: 'https://tts.example.com/v1',
    model: 'tts-test',
  );

  test('请求形状：端点拼接、鉴权头、model/input/voice/response_format', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1, 2, 3]),
      ),
    );

    final audio = await TtsModelGateway(
      client,
    ).synthesize(config: config, apiKey: ' tts-test-key ', text: '晚安。');

    expect(audio, [1, 2, 3]);
    expect(client.uri.toString(), 'https://tts.example.com/v1/audio/speech');
    expect(client.headers['authorization'], 'Bearer tts-test-key');
    expect(client.headers['content-type'], 'application/json');
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'tts-test');
    expect(body['input'], '晚安。');
    expect(body['voice'], OpenAiSpeechGateway.defaultVoice);
    expect(body['response_format'], 'mp3');
    expect(body.containsKey('speed'), isFalse);
  });

  test('自定义音色与语速原样上送；已写完整端点的地址原样使用', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([9]),
      ),
    );

    await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        baseUrl: 'https://tts.example.com/v1/audio/speech',
        model: 'tts-test',
        voice: 'nova',
        speed: 1.5,
      ),
      apiKey: 'tts-test-key',
      text: '嗯。',
    );

    expect(client.uri.toString(), 'https://tts.example.com/v1/audio/speech');
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['voice'], 'nova');
    expect(body['speed'], 1.5);
  });

  test('缺 Key 直接按鉴权失败拒绝，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: '  ', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.authentication,
        ),
      ),
    );
    expect(client.called, isFalse);
  });

  test('Key 带零宽空格按粘贴事故拒绝，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'tts-test-key\u200B', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>()
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

  test('地址指向环回按 SSRF 拒绝，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(client).synthesize(
        config: const TtsConfig(
          baseUrl: 'http://127.0.0.1:8080/v1',
          model: 'tts-test',
        ),
        apiKey: 'tts-test-key',
        text: '晚安。',
      ),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.provider)
            .having((error) => error.message, 'message', '语音服务地址不允许指向本机或内网。'),
      ),
    );
    expect(client.called, isFalse);
  });

  test('非 2xx 按错误分类上报：401 鉴权、404+model not found 模型不存在', () async {
    final unauthorized = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: HttpStatus.unauthorized,
        body: Stream.value(utf8.encode('{"error":"bad key"}')),
      ),
    );
    await expectLater(
      TtsModelGateway(
        unauthorized,
      ).synthesize(config: config, apiKey: 'tts-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.authentication,
        ),
      ),
    );

    final missingModel = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: HttpStatus.notFound,
        body: Stream.value(utf8.encode('{"error":"model not found"}')),
      ),
    );
    await expectLater(
      TtsModelGateway(
        missingModel,
      ).synthesize(config: config, apiKey: 'tts-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.modelNotFound,
        ),
      ),
    );
  });

  test('2xx 但音频为空按解析失败拒绝', () async {
    final client = _RecordingBytesHttpClient(
      response: const ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.empty(),
      ),
    );

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'tts-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>()
            .having(
              (error) => error.kind,
              'kind',
              ModelFailureKind.contentParsing,
            )
            .having((error) => error.message, 'message', '语音合成服务没有返回音频。'),
      ),
    );
  });

  test('出网超时按超时分类上报', () async {
    final client = _RecordingBytesHttpClient(error: TimeoutException('slow'));

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'tts-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.timeout,
        ),
      ),
    );
  });

  test('OpenAI 协议 extraParams 展平合并入顶层请求体', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1, 2]),
      ),
    );

    final audio = await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-1',
        voice: 'alloy',
        extraParams: {
          'user': 'test-user',
          'custom_field': 123,
        },
      ),
      apiKey: 'tts-test-key',
      text: '你好。',
    );

    expect(audio, [1, 2]);
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'tts-1');
    expect(body['input'], '你好。');
    expect(body['voice'], 'alloy');
    expect(body['user'], 'test-user');
    expect(body['custom_field'], 123);
  });
}

final class _RecordingBytesHttpClient implements ProviderBytesHttpClient {
  _RecordingBytesHttpClient({this.response, this.error});

  final ProviderBytesHttpResponse? response;
  final Object? error;
  bool called = false;
  late Uri uri;
  late Map<String, String> headers;
  late List<int> bytesBody;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
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
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) async => throw UnimplementedError();
}
