import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    const sharedUrl = 'https://tts.shared.com/v1';
    final service = TtsSettingsService(repository, _FakeTtsGateway());
    await service.save(
      baseUrl: sharedUrl,
      model: 'tts-1',
      apiKey: 'secret-tts-key',
    );

    final switched = await service.save(
      baseUrl: sharedUrl,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
    );
    expect(switched.keySet, isFalse);
    expect(switched.config?.provider, TtsProviderKind.qwenTts);
    expect((await repository.loadTts())?.apiKey, isNull);

    // 千问档同协议同地址再保存（没传新 Key）仍沿用刚存下的 Key。
    final kept = await service.save(
      baseUrl: sharedUrl,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
      apiKey: 'qwen-secret-value',
    );
    expect(kept.keySet, isTrue);
    final sameScope = await service.save(
      baseUrl: sharedUrl,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
    );
    expect(sameScope.keySet, isTrue);
  });

  test('连接测试端到端：千问档经真网关两请求拿到试听音频', () async {
    const maasUrl =
        'https://ws-12345.cn-beijing.maas.aliyuncs.com'
        '/api/v1/services/audio/tts/SpeechSynthesizer';
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
        body: Stream.value([7, 8, 9]),
      ),
    );
    // 真网关（分派 + 千问实现）配假 HTTP 客户端：锁住设置服务到两个
    // 出网请求（POST 拿地址、GET 下载）的完整链路。
    final service = TtsSettingsService(repository, TtsModelGateway(client));

    final result = await service.test(
      baseUrl: maasUrl,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
      apiKey: 'sk-dashscope',
      voice: 'longanhuan_v3.1',
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
    expect((body['input']! as Map<String, Object?>)['voice'], 'longanhuan_v3.1');
  });

  test('连接测试端到端：千问档下载失败按人话失败，不带音频', () async {
    const maasUrl =
        'https://ws-12345.cn-beijing.maas.aliyuncs.com'
        '/api/v1/services/audio/tts/SpeechSynthesizer';
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
      downloadError: TimeoutException('slow'),
    );
    final service = TtsSettingsService(repository, TtsModelGateway(client));

    final result = await service.test(
      baseUrl: maasUrl,
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

    // 千问档地址驱动：ws/wss 推理地址开会话，maas HTTP 不开。
    await service.save(
      baseUrl: qwenTtsDefaultEndpoint,
      model: qwenTtsDefaultModel,
      provider: TtsProviderKind.qwenTts,
      apiKey: 'sk-secret-value',
    );
    expect(await service.openSession(sessionId: 'chat-1'), isNotNull);
    await service.save(
      baseUrl:
          'https://ws-12345.cn-beijing.maas.aliyuncs.com'
          '/api/v1/services/audio/tts/SpeechSynthesizer',
      model: qwenTtsDefaultModel,
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

    // 票 05：正式合成的「模型与接口不匹配」分类落定后查档位映射表，
    // qwen-audio-3.1-tts-next 命中「不支持」行，通用文案升级为与连接
    // 测试同源的精确建议；错误码不变。
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
              '这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。',
            ),
      ),
    );
  });

  test('正式合成命中应换档：失败分类后查表升级为精确档位建议，错误码不变', () async {
    // 票 05：正式路径的升级只发生在「模型与接口不匹配」分类落定之后
    // ——假网关按 ADR 0015 分类抛错，查表命中「应换档」行后把通用文案
    // 换成与连接测试同源的建议话术；分类与可区分错误码不动。
    final gateway = _FakeTtsGateway(
      error: const TtsGatewayException(
        kind: ModelFailureKind.modelInterfaceMismatch,
        message: 'x',
        serviceError: ServiceErrorCategory.client,
      ),
    );
    final service = TtsSettingsService(repository, gateway);
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'qwen-audio-3.1-tts-flash',
      apiKey: 'secret-tts-key',
    );

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
              '这个型号要走千问朗读档的新版语音通道。',
            ),
      ),
    );
    expect(gateway.called, isTrue, reason: '正式合成路径照常出网后才升级文案');
  });

  test('正式合成表 miss 型号失败：文案与 ADR 0015 通用文案逐字相同', () async {
    // 回归锁定：查不到的型号在正式路径与今天逐字一致——分类、错误码
    // 与通用文案全不漂移（spec 决策 7）。
    final gateway = _FakeTtsGateway(
      error: const TtsGatewayException(
        kind: ModelFailureKind.modelInterfaceMismatch,
        message: 'x',
        serviceError: ServiceErrorCategory.client,
      ),
    );
    final service = TtsSettingsService(repository, gateway);
    await service.save(
      baseUrl: 'https://tts.example.com/v1',
      model: 'qwen-audio-tts-next',
      apiKey: 'secret-tts-key',
    );

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
    expect(gateway.called, isTrue);
  });

  test('正式合成千问档 3.1 型号：新版地址正确落位文案不变，现行地址升级为新版端点建议', () async {
    // 正式路径按落盘配置的地址派形状（与连接测试同律）：配新版地址是
    // 正确落位（表 miss，通用文案逐字不变）；配现行地址是实测必被 400
    // 拒绝的组合，升级为新版端点建议。
    final gateway = _FakeTtsGateway(
      error: const TtsGatewayException(
        kind: ModelFailureKind.modelInterfaceMismatch,
        message: 'x',
        serviceError: ServiceErrorCategory.client,
      ),
    );
    final service = TtsSettingsService(repository, gateway);
    await service.save(
      provider: TtsProviderKind.qwenTts,
      baseUrl:
          'https://ws-12345.cn-beijing.maas.aliyuncs.com'
          '/api/v1/services/audio/tts/SpeechSynthesizer',
      model: 'qwen-audio-3.1-tts-flash',
      apiKey: 'sk-bailian',
    );
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

    await service.save(
      provider: TtsProviderKind.qwenTts,
      baseUrl:
          'https://dashscope.aliyuncs.com'
          '/api/v1/services/aigc/multimodal-generation/generation',
      model: 'qwen-audio-3.1-tts-flash',
      apiKey: 'sk-bailian',
    );
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
              // 正式路径话术与连接测试同源同句（映射表 reason 单处改，
              // 票 07 起为「新版语音通道」）。
              '这个型号要走千问朗读档的新版语音通道。',
            ),
      ),
    );
    expect(gateway.called, isTrue, reason: '两个半段都走真实出网失败路径，不是查表前置拦截');
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
      voice: 'longanhuan_v3.1',
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
      'voice': 'longanhuan_v3.1',
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
      model: qwenTtsDefaultModel,
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
    expect(result.message, '这个型号要走千问朗读档的新版语音通道。');
    final suggestion = result.tierSuggestion;
    expect(suggestion, isA<VoiceTierSwitchSuggestion>());
    final switchSuggestion = suggestion! as VoiceTierSwitchSuggestion;
    expect(switchSuggestion.targetProviderWireName, 'qwen_tts');
    expect(switchSuggestion.targetModel, 'qwen-audio-3.1-tts-flash');
    // 票 07：官方 WS 推理地址实测可用，缺省端点直接代填；maas 模板与
    // 拼接指引留作备选信息。
    expect(switchSuggestion.defaultEndpoint, qwenTtsWsInferenceEndpoint);
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
      model: 'qwen-audio-3.1-tts-flash',
      apiKey: 'secret-tts-key',
    );

    expect(gateway.called, isFalse);
    expect(result.tierSuggestion, isA<VoiceTierSwitchSuggestion>());
    final switchSuggestion =
        result.tierSuggestion! as VoiceTierSwitchSuggestion;
    expect(switchSuggestion.targetProviderWireName, 'qwen_tts');
    expect(switchSuggestion.defaultEndpoint, qwenTtsWsInferenceEndpoint);
    expect(result.message, '这个型号要走千问朗读档的新版语音通道。');
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
    expect(unsupported.targetModel, 'qwen-audio-3.1-tts-flash');
    expect(result.message, unsupported.reason);
  });

  test('表 miss 照常出网试听，结果不带建议', () async {
    final gateway = _FakeTtsGateway(audio: [7, 8]);
    final service = TtsSettingsService(repository, gateway);
    final result = await service.test(
      provider: TtsProviderKind.qwenTts,
      baseUrl:
          'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
      model: 'custom-tts-model',
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

  test('3.1 型号配 wss 推理地址：正确落位，连接测试照常出网试听', () async {
    // 票 07：ws/wss 地址按 scheme 喂查询——新版语音通道条目在 wss 地址
    // 上是正确落位，不干预，照常出网。
    final gateway = _FakeTtsGateway(audio: [9]);
    final service = TtsSettingsService(repository, gateway);
    final result = await service.test(
      provider: TtsProviderKind.qwenTts,
      baseUrl: qwenTtsWsInferenceEndpoint,
      model: 'qwen-audio-3.1-tts-flash',
      apiKey: 'sk-bailian',
    );

    expect(gateway.called, isTrue);
    expect(result.succeeded, isTrue);
    expect(result.tierSuggestion, isNull);
  });

  test('连接测试端到端：wss 推理地址经新网关拿到试听音频（假 connector）', () async {
    // 地址 scheme 为 ws/wss：网关分派走经典 WS 推理会话（票 07），HTTP
    // 客户端一个字节都不该收到。脚本按 probe 02 实测形状回放：run-task
    // → task-started →（continue-task 后）WAV binary 帧 → task-finished。
    final connector = _ScriptedWsInferenceConnector();
    final service = TtsSettingsService(
      repository,
      TtsModelGateway(_ExplodingBytesHttpClient(), webSocketConnector: connector),
    );

    final result = await service.test(
      provider: TtsProviderKind.qwenTts,
      baseUrl: qwenTtsWsInferenceEndpoint,
      model: 'qwen-audio-3.1-tts-flash',
      apiKey: 'sk-bailian',
    );

    expect(result.succeeded, isTrue);
    expect(result.status, ProviderTestStatus.success);
    // 试听音频 = 网关拼 PCM 后本地包的 WAV（帧头已剥）。
    final wav = base64Decode(result.audioBase64!);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(
      ByteData.sublistView(wav, 24, 28).getUint32(0, Endian.little),
      24000,
    );
    expect(wav.sublist(44), [7, 8, 9]);

    // 建连细节：地址原样使用、Bearer 鉴权。
    expect(connector.lastUri.toString(), qwenTtsWsInferenceEndpoint);
    expect(connector.lastHeaders!['authorization'], 'Bearer sk-bailian');

    // run-task 载荷逐项（官方文档字段值 + 缺省音色/格式回落）。
    final runTask = connector.clientEvents.firstWhere(
      (event) => (event['header']! as Map)['action'] == 'run-task',
    );
    final runTaskHeader = runTask['header']! as Map<String, Object?>;
    expect(runTaskHeader['streaming'], 'duplex');
    expect(_uuidPattern.hasMatch(runTaskHeader['task_id']! as String), isTrue);
    expect(runTask['payload'], {
      'task_group': 'audio',
      'task': 'tts',
      'function': 'SpeechSynthesizer',
      'model': 'qwen-audio-3.1-tts-flash',
      'parameters': {
        'text_type': 'PlainText',
        'voice': 'longanhuan_v3.1',
        'format': 'wav',
        'sample_rate': 24000,
      },
      'input': <String, Object?>{},
    });
    // 同一任务所有事件共用同一 task_id；文本在 continue-task 的
    // payload.input.text；finish-task 的 payload.input 为空对象。
    expect(
      connector.clientEvents
          .map((event) => (event['header']! as Map)['task_id'])
          .toList(),
      everyElement(runTaskHeader['task_id']),
    );
    expect(
      connector.clientEvents
          .map((event) => (event['header']! as Map)['action'] as String)
          .toList(),
      ['run-task', 'continue-task', 'finish-task'],
    );
    expect(
      (connector.clientEvents[1]['payload']! as Map)['input'],
      {'text': ttsConnectionTestSentence},
    );
    expect(
      (connector.clientEvents[2]['payload']! as Map)['input'],
      <String, Object?>{},
    );
  });

  // 纯停顿与只有标点的回复不送朗读（票 02，ADR 0024 既存问题 2 的独立
  // 修正）：整段、分句、连续供给会话三条路径都不发；文字回复照常交付
  // 落盘（交付编排零改动），只有声音不出。
  group('纯停顿不送朗读（票 02）', () {
    test('整段路径（HTTP 档）：纯停顿回复拒绝，一个字节的网络请求都不发', () async {
      final client = _RecordingBytesHttpClient();
      final service = TtsSettingsService(
        repository,
        TtsModelGateway(client),
      );
      await service.save(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
        apiKey: 'tts-secret-value',
      );

      for (final text in const ['。。。', '……', '？？？', '。', '（等了一会儿）']) {
        await expectLater(
          service.synthesize(text),
          throwsA(
            isA<TtsServiceException>()
                .having((error) => error.code, 'code', 'tts_empty_text')
                .having(
                  (error) => error.message,
                  'message',
                  '这段话没有可以朗读的内容。',
                ),
          ),
          reason: '「$text」应拒绝且不出网',
        );
      }
      expect(client.postCalled, isFalse);
      expect(client.downloadCalled, isFalse);
    });

    test('整段路径（千问 WS 推理档）：纯停顿回复拒绝，WS 连接都不开', () async {
      final connector = _CountingWsConnector();
      final service = TtsSettingsService(
        repository,
        TtsModelGateway(
          _ExplodingBytesHttpClient(),
          webSocketConnector: connector,
        ),
      );
      await service.save(
        baseUrl: qwenTtsWsInferenceEndpoint,
        model: qwenTtsDefaultModel,
        provider: TtsProviderKind.qwenTts,
        apiKey: 'sk-secret-value',
      );

      await expectLater(
        service.synthesize('……'),
        throwsA(
          isA<TtsServiceException>().having(
            (error) => error.code,
            'code',
            'tts_empty_text',
          ),
        ),
      );
      expect(connector.connectCount, 0, reason: '纯停顿回复不应开任何会话');
    });

    test('分句路径：纯停顿句子回空块流，不请求网关、不算失败', () async {
      final ttsGateway = ScriptedTtsGateway(replies: const {
        '晚安。': ScriptedVoiceChunks([[1]]),
      });
      final service = TtsSettingsService(repository, ttsGateway);
      await service.save(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
        apiKey: 'tts-secret-value',
      );

      // 纯停顿句子：空块流（不是异常——异常会按 D1 误杀整段语音），
      // 网关零请求。
      expect(await service.synthesizeStream('。。。').toList(), isEmpty);
      expect(ttsGateway.requests, isEmpty);

      // 后续实词句子照常合成：静默不是失败，分句层继续。
      final chunks = await service.synthesizeStream('晚安。').toList();
      expect(chunks, hasLength(1));
      expect(chunks.single.bytes, [1]);
      expect(ttsGateway.requests, ['晚安。']);
    });

    test('连续供给会话：纯停顿增量扣住，实词到达先补发再发送（字节序不变）', () async {
      final ttsGateway = ScriptedTtsGateway(sessionReplies: const {
        '嗯': [[1]],
        '嗯。。。在。': [[2]],
      });
      final service = TtsSettingsService(repository, ttsGateway);
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

      // 块流先订阅（交付管线同口径）：单订阅流，收尾的 done 要有监听者。
      final chunksDone = session!.chunks.map((chunk) => chunk.bytes).toList();

      session.appendText('嗯');
      expect(ttsGateway.lastSession!.appends, ['嗯']);

      // 纯停顿增量扣住：不进会话，一个字节都不发。
      session.appendText('。。。');
      expect(ttsGateway.lastSession!.appends, ['嗯']);

      // 实词到达：先补发扣住的部分再发送——内容回复进会话的文本序与
      // 既有行为完全一致。
      session.appendText('在。');
      expect(ttsGateway.lastSession!.appends, ['嗯', '。。。', '在。']);

      await session.close();
      expect(
        await chunksDone,
        [
          [1],
          [2],
        ],
      );
    });

    test('连续供给会话：整条纯停顿的回复一个字节都不发，收尾正常', () async {
      final ttsGateway = ScriptedTtsGateway(sessionReplies: const {});
      final service = TtsSettingsService(repository, ttsGateway);
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

      // 块流先订阅（交付管线同口径）。
      final chunksDone = session!.chunks.toList();

      session.appendText('。。。');
      session.appendText('……？');
      session.appendText('（等了一会儿）');
      await session.close();

      expect(ttsGateway.lastSession!.appends, isEmpty);
      expect(await chunksDone, isEmpty);
    });

    test('连续供给会话：纯停顿尾缀在收尾时补发，内容回复听感不变', () async {
      final ttsGateway = ScriptedTtsGateway(sessionReplies: const {
        '晚安……': [[3]],
      });
      final service = TtsSettingsService(repository, ttsGateway);
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

      // 块流先订阅（交付管线同口径）。
      final chunksDone = session!.chunks.map((chunk) => chunk.bytes).toList();

      session.appendText('晚安');
      session.appendText('……');
      // 尾缀扣住中：实词已发送，纯停顿尾缀等收尾再定去留。
      expect(ttsGateway.lastSession!.appends, ['晚安']);

      await session.close();
      // 发过实词：收尾补发尾缀，服务端拿到的仍是完整原文。
      expect(ttsGateway.lastSession!.appends, ['晚安', '……']);
      expect(
        await chunksDone,
        [
          [3],
        ],
      );
    });
  });
}

/// 记录建连次数的 WS 连接器：断言「纯停顿回复连会话都不开」。
final class _CountingWsConnector implements ProviderWebSocketConnector {
  int connectCount = 0;

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async {
    connectCount += 1;
    throw StateError('测试不应建连');
  }
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

/// 票 07 端到端用例的脚本化 WS 连接器：按 probe 02 实测生命周期回放
/// 服务端事件（run-task → task-started，continue-task → WAV binary 帧，
/// finish-task → WAV binary 帧 + task-finished），上行文本帧解码留档供
/// 载荷断言。
final class _ScriptedWsInferenceConnector implements ProviderWebSocketConnector {
  final List<Map<String, Object?>> clientEvents = [];

  int connectCalls = 0;
  Uri? lastUri;
  Map<String, String>? lastHeaders;

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async {
    connectCalls += 1;
    lastUri = uri;
    lastHeaders = headers;
    return _ScriptedWsInferenceConnection(this);
  }
}

final class _ScriptedWsInferenceConnection
    implements ProviderWebSocketConnection {
  _ScriptedWsInferenceConnection(this._connector);

  final _ScriptedWsInferenceConnector _connector;
  final _binary = StreamController<List<int>>();
  final _text = StreamController<String>();

  /// 服务端帧的统一派发队列（与 tts_ws_gateways_test 的脚本化连接器同
  /// 律）：真实连接上两个帧视图出自同一条流按 wire 序派发，内存 fake
  /// 两个控制器直接 add 会让「尾帧 + task-finished」的同步 add 乱序，
  /// 按入队序逐帧派发保真。
  final _serverQueue = <({bool binary, Object? frame})>[];
  var _serverDispatchScheduled = false;

  @override
  Stream<List<int>> get messages => _binary.stream;

  @override
  Stream<String> get textMessages => _text.stream;

  @override
  void send(List<int> bytes) =>
      throw StateError('经典推理协议客户端只发文本帧');

  @override
  void sendText(String text) {
    final event = jsonDecode(text) as Map<String, Object?>;
    _connector.clientEvents.add(event);
    final action = (event['header']! as Map)['action']! as String;
    switch (action) {
      case 'run-task':
        _enqueueServerFrame(binary: false, frame: _serverEvent('task-started'));
      case 'continue-task':
        _enqueueServerFrame(binary: true, frame: _wavAudioFrame([7, 8]));
      case 'finish-task':
        _enqueueServerFrame(binary: true, frame: _wavAudioFrame([9]));
        _enqueueServerFrame(
          binary: false,
          frame: _serverEvent('task-finished'),
        );
    }
  }

  @override
  Future<void> close() async {
    unawaited(_binary.close());
    unawaited(_text.close());
  }

  void _enqueueServerFrame({required bool binary, required Object? frame}) {
    _serverQueue.add((binary: binary, frame: frame));
    _scheduleServerDispatch();
  }

  void _scheduleServerDispatch() {
    if (_serverDispatchScheduled) {
      return;
    }
    _serverDispatchScheduled = true;
    scheduleMicrotask(() {
      _serverDispatchScheduled = false;
      if (_serverQueue.isNotEmpty) {
        final queued = _serverQueue.removeAt(0);
        if (queued.binary) {
          if (!_binary.isClosed) {
            _binary.add(queued.frame as List<int>);
          }
        } else {
          if (!_text.isClosed) {
            _text.add(queued.frame as String);
          }
        }
      }
      if (_serverQueue.isNotEmpty) {
        _scheduleServerDispatch();
      }
    });
  }
}

String _serverEvent(String event) => jsonEncode({
  'header': {'task_id': 't-1', 'event': event, 'attributes': {}},
  'payload': <String, Object?>{},
});

/// 一帧自带完整 WAV 头的音频（探针基线形状：每个 binary 帧是独立的
/// WAV 文件），标准 44 字节头。
Uint8List _wavAudioFrame(List<int> pcm) {
  final bytes = BytesBuilder(copy: false);
  void tag(String value) => bytes.add(ascii.encode(value));
  void u32(int value) => bytes.add([
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]);
  void u16(int value) => bytes.add([value & 0xff, (value >> 8) & 0xff]);
  tag('RIFF');
  u32(36 + pcm.length);
  tag('WAVE');
  tag('fmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(24000);
  u32(24000 * 2);
  u16(2);
  u16(16);
  tag('data');
  u32(pcm.length);
  bytes.add(pcm);
  return bytes.takeBytes();
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// WS 路径绝不碰 HTTP：被调用即失败。
final class _ExplodingBytesHttpClient implements ProviderBytesHttpClient {
  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) => throw StateError('WS 推理路径不得走 HTTP 出网');

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) => throw StateError('WS 推理路径不得走 HTTP 出网');
}
