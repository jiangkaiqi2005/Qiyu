import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
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

  // ─── 地址派形状（ADR 0020）新增用例 ────────────────────────────────
  // qwen_tts 档按地址派形状：主机含 maas.aliyuncs.com 走 3.1 官方
  // SpeechSynthesizer 形状（CosyVoice 家族请求体），否则走上方用例锁定
  // 的现行 multimodal 形状（那些用例逐字不动）。3.1 SSE 逐块形状未实
  // 测（前置实测无可用通路），首版只接整段：流式接口按 E1 降级。
  const maasEndpoint =
      'https://ws-12345.cn-beijing.maas.aliyuncs.com'
      '/api/v1/services/audio/tts/SpeechSynthesizer';
  TtsConfig maasConfig({String? voice, Map<String, Object?>? extraParams}) =>
      TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: maasEndpoint,
        model: 'qwen-audio-3.1-tts-flash',
        voice: voice,
        extraParams: extraParams,
      );

  group('地址派形状分派判定：主机含 maas.aliyuncs.com 走 3.1 新形状', () {
    test('官方模板主机（业务空间子域）判定为新形状', () {
      expect(qwenTtsUsesMaasShape(Uri.parse(maasEndpoint)), isTrue);
    });

    test('现行端点与陌生主机判定为现行形状', () {
      expect(qwenTtsUsesMaasShape(Uri.parse(qwenTtsDefaultEndpoint)), isFalse);
      expect(
        qwenTtsUsesMaasShape(
          Uri.parse(
            'https://dashscope.aliyuncs.com'
            '/api/v1/services/audio/tts/SpeechSynthesizer',
          ),
        ),
        isFalse,
      );
      expect(
        qwenTtsUsesMaasShape(Uri.parse('https://oss.example.com/a.wav')),
        isFalse,
      );
    });

    test('主机大小写不敏感', () {
      expect(
        qwenTtsUsesMaasShape(
          Uri.parse('https://WS-12345.CN-BEIJING.MAAS.ALIYUNCS.COM/api/v1'),
        ),
        isTrue,
      );
    });

    test('端口与路径变体不改变判定：分派只认主机', () {
      expect(
        qwenTtsUsesMaasShape(
          Uri.parse('https://ws.cn-beijing.maas.aliyuncs.com:8443/other'),
        ),
        isTrue,
      );
      expect(
        qwenTtsUsesMaasShape(
          Uri.parse('https://ws.cn-beijing.maas.aliyuncs.com'),
        ),
        isTrue,
      );
      // 路径里出现同形字样不算：主机不含该后缀即现行形状。
      expect(
        qwenTtsUsesMaasShape(
          Uri.parse('https://dashscope.aliyuncs.com/maas.aliyuncs.com'),
        ),
        isFalse,
      );
    });

    test('lookalike 主机按「主机含」语义派新形状（现语义钉死）', () {
      // 分派只改请求体形状：出网目标仍是用户填的地址、SSRF 校验照查，
      // 错形状落既有 400 分类（ADR 0015）——与识别档 path.contains 先例
      // 同语义，不收紧为精确后缀匹配。票 03 的映射表建议落位判定
      // （qwen_tts 档 3.x 型号是否已配新版地址）也是本判定的消费者，
      // lookalike 误判后果同性质：少给一条建议或按现语义派形状，不出网。
      expect(
        qwenTtsUsesMaasShape(
          Uri.parse('https://maas.aliyuncs.com.evil.example/api/v1'),
        ),
        isTrue,
      );
      expect(
        qwenTtsUsesMaasShape(
          Uri.parse(
            'https://xmaas.aliyuncs.com'
            '/api/v1/services/audio/tts/SpeechSynthesizer',
          ),
        ),
        isTrue,
      );
    });
  });

  test('3.1 新形状：官方端点原样 POST，CosyVoice 家族请求体', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/qiyu.wav'),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([4, 5]),
      ),
    );

    final audio = await TtsModelGateway(client).synthesize(
      config: maasConfig(voice: 'longanhuan_v3.6'),
      apiKey: 'sk-bailian',
      text: '晚安。',
    );

    expect(audio, [4, 5]);
    // 官方完整地址整条使用：不拼后缀、不改写路径。
    expect(client.uri.toString(), maasEndpoint);
    expect(client.headers['authorization'], 'Bearer sk-bailian');
    expect(client.headers['content-type'], 'application/json');
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'qwen-audio-3.1-tts-flash');
    // CosyVoice 家族形状：text/voice/format/sample_rate（probe 实测的
    // 官方请求体），无现行形状的 language_type。
    expect(body['input'], {
      'text': '晚安。',
      'voice': 'longanhuan_v3.6',
      'format': 'wav',
      'sample_rate': 24000,
    });
  });

  test('3.1 新形状：音色空缺回落本家族官方示例音色', () async {
    for (final voice in [null, '   ']) {
      final client = _RecordingBytesHttpClient(
        postResponse: urlResponse('https://oss.example.com/a.wav'),
        downloadResponse: ProviderBytesHttpResponse(
          statusCode: 200,
          body: Stream.value([1]),
        ),
      );
      await TtsModelGateway(client).synthesize(
        config: maasConfig(voice: voice),
        apiKey: 'sk-bailian',
        text: '嗯。',
      );
      final body =
          jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
      expect(
        (body['input']! as Map<String, Object?>)['voice'],
        qwenTtsMaasDefaultVoice,
        reason: 'voice=$voice',
      );
    }
  });

  test('3.1 新形状：extraParams 深合并进 input，官方新增字段透传且可覆盖缺省', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/a.wav'),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1]),
      ),
    );

    await TtsModelGateway(client).synthesize(
      config: maasConfig(
        voice: 'longanhuan_v3.6',
        extraParams: const {
          'instruction': '用温柔的语气慢慢读',
          'format': 'mp3',
          'sample_rate': 16000,
        },
      ),
      apiKey: 'sk-bailian',
      text: '晚安。',
    );

    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['input'], {
      'text': '晚安。',
      'voice': 'longanhuan_v3.6',
      // 用户显式写的格式类字段覆盖协议缺省（与现行形状合并语义同源）。
      'format': 'mp3',
      'sample_rate': 16000,
      'instruction': '用温柔的语气慢慢读',
    });
    // 高级参数只合并进 input，不落到请求体顶层。
    expect(body.containsKey('instruction'), isFalse);
    expect(body.containsKey('format'), isFalse);
  });

  test('3.1 新形状：响应音频地址走既有下载跳（同级预算、内存返回）', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: urlResponse(
        'https://dashscope-oss.aliyuncs.com/a.wav?Expires=1893456000&Signature=abc',
      ),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([7, 8]),
      ),
    );

    final audio = await TtsModelGateway(client).synthesize(
      config: maasConfig(voice: 'longanhuan_v3.6'),
      apiKey: 'sk-bailian',
      text: '晚安。',
    );

    expect(audio, [7, 8]);
    expect(client.downloadCalled, isTrue);
    expect(
      client.downloadUri.toString(),
      'https://dashscope-oss.aliyuncs.com/a.wav?Expires=1893456000&Signature=abc',
    );
    // 下载与合成请求同级预算；不带鉴权头是通道的结构性决定（getBytes
    // 无 headers 形参），在下方真实客户端用例里钉死。
    expect(client.downloadTimeout, ttsRequestTimeout);
  });

  test('3.1 新形状：返回的音频地址指向内网时被拒，不出下载网', () async {
    for (final url in [
      'http://127.0.0.1:9000/a.wav',
      'http://192.168.1.5/a.wav',
      'http://[::1]/a.wav',
    ]) {
      final client = _RecordingBytesHttpClient(postResponse: urlResponse(url));
      await expectLater(
        TtsModelGateway(client).synthesize(
          config: maasConfig(voice: 'longanhuan_v3.6'),
          apiKey: 'sk-bailian',
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
  });

  test('3.1 新形状：响应没有有效音频地址按内容解析失败拒绝，不出下载网', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: jsonBody({'request_id': 'req-31-1'}),
    );

    await expectLater(
      TtsModelGateway(client).synthesize(
        config: maasConfig(voice: 'longanhuan_v3.6'),
        apiKey: 'sk-bailian',
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
              '语音合成服务没有返回有效的音频地址。',
            ),
      ),
    );
    expect(client.downloadCalled, isFalse);
  });

  test('3.1 新形状：非 2xx 落进既有分类（url error 归模型与接口不匹配），不出下载网', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: HttpStatus.badRequest,
        body: Stream.value(
          utf8.encode(
            '{"code":"InvalidParameter","message":"url error, please check url！"}',
          ),
        ),
      ),
    );

    await expectLater(
      TtsModelGateway(client).synthesize(
        config: maasConfig(voice: 'longanhuan_v3.6'),
        apiKey: 'sk-bailian',
        text: '晚安。',
      ),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.modelInterfaceMismatch,
        ),
      ),
    );
    expect(client.downloadCalled, isFalse);
  });

  test('3.1 新形状流式接口按 E1 降级：整段合成收成一个完整容器块，不发 SSE 请求', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: urlResponse('https://oss.example.com/qiyu.wav'),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1, 2, 3]),
      ),
    );

    final chunks = await TtsModelGateway(client)
        .synthesizeStream(
          config: maasConfig(voice: 'longanhuan_v3.6'),
          apiKey: 'sk-bailian',
          text: '晚安。',
        )
        .toList();

    expect(chunks, hasLength(1));
    expect(chunks.single.isWhole, isTrue);
    expect(chunks.single.mimeType, voiceWholeContainerMime);
    expect(chunks.single.bytes, [1, 2, 3]);
    // 走整段路径：不带 SSE 开关（3.1 流式形状未实测，不赌），请求体是
    // 新形状而非现行 multimodal 形状。
    expect(client.headers.containsKey('X-DashScope-SSE'), isFalse);
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'qwen-audio-3.1-tts-flash');
    expect(
      (body['input']! as Map<String, Object?>).containsKey('language_type'),
      isFalse,
    );
  });

  test('下载跳通道钉死：真实客户端不跟重定向、不带鉴权头', () async {
    // 内网校验会拦住本机假服务器，重定向行为没法用真实回环请求观察；
    // 改在 dart:io 客户端注入层钉死：getBytes 发出的请求必须显式关掉
    // followRedirects（重定向目标会绕开下载前的内网校验，ADR 0014），
    // 且不写任何鉴权头。
    final ioClient = _RedirectProbeIoClient();
    final client = DartIoProviderHttpClient(httpClientFactory: (_) => ioClient);

    final response = await client.getBytes(
      uri: Uri.parse('https://oss.example.com/qiyu.wav'),
      timeout: ttsRequestTimeout,
    );
    await response.body.drain<void>();

    final request = ioClient.lastRequest;
    expect(request, isNotNull);
    // dart:io 的 HttpClientRequest 缺省跟随重定向，通道必须显式关掉。
    expect(request!.followRedirects, isFalse);
    expect(
      request.recordedHeaders.written.containsKey('authorization'),
      isFalse,
    );
  });

  test('3.1 降级路径慢两跳（40s+40s）不被外层空闲计时提前砍掉', () {
    // 降级路径不套 guardTtsAudioStream 的外层空闲计时：首块要等合成
    // POST 与下载跳两跳串行，若套了单跳 60s 计时，合法慢两跳会在第
    // 60 秒被砍。真实时钟测不了 80s 的预算，用假时钟锁行为。
    fakeAsync((async) {
      final client = _DelayedBytesHttpClient(
        postDelay: const Duration(seconds: 40),
        downloadDelay: const Duration(seconds: 40),
        postResponse: urlResponse('https://oss.example.com/qiyu.wav'),
        downloadResponse: ProviderBytesHttpResponse(
          statusCode: 200,
          body: Stream.value([1, 2]),
        ),
      );
      final chunks = <VoiceAudioChunk>[];
      final errors = <Object>[];
      var done = false;
      TtsModelGateway(client)
          .synthesizeStream(
            config: maasConfig(voice: 'longanhuan_v3.6'),
            apiKey: 'sk-bailian',
            text: '晚安。',
          )
          .listen(chunks.add, onError: errors.add, onDone: () => done = true);

      // 80s 时首块（也是唯一一块）应已到达：若外层仍按单跳 60s 计时，
      // 60s 处就会报超时、80s 的块永远收不到。
      async.elapse(const Duration(seconds: 80));
      expect(errors, isEmpty);
      expect(done, isTrue);
      expect(chunks, hasLength(1));
      expect(chunks.single.isWhole, isTrue);
      expect(chunks.single.bytes, [1, 2]);
      // 外层放宽不放松单跳：两跳各自仍按单跳预算出网。
      expect(client.postTimeout, ttsRequestTimeout);
      expect(client.downloadTimeout, ttsRequestTimeout);
    });
  });

  test('3.1 降级路径单跳卡死仍按单跳预算报超时，不等外层两跳合计', () {
    fakeAsync((async) {
      // 模拟真实 HTTP 客户端：连接卡死到自己的 timeout 预算即抛。
      final client = _DelayedBytesHttpClient(simulateHopTimeout: true);
      final chunks = <VoiceAudioChunk>[];
      final errors = <Object>[];
      TtsModelGateway(client)
          .synthesizeStream(
            config: maasConfig(voice: 'longanhuan_v3.6'),
            apiKey: 'sk-bailian',
            text: '晚安。',
          )
          .listen(chunks.add, onError: errors.add);

      // 内层单跳预算（60s）先于外层合计（120s）触发：59s 未报、61s 已报。
      async.elapse(const Duration(seconds: 59));
      expect(errors, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(chunks, isEmpty);
      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.timeout)
            .having(
              (error) => error.message,
              'message',
              '连接语音合成服务超时。',
            ),
      );
    });
  });
}

/// 假时钟用延迟客户端：POST/GET 各自按给定延迟返回；[simulateHopTimeout]
/// 为真时模拟真实 HTTP 客户端「连接卡死到自己的 timeout 预算即抛
/// TimeoutException」的行为（内层单跳预算的触发器）。
final class _DelayedBytesHttpClient implements ProviderBytesHttpClient {
  _DelayedBytesHttpClient({
    this.postDelay = Duration.zero,
    this.downloadDelay = Duration.zero,
    this.simulateHopTimeout = false,
    this.postResponse,
    this.downloadResponse,
  });

  final Duration postDelay;
  final Duration downloadDelay;
  final bool simulateHopTimeout;
  final ProviderBytesHttpResponse? postResponse;
  final ProviderBytesHttpResponse? downloadResponse;

  late Duration postTimeout;
  late Duration downloadTimeout;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) {
    postTimeout = timeout;
    if (simulateHopTimeout) {
      return Future.delayed(timeout, () => throw TimeoutException('post'));
    }
    return Future.delayed(postDelay, () => postResponse!);
  }

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) {
    downloadTimeout = timeout;
    if (simulateHopTimeout) {
      return Future.delayed(timeout, () => throw TimeoutException('download'));
    }
    return Future.delayed(downloadDelay, () => downloadResponse!);
  }
}

final class _RedirectProbeIoClient implements HttpClient {
  @override
  Duration? connectionTimeout;
  _RedirectProbeRequest? lastRequest;

  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final request = _RedirectProbeRequest();
    lastRequest = request;
    return request;
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RedirectProbeRequest implements HttpClientRequest {
  final _RecordingHttpHeaders recordedHeaders = _RecordingHttpHeaders();

  // dart:io 缺省为 true：通道必须显式置 false，测试才锁得住。
  @override
  bool followRedirects = true;

  @override
  HttpHeaders get headers => recordedHeaders;

  @override
  Future<HttpClientResponse> close() async => _EmptyBytesResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordingHttpHeaders implements HttpHeaders {
  final Map<String, String> written = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      written[name.toLowerCase()] = '$value';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _EmptyBytesResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  final int statusCode = 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> data)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<List<int>>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
