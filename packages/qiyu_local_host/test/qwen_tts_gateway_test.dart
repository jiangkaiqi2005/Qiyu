import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  const config = TtsConfig(
    provider: TtsProviderKind.qwenTts,
    baseUrl: qwenTtsDefaultEndpoint,
    model: qwenTtsDefaultModel,
    voice: qwenTtsDefaultVoice,
  );

  ProviderBytesHttpResponse jsonBody(Map<String, Object?> body) =>
      ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode(jsonEncode(body))),
      );

  /// 带音频地址的非流式合成响应（官方形状：output.audio.url 是 24 小时
  /// 有效的公网地址）。
  ProviderBytesHttpResponse urlResponse(String url) => jsonBody({
    'output': {
      'audio': {'url': url},
    },
    'request_id': 'req-test-123',
  });

  test('请求形状：完整端点原样使用、Bearer 头、input 逐字段', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/qiyu.mp3'),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        // 分块流：验证下载读完全量字节再返回，不停在第一块。
        body: Stream.fromIterable([
          [1, 2],
          [3],
        ]),
      ),
    );

    final audio = await TtsModelGateway(
      client,
    ).synthesize(config: config, apiKey: ' sk-dashscope ', text: '晚安。');

    expect(audio, [1, 2, 3]);
    // 地址栏填的是完整端点：原样使用，不拼后缀。
    expect(client.uri.toString(), qwenTtsDefaultEndpoint);
    expect(client.headers['authorization'], 'Bearer sk-dashscope');
    expect(client.headers['content-type'], 'application/json');
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], qwenTtsDefaultModel);
    expect(body['input'], {
      'text': '晚安。',
      'voice': 'Cherry',
      'language_type': 'Chinese',
    });
  });

  test('响应里的音频地址经下载跳取回完整音频，预算与合成同级', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: urlResponse(
        'https://oss.example.com/audio/qiyu.mp3?Expires=1893456000&Signature=abc',
      ),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([9, 8]),
      ),
    );

    final audio = await TtsModelGateway(
      client,
    ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。');

    expect(audio, [9, 8]);
    expect(client.downloadCalled, isTrue);
    expect(
      client.downloadUri.toString(),
      'https://oss.example.com/audio/qiyu.mp3?Expires=1893456000&Signature=abc',
    );
    expect(client.downloadTimeout, ttsRequestTimeout);
  });

  test('音色自由输入：自定义 ID 原样上送，空白回落官方示例音色', () async {
    final custom = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/a.mp3'),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1]),
      ),
    );
    await TtsModelGateway(custom).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: qwenTtsDefaultEndpoint,
        model: qwenTtsDefaultModel,
        voice: 'Nofish',
      ),
      apiKey: 'sk-dashscope',
      text: '嗯。',
    );
    final customBody =
        jsonDecode(utf8.decode(custom.bytesBody)) as Map<String, Object?>;
    expect((customBody['input']! as Map<String, Object?>)['voice'], 'Nofish');

    final blank = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/a.mp3'),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1]),
      ),
    );
    await TtsModelGateway(blank).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: qwenTtsDefaultEndpoint,
        model: qwenTtsDefaultModel,
        voice: '   ',
      ),
      apiKey: 'sk-dashscope',
      text: '嗯。',
    );
    final blankBody =
        jsonDecode(utf8.decode(blank.bytesBody)) as Map<String, Object?>;
    expect((blankBody['input']! as Map<String, Object?>)['voice'], 'Cherry');
  });

  test('extraParams 深合并进 input：嵌套对象原样落进 input 且可覆盖基础字段', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/a.mp3'),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1]),
      ),
    );

    await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: qwenTtsDefaultEndpoint,
        model: 'qwen3-tts-flash-instruct',
        voice: 'Cherry',
        extraParams: {
          'instructions': '用温柔的语气慢慢读',
          'sampling': {'temperature': 0.5, 'nested': {'top_p': 0.8}},
          'language_type': 'English',
        },
      ),
      apiKey: 'sk-dashscope',
      text: '晚安。',
    );

    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'qwen3-tts-flash-instruct');
    expect(body['input'], {
      // 基础字段保留，extraParams 的标量覆盖同名字段。
      'text': '晚安。',
      'voice': 'Cherry',
      'language_type': 'English',
      'instructions': '用温柔的语气慢慢读',
      'sampling': {'temperature': 0.5, 'nested': {'top_p': 0.8}},
    });
    // 高级参数只合并进 input，不落到请求体顶层。
    expect(body.containsKey('instructions'), isFalse);
    expect(body.containsKey('sampling'), isFalse);
  });

  test('URL 缺失或无效按内容解析失败拒绝，不出下载网', () async {
    final bodies = <Map<String, Object?>>[
      {'request_id': 'req-1'},
      {'output': {}},
      {'output': {'audio': {}}},
      {
        'output': {
          'audio': {'url': 123},
        },
      },
      {
        'output': {
          'audio': {'url': '   '},
        },
      },
      {
        'output': {
          'audio': {'url': 'ftp://oss.example.com/a.mp3'},
        },
      },
      {
        'output': {
          'audio': {'url': 'example.com/a.mp3'},
        },
      },
    ];
    for (final body in bodies) {
      final client = _RecordingBytesHttpClient(postResponse: jsonBody(body));
      await expectLater(
        TtsModelGateway(
          client,
        ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
        throwsA(
          isA<TtsGatewayException>()
              .having(
                (error) => error.kind,
                'kind',
                ModelFailureKind.contentParsing,
              )
              .having(
                (error) => error.message,
                'message',
                '语音合成服务没有返回有效的音频地址。',
              ),
        ),
        reason: jsonEncode(body),
      );
      expect(client.downloadCalled, isFalse, reason: jsonEncode(body));
    }
  });

  test('响应不是合法 JSON 时按没有有效音频地址拒绝，不出下载网', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode('<html>gateway error</html>')),
      ),
    );

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>()
            .having(
              (error) => error.kind,
              'kind',
              ModelFailureKind.contentParsing,
            )
            .having(
              (error) => error.message,
              'message',
              '语音合成服务没有返回有效的音频地址。',
            ),
      ),
    );
    expect(client.downloadCalled, isFalse);
  });

  test('下载跳内网字面量 URL 拒绝、公网放行', () async {
    final refused = [
      'http://127.0.0.1:8080/a.mp3',
      'http://localhost/a.mp3',
      'http://192.168.1.5/a.mp3',
      'http://10.0.0.9/a.mp3',
      'http://[::1]/a.mp3',
    ];
    for (final url in refused) {
      final client = _RecordingBytesHttpClient(postResponse: urlResponse(url));
      await expectLater(
        TtsModelGateway(
          client,
        ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
        throwsA(
          isA<TtsGatewayException>()
              .having((error) => error.kind, 'kind', ModelFailureKind.provider)
              .having(
                (error) => error.message,
                'message',
                '语音服务地址不允许指向本机或内网。',
              ),
        ),
        reason: url,
      );
      expect(client.downloadCalled, isFalse, reason: url);
    }

    // 公网地址放行（含地域 CDN 域名与查询串签名）。
    final allowed = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://dashscope-oss.aliyuncs.com/a.mp3?x=1'),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([5]),
      ),
    );
    expect(
      await TtsModelGateway(
        allowed,
      ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
      [5],
    );
    expect(allowed.downloadCalled, isTrue);
  });

  test('下载失败按现有分类上报：404 服务拒绝、超时', () async {
    final rejected = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/a.mp3'),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: HttpStatus.notFound,
        body: Stream.value(utf8.encode('denied')),
      ),
    );
    await expectLater(
      TtsModelGateway(
        rejected,
      ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.provider)
            .having(
              (error) => error.message,
              'message',
              '语音合成服务拒绝了这次请求。',
            ),
      ),
    );

    final slow = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/a.mp3'),
      downloadError: TimeoutException('slow'),
    );
    await expectLater(
      TtsModelGateway(
        slow,
      ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.timeout,
        ),
      ),
    );

    final interrupted = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/a.mp3'),
      downloadError: const SocketException('connection failed'),
    );
    await expectLater(
      TtsModelGateway(
        interrupted,
      ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.network)
            .having((error) => error.message, 'message', '无法连接语音合成服务。'),
      ),
    );
  });

  test('非 2xx 合成响应按错误分类上报：401 鉴权、404 模型不存在，不出下载网', () async {
    final unauthorized = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: HttpStatus.unauthorized,
        body: Stream.value(utf8.encode('{"code":"InvalidApiKey"}')),
      ),
    );
    await expectLater(
      TtsModelGateway(
        unauthorized,
      ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.authentication,
        ),
      ),
    );
    expect(unauthorized.downloadCalled, isFalse);

    final missingModel = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: HttpStatus.notFound,
        body: Stream.value(utf8.encode('{"message":"model not found"}')),
      ),
    );
    await expectLater(
      TtsModelGateway(
        missingModel,
      ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.modelNotFound,
        ),
      ),
    );
    expect(missingModel.downloadCalled, isFalse);
  });

  test('空 Key 与脏 Key 前置拦截，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: '   ', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.authentication,
        ),
      ),
    );
    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'sk-key\u200B', text: '晚安。'),
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
    expect(client.postCalled, isFalse);
    expect(client.downloadCalled, isFalse);
  });

  test('合成端点指向环回按 SSRF 拒绝，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(client).synthesize(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'http://127.0.0.1:8080/api/v1',
          model: qwenTtsDefaultModel,
        ),
        apiKey: 'sk-dashscope',
        text: '晚安。',
      ),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.provider)
            .having(
              (error) => error.message,
              'message',
              '语音服务地址不允许指向本机或内网。',
            ),
      ),
    );
    expect(client.postCalled, isFalse);
    expect(client.downloadCalled, isFalse);
  });

  test('合成出网超时按超时分类上报', () async {
    final client = _RecordingBytesHttpClient(
      postError: TimeoutException('slow'),
    );

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'sk-dashscope', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.timeout,
        ),
      ),
    );
  });
}

final class _RecordingBytesHttpClient implements ProviderBytesHttpClient {
  _RecordingBytesHttpClient({
    this.postResponse,
    this.downloadResponse,
    this.postError,
    this.downloadError,
  });

  final ProviderBytesHttpResponse? postResponse;
  final ProviderBytesHttpResponse? downloadResponse;
  final Object? postError;
  final Object? downloadError;

  bool postCalled = false;
  bool downloadCalled = false;
  late Uri uri;
  late Map<String, String> headers;
  late List<int> bytesBody;
  late Uri downloadUri;
  late Duration downloadTimeout;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    postCalled = true;
    this.uri = uri;
    this.headers = headers;
    bytesBody = body;
    if (postError case final failure?) {
      throw failure;
    }
    return postResponse!;
  }

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) async {
    downloadCalled = true;
    downloadUri = uri;
    downloadTimeout = timeout;
    if (downloadError case final failure?) {
      throw failure;
    }
    return downloadResponse!;
  }
}
