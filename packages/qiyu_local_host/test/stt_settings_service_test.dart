import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('qiyu-stt-settings-');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  String configPath() =>
      '${temp.path}${Platform.pathSeparator}provider.json';

  JsonProviderConfigRepository repository() =>
      JsonProviderConfigRepository(filePath: configPath());

  test('保存往返：configured/keySet 准确且快照永不包含明文 Key', () async {
    final service = SttSettingsService(repository(), _sttGateway('在吗'));
    final saved = await service.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: 'stt-secret-value',
    );

    expect(saved.configured, isTrue);
    expect(saved.keySet, isTrue);
    expect(saved.toJson(), isNot(contains('stt-secret-value')));
    // Key 随 stt 段落盘：用户可直接编辑该文件更换。
    final stored =
        jsonDecode(await File(configPath()).readAsString())
            as Map<String, Object?>;
    expect((stored['stt']! as Map<String, Object?>)['apiKey'], 'stt-secret-value');
  });

  test('同地址保存不带 Key 沿用旧 Key；换地址不沿用', () async {
    final service = SttSettingsService(repository(), _sttGateway('在吗'));
    await service.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: 'stt-secret-value',
    );

    final sameAddress = await service.save(
      baseUrl: 'https://stt.example.com/v1/',
      model: 'whisper-v2',
    );
    expect(sameAddress.keySet, isTrue);
    expect(sameAddress.config!.model, 'whisper-v2');

    final moved = await service.save(
      baseUrl: 'https://other.example.com/v1',
      model: 'whisper-test',
    );
    expect(moved.keySet, isFalse);
    expect(moved.configured, isTrue);
  });

  for (final scenario in [
    (
      name: '新 Key 优先并去空白',
      storedUrl: 'https://stt.example.com/v1',
      key: ' new-key ',
      expected: 'new-key',
    ),
    (
      name: 'null 沿用同作用域原值',
      storedUrl: 'https://stt.example.com/v1/',
      key: null,
      expected: 'old-key',
    ),
    (
      name: '空字符串沿用原值',
      storedUrl: 'https://stt.example.com/v1',
      key: '',
      expected: 'old-key',
    ),
    (
      name: '空白沿用原值',
      storedUrl: 'https://stt.example.com/v1',
      key: ' \t ',
      expected: 'old-key',
    ),
    (
      name: '换地址不沿用',
      storedUrl: 'https://other.example.com/v1',
      key: null,
      expected: null,
    ),
    (
      name: '换地址空白不沿用',
      storedUrl: 'https://other.example.com/v1',
      key: ' ',
      expected: null,
    ),
    (
      name: '换地址可提供新 Key',
      storedUrl: 'https://other.example.com/v1',
      key: ' new-key ',
      expected: 'new-key',
    ),
    (name: '无历史配置且无 Key', storedUrl: null, key: null, expected: null),
    (name: '无历史配置且空白 Key', storedUrl: null, key: ' ', expected: null),
    (
      name: '无历史配置可提供新 Key',
      storedUrl: null,
      key: ' new-key ',
      expected: 'new-key',
    ),
  ]) {
    test('保存与连接测试选择 Key：${scenario.name}', () async {
      final previous = scenario.storedUrl == null
          ? null
          : SttConfig(
              baseUrl: scenario.storedUrl!,
              model: 'old-model',
              apiKey: 'old-key',
            );
      final stored = _StaticSttConfigRepository(previous);
      final http = _StaticSttHttpClient('{"text":""}');
      final service = SttSettingsService(stored, SttModelGateway(http));

      final result = await service.test(
        baseUrl: 'https://stt.example.com/v1',
        model: 'new-model',
        apiKey: scenario.key,
      );

      expect(stored.config, same(previous));
      if (scenario.expected == null) {
        expect(result.status, ProviderTestStatus.authentication);
        expect(http.lastHeaders, isNull);
      } else {
        expect(result.succeeded, isTrue);
        expect(
          http.lastHeaders?['authorization'],
          'Bearer ${scenario.expected!.trim()}',
        );
      }

      final saved = await service.save(
        baseUrl: 'https://stt.example.com/v1',
        model: 'new-model',
        apiKey: scenario.key,
      );
      expect(saved.config!.apiKey, scenario.expected);
      expect(stored.config!.apiKey, scenario.expected);
      expect(saved.config!.model, 'new-model');
    });
  }

  test('连接测试沿用的 Key 保留脏字符并在出网前拒绝', () async {
    final http = _StaticSttHttpClient('{"text":""}');
    final stored = _StaticSttConfigRepository(
      const SttConfig(
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-test',
        apiKey: '\told-key\t',
      ),
    );
    final service = SttSettingsService(stored, SttModelGateway(http));

    final result = await service.test(apiKey: ' ');

    expect(result.status, ProviderTestStatus.contentParsing);
    expect(result.message, 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。');
    expect(http.lastHeaders, isNull);
    expect(stored.config!.apiKey, '\told-key\t');
    final saved = await service.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: ' ',
    );
    expect(saved.config!.apiKey, '\told-key\t');
  });

  test('忘记 Key 只清 Key，地址与模型保留', () async {
    final service = SttSettingsService(repository(), _sttGateway('在吗'));
    await service.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: 'stt-secret-value',
    );

    final forgotten = await service.forgetApiKey();

    expect(forgotten.configured, isTrue);
    expect(forgotten.keySet, isFalse);
    expect(forgotten.config!.baseUrl, 'https://stt.example.com/v1');
  });

  test('连接测试用内置静音音频：空文本也算成功，错误按分类上报', () async {
    final http = _StaticSttHttpClient('{"text":""}');
    final service = SttSettingsService(repository(), SttModelGateway(http));

    final result = await service.test(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: 'stt-test-key',
    );

    expect(result.succeeded, isTrue);
    expect(result.message, '连接成功，语音输入可以使用。');
    expect(http.lastBody, isNotEmpty);
    // 静音音频是合法 WAV（RIFF 头），且以 audio/wav 作为文件类型上送。
    expect(latin1.decode(http.lastBody!), contains('RIFF'));
    expect(latin1.decode(http.lastBody!), contains('content-type: audio/wav'));

    final failing = SttSettingsService(
      repository(),
      SttModelGateway(
        _StaticSttHttpClient('{}', statusCode: 429),
      ),
    );
    await failing.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: 'stt-secret-value',
    );
    final failure = await failing.test(baseUrl: '', model: '');
    expect(failure.succeeded, isFalse);
    expect(failure.status, ProviderTestStatus.rateLimited);
    expect(failure.message, '语音服务请求过于频繁，请稍后再试。');
  });

  test('filetrans：连接测试命中映射表零出网给精确建议，正式转写照旧出网给原文案', () async {
    // 诊断实录：流式/异步型号（如 filetrans）打到 HTTP 内联端点，服务端
    // 回 400「url error」，帮助链接是 error-code#error-url 形态。票 04 起
    // 连接测试在出网前查表命中、直接给精确建议（零出网）；正式转写路径
    // 与 ADR 0015 文案一字未动（正式路径文案升级是票 05）。
    final http = _StaticSttHttpClient(
      '{"code":"InvalidParameter","message":"url error, please check url！ For details, see: https://help.aliyun.com/zh/model-studio/error-code#error-url"}',
      statusCode: 400,
    );
    final service = SttSettingsService(repository(), SttModelGateway(http));
    await service.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'qwen-audio-3.0-asr-flash-filetrans',
      apiKey: 'stt-secret-value',
    );

    final tested = await service.test(
      baseUrl: 'https://stt.example.com/v1',
      model: 'qwen-audio-3.0-asr-flash-filetrans',
      apiKey: 'stt-secret-value',
    );
    expect(tested.status, ProviderTestStatus.modelInterfaceMismatch);
    expect(tested.message, '这是录音文件转写型号，栖语不支持。');
    expect(http.postCalls, 0, reason: '命中映射表不得出网');
    expect(tested.tierSuggestion, isA<VoiceTierUnsupportedSuggestion>());

    await expectLater(
      service.transcribe(audio: [1, 2], mimeType: 'audio/webm'),
      throwsA(
        isA<SttServiceException>()
            .having(
              (error) => error.code,
              'code',
              'stt_model_interface_mismatch',
            )
            .having(
              (error) => error.message,
              'message',
              '这个模型不能用当前服务地址调用，请更换模型或调整服务地址。',
            ),
      ),
    );
    expect(http.postCalls, 1, reason: '正式转写路径照常出网');
  });

  test('表 miss 型号挂 400 url error：连接测试照常出网，分类映射与文案一字不变', () async {
    // 既有分类映射回归：表外型号（qwen3-asr-turbo 不在映射表）走到真实
    // 上游、400 url error 按 ADR 0015 分类为「模型与接口不匹配」，通用
    // 文案逐字保留——filetrans 用例半段改写后，本条是连接测试路径对该
    // 分类映射的唯一锁定（与朗读侧同构）。
    final http = _StaticSttHttpClient(
      '{"code":"InvalidParameter","message":"url error, please check url！ For details, see: https://help.aliyun.com/zh/model-studio/error-code#error-url"}',
      statusCode: 400,
    );
    final service = SttSettingsService(repository(), SttModelGateway(http));
    await service.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'qwen3-asr-turbo',
      apiKey: 'stt-secret-value',
    );

    final tested = await service.test(
      baseUrl: 'https://stt.example.com/v1',
      model: 'qwen3-asr-turbo',
      apiKey: 'stt-secret-value',
    );
    expect(http.postCalls, 1, reason: '表 miss 照常出网');
    expect(tested.succeeded, isFalse);
    expect(tested.status, ProviderTestStatus.modelInterfaceMismatch);
    expect(tested.message, '这个模型不能用当前服务地址调用，请更换模型或调整服务地址。');
    expect(tested.tierSuggestion, isNull);
  });

  test('未配置时连接测试报 notConfigured，正式转写报可恢复失败', () async {
    final service = SttSettingsService(repository(), _sttGateway('在吗'));

    final result = await service.test(baseUrl: '', model: '');
    expect(result.status, ProviderTestStatus.notConfigured);

    await expectLater(
      service.transcribe(audio: [1, 2], mimeType: 'audio/webm'),
      throwsA(
        isA<SttServiceException>()
            .having((error) => error.code, 'code', 'stt_not_configured')
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
  });

  test('连接测试：Key 混入零宽空格提前拦为人话文案，不出网', () async {
    final http = _StaticSttHttpClient('{"text":""}');
    final service = SttSettingsService(repository(), SttModelGateway(http));

    final result = await service.test(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: 'stt-test-key\u200B',
    );

    expect(result.status, ProviderTestStatus.contentParsing);
    expect(result.message, 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。');
    expect(http.lastBody, isNull);
  });

  test('保存的配置模型带脏字符：正式转写报 stt_config_invalid 人话', () async {
    // save() 会拦住脏值，只有手改 provider.json 才会出现这种形态：用内存
    // 仓库直接注入脏配置，验证网关的配置校验被映射成可定位的诊断码。
    final http = _StaticSttHttpClient('{"text":"不应到达"}');
    final service = SttSettingsService(
      _StaticSttConfigRepository(
        const SttConfig(
          baseUrl: 'https://stt.example.com/v1',
          model: 'whisper-test\u200B',
          apiKey: 'stt-secret-value',
        ),
      ),
      SttModelGateway(http),
    );

    await expectLater(
      service.transcribe(audio: [1, 2], mimeType: 'audio/webm'),
      throwsA(
        isA<SttServiceException>()
            .having((error) => error.code, 'code', 'stt_config_invalid')
            .having(
              (error) => error.message,
              'message',
              '语音服务的模型名称里混入了中文或看不见的字符，请重新填写。',
            )
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
    expect(http.lastBody, isNull);
  });

  test('保存的配置 Key 带脏字符：正式转写报 stt_config_invalid 且不出网', () async {
    // Key 不进 validate()，save() 存得进脏 Key：正式转写在出网前按本地
    // 配置错误拦截，给出可定位文案。
    final http = _StaticSttHttpClient('{"text":"不应到达"}');
    final service = SttSettingsService(
      _StaticSttConfigRepository(
        const SttConfig(
          baseUrl: 'https://stt.example.com/v1',
          model: 'whisper-test',
          apiKey: 'stt-secret-value\u200B',
        ),
      ),
      SttModelGateway(http),
    );

    await expectLater(
      service.transcribe(audio: [1, 2], mimeType: 'audio/webm'),
      throwsA(
        isA<SttServiceException>()
            .having((error) => error.code, 'code', 'stt_config_invalid')
            .having(
              (error) => error.message,
              'message',
              'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
            )
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
    expect(http.lastBody, isNull);
  });

  for (final scenario in [
    (error: const SocketException('Failed host lookup'), code: 'stt_dns'),
    (error: const SocketException('offline'), code: 'stt_network'),
    (error: TimeoutException('timeout'), code: 'stt_timeout'),
    (error: HandshakeException('TLS failed'), code: 'stt_tls'),
  ]) {
    test('网络失败保留可重试分类 ${scenario.code}', () async {
      final service = SttSettingsService(repository(), SttModelGateway(
        _StaticSttHttpClient('')..postError = scenario.error));
      await service.save(baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-test', apiKey: 'stt-test-key');
      await expectLater(service.transcribe(audio: [1, 2], mimeType: 'audio/webm'),
        throwsA(isA<SttServiceException>()
          .having((error) => error.code, 'code', scenario.code)
          .having((error) => error.retryable, 'retryable', isTrue)));
    });
  }

  for (final status in [401, 403, 429]) {
    test('豆包真实 WebSocket 握手 $status 保留服务故障弹窗分类', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = status;
        await request.response.close();
      });
      final service = SttSettingsService(repository(), SttModelGateway(
        _StaticSttHttpClient(''),
        webSocketConnector: _LocalHandshakeConnector(server.port)));
      await service.save(provider: SttProviderKind.volcSeedAsr,
        baseUrl: 'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
        model: 'volc.seedasr.sauc.duration', apiKey: 'stt-test-key');
      await expectLater(service.transcribe(audio: [1, 2], mimeType: 'audio/wav'),
        throwsA(isA<SttServiceException>()
          .having((error) => error.code, 'code', status == 429
            ? 'stt_rate_limited' : 'stt_authentication')
          .having((error) => error.message, 'message', status == 429
            ? '语音服务请求过于频繁。' : 'API Key 未通过语音服务验证。')));
    });
  }

  test('正式转写空文本视为失败，正常文本照常返回', () async {
    final service = SttSettingsService(repository(), _sttGateway(''));
    await service.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: 'stt-secret-value',
    );

    await expectLater(
      service.transcribe(audio: [1, 2], mimeType: 'audio/webm'),
      throwsA(
        isA<SttServiceException>()
            .having((error) => error.code, 'code', 'stt_no_speech')
            .having((error) => error.message, 'message', contains('没有识别到语音'))
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );

    final speaking = SttSettingsService(repository(), _sttGateway(' 今天有点累 '));
    expect(
      await speaking.transcribe(audio: [1, 2], mimeType: 'audio/webm'),
      '今天有点累',
    );
  });

  test('上游转写失败映射为允许列表诊断码，不透出服务商原文', () async {
    final service = SttSettingsService(
      repository(),
      SttModelGateway(
        _StaticSttHttpClient('{"error":"429 Too Many Requests detail"}', statusCode: 429),
      ),
    );
    await service.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: 'stt-secret-value',
    );

    await expectLater(
      service.transcribe(audio: [1, 2], mimeType: 'audio/webm'),
      throwsA(
        isA<SttServiceException>()
            .having((error) => error.code, 'code', 'stt_rate_limited')
            .having((error) => error.message, 'message', '语音服务请求过于频繁。')
            .having(
              (error) => error.toString(),
              'redacted',
              isNot(contains('429 Too Many Requests detail')),
            ),
      ),
    );
  });

  test('豆包类型转写走 WS 网关：HTTP transcriptions 不再被调用', () async {
    final connector = _ScriptedVolcConnector(
      responsePayload: {'result': {'text': '今天有点累'}},
    );
    final http = _StaticSttHttpClient('{"text":"不应出现"}');
    final service = SttSettingsService(
      repository(),
      SttModelGateway(http, webSocketConnector: connector),
    );
    await service.save(
      provider: SttProviderKind.volcSeedAsr,
      baseUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
      model: 'volc.seedasr.sauc.duration',
      apiKey: 'ark-secret-value',
    );

    final audio = [9, 8, 7, 6];
    expect(await service.transcribe(audio: audio, mimeType: 'audio/wav'), '今天有点累');
    expect(http.lastBody, isNull); // HTTP 出网路径绝未触发。
    // 上送音频原样分块：全部 audio 帧解压拼接等于原始字节。
    expect(_rejoinAudioFrames(connector.sentFrames), audio);
    expect(
      connector.lastHeaders?['X-Api-Resource-Id'],
      'volc.seedasr.sauc.duration',
    );
  });

  test('豆包连接测试：内置静音 WAV 经 WS 代发，45000002/空文本都算成功', () async {
    // 静音 WAV 得到空文本（正常最终包）。
    final emptyText = SttSettingsService(
      repository(),
      SttModelGateway(
        _StaticSttHttpClient('{}'),
        webSocketConnector: _ScriptedVolcConnector(
          responsePayload: {'result': {'text': ''}},
        ),
      ),
    );
    final ok = await emptyText.test(
      provider: SttProviderKind.volcSeedAsr,
      baseUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
      model: 'volc.seedasr.sauc.duration',
      apiKey: 'ark-test-key',
    );
    expect(ok.succeeded, isTrue);
    expect(ok.message, '连接成功，语音输入可以使用。');

    // 静音 WAV 得到 45000002（空音频）error 码：同样算成功。
    final connector = _ScriptedVolcConnector(errorCode: 45000002);
    final errorOk = SttSettingsService(
      repository(),
      SttModelGateway(
        _StaticSttHttpClient('{}'),
        webSocketConnector: connector,
      ),
    );
    final result = await errorOk.test(
      provider: SttProviderKind.volcSeedAsr,
      baseUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
      model: 'volc.seedasr.sauc.duration',
      apiKey: 'ark-test-key',
    );
    expect(result.succeeded, isTrue);
    // 代发的就是内置静音 WAV（16kHz、单声道、含 RIFF 头）。
    expect(_rejoinAudioFrames(connector.sentFrames), sttConnectionTestAudio);
    expect(latin1.decode(sttConnectionTestAudio).startsWith('RIFF'), isTrue);
  });

  test('豆包正式转写遇 45000002 报「没有识别到语音」且可重试', () async {
    final service = SttSettingsService(
      repository(),
      SttModelGateway(
        _StaticSttHttpClient('{}'),
        webSocketConnector: _ScriptedVolcConnector(errorCode: 45000002),
      ),
    );
    await service.save(
      provider: SttProviderKind.volcSeedAsr,
      baseUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
      model: 'volc.seedasr.sauc.duration',
      apiKey: 'ark-secret-value',
    );

    await expectLater(
      service.transcribe(audio: [1], mimeType: 'audio/wav'),
      throwsA(
        isA<SttServiceException>()
            .having((error) => error.code, 'code', 'stt_no_speech')
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('千问档保存往返：provider 落 qwen_asr，快照不带明文 Key', () async {
    final service = SttSettingsService(repository(), _sttGateway('在吗'));

    final saved = await service.save(
      provider: SttProviderKind.qwenAsr,
      baseUrl: qwenAsrDefaultEndpoint,
      model: qwenAsrDefaultModel,
      apiKey: 'qwen-secret-value',
    );

    expect(saved.configured, isTrue);
    expect(saved.keySet, isTrue);
    expect(saved.config!.provider, SttProviderKind.qwenAsr);
    expect(saved.toJson()['provider'], 'qwen_asr');
    expect(saved.toJson(), isNot(contains('qwen-secret-value')));
    final stored =
        jsonDecode(await File(configPath()).readAsString())
            as Map<String, Object?>;
    expect(
      (stored['stt']! as Map<String, Object?>)['provider'],
      'qwen_asr',
    );
  });

  test('千问档连接测试与正式转写：原生形状请求、文本经 output 路径取出', () async {
    final http = _StaticSttHttpClient(
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
      }),
    );
    final service = SttSettingsService(repository(), SttModelGateway(http));

    final tested = await service.test(
      provider: SttProviderKind.qwenAsr,
      baseUrl: qwenAsrDefaultEndpoint,
      model: qwenAsrDefaultModel,
      apiKey: 'qwen-test-key',
    );
    expect(tested.succeeded, isTrue);
    expect(tested.message, '连接成功，语音输入可以使用。');
    expect(http.lastHeaders!['authorization'], 'Bearer qwen-test-key');
    // 静音代发音频是 WAV：data URL 的 mediatype 因此是 audio/wav。
    final sent = jsonDecode(utf8.decode(http.lastBody!)) as Map<String, Object?>;
    final content =
        ((sent['input'] as Map<String, Object?>)['messages'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .single['content'] as List<Object?>;
    expect(
      (content.single as Map<String, Object?>)['audio'],
      startsWith('data:audio/wav;base64,'),
    );

    await service.save(
      provider: SttProviderKind.qwenAsr,
      baseUrl: qwenAsrDefaultEndpoint,
      model: qwenAsrDefaultModel,
      apiKey: 'qwen-secret-value',
    );
    expect(
      await service.transcribe(audio: [1, 2, 3], mimeType: 'audio/wav'),
      '今天有点累',
    );
  });

  test('档位映射表命中：OpenAI 兼容档误填千问识别型号，发请求前引导换档，零出网', () async {
    final http = _StaticSttHttpClient('{"text":"不应到达"}');
    final service = SttSettingsService(repository(), SttModelGateway(http));

    final result = await service.test(
      baseUrl: 'https://stt.example.com/v1',
      // 大小写与首尾空白按表查询的归一口径命中。
      model: ' QWEN3-ASR-Flash ',
      apiKey: 'stt-test-key',
    );

    expect(http.postCalls, 0, reason: '命中映射表不得出网');
    expect(result.succeeded, isFalse);
    expect(result.status, ProviderTestStatus.modelInterfaceMismatch);
    expect(result.message, '这个型号要走千问识别档。');
    final suggestion = result.tierSuggestion;
    expect(suggestion, isA<VoiceTierSwitchSuggestion>());
    final switchSuggestion = suggestion! as VoiceTierSwitchSuggestion;
    expect(switchSuggestion.targetFamily, VoiceServiceFamily.transcription);
    expect(switchSuggestion.targetProviderWireName, 'qwen_asr');
    expect(switchSuggestion.targetModel, 'qwen3-asr-flash');
    // 缺省地址与型号可代填（现行形状条目）。
    expect(switchSuggestion.defaultEndpoint, qwenAsrDefaultEndpoint);
    // 建议 wire 形状与票 03 朗读侧同款（同一下发通道、同一字段集）。
    expect(result.toJson()['suggestion'], {
      'kind': 'switchTier',
      'targetFamily': 'transcription',
      'targetProvider': 'qwen_asr',
      'targetModel': 'qwen3-asr-flash',
      'reason': '这个型号要走千问识别档。',
      'defaultEndpoint': qwenAsrDefaultEndpoint,
    });
  });

  test('档位映射表命中：豆包档填千问识别型号，WS 连接器零建连（第二出网面）', () async {
    // 豆包档的出网面是 WebSocket 握手：零出网断言必须同时覆盖 HTTP POST
    // 与 WS 建连两个面，命中映射表时一个字节都不出门。
    final connector = _ScriptedVolcConnector(
      responsePayload: {'result': {'text': '不应到达'}},
    );
    final http = _StaticSttHttpClient('{"text":"不应到达"}');
    final service = SttSettingsService(
      repository(),
      SttModelGateway(http, webSocketConnector: connector),
    );

    final result = await service.test(
      provider: SttProviderKind.volcSeedAsr,
      baseUrl: 'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
      model: 'qwen3-asr-flash',
      apiKey: 'ark-test-key',
    );

    expect(connector.connectCalls, 0, reason: '命中映射表不得建连');
    expect(http.postCalls, 0, reason: '命中映射表不得出网');
    expect(result.status, ProviderTestStatus.modelInterfaceMismatch);
    expect(result.message, '这个型号要走千问识别档。');
    final suggestion = result.tierSuggestion;
    expect(suggestion, isA<VoiceTierSwitchSuggestion>());
    expect(
      (suggestion! as VoiceTierSwitchSuggestion).targetProviderWireName,
      'qwen_asr',
    );
  });

  test('档位映射表命中：千问识别档填 3.1 filetrans，给不支持话术与同档替代型号，零出网', () async {
    final http = _StaticSttHttpClient('{"text":"不应到达"}');
    final service = SttSettingsService(repository(), SttModelGateway(http));

    final result = await service.test(
      provider: SttProviderKind.qwenAsr,
      baseUrl: qwenAsrDefaultEndpoint,
      model: 'qwen-audio-3.1-asr-flash-filetrans',
      apiKey: 'qwen-test-key',
    );

    expect(http.postCalls, 0, reason: '命中映射表不得出网');
    expect(result.status, ProviderTestStatus.modelInterfaceMismatch);
    expect(result.message, '这是录音文件转写型号，栖语不支持。');
    final suggestion = result.tierSuggestion;
    expect(suggestion, isA<VoiceTierUnsupportedSuggestion>());
    final unsupported = suggestion! as VoiceTierUnsupportedSuggestion;
    expect(unsupported.targetFamily, VoiceServiceFamily.transcription);
    // 替代型号落位就在当前档：界面侧据此按同档回填（只改型号、Key 保留）。
    expect(unsupported.targetProviderWireName, 'qwen_asr');
    expect(unsupported.targetModel, 'qwen3-asr-flash');
    expect(unsupported.defaultEndpoint, qwenAsrDefaultEndpoint);

    // 映射表只给建议不拦保存：不支持的型号照样存得进（用户故事 8）。
    final saved = await service.save(
      provider: SttProviderKind.qwenAsr,
      baseUrl: qwenAsrDefaultEndpoint,
      model: 'qwen-audio-3.1-asr-flash-filetrans',
      apiKey: 'qwen-secret-value',
    );
    expect(saved.configured, isTrue);
    expect(saved.config!.model, 'qwen-audio-3.1-asr-flash-filetrans');
  });

  test('表 miss 与正确落位照常出网连接测试，结果不带建议', () async {
    final http = _StaticSttHttpClient('{"text":""}');
    final service = SttSettingsService(repository(), SttModelGateway(http));

    // 表外陌生型号：一切照旧。
    final miss = await service.test(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-test',
      apiKey: 'stt-test-key',
    );
    expect(miss.succeeded, isTrue);
    expect(miss.tierSuggestion, isNull);
    expect(http.postCalls, 1);

    // 千问识别档配 qwen3-asr-flash：正确落位同样不干预、照常出网。
    final qwenHttp = _StaticSttHttpClient(
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
    );
    final qwenService = SttSettingsService(repository(), SttModelGateway(qwenHttp));
    final placedRight = await qwenService.test(
      provider: SttProviderKind.qwenAsr,
      baseUrl: qwenAsrDefaultEndpoint,
      model: qwenAsrDefaultModel,
      apiKey: 'qwen-test-key',
    );
    expect(placedRight.succeeded, isTrue);
    expect(placedRight.tierSuggestion, isNull);
    expect(qwenHttp.postCalls, 1, reason: '正确落位照常出网');
  });

  test('自定义档保存往返：provider 落 custom，旋钮与高级参数随段落盘', () async {
    final service = SttSettingsService(repository(), _sttGateway('在吗'));

    final saved = await service.save(
      provider: SttProviderKind.custom,
      baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
      model: 'whisper-test',
      apiKey: 'custom-secret-value',
      authHeader: 'X-Api-Key',
      responseShape: SttResponseShape.sse,
      responseField: 'result.text',
      extraParams: {'speaker': 'zh'},
    );

    expect(saved.configured, isTrue);
    expect(saved.keySet, isTrue);
    expect(saved.config!.provider, SttProviderKind.custom);
    expect(saved.toJson()['provider'], 'custom');
    // 快照带旋钮供界面回显，但绝不带明文 Key。
    expect(saved.toJson()['authHeader'], 'X-Api-Key');
    expect(saved.toJson()['responseShape'], 'sse');
    expect(saved.toJson()['responseField'], 'result.text');
    expect(saved.toJson()['extraParams'], {'speaker': 'zh'});
    expect(saved.toJson(), isNot(contains('custom-secret-value')));
    final stored =
        jsonDecode(await File(configPath()).readAsString())
            as Map<String, Object?>;
    final section = stored['stt']! as Map<String, Object?>;
    expect(section['provider'], 'custom');
    expect(section['authHeader'], 'X-Api-Key');
    expect(section['responseShape'], 'sse');
    expect(section['responseField'], 'result.text');
    expect(section['extraParams'], {'speaker': 'zh'});
  });

  test('自定义档连接测试：multipart 上送、按所选响应形态完整走一遍', () async {
    // SSE 形态：逐行 data 事件拼出文本即算连通。
    final http = _StaticSttHttpClient('data: 连接\n\ndata: 成功\n\n');
    final service = SttSettingsService(repository(), SttModelGateway(http));

    final tested = await service.test(
      provider: SttProviderKind.custom,
      baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
      model: 'whisper-test',
      apiKey: 'custom-test-key',
      authHeader: 'X-Api-Key',
      responseShape: SttResponseShape.sse,
      extraParams: {'speaker': 'zh'},
    );

    expect(tested.succeeded, isTrue);
    expect(tested.message, '连接成功，语音输入可以使用。');
    expect(
      http.lastUri.toString(),
      'https://stt.example.com/v1/audio/transcriptions',
    );
    // 鉴权头按配置拼接，multipart 表单带模型、语言与高级参数字段。
    expect(http.lastHeaders!['x-api-key'], 'custom-test-key');
    expect(http.lastHeaders!['content-type'], startsWith('multipart/form-data'));
    final body = latin1.decode(http.lastBody!);
    expect(body, contains('name="model"\r\n\r\nwhisper-test'));
    expect(body, contains('name="language"\r\n\r\nzh'));
    expect(body, contains('name="speaker"\r\n\r\nzh'));
    expect(body, contains('filename="recording.wav"'));

    // json_path 形态：嵌套点号路径取到文本即算连通。
    final nested = SttSettingsService(
      repository(),
      SttModelGateway(
        _StaticSttHttpClient('{"result":{"text":"在"}}'),
      ),
    );
    final nestedResult = await nested.test(
      provider: SttProviderKind.custom,
      baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
      model: 'whisper-test',
      apiKey: 'custom-test-key',
      responseField: 'result.text',
    );
    expect(nestedResult.succeeded, isTrue);

    // 空文本语义两半分：连接测试遇静音空文本算成功（与既有档同口径）。
    final silent = SttSettingsService(
      repository(),
      SttModelGateway(_StaticSttHttpClient('data: [DONE]\n\n')),
    );
    final silentResult = await silent.test(
      provider: SttProviderKind.custom,
      baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
      model: 'whisper-test',
      apiKey: 'custom-test-key',
      responseShape: SttResponseShape.sse,
    );
    expect(silentResult.succeeded, isTrue);
    expect(silentResult.message, '连接成功，语音输入可以使用。');

    // 正式转写沿用空文本语义：识别为空视为失败。
    final empty = SttSettingsService(repository(), _sttGateway(''));
    await empty.save(
      provider: SttProviderKind.custom,
      baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
      model: 'whisper-test',
      apiKey: 'custom-secret-value',
    );
    await expectLater(
      empty.transcribe(audio: [1, 2], mimeType: 'audio/webm'),
      throwsA(
        isA<SttServiceException>()
            .having((error) => error.code, 'code', 'stt_no_speech')
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('损坏的 stt 段只影响 STT，不拖垮聊天配置读取', () async {
    await repository().save(
      const ProviderConfig(
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://chat.example.com/v1',
        model: 'chat-model',
        temperature: 0.6,
        timeoutSeconds: 25,
      ),
    );
    final raw =
        jsonDecode(await File(configPath()).readAsString())
            as Map<String, Object?>;
    raw['stt'] = 'broken';
    await File(configPath()).writeAsString(jsonEncode(raw));

    final chat = await repository().load();
    expect(chat!.model, 'chat-model');
    await expectLater(
      repository().loadStt(),
      throwsA(isA<ProviderConfigException>()),
    );
  });
}

SttModelGateway _sttGateway(String text) =>
    SttModelGateway(_StaticSttHttpClient(jsonEncode({'text': text})));

/// 内存版 STT 配置仓库：绕过文件仓库自带的校验，模拟只有手改
/// provider.json 才会出现的脏配置形态。
final class _StaticSttConfigRepository implements SttConfigRepository {
  _StaticSttConfigRepository(this.config);

  SttConfig? config;

  @override
  Future<SttConfig?> loadStt() async => config;

  @override
  Future<void> saveStt(SttConfig config) async => this.config = config;

  @override
  Future<T> runTransaction<T>(Future<T> Function() action) => action();
}

/// 把豆包 audio 帧（正包与末片）解压拼接：验证整段音频原样上送。
/// 带序列号的帧结构：头 4 + i32 序号 + u32 长度 + payload。
List<int> _rejoinAudioFrames(List<List<int>> frames) {
  final rejoined = <int>[];
  for (final frame in frames) {
    final typeFlags = frame[1];
    if (typeFlags != 0x21 && typeFlags != 0x23) {
      continue; // 只看音频帧（0x21 正包 / 0x23 末片），跳过 full request。
    }
    final length =
        (frame[8] << 24) | (frame[9] << 16) | (frame[10] << 8) | frame[11];
    rejoined.addAll(gzip.decode(frame.sublist(12, 12 + length)));
  }
  return rejoined;
}

/// 脚本化豆包 WS 连接器：记录全部上行帧；收到 full request 回确认帧，
/// 收到负序号末片回最终包或 error 帧（与官方示例时序一致）。
final class _ScriptedVolcConnector implements ProviderWebSocketConnector {
  _ScriptedVolcConnector({this.responsePayload, this.errorCode});

  final Map<String, Object?>? responsePayload;
  final int? errorCode;
  int connectCalls = 0;
  final sentFrames = <List<int>>[];
  Map<String, String>? lastHeaders;

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async {
    connectCalls += 1;
    lastHeaders = headers;
    return _ScriptedVolcConnection(this);
  }
}

final class _ScriptedVolcConnection implements ProviderWebSocketConnection {
  _ScriptedVolcConnection(this._connector);

  final _ScriptedVolcConnector _connector;
  final _incoming = StreamController<List<int>>();

  static Uint8List _responseFrame(
    int flags,
    Map<String, Object?> payload,
  ) {
    final compressed = gzip.encode(utf8.encode(jsonEncode(payload)));
    return Uint8List.fromList([
      0x11, 0x90 | flags, 0x11, 0x00,
      0, 0, 0, 1, // sequence
      (compressed.length >> 24) & 0xFF, (compressed.length >> 16) & 0xFF,
      (compressed.length >> 8) & 0xFF, compressed.length & 0xFF,
      ...compressed,
    ]);
  }

  void _serverSends(Uint8List frame) {
    scheduleMicrotask(() => _incoming.add(frame));
  }

  @override
  Stream<List<int>> get messages => _incoming.stream;

  // 票三新增的文本帧视图：转写假连接只回二进制帧，文本流恒空。
  @override
  Stream<String> get textMessages => const Stream.empty();

  @override
  void send(List<int> bytes) {
    _connector.sentFrames.add(bytes);
    if (bytes.length < 2) {
      return;
    }
    if (bytes[1] == 0x11) {
      // full client request（type 0001 + POS_SEQUENCE）→ 回确认帧。
      _serverSends(_responseFrame(0x91, {}));
    } else if (bytes[1] == 0x23) {
      // 负序号末片 → 回最终包或 error 帧。
      if (_connector.errorCode case final code?) {
        final message = utf8.encode('upstream secret detail');
        _serverSends(Uint8List.fromList([
          0x11, 0xF0, 0x11, 0x00,
          (code >> 24) & 0xFF, (code >> 16) & 0xFF,
          (code >> 8) & 0xFF, code & 0xFF,
          0, 0, 0, message.length,
          ...message,
        ]));
      } else {
        _serverSends(
          _responseFrame(0x93, _connector.responsePayload ?? const {}),
        );
      }
    }
  }

  @override
  void sendText(String text) {}

  @override
  Future<void> close() async {}
}

final class _StaticSttHttpClient implements ProviderHttpClient {
  _StaticSttHttpClient(this.responseBody, {this.statusCode = 200});

  final String responseBody;
  Object? postError;
  final int statusCode;
  int postCalls = 0;
  Uri? lastUri;
  List<int>? lastBody;
  Map<String, String>? lastHeaders;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    postCalls += 1;
    if (postError case final error?) throw error;
    lastUri = uri;
    lastBody = body;
    lastHeaders = headers;
    return ProviderHttpResponse(
      statusCode: statusCode,
      body: Stream.value(responseBody),
    );
  }
}

/// 将测试请求送至本地握手服务器，连接与异常构造仍由真实 Dart 实现完成。
final class _LocalHandshakeConnector implements ProviderWebSocketConnector {
  _LocalHandshakeConnector(this.port);
  final int port;

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri, required Map<String, String> headers,
  }) => const DartIoProviderWebSocketConnector().connect(
    uri: Uri.parse('ws://127.0.0.1:$port/'), headers: headers);
}
