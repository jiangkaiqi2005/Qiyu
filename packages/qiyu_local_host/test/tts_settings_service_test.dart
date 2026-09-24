import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/scripted_voice_synthesizer.dart';

void main() {
  late String configPath;
  late JsonProviderConfigRepository repository;

  setUp(() {
    final directory = Directory.systemTemp.createTempSync('qiyu-tts-settings');
    configPath = '${directory.path}${Platform.pathSeparator}provider.json';
    repository = JsonProviderConfigRepository(filePath: configPath);
  });

  tearDown(() {
    final directory = File(configPath).parent;
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('保存与读回：音色、语速、自动朗读随快照返回，明文 Key 绝不出现', () async {
    final service = TtsSettingsService(repository, _FakeTtsGateway());
    final snapshot = await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
      voice: 'nova',
      speed: 1.2,
    );
    expect(snapshot.configured, isTrue);
    expect(snapshot.keySet, isTrue);
    expect(snapshot.config?.voice, 'nova');
    expect(snapshot.config?.speed, 1.2);
    expect(snapshot.config?.autoSpeak, isTrue);
    expect(snapshot.toJson().containsKey('apiKey'), isFalse);
    // Key 明文只落文件（本机 provider.json），HTTP 快照路径没有它。
    expect(snapshot.toJson()['voice'], 'nova');
    expect(snapshot.toJson()['autoSpeak'], isTrue);
  });

  test('Key 沿用规则：同地址未传新 Key 保留，换地址清空', () async {
    final service = TtsSettingsService(repository, _FakeTtsGateway());
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
    );
    final kept = await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
    );
    expect(kept.keySet, isTrue);

    final moved = await service.save(
      baseUrl: 'https://other.example.com/v1',
      model: 'tts-test',
    );
    expect(moved.keySet, isFalse);
  });

  test('Key 沿用规则：同地址换协议（换千问档）不沿用旧 Key', () async {
    final service = TtsSettingsService(repository, _FakeTtsGateway());
    await service.save(
      baseUrl: qwenTtsDefaultEndpoint,
      model: 'tts-1',
      apiKey: 'secret-tts-key',
    );

    final switched = await service.save(
      baseUrl: qwenTtsDefaultEndpoint,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
    );
    expect(switched.keySet, isFalse);
    expect(switched.config?.provider, TtsProviderKind.qwenTts);
    expect((await repository.loadTts())?.apiKey, isNull);

    // 千问档同协议同地址再保存（没传新 Key）仍沿用刚存下的 Key。
    final kept = await service.save(
      baseUrl: qwenTtsDefaultEndpoint,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
      apiKey: 'qwen-secret-value',
    );
    expect(kept.keySet, isTrue);
    final sameScope = await service.save(
      baseUrl: qwenTtsDefaultEndpoint,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
    );
    expect(sameScope.keySet, isTrue);
  });

  test('连接测试端到端：千问档经真网关两请求拿到试听音频', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(
          utf8.encode(
            jsonEncode({
              'output': {
                'audio': {'url': 'https://oss.example.com/qiyu.mp3'},
              },
            }),
          ),
        ),
      ),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([7, 8, 9]),
      ),
    );
    // 真网关（分派 + 千问实现）配假 HTTP 客户端：锁住设置服务到两个
    // 出网请求（POST 拿地址、GET 下载）的完整链路。
    final service = TtsSettingsService(repository, TtsModelGateway(client));

    final result = await service.test(
      baseUrl: qwenTtsDefaultEndpoint,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
      apiKey: 'sk-dashscope',
      voice: 'Cherry',
    );

    expect(result.succeeded, isTrue);
    expect(result.status, ProviderTestStatus.success);
    expect(base64Decode(result.audioBase64!), [7, 8, 9]);
    expect(client.postCalled, isTrue);
    expect(client.downloadCalled, isTrue);
    // 试听用的是内置示例句，音色按表单值上送。
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect((body['input']! as Map<String, Object?>)['text'],
        ttsConnectionTestSentence);
    expect((body['input']! as Map<String, Object?>)['voice'], 'Cherry');
  });

  test('连接测试端到端：千问档下载失败按人话失败，不带音频', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(
          utf8.encode(
            jsonEncode({
              'output': {
                'audio': {'url': 'https://oss.example.com/qiyu.mp3'},
              },
            }),
          ),
        ),
      ),
      downloadError: TimeoutException('slow'),
    );
    final service = TtsSettingsService(repository, TtsModelGateway(client));

    final result = await service.test(
      baseUrl: qwenTtsDefaultEndpoint,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
      apiKey: 'sk-dashscope',
    );

    expect(result.succeeded, isFalse);
    expect(result.status, ProviderTestStatus.timeout);
    expect(result.audioBase64, isNull);
    expect(result.message, '连接语音合成服务超时。');
  });

  test('连接测试端到端：自定义档按所选响应形态完整走一遍拿到试听音频', () async {
    // 三种形态各来一次：裸音频字节、JSON 字段（base64 与 URL 下载）、
    // 逐行 JSON 拼接——形态选错在保存前暴露。
    final rawClient = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1, 2]),
      ),
    );
    final rawService = TtsSettingsService(
      repository,
      TtsModelGateway(rawClient),
    );
    final rawResult = await rawService.test(
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
      provider: TtsProviderKind.custom,
      apiKey: 'sk-custom',
      responseShape: TtsResponseShape.rawBytes,
    );
    expect(rawResult.succeeded, isTrue);
    expect(base64Decode(rawResult.audioBase64!), [1, 2]);
    expect(rawClient.downloadCalled, isFalse);

    final fieldBody = jsonEncode({
      'data': base64Encode([3, 4]),
    });
    final fieldClient = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode(fieldBody)),
      ),
    );
    final fieldService = TtsSettingsService(
      repository,
      TtsModelGateway(fieldClient),
    );
    final fieldResult = await fieldService.test(
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
      provider: TtsProviderKind.custom,
      apiKey: 'sk-custom',
      responseShape: TtsResponseShape.jsonField,
    );
    expect(fieldResult.succeeded, isTrue);
    expect(base64Decode(fieldResult.audioBase64!), [3, 4]);

    final linesClient = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(
          utf8.encode(
            '{"data":"${base64Encode([5])}"}\n{"data":"${base64Encode([6])}"}\n',
          ),
        ),
      ),
    );
    final linesService = TtsSettingsService(
      repository,
      TtsModelGateway(linesClient),
    );
    final linesResult = await linesService.test(
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
      provider: TtsProviderKind.custom,
      apiKey: 'sk-custom',
      responseShape: TtsResponseShape.jsonLines,
    );
    expect(linesResult.succeeded, isTrue);
    expect(base64Decode(linesResult.audioBase64!), [5, 6]);
    // 试听用的是内置示例句，请求体固定 {model, input}。
    final body =
        jsonDecode(utf8.decode(rawClient.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'tts-test');
    expect(body['input'], {'text': ttsConnectionTestSentence});
  });

  test('连接测试端到端：自定义档 URL 字段经下载跳取音频，鉴权头按表单值发出', () async {
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(
          utf8.encode(
            jsonEncode({'audio': 'https://oss.example.com/qiyu.mp3'}),
          ),
        ),
      ),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([7, 8, 9]),
      ),
    );
    final service = TtsSettingsService(repository, TtsModelGateway(client));

    final result = await service.test(
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
      provider: TtsProviderKind.custom,
      apiKey: 'sk-custom',
      authHeader: 'X-Api-Key',
      responseShape: TtsResponseShape.jsonField,
      responseField: 'audio',
    );

    expect(result.succeeded, isTrue);
    expect(base64Decode(result.audioBase64!), [7, 8, 9]);
    expect(client.downloadCalled, isTrue);
    expect(client.headers['x-api-key'], 'sk-custom');
    expect(client.headers['authorization'], isNull);
  });

  test('连接测试：自定义档旋钮回落已存值，鉴权头留空按默认 Bearer 测', () async {
    final gateway = _FakeTtsGateway(audio: [1, 2, 3]);
    final service = TtsSettingsService(repository, gateway);
    await service.save(
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
      provider: TtsProviderKind.custom,
      apiKey: 'secret-tts-key',
      authHeader: 'X-Api-Key',
      responseShape: TtsResponseShape.jsonField,
      responseField: 'result.audio',
    );

    // 整份表单为空（测已存配置）：旋钮回落已存值。
    await service.test();
    expect(gateway.lastConfig?.provider, TtsProviderKind.custom);
    expect(gateway.lastConfig?.authHeader, 'X-Api-Key');
    expect(gateway.lastConfig?.responseShape, TtsResponseShape.jsonField);
    expect(gateway.lastConfig?.responseField, 'result.audio');

    // 表单填了就以表单为准：换一个鉴权头与形态，不与已存值混淆。
    await service.test(
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
      provider: TtsProviderKind.custom,
      authHeader: 'Authorization: Token',
      responseShape: TtsResponseShape.rawBytes,
    );
    expect(gateway.lastConfig?.authHeader, 'Authorization: Token');
    expect(gateway.lastConfig?.responseShape, TtsResponseShape.rawBytes);
    // 空白字段名归一为缺省 data。
    expect(gateway.lastConfig?.responseField, 'data');
  });

  test('保存设置：自定义档旋钮随快照返回，非自定义档不落盘旋钮', () async {
    final service = TtsSettingsService(repository, _FakeTtsGateway());
    final snapshot = await service.save(
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
      provider: TtsProviderKind.custom,
      apiKey: 'secret-tts-key',
      authHeader: 'Authorization: Bearer',
      responseShape: TtsResponseShape.jsonLines,
      responseField: '  ',
      extraParams: {'voice': 'custom-voice'},
    );

    expect(snapshot.config?.authHeader, 'Authorization: Bearer');
    expect(snapshot.config?.responseShape, TtsResponseShape.jsonLines);
    // 空白字段名归一为缺省 data：落盘的值恒有含义。
    expect(snapshot.config?.responseField, 'data');
    expect(snapshot.toJson()['responseShape'], 'json_lines');
    expect(snapshot.toJson()['responseField'], 'data');
    expect(snapshot.toJson()['authHeader'], 'Authorization: Bearer');

    final openAi = await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
    );
    expect(openAi.config?.provider, TtsProviderKind.openAiCompatible);
    expect(openAi.config?.authHeader, isNull);
    expect(openAi.config?.responseShape, TtsResponseShape.rawBytes);
    expect(openAi.config?.responseField, 'data');
    expect(openAi.toJson().containsKey('authHeader'), isFalse);
    expect(openAi.toJson().containsKey('responseShape'), isFalse);
    expect(openAi.toJson().containsKey('responseField'), isFalse);
  });

  test('setAutoSpeak 保留自定义档旋钮：翻朗读开关不写丢配置', () async {
    final service = TtsSettingsService(repository, _FakeTtsGateway());
    await service.save(
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
      provider: TtsProviderKind.custom,
      apiKey: 'secret-tts-key',
      authHeader: 'X-Api-Key',
      responseShape: TtsResponseShape.jsonField,
      responseField: 'result.audio',
    );

    final toggled = await service.setAutoSpeak(false);

    expect(toggled.config?.autoSpeak, isFalse);
    expect(toggled.config?.authHeader, 'X-Api-Key');
    expect(toggled.config?.responseShape, TtsResponseShape.jsonField);
    expect(toggled.config?.responseField, 'result.audio');
  });

  test('传输方式保存口径（票三）：豆包档落盘，切档回落缺省，开关不写丢', () async {
    final service = TtsSettingsService(repository, _FakeTtsGateway());

    final saved = await service.save(
      baseUrl:
          'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
      model: 'seed-tts-2.0',
      provider: TtsProviderKind.volcTts,
      apiKey: 'ark-secret-value',
      transport: TtsTransport.wsBidirection,
    );
    expect(saved.config?.transport, TtsTransport.wsBidirection);
    // 没显式选时沿用已存值。
    final kept = await service.save(
      baseUrl:
          'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
      model: 'seed-tts-2.0',
      provider: TtsProviderKind.volcTts,
    );
    expect(kept.config?.transport, TtsTransport.wsBidirection);

    // 翻朗读开关不写丢传输方式。
    final toggled = await service.setAutoSpeak(false);
    expect(toggled.config?.transport, TtsTransport.wsBidirection);

    // 切到非豆包档：回落缺省 HTTP 分块（配置不落盘）。
    final switched = await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'openai-secret-value',
    );
    expect(switched.config?.transport, TtsTransport.httpChunk);
    // 切回豆包档没显式选：按缺省（上一个配置已是别的档）。
    final back = await service.save(
      baseUrl:
          'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
      model: 'seed-tts-2.0',
      provider: TtsProviderKind.volcTts,
    );
    expect(back.config?.transport, TtsTransport.httpChunk);
  });

  test('连续供给会话路由（票三）：按协议/传输/型号决定开不开会话', () async {
    final service = TtsSettingsService(
      repository,
      ScriptedTtsGateway(sessionReplies: const {
        '我在': [[1]],
      }),
    );

    // 未配置：不开会话。
    expect(await service.openSession(sessionId: 'chat-1'), isNull);

    // 豆包档 WebSocket 双向：开会话，配置/Key/聊天会话标识原样交给网关。
    await service.save(
      baseUrl:
          'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
      model: 'seed-tts-2.0',
      provider: TtsProviderKind.volcTts,
      apiKey: 'ark-secret-value',
      transport: TtsTransport.wsBidirection,
    );
    final session = await service.openSession(sessionId: 'chat-1');
    expect(session, isNotNull);
    final opened = (service.ttsGateway as ScriptedTtsGateway).sessionOpens;
    expect(opened.single.sessionId, 'chat-1');
    expect(opened.single.apiKey, 'ark-secret-value');
    expect(opened.single.config.transport, TtsTransport.wsBidirection);
    session!.appendText('我在');
    expect(
      await session.chunks.first,
      isA<VoiceAudioChunk>().having((chunk) => chunk.bytes, 'bytes', [1]),
    );

    // 豆包档 HTTP 分块：不开会话，回落票二的分句模式。
    await service.save(
      baseUrl:
          'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
      model: 'seed-tts-2.0',
      provider: TtsProviderKind.volcTts,
      transport: TtsTransport.httpChunk,
    );
    expect(await service.openSession(sessionId: 'chat-1'), isNull);

    // 千问档型号驱动：realtime 型号开会话，其余不开。
    await service.save(
      baseUrl:
          'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
      model: 'qwen3-tts-flash-realtime',
      provider: TtsProviderKind.qwenTts,
      apiKey: 'sk-secret-value',
    );
    expect(await service.openSession(sessionId: 'chat-1'), isNotNull);
    await service.save(
      baseUrl:
          'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
      model: 'qwen3-tts-flash',
      provider: TtsProviderKind.qwenTts,
      apiKey: 'sk-secret-value',
    );
    expect(await service.openSession(sessionId: 'chat-1'), isNull);
  });

  test('整段路径随传输走（票三）：ws 档试听与连接测试都走 WS 会话', () async {
    final gateway = _FakeTtsGateway(audio: [1, 2, 3]);
    final service = TtsSettingsService(repository, gateway);
    await service.save(
      baseUrl:
          'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
      model: 'seed-tts-2.0',
      provider: TtsProviderKind.volcTts,
      apiKey: 'ark-secret-value',
      transport: TtsTransport.wsBidirection,
    );

    final audio = await service.synthesize('晚安。');

    expect(audio, [1, 2, 3]);
    expect(gateway.lastConfig?.transport, TtsTransport.wsBidirection);

    // 连接测试随表单传输走（裁定 A）：选了 WebSocket 双向就连 WS 实测，
    // 不拿 HTTP 假绿。
    await service.test(transport: TtsTransport.wsBidirection);
    expect(gateway.lastConfig?.transport, TtsTransport.wsBidirection);
  });

  test('保存设置保留既有朗读开关，脏 Key 不落盘', () async {
    final service = TtsSettingsService(repository, _FakeTtsGateway());
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
      autoSpeak: false,
    );

    final updated = await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-next',
    );
    expect(updated.config?.autoSpeak, isFalse);

    await expectLater(
      service.save(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-next',
        apiKey: 'key\u200B',
      ),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
        ),
      ),
    );
    expect((await repository.loadTts())?.apiKey, 'secret-tts-key');

    await expectLater(
      service.save(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-next',
        apiKey: ' secret-tts-key',
      ),
      throwsA(isA<ProviderConfigException>()),
    );
    expect((await repository.loadTts())?.apiKey, 'secret-tts-key');
  });

  test('忘记 Key 只清 Key，音色语速开关与地址模型保留', () async {
    final service = TtsSettingsService(repository, _FakeTtsGateway());
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
      voice: 'nova',
      speed: 0.8,
    );
    final snapshot = await service.forgetApiKey();
    expect(snapshot.keySet, isFalse);
    expect(snapshot.config?.voice, 'nova');
    expect(snapshot.config?.speed, 0.8);
    expect(snapshot.config?.baseUrl, 'https://tts.example.com/v1');
  });

  test('setAutoSpeak 只改开关位；未配置时拒绝', () async {
    final service = TtsSettingsService(repository, _FakeTtsGateway());
    await expectLater(
      service.setAutoSpeak(false),
      throwsA(
        isA<TtsServiceException>().having(
          (error) => error.code,
          'code',
          'tts_not_configured',
        ),
      ),
    );
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
    );
    final snapshot = await service.setAutoSpeak(false);
    expect(snapshot.config?.autoSpeak, isFalse);
    // 其他字段原样保留。
    expect(snapshot.config?.model, 'tts-test');
    expect(snapshot.keySet, isTrue);
  });

  test('连接测试成功：真实合成内置示例句并返回试听音频', () async {
    final gateway = _FakeTtsGateway(audio: [7, 8, 9]);
    final service = TtsSettingsService(repository, gateway);
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
    );
    final result = await service.test(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
      voice: 'nova',
    );
    expect(result.succeeded, isTrue);
    expect(result.audioBase64, isNotNull);
    expect(gateway.lastText, ttsConnectionTestSentence);
    expect(gateway.lastConfig?.voice, 'nova');
  });

  test('连接测试：当前表单缺省音色语速用服务默认，空负载才沿用已存值', () async {
    final gateway = _FakeTtsGateway(audio: [7, 8, 9]);
    final service = TtsSettingsService(repository, gateway);
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
      voice: 'nova',
      speed: 1.25,
    );

    await service.test(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
    );
    expect(gateway.lastConfig?.voice, isNull);
    expect(gateway.lastConfig?.speed, isNull);

    await service.test();
    expect(gateway.lastConfig?.voice, 'nova');
    expect(gateway.lastConfig?.speed, 1.25);
  });

  test('连接测试失败：按分类给人话，不带音频', () async {
    final service = TtsSettingsService(
      repository,
      _FakeTtsGateway(
        error: const TtsGatewayException(
          kind: ModelFailureKind.authentication,
          message: 'x',
        ),
      ),
    );
    final result = await service.test(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
    );
    expect(result.succeeded, isFalse);
    expect(result.audioBase64, isNull);
    expect(result.message, 'API Key 没有通过验证。');
  });

  test('模型与接口不匹配：连接测试与正式合成都给可定位提示', () async {
    // 异常带 client 公开类别（与 providerStatusFailure 新分支一致）：
    // 正式路径的 client 前置分支按 kind 排除本种类，错误码仍可区分。
    final service = TtsSettingsService(
      repository,
      _FakeTtsGateway(
        error: const TtsGatewayException(
          kind: ModelFailureKind.modelInterfaceMismatch,
          message: 'x',
          serviceError: ServiceErrorCategory.client,
        ),
      ),
    );
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'qwen-audio-3.1-tts-next',
      apiKey: 'secret-tts-key',
    );

    final result = await service.test(
      baseUrl: 'https://tts.example.com/v1',
      // 连接测试半段用表 miss 型号：qwen-audio-3.1-tts-next 已被档位映射
      // 表收作「不支持」，会在发请求前给结构化建议（见下方新增用例），
      // 到不了网关；分类路径本身由表 miss 型号锁定。
      model: 'qwen-audio-tts-next',
      apiKey: 'secret-tts-key',
    );
    expect(result.succeeded, isFalse);
    expect(result.audioBase64, isNull);
    expect(result.status, ProviderTestStatus.modelInterfaceMismatch);
    expect(result.message, '这个模型不能用当前服务地址调用，请更换模型或调整服务地址。');
    expect(result.tierSuggestion, isNull);

    await expectLater(
      service.synthesize('晚安'),
      throwsA(
        isA<TtsServiceException>()
            .having(
              (error) => error.code,
              'code',
              'tts_model_interface_mismatch',
            )
            .having(
              (error) => error.message,
              'message',
              '这个模型不能用当前服务地址调用，请更换模型或调整服务地址。',
            ),
      ),
    );
  });

  test('连接测试脏 Key：前置拦截人话文案，不出网', () async {
    final gateway = _FakeTtsGateway(audio: [1]);
    final service = TtsSettingsService(repository, gateway);
    final result = await service.test(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'key\u200B',
    );
    expect(result.succeeded, isFalse);
    expect(result.message, 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。');
    expect(gateway.called, isFalse);

    final spaced = await service.test(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: ' secret-tts-key',
    );
    expect(spaced.succeeded, isFalse);
    expect(spaced.message, 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。');
    expect(gateway.called, isFalse);
  });

  test('正式合成：空文本与超长文本不出网直接拒绝', () async {
    final gateway = _FakeTtsGateway(audio: [1]);
    final service = TtsSettingsService(repository, gateway);
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
    );
    await expectLater(
      service.synthesize('   '),
      throwsA(
        isA<TtsServiceException>().having(
          (error) => error.code,
          'code',
          'tts_empty_text',
        ),
      ),
    );
    await expectLater(
      service.synthesize('夜' * (ttsMaxTextLength + 1)),
      throwsA(
        isA<TtsServiceException>().having(
          (error) => error.code,
          'code',
          'tts_text_too_long',
        ),
      ),
    );
    expect(gateway.called, isFalse);
  });

  test('正式合成：未配置拒绝；正常返回音频字节', () async {
    final gateway = _FakeTtsGateway(audio: [4, 5]);
    final service = TtsSettingsService(repository, gateway);
    await expectLater(
      service.synthesize('晚安。'),
      throwsA(
        isA<TtsServiceException>().having(
          (error) => error.code,
          'code',
          'tts_not_configured',
        ),
      ),
    );
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
    );
    expect(await service.synthesize('晚安。'), [4, 5]);
    expect(gateway.lastText, '晚安。');
  });

  test('正式合成：上游错误保留既有分类诊断码', () async {
    final service = TtsSettingsService(
      repository,
      _FakeTtsGateway(
        error: const TtsGatewayException(
          kind: ModelFailureKind.rateLimited,
          message: '上游额度详情 secret-provider-body',
        ),
      ),
    );
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
    );

    await expectLater(
      service.synthesize('晚安。'),
      throwsA(
        isA<TtsServiceException>()
            .having((error) => error.code, 'code', 'tts_rate_limited')
            .having((error) => error.message, 'message', '语音合成服务请求过于频繁，请稍后再试。'),
      ),
    );
  });

  test('extraParams 透传保存、快照返回与连接测试透传', () async {
    final fakeGateway = _FakeTtsGateway(audio: [1, 2, 3]);
    final service = TtsSettingsService(repository, fakeGateway);

    final snapshot = await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
      extraParams: {'response_format': 'wav'},
    );

    expect(snapshot.config?.extraParams, {'response_format': 'wav'});
    expect(snapshot.toJson()['extraParams'], {'response_format': 'wav'});

    final testResult = await service.test(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'secret-tts-key',
      extraParams: {'response_format': 'opus'},
    );

    expect(testResult.succeeded, isTrue);
    expect(fakeGateway.called, isTrue);
    expect(fakeGateway.lastConfig?.extraParams, {'response_format': 'opus'});
  });

  test('连接测试端到端：千问 3.1 新形状（maas 地址）经真网关拿到试听音频', () async {
    // 地址主机含 maas.aliyuncs.com：网关按地址派形状走 3.1 官方
    // SpeechSynthesizer 请求体（ADR 0020），响应音频地址照旧走下载跳。
    final client = _RecordingBytesHttpClient(
      postResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(
          utf8.encode(
            jsonEncode({
              'output': {
                'audio': {'url': 'https://oss.example.com/qiyu.wav'},
              },
            }),
          ),
        ),
      ),
      downloadResponse: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([3, 1, 4]),
      ),
    );
    final service = TtsSettingsService(repository, TtsModelGateway(client));

    final result = await service.test(
      baseUrl:
          'https://ws-12345.cn-beijing.maas.aliyuncs.com'
          '/api/v1/services/audio/tts/SpeechSynthesizer',
      model: 'qwen-audio-3.1-tts-flash',
      provider: TtsProviderKind.qwenTts,
      apiKey: 'sk-bailian',
      voice: 'longanhuan_v3.6',
    );

    expect(result.succeeded, isTrue);
    expect(result.status, ProviderTestStatus.success);
    expect(base64Decode(result.audioBase64!), [3, 1, 4]);
    expect(client.postCalled, isTrue);
    expect(client.downloadCalled, isTrue);
    // 新形状请求体：CosyVoice 家族 input，无现行形状的 language_type。
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'qwen-audio-3.1-tts-flash');
    expect(body['input'], {
      'text': ttsConnectionTestSentence,
      'voice': 'longanhuan_v3.6',
      'format': 'wav',
      'sample_rate': 24000,
    });
  });

  test('档位映射表命中：3.1 型号配现行地址在发请求前给建议，零出网', () async {
    final gateway = _FakeTtsGateway(audio: [1]);
    final service = TtsSettingsService(repository, gateway);
    await service.save(
      baseUrl:
          'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
      model: 'qwen3-tts-flash',
      provider: TtsProviderKind.qwenTts,
      apiKey: 'secret-tts-key',
    );

    final result = await service.test(
      provider: TtsProviderKind.qwenTts,
      baseUrl:
          'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
      model: ' qwen-audio-3.1-tts-flash ',
      apiKey: 'secret-tts-key',
    );

    expect(gateway.called, isFalse, reason: '命中映射表不得出网');
    expect(result.succeeded, isFalse);
    expect(result.audioBase64, isNull);
    expect(result.status, ProviderTestStatus.modelInterfaceMismatch);
    expect(result.message, '这个型号要走千问朗读档的新版千问端点。');
    final suggestion = result.tierSuggestion;
    expect(suggestion, isA<VoiceTierSwitchSuggestion>());
    final switchSuggestion = suggestion! as VoiceTierSwitchSuggestion;
    expect(switchSuggestion.targetProviderWireName, 'qwen_tts');
    expect(switchSuggestion.targetModel, 'qwen-audio-3.1-tts-flash');
    // 业务空间 ID 不代填：只有模板与拼接指引。
    expect(switchSuggestion.defaultEndpoint, isNull);
    expect(switchSuggestion.addressTemplate, voiceTierMaasAddressTemplate);
    expect(switchSuggestion.addressGuidance, voiceTierMaasAddressGuidance);
  });

  test('档位映射表命中：地址解析不出也按现行形状查表，建议照常给', () async {
    // 地址解析失败（畸形 IPv6）时新形状判定回落 false：查表只按档与
    // 型号走，命中照常给建议；不因地址草稿坏掉而跳过引导。
    final gateway = _FakeTtsGateway(audio: [1]);
    final service = TtsSettingsService(repository, gateway);
    final result = await service.test(
      provider: TtsProviderKind.qwenTts,
      baseUrl: 'https://[::1:80',
      model: 'qwen-audio-3.1-tts-flash',
      apiKey: 'secret-tts-key',
    );

    expect(gateway.called, isFalse);
    expect(result.tierSuggestion, isA<VoiceTierSwitchSuggestion>());
    expect(
      (result.tierSuggestion! as VoiceTierSwitchSuggestion).addressTemplate,
      voiceTierMaasAddressTemplate,
    );
  });

  test('档位映射表命中：其他档误填千问朗读型号，发请求前引导换档', () async {
    final gateway = _FakeTtsGateway(audio: [1]);
    final service = TtsSettingsService(repository, gateway);
    final result = await service.test(
      baseUrl: 'https://tts.example.com/v1',
      model: 'qwen3-tts-flash',
      apiKey: 'secret-tts-key',
    );

    expect(gateway.called, isFalse);
    expect(result.tierSuggestion, isA<VoiceTierSwitchSuggestion>());
    final switchSuggestion =
        result.tierSuggestion! as VoiceTierSwitchSuggestion;
    expect(switchSuggestion.targetProviderWireName, 'qwen_tts');
    expect(switchSuggestion.defaultEndpoint, qwenTtsDefaultEndpoint);
    expect(result.message, '这个型号要走千问朗读档。');
  });

  test('档位映射表命中：不支持型号直接给原因话术与替代型号，零出网', () async {
    final gateway = _FakeTtsGateway(audio: [1]);
    final service = TtsSettingsService(repository, gateway);
    final result = await service.test(
      provider: TtsProviderKind.qwenTts,
      baseUrl:
          'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
      model: 'qwen-audio-3.1-tts-next',
      apiKey: 'secret-tts-key',
    );

    expect(gateway.called, isFalse);
    expect(result.tierSuggestion, isA<VoiceTierUnsupportedSuggestion>());
    final unsupported =
        result.tierSuggestion! as VoiceTierUnsupportedSuggestion;
    expect(unsupported.reason, '这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。');
    expect(unsupported.targetModel, 'qwen3-tts-flash');
    expect(result.message, unsupported.reason);
  });

  test('表 miss 照常出网试听，结果不带建议', () async {
    final gateway = _FakeTtsGateway(audio: [7, 8]);
    final service = TtsSettingsService(repository, gateway);
    final result = await service.test(
      provider: TtsProviderKind.qwenTts,
      baseUrl:
          'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
      model: 'qwen3-tts-flash',
      apiKey: 'secret-tts-key',
    );

    expect(gateway.called, isTrue);
    expect(result.succeeded, isTrue);
    expect(result.tierSuggestion, isNull);
    expect(result.audioBase64, base64Encode([7, 8]));
  });

  test('3.1 型号配新版地址：正确落位，连接测试照常出网试听', () async {
    final gateway = _FakeTtsGateway(audio: [9]);
    final service = TtsSettingsService(repository, gateway);
    final result = await service.test(
      provider: TtsProviderKind.qwenTts,
      baseUrl:
          'https://ws-12345.cn-beijing.maas.aliyuncs.com'
          '/api/v1/services/audio/tts/SpeechSynthesizer',
      model: 'qwen-audio-3.1-tts-flash',
      apiKey: 'sk-bailian',
    );

    expect(gateway.called, isTrue);
    expect(result.succeeded, isTrue);
    expect(result.tierSuggestion, isNull);
  });
}

final class _FakeTtsGateway implements TtsSynthesisGateway {
  _FakeTtsGateway({this.audio = const [], this.error});

  final List<int> audio;
  final TtsGatewayException? error;

  bool called = false;
  String? lastText;
  TtsConfig? lastConfig;

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    called = true;
    lastText = text;
    lastConfig = config;
    if (error case final failure?) {
      throw failure;
    }
    return audio;
  }
}

/// 记录型二进制 HTTP 客户端：合成 POST 与音频地址下载（GET）分别留档，
/// 端到端用例用它把「两个请求」逐条观测出来。
final class _RecordingBytesHttpClient implements ProviderBytesHttpClient {
  _RecordingBytesHttpClient({
    this.postResponse,
    this.downloadResponse,
    this.downloadError,
  });

  final ProviderBytesHttpResponse? postResponse;
  final ProviderBytesHttpResponse? downloadResponse;
  final Object? downloadError;

  bool postCalled = false;
  bool downloadCalled = false;
  late List<int> bytesBody;
  late Map<String, String> headers;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    postCalled = true;
    this.headers = headers;
    bytesBody = body;
    return postResponse!;
  }

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) async {
    downloadCalled = true;
    if (downloadError case final failure?) {
      throw failure;
    }
    return downloadResponse!;
  }
}
