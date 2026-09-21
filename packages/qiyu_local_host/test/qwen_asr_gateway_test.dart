import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/recording_http_client.dart';

/// 千问语音识别（qwen_asr）网关：DashScope 多模态接口的两种请求形状、
/// 地址形状分派、文本提取与错误分类。记录型假 HTTP 客户端与转写网关
/// 测试共用（test/support/recording_http_client.dart）。
void main() {
  const nativeConfig = SttConfig(
    provider: SttProviderKind.qwenAsr,
    baseUrl:
        'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
    model: 'qwen3-asr-flash',
  );
  const compatibleConfig = SttConfig(
    provider: SttProviderKind.qwenAsr,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    model: 'qwen3-asr-flash',
  );

  Map<String, Object?> bodyOf(RecordingHttpClient client) =>
      jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;

  test('原生形状：端点原样使用、逐字段请求体、文本从 output 原生路径取出', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'output': {
              'choices': [
                {
                  'message': {
                    'content': [
                      {'text': '今天有点累'},
                    ],
                  },
                },
              ],
            },
            'request_id': 'req-native-1',
          }),
        ),
      ),
    );

    final text = await SttModelGateway(client).transcribe(
      config: nativeConfig,
      apiKey: ' sk-qwen ',
      audio: [1, 2, 3, 4],
      mimeType: 'audio/wav',
    );

    expect(text, '今天有点累');
    expect(client.timeout, const Duration(seconds: 60));
    expect(client.uri.toString(), nativeConfig.baseUrl);
    expect(client.headers['authorization'], 'Bearer sk-qwen');
    expect(client.headers['content-type'], 'application/json');
    // 逐字段比对：固定中文识别、文本规整关、data URL 的 mediatype 跟容器。
    expect(bodyOf(client), {
      'model': 'qwen3-asr-flash',
      'input': {
        'messages': [
          {
            'role': 'user',
            'content': [
              {'audio': 'data:audio/wav;base64,AQIDBA=='},
            ],
          },
        ],
      },
      'parameters': {
        'asr_options': {'language': 'zh', 'enable_itn': false},
      },
    });
  });

  test('兼容形状：地址路径带 /compatible-mode/ 时按兼容形状发送、文本从 choices 取出', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'choices': [
              {'message': {'content': '嗯，睡了'}},
            ],
          }),
        ),
      ),
    );

    final text = await SttModelGateway(client).transcribe(
      config: compatibleConfig,
      apiKey: 'sk-qwen',
      audio: [1, 2, 3, 4],
      mimeType: 'audio/wav',
    );

    expect(text, '嗯，睡了');
    // 兼容形状也不拼后缀：地址本身就是完整端点。
    expect(client.uri.toString(), compatibleConfig.baseUrl);
    expect(bodyOf(client), {
      'model': 'qwen3-asr-flash',
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'input_audio',
              'input_audio': {'data': 'data:audio/wav;base64,AQIDBA=='},
            },
          ],
        },
      ],
      'asr_options': {'language': 'zh', 'enable_itn': false},
    });
  });

  test('形状分派只看地址路径是否含 /compatible-mode/（前中后位都算）', () async {
    for (final scenario in [
      (url: 'https://dashscope.aliyuncs.com/compatible-mode/v1', compatible: true),
      (
        url: 'https://example.com/api/compatible-mode/v1/chat/completions',
        compatible: true,
      ),
      (
        url: 'https://example.com/compatible-mode/',
        compatible: true,
      ),
      (url: 'https://example.com/v1/chat/completions', compatible: false),
      (url: 'https://example.com/v1', compatible: false),
      // 只在前缀或 query 里出现都不算：判定只看 path。
      (url: 'https://compatible-mode.example.com/v1', compatible: false),
    ]) {
      final client = RecordingHttpClient(
        response: ProviderHttpResponse(
          statusCode: 200,
          body: Stream.value(
            jsonEncode({
              if (scenario.compatible)
                'choices': [
                  {'message': {'content': '兼容'}},
                ]
              else
                'output': {
                  'choices': [
                    {
                      'message': {
                        'content': [
                          {'text': '原生'},
                        ],
                      },
                    },
                  ],
                },
            }),
          ),
        ),
      );

      final text = await SttModelGateway(client).transcribe(
        config: SttConfig(
          provider: SttProviderKind.qwenAsr,
          baseUrl: scenario.url,
          model: 'qwen3-asr-flash',
        ),
        apiKey: 'sk-qwen',
        audio: [1],
        mimeType: 'audio/wav',
      );

      expect(text, scenario.compatible ? '兼容' : '原生', reason: scenario.url);
      final body = bodyOf(client);
      expect(
        body.containsKey('input'),
        !scenario.compatible,
        reason: '原生形状带 input/parameters：${scenario.url}',
      );
      expect(
        body.containsKey('asr_options'),
        scenario.compatible,
        reason: '兼容形状的 asr_options 在顶层：${scenario.url}',
      );
    }
  });

  test('文本提取按请求形状绑定：响应形状对不上按解析失败', () async {
    // 原生请求却回兼容形状的响应（顶层 choices）：不跨形状猜，按解析失败。
    final nativeRequestCompatibleResponse = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'choices': [
              {'message': {'content': '形状对不上'}},
            ],
          }),
        ),
      ),
    );
    await expectLater(
      SttModelGateway(nativeRequestCompatibleResponse).transcribe(
        config: nativeConfig,
        apiKey: 'sk-qwen',
        audio: [1],
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<SttGatewayException>()
            .having(
              (error) => error.kind,
              'kind',
              ModelFailureKind.contentParsing,
            )
            .having(
              (error) => error.message,
              'message',
              '语音服务返回的内容无法解析。',
            ),
      ),
    );

    // 兼容请求却回原生形状的响应（output.choices）：同样按解析失败。
    final compatibleRequestNativeResponse = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'output': {
              'choices': [
                {
                  'message': {
                    'content': [
                      {'text': '形状也对不上'},
                    ],
                  },
                },
              ],
            },
          }),
        ),
      ),
    );
    await expectLater(
      SttModelGateway(compatibleRequestNativeResponse).transcribe(
        config: compatibleConfig,
        apiKey: 'sk-qwen',
        audio: [1],
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<SttGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.contentParsing,
        ),
      ),
    );

    // 原生形状的 content 不是分块列表（是整段字符串）同样取不到文本。
    final nativeStringContent = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'output': {
              'choices': [
                {'message': {'content': '整段字符串'}},
              ],
            },
          }),
        ),
      ),
    );
    await expectLater(
      SttModelGateway(nativeStringContent).transcribe(
        config: nativeConfig,
        apiKey: 'sk-qwen',
        audio: [1],
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<SttGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.contentParsing,
        ),
      ),
    );
  });

  test('data URL 的 mediatype 跟随实际上送容器（webm/mp4/wav）', () async {
    for (final mimeType in ['audio/webm', 'audio/mp4', 'audio/wav']) {
      final client = RecordingHttpClient(
        response: ProviderHttpResponse(
          statusCode: 200,
          body: Stream.value(
            jsonEncode({
              'output': {
                'choices': [
                  {
                    'message': {
                      'content': [
                        {'text': '好'},
                      ],
                    },
                  },
                ],
              },
            }),
          ),
        ),
      );

      await SttModelGateway(client).transcribe(
        config: nativeConfig,
        apiKey: 'sk-qwen',
        audio: [1, 2, 3, 4],
        mimeType: mimeType,
      );

      final content =
          ((bodyOf(client)['input'] as Map<String, Object?>)['messages']
                  as List<Object?>)
              .cast<Map<String, Object?>>()
              .single['content'] as List<Object?>;
      expect(
        (content.single as Map<String, Object?>)['audio'],
        'data:$mimeType;base64,AQIDBA==',
      );
    }
  });

  test('空文本照实返回：空与失败的语义区分交给调用方', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'output': {
              'choices': [
                {
                  'message': {
                    'content': [
                      {'text': ''},
                    ],
                  },
                },
              ],
            },
          }),
        ),
      ),
    );

    expect(
      await SttModelGateway(client).transcribe(
        config: nativeConfig,
        apiKey: 'sk-qwen',
        audio: [0],
        mimeType: 'audio/wav',
      ),
      isEmpty,
    );
  });

  test('缺 Key 直接按鉴权失败拒绝，不出网', () async {
    final client = RecordingHttpClient();

    await expectLater(
      SttModelGateway(client).transcribe(
        config: nativeConfig,
        apiKey: '  ',
        audio: [0],
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<SttGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.authentication,
        ),
      ),
    );
    expect(client.called, isFalse);
  });

  test('Key 带零宽空格按粘贴事故拒绝，不出网', () async {
    final client = RecordingHttpClient();

    await expectLater(
      SttModelGateway(client).transcribe(
        config: nativeConfig,
        apiKey: 'sk-qwen\u200B',
        audio: [0],
        mimeType: 'audio/wav',
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

  test('地址与模型的脏配置在出网前按配置错误拒绝，不出网', () async {
    final client = RecordingHttpClient();

    // 配置脏字符的口径与 OpenAI 兼容档一致：ProviderConfigException，
    // 由服务层映射成 stt_config_invalid 的人话（见 stt_settings_service）。
    await expectLater(
      SttModelGateway(client).transcribe(
        config: const SttConfig(
          provider: SttProviderKind.qwenAsr,
          baseUrl: 'https://dashscope.aliyuncs.com/api/v1/\u200Bgeneration',
          model: 'qwen3-asr-flash',
        ),
        apiKey: 'sk-qwen',
        audio: [0],
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '语音服务地址里混入了中文或看不见的字符，请重新复制粘贴。',
        ),
      ),
    );
    expect(client.called, isFalse);

    // 模型名脏字符同理。
    await expectLater(
      SttModelGateway(client).transcribe(
        config: const SttConfig(
          provider: SttProviderKind.qwenAsr,
          baseUrl: qwenAsrDefaultEndpoint,
          model: 'qwen3-asr-flash测试',
        ),
        apiKey: 'sk-qwen',
        audio: [0],
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '语音服务的模型名称里混入了中文或看不见的字符，请重新填写。',
        ),
      ),
    );
    expect(client.called, isFalse);
  });

  test('非 2xx 与出网异常按语音服务文案分类且不回传服务商原文', () async {
    final scenarios = [
      (
        client: RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 401,
            body: Stream.value('{"code":"InvalidApiKey","message":"bad key"}'),
          ),
        ),
        kind: ModelFailureKind.authentication,
        message: 'API Key 未通过语音服务验证。',
      ),
      (
        client: RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 404,
            body: Stream.value('{"error":{"code":"model_not_found"}}'),
          ),
        ),
        kind: ModelFailureKind.modelNotFound,
        message: '模型名称不存在或当前账号不可用。',
      ),
      (
        client: RecordingHttpClient(
          response: ProviderHttpResponse(statusCode: 429, body: Stream.value('{}')),
        ),
        kind: ModelFailureKind.rateLimited,
        message: '语音服务请求过于频繁。',
      ),
      (
        client: RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 400,
            body: Stream.value('{"code":"InvalidParameter","message":"audio bad"}'),
          ),
        ),
        kind: ModelFailureKind.provider,
        message: '语音服务拒绝了这次请求。',
      ),
      (
        client: RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 200,
            body: Stream.value('<html>not json</html>'),
          ),
        ),
        kind: ModelFailureKind.contentParsing,
        message: '语音服务返回的内容无法解析。',
      ),
      (
        client: RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 200,
            body: Stream.value(jsonEncode({'output': {'choices': []}})),
          ),
        ),
        kind: ModelFailureKind.contentParsing,
        message: '语音服务返回的内容无法解析。',
      ),
      (
        client: RecordingHttpClient(
          error: const SocketException(
            'Failed host lookup',
            osError: OSError('host not found', 11001),
          ),
        ),
        kind: ModelFailureKind.dns,
        message: '找不到语音服务域名。',
      ),
      (
        client: RecordingHttpClient(error: HandshakeException('bad tls')),
        kind: ModelFailureKind.tls,
        message: '语音服务的 TLS 安全连接失败。',
      ),
      (
        client: RecordingHttpClient(error: TimeoutException('slow')),
        kind: ModelFailureKind.timeout,
        message: '连接语音服务超时。',
      ),
      (
        client: RecordingHttpClient(error: const SocketException('offline')),
        kind: ModelFailureKind.network,
        message: '无法连接语音服务。',
      ),
    ];
    for (final scenario in scenarios) {
      await expectLater(
        SttModelGateway(scenario.client).transcribe(
          config: nativeConfig,
          apiKey: 'sk-qwen',
          audio: [0],
          mimeType: 'audio/wav',
        ),
        throwsA(
          isA<SttGatewayException>()
              .having((error) => error.kind, 'kind', scenario.kind)
              .having((error) => error.message, 'message', scenario.message)
              .having(
                (error) => error.toString(),
                'redacted message',
                isNot(contains('bad key')),
              ),
        ),
        reason: scenario.kind.name,
      );
    }
  });

  test('SSRF 拒绝：千问档指向环回/内网地址时在出网前抛错', () async {
    const targets = [
      'https://localhost/api/v1',
      'https://127.0.0.1/api/v1',
      'https://10.1.2.3/api/v1',
      'https://192.168.0.2/api/v1',
    ];
    for (final baseUrl in targets) {
      final client = RecordingHttpClient();
      await expectLater(
        SttModelGateway(client).transcribe(
          config: SttConfig(
            provider: SttProviderKind.qwenAsr,
            baseUrl: baseUrl,
            model: 'qwen3-asr-flash',
          ),
          apiKey: 'sk-qwen',
          audio: [0],
          mimeType: 'audio/wav',
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

  test('响应带 request_id 时写本机诊断，不带正文与音频', () async {
    final lines = <String>[];
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'output': {
              'choices': [
                {
                  'message': {
                    'content': [
                      {'text': '诊断标记文本'},
                    ],
                  },
                },
              ],
            },
            'request_id': 'req-diag-7788',
          }),
        ),
      ),
    );

    await IOOverrides.runZoned(
      () async {
        expect(
          await SttModelGateway(client).transcribe(
            config: nativeConfig,
            apiKey: 'sk-qwen',
            audio: [1, 2, 3, 4],
            mimeType: 'audio/wav',
          ),
          '诊断标记文本',
        );
      },
      stderr: () => _CollectingStderr(lines),
    );

    expect(lines, hasLength(1));
    expect(lines.single, contains('req-diag-7788'));
    expect(lines.single, isNot(contains('诊断标记文本')));
    expect(lines.single, isNot(contains('sk-qwen')));
  });

  test('响应不带 request_id 时不写诊断', () async {
    final lines = <String>[];
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'choices': [
              {'message': {'content': '没有请求标识'}},
            ],
          }),
        ),
      ),
    );

    await IOOverrides.runZoned(
      () async {
        await SttModelGateway(client).transcribe(
          config: compatibleConfig,
          apiKey: 'sk-qwen',
          audio: [1],
          mimeType: 'audio/wav',
        );
      },
      stderr: () => _CollectingStderr(lines),
    );

    expect(lines, isEmpty);
  });

  test('协议分派：千问配置打 HTTP 多模态端点，豆包配置仍走 WebSocket', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'output': {
              'choices': [
                {
                  'message': {
                    'content': [
                      {'text': '分派'},
                    ],
                  },
                },
              ],
            },
          }),
        ),
      ),
    );

    expect(
      await SttModelGateway(client).transcribe(
        config: nativeConfig,
        apiKey: 'sk-qwen',
        audio: [1],
        mimeType: 'audio/wav',
      ),
      '分派',
    );
    expect(client.called, isTrue);
    expect(client.headers['authorization'], 'Bearer sk-qwen');
  });
}

/// 捕获 stderr 的假出口：只收 writeln 的行，供 request_id 诊断断言。
final class _CollectingStderr implements Stdout {
  _CollectingStderr(this._lines);

  final List<String> _lines;

  @override
  void writeln([Object? object = '']) => _lines.add('$object');

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable objects, [String sep = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> flush() async {}

  @override
  bool get hasTerminal => false;

  @override
  int get terminalColumns => 0;

  @override
  int get terminalLines => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
