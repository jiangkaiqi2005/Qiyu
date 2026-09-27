import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

/// 自定义语音合成服务（custom）网关：完整地址直填、请求体固定
/// {model, input}、高级参数深合并、鉴权头拼接与回落、三种响应形态
/// （裸音频字节 / JSON 字段含 URL 自动下载 / 逐行 JSON 拼接）、坏响应
/// 分类与出网前校验。记录型假二进制客户端与千问合成网关测试同构
/// （postBytes 与 getBytes 分别留档）。
void main() {
  TtsConfig configWith({
    String baseUrl = 'https://tts.example.com/v1/audio/speech',
    String model = 'tts-test',
    String? authHeader,
    TtsResponseShape? responseShape,
    String responseField = 'data',
    Map<String, Object?>? extraParams,
  }) => TtsConfig(
    provider: TtsProviderKind.custom,
    baseUrl: baseUrl,
    model: model,
    authHeader: authHeader,
    responseShape: responseShape ?? TtsResponseShape.rawBytes,
    responseField: responseField,
    extraParams: extraParams,
  );

  ProviderBytesHttpResponse jsonBody(Map<String, Object?> body) =>
      ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode(jsonEncode(body))),
      );

  /// 字段里是 base64 音频的 JSON 合成响应（json_field 与 json_lines 两种
  /// 形态最常见形状）。
  ProviderBytesHttpResponse base64Response(
    List<int> audio, {
    String field = 'data',
  }) => jsonBody({field: base64Encode(audio)});

  test('请求形状：完整地址原样使用、body 固定 {model, input}、默认 Bearer 鉴权', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1, 2, 3]),
      ),
    );

    final audio = await TtsModelGateway(
      client,
    ).synthesize(config: configWith(), apiKey: ' sk-tts ', text: '晚安。');

    expect(audio, [1, 2, 3]);
    expect(client.timeout, ttsRequestTimeout);
    // 用户填的完整地址就是端点：不拼 audio/speech 后缀。
    expect(client.uri.toString(), 'https://tts.example.com/v1/audio/speech');
    expect(client.headers['authorization'], 'Bearer sk-tts');
    expect(client.headers['content-type'], 'application/json');
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'tts-test');
    // 请求体固定两字段：input 里只有 text，没有音色/语速这类档位旋钮。
    expect(body['input'], {'text': '晚安。'});
    expect(body.keys.toSet(), {'model', 'input'});
  });

  test('extraParams 深合并进 input：嵌套对象原样落进 input 且可覆盖基础字段', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1]),
      ),
    );

    await TtsModelGateway(client).synthesize(
      config: configWith(
        extraParams: {
          'voice': 'custom-voice',
          'sampling': {'temperature': 0.5, 'nested': {'top_p': 0.8}},
          'text': '覆盖',
        },
      ),
      apiKey: 'sk-tts',
      text: '晚安。',
    );

    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'tts-test');
    expect(body['input'], {
      'text': '覆盖',
      'voice': 'custom-voice',
      'sampling': {'temperature': 0.5, 'nested': {'top_p': 0.8}},
    });
    // 高级参数只合并进 input，不落到请求体顶层。
    expect(body.containsKey('voice'), isFalse);
    expect(body.containsKey('sampling'), isFalse);
  });

  test('raw_bytes 形态：响应体原样当音频，空体按没有返回音频拒绝', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        // 分块流：验证读完全量字节再返回，不停在第一块。
        body: Stream.fromIterable([
          [9, 8],
          [7],
        ]),
      ),
    );
    expect(
      await TtsModelGateway(
        client,
      ).synthesize(config: configWith(), apiKey: 'sk-tts', text: '晚安。'),
      [9, 8, 7],
    );

    final empty = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: const Stream.empty(),
      ),
    );
    await expectLater(
      TtsModelGateway(
        empty,
      ).synthesize(config: configWith(), apiKey: 'sk-tts', text: '晚安。'),
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
              '语音合成服务没有返回音频。',
            ),
      ),
    );
  });

  test('json_field 形态：缺省字段 data 取 base64 解，自定义字段名与空白回落', () async {
    final defaultField = _RecordingBytesHttpClient(
      postResponse: base64Response([1, 2, 3]),
    );
    expect(
      await TtsModelGateway(defaultField).synthesize(
        config: configWith(responseShape: TtsResponseShape.jsonField),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
      [1, 2, 3],
    );
    expect(defaultField.downloadCalled, isFalse);

    final customField = _RecordingBytesHttpClient(
      postResponse: base64Response([4, 5], field: 'audio'),
    );
    expect(
      await TtsModelGateway(customField).synthesize(
        config: configWith(
          responseShape: TtsResponseShape.jsonField,
          responseField: 'audio',
        ),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
      [4, 5],
    );

    // 空白字段名回落缺省 data：与 STT 侧字段路径归一同律。
    final blankField = _RecordingBytesHttpClient(
      postResponse: base64Response([6]),
    );
    expect(
      await TtsModelGateway(blankField).synthesize(
        config: configWith(
          responseShape: TtsResponseShape.jsonField,
          responseField: '   ',
        ),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
      [6],
    );
  });

  test('json_field 形态：值是 http(s) 地址时经下载通道取回完整音频', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: jsonBody({
        'data': 'https://oss.example.com/audio/qiyu.mp3?Expires=1&Signature=abc',
      }),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          [1, 2],
          [3],
        ]),
      ),
    );

    final audio = await TtsModelGateway(client).synthesize(
      config: configWith(responseShape: TtsResponseShape.jsonField),
      apiKey: 'sk-tts',
      text: '晚安。',
    );

    expect(audio, [1, 2, 3]);
    expect(client.downloadCalled, isTrue);
    expect(
      client.downloadUri.toString(),
      'https://oss.example.com/audio/qiyu.mp3?Expires=1&Signature=abc',
    );
    expect(client.downloadTimeout, ttsRequestTimeout);
  });

  test('json_field 形态：URL 走内网校验，下载失败按现有分类上报', () async {
    final refused = [
      'http://127.0.0.1:8080/a.mp3',
      'http://localhost/a.mp3',
      'http://192.168.1.5/a.mp3',
      'http://10.0.0.9/a.mp3',
    ];
    for (final url in refused) {
      final client = _RecordingBytesHttpClient(
        postResponse: jsonBody({'data': url}),
      );
      await expectLater(
        TtsModelGateway(client).synthesize(
          config: configWith(responseShape: TtsResponseShape.jsonField),
          apiKey: 'sk-tts',
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
        reason: url,
      );
      expect(client.downloadCalled, isFalse, reason: url);
    }

    // 下载跳失败（404）按服务拒绝分类，不透出服务商原文。
    final rejected = _RecordingBytesHttpClient(
      postResponse: jsonBody({'data': 'https://oss.example.com/a.mp3'}),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: HttpStatus.notFound,
        body: Stream.value(utf8.encode('denied')),
      ),
    );
    await expectLater(
      TtsModelGateway(rejected).synthesize(
        config: configWith(responseShape: TtsResponseShape.jsonField),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
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

    // 下载跳超时按超时分类，预算与合成同级。
    final slow = _RecordingBytesHttpClient(
      postResponse: jsonBody({'data': 'https://oss.example.com/a.mp3'}),
      downloadError: TimeoutException('slow'),
    );
    await expectLater(
      TtsModelGateway(slow).synthesize(
        config: configWith(responseShape: TtsResponseShape.jsonField),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.timeout,
        ),
      ),
    );
  });

  test('json_field 形态：坏响应（非 JSON/缺字段/非字符串/坏 base64）按解析失败', () async {
    final scenarios = [
      (field: 'data', body: 'oops'),
      (field: 'data', body: '["不是对象"]'),
      (field: 'data', body: '{"other":"x"}'),
      (field: 'data', body: '{"data":123}'),
      (field: 'data', body: '{"data":null}'),
      (field: 'data', body: '{"data":"!!不是base64!!"}'),
      (field: 'data', body: '{"data":""}'),
    ];
    for (final scenario in scenarios) {
      final client = _RecordingBytesHttpClient(
        postResponse: ProviderBytesHttpResponse(
          statusCode: 200,
          body: Stream.value(utf8.encode(scenario.body)),
        ),
      );
      await expectLater(
        TtsModelGateway(client).synthesize(
          config: configWith(responseShape: TtsResponseShape.jsonField),
          apiKey: 'sk-tts',
          text: '晚安。',
        ),
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
                // 空 base64 解出空字节按没有音频，其余按内容无法解析。
                scenario.body == '{"data":""}'
                    ? '语音合成服务没有返回音频。'
                    : '语音合成服务返回的内容无法解析。',
              ),
        ),
        reason: scenario.body,
      );
      expect(client.downloadCalled, isFalse, reason: scenario.body);
    }
  });

  test('json_lines 形态：逐行 JSON 的 base64 按序拼接，空行跳过', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(
          utf8.encode(
            '{"data":"${base64Encode([1])}"}\n'
            '\n'
            '{"data":"${base64Encode([2, 3])}"}\n'
            '\n',
          ),
        ),
      ),
    );

    expect(
      await TtsModelGateway(client).synthesize(
        config: configWith(responseShape: TtsResponseShape.jsonLines),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
      [1, 2, 3],
    );

    // 自定义字段名按所填字段取；空白字段名回落缺省 data。
    final customField = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode('{"chunk":"${base64Encode([7])}"}\n')),
      ),
    );
    expect(
      await TtsModelGateway(customField).synthesize(
        config: configWith(
          responseShape: TtsResponseShape.jsonLines,
          responseField: 'chunk',
        ),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
      [7],
    );

    final blankField = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode('{"data":"${base64Encode([8])}"}\n')),
      ),
    );
    expect(
      await TtsModelGateway(blankField).synthesize(
        config: configWith(
          responseShape: TtsResponseShape.jsonLines,
          responseField: '   ',
        ),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
      [8],
    );
  });

  test('json_lines 形态：坏行与全空按解析失败/没有音频拒绝', () async {
    final badLine = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(
          utf8.encode(
            '{"data":"${base64Encode([1])}"}\n'
            'not-json\n',
          ),
        ),
      ),
    );
    await expectLater(
      TtsModelGateway(badLine).synthesize(
        config: configWith(responseShape: TtsResponseShape.jsonLines),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
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
              '语音合成服务返回的内容无法解析。',
            ),
      ),
    );

    final badField = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode('{"other":"x"}\n')),
      ),
    );
    await expectLater(
      TtsModelGateway(badField).synthesize(
        config: configWith(responseShape: TtsResponseShape.jsonLines),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.contentParsing,
        ),
      ),
    );

    // 整段只有空行：拼不出音频，按没有返回音频拒绝。
    final allEmpty = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode('\n\n')),
      ),
    );
    await expectLater(
      TtsModelGateway(allEmpty).synthesize(
        config: configWith(responseShape: TtsResponseShape.jsonLines),
        apiKey: 'sk-tts',
        text: '晚安。',
      ),
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
              '语音合成服务没有返回音频。',
            ),
      ),
    );
  });

  test('鉴权头可配：整行头名拼 Key，Authorization: Bearer 与 X-Api-Key 两例', () async {
    final scenarios = [
      (authHeader: 'Authorization: Bearer', name: 'authorization', value: 'Bearer sk-tts'),
      (authHeader: 'X-Api-Key', name: 'x-api-key', value: 'sk-tts'),
      (authHeader: 'Authorization:Bearer', name: 'authorization', value: 'Bearer sk-tts'),
    ];
    for (final scenario in scenarios) {
      final client = _RecordingBytesHttpClient(
        postResponse: ProviderBytesHttpResponse(
          statusCode: 200,
          body: Stream.value([1]),
        ),
      );

      await TtsModelGateway(client).synthesize(
        config: configWith(authHeader: scenario.authHeader),
        apiKey: 'sk-tts',
        text: '晚安。',
      );

      expect(
        client.headers[scenario.name],
        scenario.value,
        reason: scenario.authHeader,
      );
    }
  });

  test('鉴权头留空回落默认 Bearer：不允许无鉴权出网', () async {
    for (final authHeader in [null, '', '   ']) {
      final client = _RecordingBytesHttpClient(
        postResponse: ProviderBytesHttpResponse(
          statusCode: 200,
          body: Stream.value([1]),
        ),
      );

      await TtsModelGateway(client).synthesize(
        config: configWith(authHeader: authHeader),
        apiKey: 'sk-tts',
        text: '晚安。',
      );

      expect(
        client.headers['authorization'],
        'Bearer sk-tts',
        reason: '$authHeader',
      );
      // 回落只发生在默认头上：不会凭空多出别的头。
      expect(
        client.headers.keys.where((k) => k != 'content-type'),
        ['authorization'],
      );
    }
  });

  test('鉴权头名混入脏字符、空头名或保留头名在出网前按配置错误拒绝，不出网', () async {
    final scenarios = [
      (
        authHeader: 'X-Api-Key\u200B',
        message: '鉴权头里混入了中文或看不见的字符，请重新填写。',
      ),
      (
        authHeader: 'X-Api-Key 测试',
        message: '鉴权头里混入了中文或看不见的字符，请重新填写。',
      ),
      (
        authHeader: ': Bearer',
        message: '鉴权头格式不正确，请填写如 Authorization: Bearer 的头名。',
      ),
      // 保留头名撞名：content-type 会被网关自己写的 application/json 头
      // 静默覆盖（无鉴权出网），content-length 等由 dart:io 自管。
      (
        authHeader: 'Content-Type: Bearer',
        message: '鉴权头不能使用 Content-Type、Content-Length 这类保留头名，请重新填写。',
      ),
      (
        authHeader: 'content-length',
        message: '鉴权头不能使用 Content-Type、Content-Length 这类保留头名，请重新填写。',
      ),
      (
        authHeader: 'HOST: example.com',
        message: '鉴权头不能使用 Content-Type、Content-Length 这类保留头名，请重新填写。',
      ),
    ];
    for (final scenario in scenarios) {
      final client = _RecordingBytesHttpClient();

      await expectLater(
        TtsModelGateway(client).synthesize(
          config: configWith(authHeader: scenario.authHeader),
          apiKey: 'sk-tts',
          text: '晚安。',
        ),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            scenario.message,
          ),
        ),
        reason: scenario.authHeader,
      );
      expect(client.postCalled, isFalse, reason: scenario.authHeader);
      expect(client.downloadCalled, isFalse, reason: scenario.authHeader);
    }
  });

  test('空 Key 与脏 Key 前置拦截，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: configWith(), apiKey: '   ', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.authentication)
            .having(
              (error) => error.message,
              'message',
              '还没有保存语音合成服务的 API Key。',
            ),
      ),
    );
    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: configWith(), apiKey: 'sk-key\u200B', text: '晚安。'),
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

  test('非 2xx 与出网异常按语音合成服务文案分类且不回传服务商原文', () async {
    final scenarios = [
      (
        client: _RecordingBytesHttpClient(
          postResponse: ProviderBytesHttpResponse(
            statusCode: 401,
            body: Stream.value(utf8.encode('{"error":"bad sk-tts"}')),
          ),
        ),
        kind: ModelFailureKind.authentication,
        message: 'API Key 未通过语音合成服务验证。',
      ),
      (
        client: _RecordingBytesHttpClient(
          postResponse: ProviderBytesHttpResponse(
            statusCode: 429,
            body: Stream.value(utf8.encode('{}')),
          ),
        ),
        kind: ModelFailureKind.rateLimited,
        message: '语音合成服务请求过于频繁。',
      ),
      (
        client: _RecordingBytesHttpClient(
          postResponse: ProviderBytesHttpResponse(
            statusCode: 500,
            body: Stream.value(utf8.encode('{"error":"internal secret detail"}')),
          ),
        ),
        kind: ModelFailureKind.provider,
        message: '语音合成服务拒绝了这次请求。',
      ),
      (
        client: _RecordingBytesHttpClient(
          postError: const SocketException(
            'Failed host lookup',
            osError: OSError('host not found', 11001),
          ),
        ),
        kind: ModelFailureKind.dns,
        message: '找不到语音合成服务域名。',
      ),
      (
        client: _RecordingBytesHttpClient(postError: TimeoutException('slow')),
        kind: ModelFailureKind.timeout,
        message: '连接语音合成服务超时。',
      ),
    ];
    for (final scenario in scenarios) {
      await expectLater(
        TtsModelGateway(scenario.client).synthesize(
          config: configWith(),
          apiKey: 'sk-tts',
          text: '晚安。',
        ),
        throwsA(
          isA<TtsGatewayException>()
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

  test('SSRF 拒绝：自定义档指向环回/内网地址时在出网前抛错', () async {
    const targets = [
      'https://localhost/v1/audio/speech',
      'http://127.0.0.1:8080/speech',
      'https://10.1.2.3/speech',
      'https://192.168.0.2/speech',
    ];
    for (final baseUrl in targets) {
      final client = _RecordingBytesHttpClient();
      await expectLater(
        TtsModelGateway(client).synthesize(
          config: configWith(baseUrl: baseUrl),
          apiKey: 'sk-tts',
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
        reason: baseUrl,
      );
      expect(client.postCalled, isFalse, reason: baseUrl);
    }
  });

  test('协议分派：custom 配置打完整地址的 JSON，与千问档互不串档', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1]),
      ),
    );

    expect(
      await TtsModelGateway(client).synthesize(
        config: configWith(),
        apiKey: 'sk-tts',
        text: '分派',
      ),
      [1],
    );
    expect(client.postCalled, isTrue);
    expect(client.uri.toString(), 'https://tts.example.com/v1/audio/speech');
    expect(client.headers['authorization'], 'Bearer sk-tts');
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
  late Duration timeout;
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
    this.timeout = timeout;
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
