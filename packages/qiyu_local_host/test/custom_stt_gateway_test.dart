import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/recording_http_client.dart';

/// 自定义转写服务（custom）网关：完整地址直填、multipart 表单构造、
/// 高级参数作额外表单字段、两种响应形态、鉴权头拼接与回落、空文本
/// 语义与出网前校验。记录型假 HTTP 客户端与转写网关测试共用
/// （test/support/recording_http_client.dart）。
void main() {
  SttConfig configWith({
    String baseUrl = 'https://stt.example.com/v1/audio/transcriptions',
    String model = 'whisper-test',
    String? authHeader,
    SttResponseShape? responseShape,
    String responseField = 'text',
    Map<String, Object?>? extraParams,
  }) => SttConfig(
    provider: SttProviderKind.custom,
    baseUrl: baseUrl,
    model: model,
    authHeader: authHeader,
    responseShape: responseShape ?? SttResponseShape.jsonPath,
    responseField: responseField,
    extraParams: extraParams,
  );

  test('multipart 请求形状：完整地址原样使用、逐字段表单、默认 Bearer 鉴权', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('{"text":"今天有点累"}'),
      ),
    );

    final text = await SttModelGateway(client).transcribe(
      config: configWith(),
      apiKey: ' stt-test-key ',
      audio: [1, 2, 3, 4],
      mimeType: 'audio/webm',
    );

    expect(text, '今天有点累');
    expect(client.timeout, sttRequestTimeout);
    // 用户填的完整地址就是端点：不拼 audio/transcriptions 后缀。
    expect(
      client.uri.toString(),
      'https://stt.example.com/v1/audio/transcriptions',
    );
    expect(client.headers['authorization'], 'Bearer stt-test-key');
    final contentType = client.headers['content-type']!;
    expect(contentType, startsWith('multipart/form-data; boundary='));
    final boundary = contentType.split('boundary=').last;
    final body = latin1.decode(client.bytesBody);
    // 与 OpenAI 兼容档逐字一致的字段：model、language=zh、file 带文件名
    // 与 content-type，关闭边界收尾。
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

  test('文件名跟容器：mp4/wav 给出对应扩展名', () async {
    for (final scenario in [
      (mimeType: 'audio/mp4', fileName: 'recording.mp4'),
      (mimeType: 'audio/wav', fileName: 'recording.wav'),
    ]) {
      final client = RecordingHttpClient(
        response: ProviderHttpResponse(
          statusCode: 200,
          body: Stream.value('{"text":"嗯"}'),
        ),
      );

      await SttModelGateway(client).transcribe(
        config: configWith(),
        apiKey: 'stt-test-key',
        audio: [9],
        mimeType: scenario.mimeType,
      );

      expect(
        latin1.decode(client.bytesBody),
        contains('filename="${scenario.fileName}"'),
        reason: scenario.mimeType,
      );
    }
  });

  test('高级参数作额外表单字段：字符串原样、其他类型按 JSON 编码、null 跳过', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('{"text":"好"}'),
      ),
    );

    await SttModelGateway(client).transcribe(
      config: configWith(
        extraParams: {
          'speaker': 'zh',
          'temperature': 0,
          'enable_punctuation': true,
          'nested': {'a': 1},
          'absent': null,
        },
      ),
      apiKey: 'stt-test-key',
      audio: [1],
      mimeType: 'audio/webm',
    );

    final body = latin1.decode(client.bytesBody);
    expect(
      body,
      contains('content-disposition: form-data; name="speaker"\r\n\r\nzh'),
    );
    expect(
      body,
      contains('content-disposition: form-data; name="temperature"\r\n\r\n0'),
    );
    expect(
      body,
      contains(
        'content-disposition: form-data; name="enable_punctuation"\r\n\r\ntrue',
      ),
    );
    expect(
      body,
      contains('content-disposition: form-data; name="nested"\r\n\r\n{"a":1}'),
    );
    // null 值没有表单语义：不发一个写着 null 的字段出去。
    expect(body, isNot(contains('name="absent"')));
    // 额外字段排在文件字段之前：文件段带着关闭边界，必须最后。
    expect(
      body.indexOf('name="speaker"'),
      lessThan(body.indexOf('name="file"')),
    );
  });

  test('json_path 形态：缺省取 text，空白字段名也回落 text', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('{"text":"嗯，睡了"}'),
      ),
    );

    expect(
      await SttModelGateway(client).transcribe(
        config: configWith(),
        apiKey: 'stt-test-key',
        audio: [1],
        mimeType: 'audio/webm',
      ),
      '嗯，睡了',
    );

    final blankField = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('{"text":"空白回落"}'),
      ),
    );
    expect(
      await SttModelGateway(blankField).transcribe(
        config: configWith(responseField: '   '),
        apiKey: 'stt-test-key',
        audio: [1],
        mimeType: 'audio/webm',
      ),
      '空白回落',
    );
  });

  test('json_path 形态：嵌套点号路径逐层取文本', () async {
    for (final scenario in [
      (field: 'result.text', body: '{"result":{"text":"嵌套取值"}}'),
      (field: 'data.result.text', body: '{"data":{"result":{"text":"深层取值"}}}'),
      (field: 'text', body: '{"text":"顶层"}'),
    ]) {
      final client = RecordingHttpClient(
        response: ProviderHttpResponse(
          statusCode: 200,
          body: Stream.value(scenario.body),
        ),
      );

      expect(
        await SttModelGateway(client).transcribe(
          config: configWith(responseField: scenario.field),
          apiKey: 'stt-test-key',
          audio: [1],
          mimeType: 'audio/webm',
        ),
        scenario.field == 'result.text'
            ? '嵌套取值'
            : scenario.field == 'data.result.text'
            ? '深层取值'
            : '顶层',
        reason: scenario.field,
      );
    }
  });

  test('json_path 形态：数组下标路径按不支持处理，解析失败给人话', () async {
    // 点号路径只认对象字段：choices.0.text 走到 List 上就走不下去。
    // 响应文本在数组下标的服务是本期范围外，按解析失败交给人话。
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('{"choices":[{"text":"下标里的文本"}]}'),
      ),
    );

    await expectLater(
      SttModelGateway(client).transcribe(
        config: configWith(responseField: 'choices.0.text'),
        apiKey: 'stt-test-key',
        audio: [1],
        mimeType: 'audio/webm',
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
  });

  test('json_path 形态：路径取不到文本（缺字段/非字符串/非 JSON）按解析失败', () async {
    final scenarios = [
      (field: 'result.text', body: '{"result":{}}'),
      (field: 'text', body: '{"text":123}'),
      (field: 'text', body: '{"text":null}'),
      (field: 'text', body: '{"text":["列表"]}'),
      (field: 'text', body: 'oops'),
      (field: 'text', body: '["不是对象"]'),
    ];
    for (final scenario in scenarios) {
      final client = RecordingHttpClient(
        response: ProviderHttpResponse(
          statusCode: 200,
          body: Stream.value(scenario.body),
        ),
      );

      await expectLater(
        SttModelGateway(client).transcribe(
          config: configWith(responseField: scenario.field),
          apiKey: 'stt-test-key',
          audio: [1],
          mimeType: 'audio/webm',
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
        reason: scenario.body,
      );
    }
  });

  test('sse 形态：逐行 data 事件按序拼接，跳过空行与 [DONE]', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          'data: 今天\n'
          '\n'
          'data:有点累\n'
          '\n'
          'event: done\n'
          '\n'
          'data: [DONE]\n'
          '\n',
        ),
      ),
    );

    expect(
      await SttModelGateway(client).transcribe(
        config: configWith(responseShape: SttResponseShape.sse),
        apiKey: 'stt-test-key',
        audio: [1],
        mimeType: 'audio/webm',
      ),
      '今天有点累',
    );
  });

  test('sse 形态：载荷只剥一个前导空格，delta 的首尾空白原样保留', () async {
    // SSE 规范只剥载荷前的一个空格；「你好 」的尾随空格是服务端有意的
    // 分词内容，逐事件 trim 会把词粘在一起。CRLF 行尾同样只剥 \r。
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          'data: 你好 \r\n'
          '\r\n'
          'data: 世界\r\n'
          '\r\n'
          'data:  双重空格\r\n'
          '\r\n',
        ),
      ),
    );

    expect(
      await SttModelGateway(client).transcribe(
        config: configWith(responseShape: SttResponseShape.sse),
        apiKey: 'stt-test-key',
        audio: [1],
        mimeType: 'audio/webm',
      ),
      '你好 世界 双重空格',
    );
  });

  test('sse 形态：没有 data 事件时返回空文本（语义区分交给调用方）', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('data: [DONE]\n\n'),
      ),
    );

    expect(
      await SttModelGateway(client).transcribe(
        config: configWith(responseShape: SttResponseShape.sse),
        apiKey: 'stt-test-key',
        audio: [1],
        mimeType: 'audio/webm',
      ),
      isEmpty,
    );
  });

  test('空文本照实返回：json_path 与 sse 两种形态都不把空当失败', () async {
    final jsonPath = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('{"text":""}'),
      ),
    );
    expect(
      await SttModelGateway(jsonPath).transcribe(
        config: configWith(),
        apiKey: 'stt-test-key',
        audio: [0],
        mimeType: 'audio/webm',
      ),
      isEmpty,
    );

    final sse = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('data: \n\n'),
      ),
    );
    expect(
      await SttModelGateway(sse).transcribe(
        config: configWith(responseShape: SttResponseShape.sse),
        apiKey: 'stt-test-key',
        audio: [0],
        mimeType: 'audio/webm',
      ),
      isEmpty,
    );
  });

  test('鉴权头可配：整行头名拼 Key，Authorization: Bearer 与 X-Api-Key 两例', () async {
    final scenarios = [
      (authHeader: 'Authorization: Bearer', name: 'authorization', value: 'Bearer stt-test-key'),
      (authHeader: 'X-Api-Key', name: 'x-api-key', value: 'stt-test-key'),
      (authHeader: 'api-key', name: 'api-key', value: 'stt-test-key'),
      (authHeader: 'Authorization:Bearer', name: 'authorization', value: 'Bearer stt-test-key'),
    ];
    for (final scenario in scenarios) {
      final client = RecordingHttpClient(
        response: ProviderHttpResponse(
          statusCode: 200,
          body: Stream.value('{"text":"通"}'),
        ),
      );

      await SttModelGateway(client).transcribe(
        config: configWith(authHeader: scenario.authHeader),
        apiKey: 'stt-test-key',
        audio: [1],
        mimeType: 'audio/webm',
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
      final client = RecordingHttpClient(
        response: ProviderHttpResponse(
          statusCode: 200,
          body: Stream.value('{"text":"通"}'),
        ),
      );

      await SttModelGateway(client).transcribe(
        config: configWith(authHeader: authHeader),
        apiKey: 'stt-test-key',
        audio: [1],
        mimeType: 'audio/webm',
      );

      expect(
        client.headers['authorization'],
        'Bearer stt-test-key',
        reason: '$authHeader',
      );
      // 回落只发生在默认头上：不会凭空多出别的头。
      expect(client.headers.keys.where((k) => k != 'content-type'), ['authorization']);
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
      (
        authHeader: '  : Bearer',
        message: '鉴权头格式不正确，请填写如 Authorization: Bearer 的头名。',
      ),
      // 保留头名撞名：content-type 会被网关自己写的 multipipart 头静默
      // 覆盖（无鉴权出网），content-length 等由 dart:io 自管。
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
      final client = RecordingHttpClient();

      await expectLater(
        SttModelGateway(client).transcribe(
          config: configWith(authHeader: scenario.authHeader),
          apiKey: 'stt-test-key',
          audio: [1],
          mimeType: 'audio/webm',
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
      expect(client.called, isFalse, reason: scenario.authHeader);
    }
  });

  test('缺 Key 直接按鉴权失败拒绝，不出网', () async {
    final client = RecordingHttpClient();

    await expectLater(
      SttModelGateway(client).transcribe(
        config: configWith(),
        apiKey: '  ',
        audio: [0],
        mimeType: 'audio/webm',
      ),
      throwsA(
        isA<SttGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.authentication)
            .having(
              (error) => error.message,
              'message',
              '还没有保存语音服务的 API Key。',
            ),
      ),
    );
    expect(client.called, isFalse);
  });

  test('Key 带零宽空格按粘贴事故拒绝，不出网', () async {
    final client = RecordingHttpClient();

    await expectLater(
      SttModelGateway(client).transcribe(
        config: configWith(),
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
        client: RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 401,
            body: Stream.value('{"error":"bad stt-test-key"}'),
          ),
        ),
        kind: ModelFailureKind.authentication,
        message: 'API Key 未通过语音服务验证。',
      ),
      (
        client: RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 429,
            body: Stream.value('{}'),
          ),
        ),
        kind: ModelFailureKind.rateLimited,
        message: '语音服务请求过于频繁。',
      ),
      (
        client: RecordingHttpClient(
          response: ProviderHttpResponse(
            statusCode: 500,
            body: Stream.value('{"error":"internal secret detail"}'),
          ),
        ),
        kind: ModelFailureKind.provider,
        message: '语音服务拒绝了这次请求。',
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
        client: RecordingHttpClient(error: TimeoutException('slow')),
        kind: ModelFailureKind.timeout,
        message: '连接语音服务超时。',
      ),
    ];
    for (final scenario in scenarios) {
      await expectLater(
        SttModelGateway(scenario.client).transcribe(
          config: configWith(),
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

  test('SSRF 拒绝：自定义档指向环回/内网地址时在出网前抛错', () async {
    const targets = [
      'https://localhost/v1/audio/transcriptions',
      'http://127.0.0.1:8080/transcribe',
      'https://10.1.2.3/transcribe',
      'https://192.168.0.2/transcribe',
    ];
    for (final baseUrl in targets) {
      final client = RecordingHttpClient();
      await expectLater(
        SttModelGateway(client).transcribe(
          config: configWith(baseUrl: baseUrl),
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

  test('协议分派：custom 配置打完整地址的 multipart，与 OpenAI 兼容档互不串档', () async {
    final client = RecordingHttpClient(
      response: ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value('{"text":"分派"}'),
      ),
    );

    expect(
      await SttModelGateway(client).transcribe(
        config: configWith(),
        apiKey: 'stt-test-key',
        audio: [1],
        mimeType: 'audio/webm',
      ),
      '分派',
    );
    expect(client.called, isTrue);
    expect(
      client.uri.toString(),
      'https://stt.example.com/v1/audio/transcriptions',
    );
    expect(client.headers['authorization'], 'Bearer stt-test-key');
  });
}
