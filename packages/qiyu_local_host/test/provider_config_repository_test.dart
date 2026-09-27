import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';

void main() {
  test('webSearch 段独立往返且损坏只使搜索不可用', () async {
    final temp = await Directory.systemTemp.createTemp(
      'qiyu-web-search-config-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    final repository = JsonProviderConfigRepository(filePath: filePath);
    await repository.save(
      const ProviderConfig(
        kind: ProviderKind.anthropic,
        baseUrl: 'https://api.example.com/v1',
        model: 'deepseek-v4-flash',
        temperature: 0.6,
        timeoutSeconds: 25,
      ).withApiKey('chat-secret'),
    );
    await repository.saveWebSearch(const WebSearchConfig(apiKey: 'any-secret'));

    expect((await repository.loadWebSearch())!.apiKey, 'any-secret');
    expect((await repository.load())!.apiKey, 'chat-secret');
    final json =
        jsonDecode(await File(filePath).readAsString()) as Map<String, Object?>;
    json['webSearch'] = 'broken';
    await File(filePath).writeAsString(jsonEncode(json));

    expect(await repository.loadWebSearch(), isNull);
    expect((await repository.load())!.apiKey, 'chat-secret');
  });

  test('普通 Provider 配置重启后仍可读取且文件不包含 Key', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-provider-config-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    final repository = JsonProviderConfigRepository(filePath: filePath);
    const config = ProviderConfig(
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'https://example.com/v1',
      model: 'chat-model',
      temperature: 0.6,
      timeoutSeconds: 25,
    );

    await repository.save(config);
    final restored = await JsonProviderConfigRepository(
      filePath: filePath,
    ).load();

    expect(restored, config);
    final json = jsonDecode(await File(filePath).readAsString());
    expect(json, isNot(contains('apiKey')));
    expect(await File(filePath).readAsString(), isNot(contains('secret')));
  });

  test('保存的 API Key 原样落盘并在重启后读回', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-provider-key-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    final repository = JsonProviderConfigRepository(filePath: filePath);
    const config = ProviderConfig(
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'https://example.com/v1',
      model: 'chat-model',
      temperature: 0.6,
      timeoutSeconds: 25,
    );

    await repository.save(config.withApiKey('file-secret-value'));
    final restored = await JsonProviderConfigRepository(
      filePath: filePath,
    ).load();

    // Key 属于凭据不参与配置相等判断；快照序列化也不携带明文。
    expect(restored, config);
    expect(restored!.apiKey, 'file-secret-value');
    final json =
        jsonDecode(await File(filePath).readAsString()) as Map<String, Object?>;
    expect(json['apiKey'], 'file-secret-value');
    expect(config.toJson(), isNot(contains('apiKey')));
  });

  test('带 BOM 的配置文件与无 BOM 解析一致，保存不整体重建', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-provider-bom-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    const fixtureText = '''
{
  "schemaVersion": 1,
  "provider": "openai_compatible",
  "baseUrl": "https://chat.example.com/v1",
  "model": "chat-model",
  "temperature": 0.6,
  "timeoutSeconds": 25,
  "apiKey": "fake-chat-key-not-real",
  "stt": {
    "provider": "openai_compatible",
    "baseUrl": "https://stt.example.com/v1",
    "model": "whisper-fake",
    "apiKey": "fake-stt-key-not-real"
  },
  "webSearch": {
    "apiKey": "fake-search-key-not-real"
  },
  "proxy": {
    "enabled": true,
    "host": "proxy.example.com",
    "port": 7890
  },
  "unknownObject": {
    "keptByBaseline": "do-not-touch"
  }
}
''';
    // 手动编辑过的文件可能以 UTF-8 BOM 开头：读取层剥 BOM 再解析，
    // 与无 BOM 文件的解析结果一致。
    final file = File(filePath);
    await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(fixtureText)]);

    final repository = JsonProviderConfigRepository(filePath: filePath);
    final loaded = await repository.load();
    expect(loaded!.kind, ProviderKind.openAiCompatible);
    expect(loaded.model, 'chat-model');
    expect(loaded.apiKey, 'fake-chat-key-not-real');
    expect((await repository.loadStt())!.apiKey, 'fake-stt-key-not-real');
    expect((await repository.loadWebSearch())!.apiKey, 'fake-search-key-not-real');
    expect((await repository.loadProxy())!.host, 'proxy.example.com');
    // 读取不回写：文件字节原样保留（BOM 与内容都不动）。
    final bytesAfterLoad = await file.readAsBytes();
    expect(bytesAfterLoad.sublist(0, 3), [0xEF, 0xBB, 0xBF]);

    // 保存设置沿用「读整份只改本段」：其余段与未知键不静默消失。
    await repository.runTransaction(() async {
      await repository.save(
        const ProviderConfig(
          kind: ProviderKind.openAiCompatible,
          baseUrl: 'https://chat.example.com/v2',
          model: 'chat-model-2',
          temperature: 0.6,
          timeoutSeconds: 25,
        ).withApiKey('fake-chat-key-not-real'),
      );
    });
    final stored =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(stored['model'], 'chat-model-2');
    expect(stored['stt'], isNotNull);
    expect(stored['webSearch'], isNotNull);
    expect(stored['proxy'], isNotNull);
    expect(stored['unknownObject'], isNotNull);
  });

  test('文件开头残留 BOM 字符（重复 BOM）也在解析层剥除', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-provider-bom2-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    const json = '''
{
  "provider": "anthropic",
  "baseUrl": "https://api.anthropic.com/v1",
  "model": "claude-test",
  "temperature": 0.7,
  "timeoutSeconds": 30,
  "apiKey": "fake-key-not-real"
}
''';
    // 文件首 BOM 由 utf8 解码器丢弃后，重复 BOM 的第二个字符会留在
    // 字符串层；解析层剥除后同样照常解析，不再当作损坏。
    final file = File(filePath);
    await file.writeAsBytes([
      0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, ...utf8.encode(json),
    ]);

    final repository = JsonProviderConfigRepository(filePath: filePath);
    final loaded = await repository.load();
    expect(loaded!.kind, ProviderKind.anthropic);
    expect(loaded.apiKey, 'fake-key-not-real');
    // 保存也不再按整体重建：读路径与写路径都剥 BOM。
    await repository.runTransaction(() async {
      await repository.save(
        const ProviderConfig(
          kind: ProviderKind.anthropic,
          baseUrl: 'https://api.anthropic.com/v1',
          model: 'claude-test',
          temperature: 0.7,
          timeoutSeconds: 30,
        ).withApiKey('fake-key-not-real'),
      );
    });
    expect(jsonDecode(await file.readAsString()), isA<Map<String, Object?>>());
  });

  test('兼容用户直接写 API_KEY 大写字段，空白值视为未设置', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-provider-alias-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    await File(filePath).writeAsString('''
{
  "schemaVersion": 1,
  "provider": "anthropic",
  "baseUrl": "https://api.anthropic.com/v1",
  "model": "claude-test",
  "temperature": 0.7,
  "timeoutSeconds": 30,
  "API_KEY": "upper-case-secret"
}
''');

    final restored = await JsonProviderConfigRepository(
      filePath: filePath,
    ).load();
    expect(restored!.apiKey, 'upper-case-secret');

    await File(filePath).writeAsString('''
{
  "schemaVersion": 1,
  "provider": "anthropic",
  "baseUrl": "https://api.anthropic.com/v1",
  "model": "claude-test",
  "temperature": 0.7,
  "timeoutSeconds": 30,
  "apiKey": "   "
}
''');
    final blank = await JsonProviderConfigRepository(filePath: filePath).load();
    expect(blank!.apiKey, isNull);
  });

  test('无效 Provider 配置不会被保存', () async {
    final temp = await Directory.systemTemp.createTemp(
      'qiyu-provider-invalid-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final repository = JsonProviderConfigRepository(
      filePath: '${temp.path}${Platform.pathSeparator}provider.json',
    );

    expect(
      () => repository.save(
        const ProviderConfig(
          kind: ProviderKind.anthropic,
          baseUrl: 'file:///not-http',
          model: '',
          temperature: 3,
          timeoutSeconds: 0,
        ),
      ),
      throwsA(isA<ProviderConfigException>()),
    );
  });

  test('stt 段 provider 解析：缺省 openai_compatible、豆包往返、非法值中文报错', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-stt-provider-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}${Platform.pathSeparator}provider.json';
    JsonProviderConfigRepository repository() =>
        JsonProviderConfigRepository(filePath: path);

    // 不带 provider 字段的存量配置照常读为 openai_compatible。
    await File(path).writeAsString(
      jsonEncode({
        'stt': {
          'baseUrl': 'https://stt.example.com/v1',
          'model': 'whisper-test',
        },
      }),
    );
    expect(
      (await repository().loadStt())!.provider,
      SttProviderKind.openAiCompatible,
    );

    // 豆包协议往返：wss 地址通过校验并原样落盘。
    await repository().saveStt(
      const SttConfig(
        provider: SttProviderKind.volcSeedAsr,
        baseUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
        model: 'volc.seedasr.sauc.duration',
      ),
    );
    final restored = await repository().loadStt();
    expect(restored!.provider, SttProviderKind.volcSeedAsr);
    expect(
      restored.baseUrl,
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
    );
    final json =
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    expect((json['stt']! as Map<String, Object?>)['provider'], 'volc_seed_asr');

    // 非法协议名按中文配置错误拒绝。
    await File(path).writeAsString(
      jsonEncode({
        'stt': {
          'provider': 'azure_speech',
          'baseUrl': 'https://stt.example.com/v1',
          'model': 'whisper-test',
        },
      }),
    );
    await expectLater(
      repository().loadStt(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '不支持这个语音服务协议。',
        ),
      ),
    );
  });

  test('stt 段按协议校验地址 scheme 与 Key 沿用作用域', () async {
    // 豆包协议只接受 ws/wss 地址。
    expect(
      () => const SttConfig(
        provider: SttProviderKind.volcSeedAsr,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
        model: 'volc.seedasr.sauc.duration',
      ).validate(),
      throwsA(isA<ProviderConfigException>()),
    );
    // OpenAI 兼容协议沿用 http/https 约束。
    expect(
      () => const SttConfig(
        baseUrl: 'ws://stt.example.com/v1',
        model: 'whisper-test',
      ).validate(),
      throwsA(isA<ProviderConfigException>()),
    );
    // 协议不同则 Key 作用域不同：换协议不沿用旧 Key。
    const openAi = SttConfig(
      baseUrl: 'https://openspeech.bytedance.com/v1',
      model: 'whisper-test',
    );
    const volc = SttConfig(
      provider: SttProviderKind.volcSeedAsr,
      baseUrl: 'https://openspeech.bytedance.com/v1',
      model: 'volc.seedasr.sauc.duration',
    );
    expect(openAi.credentialScope, isNot(volc.credentialScope));
  });

  test('stt 地址与模型名混入非可见 ASCII 按粘贴事故拒绝', () {
    // baseUrl 里的零宽空格（U+200B）：从控制台/文档复制时常见，会让
    // dart:io 写 HTTP 头时抛未分类异常。
    expect(
      () => const SttConfig(
        provider: SttProviderKind.volcSeedAsr,
        baseUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel\u200B',
        model: 'volc.seedasr.sauc.duration',
      ).validate(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '语音服务地址里混入了中文或看不见的字符，请重新复制粘贴。',
        ),
      ),
    );
    // 模型名里的中文。
    expect(
      () => const SttConfig(
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper测试',
      ).validate(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '语音服务的模型名称里混入了中文或看不见的字符，请重新填写。',
        ),
      ),
    );
    // 干净值不受影响。
    expect(
      () => const SttConfig(
        provider: SttProviderKind.volcSeedAsr,
        baseUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
        model: 'volc.seedasr.sauc.duration',
      ).validate(),
      returnsNormally,
    );
  });

  test('containsNonVisibleAscii 边界值：0x21–0x7E 通过，0x20/0x7F 拒绝', () {
    // 可见 ASCII 两端恰好通过。
    expect(containsNonVisibleAscii(String.fromCharCode(0x21)), isFalse); // !
    expect(containsNonVisibleAscii(String.fromCharCode(0x7E)), isFalse); // ~
    expect(containsNonVisibleAscii('Az09-._~'), isFalse);
    // 空格与 DEL 恰好拒绝。
    expect(containsNonVisibleAscii(String.fromCharCode(0x20)), isTrue);
    expect(containsNonVisibleAscii(String.fromCharCode(0x7F)), isTrue);
  });

  test('stt 段 qwen_asr 往返：HTTP scheme 放行、Key 作用域随协议隔离', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-stt-qwen-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}${Platform.pathSeparator}provider.json';
    JsonProviderConfigRepository repository() =>
        JsonProviderConfigRepository(filePath: path);

    await repository().saveStt(
      const SttConfig(
        provider: SttProviderKind.qwenAsr,
        baseUrl: qwenAsrDefaultEndpoint,
        model: qwenAsrDefaultModel,
        apiKey: 'qwen-secret-value',
      ),
    );
    final restored = await repository().loadStt();
    expect(restored!.provider, SttProviderKind.qwenAsr);
    expect(restored.baseUrl, qwenAsrDefaultEndpoint);
    expect(restored.model, qwenAsrDefaultModel);
    expect(restored.apiKey, 'qwen-secret-value');
    final json = jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    expect((json['stt']! as Map<String, Object?>)['provider'], 'qwen_asr');

    // 千问档与 OpenAI 兼容档同为 HTTP 家族：http/https 都放行，ws 拒绝。
    expect(
      () => const SttConfig(
        provider: SttProviderKind.qwenAsr,
        baseUrl: 'http://dashscope.example.com/api/v1',
        model: qwenAsrDefaultModel,
      ).validate(),
      returnsNormally,
    );
    expect(
      () => const SttConfig(
        provider: SttProviderKind.qwenAsr,
        baseUrl: 'ws://dashscope.example.com/api/v1',
        model: qwenAsrDefaultModel,
      ).validate(),
      throwsA(isA<ProviderConfigException>()),
    );

    // 新协议自然进入「协议 + 规范化地址」作用域：同地址换协议不沿用 Key。
    const openAi = SttConfig(
      baseUrl: qwenAsrDefaultEndpoint,
      model: 'whisper-test',
    );
    const qwen = SttConfig(
      provider: SttProviderKind.qwenAsr,
      baseUrl: qwenAsrDefaultEndpoint,
      model: qwenAsrDefaultModel,
    );
    expect(openAi.credentialScope, isNot(qwen.credentialScope));
    // 同协议换地址（地域端点）同样不沿用。
    expect(
      qwen.credentialScope,
      isNot(
        const SttConfig(
          provider: SttProviderKind.qwenAsr,
          baseUrl:
              'https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
          model: qwenAsrDefaultModel,
        ).credentialScope,
      ),
    );
  });

  test('stt 段 custom 往返：旋钮与高级参数落盘、缺省值、非自定义档不落盘旋钮', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-stt-custom-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}${Platform.pathSeparator}provider.json';
    JsonProviderConfigRepository repository() =>
        JsonProviderConfigRepository(filePath: path);

    // 自定义档完整往返：鉴权头、响应形态、字段路径与高级参数逐一读回。
    await repository().saveStt(
      const SttConfig(
        provider: SttProviderKind.custom,
        baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
        model: 'whisper-test',
        apiKey: 'custom-secret-value',
        authHeader: 'X-Api-Key',
        responseShape: SttResponseShape.sse,
        responseField: 'result.text',
        extraParams: {'speaker': 'zh'},
      ),
    );
    final restored = await repository().loadStt();
    expect(restored!.provider, SttProviderKind.custom);
    expect(restored.authHeader, 'X-Api-Key');
    expect(restored.responseShape, SttResponseShape.sse);
    expect(restored.responseField, 'result.text');
    expect(restored.extraParams, {'speaker': 'zh'});
    expect(restored.apiKey, 'custom-secret-value');
    final json =
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    final section = json['stt']! as Map<String, Object?>;
    expect(section['provider'], 'custom');
    expect(section['authHeader'], 'X-Api-Key');
    expect(section['responseShape'], 'sse');
    expect(section['responseField'], 'result.text');
    expect(section['extraParams'], {'speaker': 'zh'});

    // 旋钮缺省值：custom 段不带旋钮时按缺省读（等价默认 Bearer 与 text）。
    await File(path).writeAsString(
      jsonEncode({
        'stt': {
          'provider': 'custom',
          'baseUrl': 'https://stt.example.com/v1/audio/transcriptions',
          'model': 'whisper-test',
        },
      }),
    );
    final defaults = await repository().loadStt();
    expect(defaults!.authHeader, isNull);
    expect(defaults.responseShape, SttResponseShape.jsonPath);
    expect(defaults.responseField, 'text');
    expect(defaults.extraParams, isNull);

    // 非自定义档不落盘旋钮与高级参数：构造时带上也只在 custom 档生效。
    await repository().saveStt(
      const SttConfig(
        provider: SttProviderKind.openAiCompatible,
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-test',
        authHeader: 'X-Api-Key',
        responseShape: SttResponseShape.sse,
        responseField: 'result.text',
        extraParams: {'speaker': 'zh'},
      ),
    );
    final openAi =
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    final openAiSection = openAi['stt']! as Map<String, Object?>;
    expect(openAiSection['provider'], 'openai_compatible');
    expect(openAiSection.containsKey('authHeader'), isFalse);
    expect(openAiSection.containsKey('responseShape'), isFalse);
    expect(openAiSection.containsKey('responseField'), isFalse);
    expect(openAiSection.containsKey('extraParams'), isFalse);

    // 存量配置兼容：不带 provider 与旋钮的老 stt 段照常读为 OpenAI 兼容。
    await File(path).writeAsString(
      jsonEncode({
        'stt': {
          'baseUrl': 'https://stt.example.com/v1',
          'model': 'whisper-test',
          'apiKey': 'legacy-secret-value',
        },
      }),
    );
    final legacy = await repository().loadStt();
    expect(legacy!.provider, SttProviderKind.openAiCompatible);
    expect(legacy.apiKey, 'legacy-secret-value');
    expect(legacy.responseShape, SttResponseShape.jsonPath);
    expect(legacy.responseField, 'text');
  });

  test('stt 段 custom 校验：HTTP scheme 放行、鉴权头脏字符与空头名人话、Key 作用域随协议隔离', () {
    // 自定义档同属 HTTP 家族：http/https 放行，ws 拒绝。
    expect(
      () => const SttConfig(
        provider: SttProviderKind.custom,
        baseUrl: 'http://stt.example.com/v1/audio/transcriptions',
        model: 'whisper-test',
      ).validate(),
      returnsNormally,
    );
    expect(
      () => const SttConfig(
        provider: SttProviderKind.custom,
        baseUrl: 'ws://stt.example.com/v1/audio/transcriptions',
        model: 'whisper-test',
      ).validate(),
      throwsA(isA<ProviderConfigException>()),
    );

    // 鉴权头脏字符与空头名（": Bearer" 这种粘贴事故会让 dart:io 写出
    // 空头名，请求期才炸未分类异常）在保存前拦成人话。
    expect(
      () => const SttConfig(
        provider: SttProviderKind.custom,
        baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
        model: 'whisper-test',
        authHeader: 'X-Api-Key\u200B',
      ).validate(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '鉴权头里混入了中文或看不见的字符，请重新填写。',
        ),
      ),
    );
    expect(
      () => const SttConfig(
        provider: SttProviderKind.custom,
        baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
        model: 'whisper-test',
        authHeader: ': Bearer',
      ).validate(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '鉴权头格式不正确，请填写如 Authorization: Bearer 的头名。',
        ),
      ),
    );

    // 保留头名撞名在保存前拦成人话：content-type 撞名会被网关自己写的
    // multipart 头静默覆盖（无鉴权出网），大小写不敏感都拦。
    for (final authHeader in ['Content-Type: Bearer', 'content-length', 'HOST']) {
      expect(
        () => SttConfig(
          provider: SttProviderKind.custom,
          baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
          model: 'whisper-test',
          authHeader: authHeader,
        ).validate(),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            '鉴权头不能使用 Content-Type、Content-Length 这类保留头名，请重新填写。',
          ),
        ),
        reason: authHeader,
      );
    }

    // 高级参数空键名按格式不正确拒绝（仅 custom 档校验）。
    expect(
      () => const SttConfig(
        provider: SttProviderKind.custom,
        baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
        model: 'whisper-test',
        extraParams: {'': 'value'},
      ).validate(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '自定义高级参数格式不正确。',
        ),
      ),
    );

    // 新 wire 名自然进入「协议 + 规范化地址」作用域：换协议不沿用 Key。
    const openAi = SttConfig(
      baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
      model: 'whisper-test',
    );
    const custom = SttConfig(
      provider: SttProviderKind.custom,
      baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
      model: 'whisper-test',
    );
    expect(openAi.credentialScope, isNot(custom.credentialScope));
  });

  test('stt 段读写往返且 Key 只落在文件里', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-stt-section-');
    addTearDown(() => temp.delete(recursive: true));
    final repository = JsonProviderConfigRepository(
      filePath: '${temp.path}${Platform.pathSeparator}provider.json',
    );

    expect(await repository.loadStt(), isNull);
    await repository.saveStt(
      const SttConfig(
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-test',
        apiKey: 'stt-secret-value',
      ),
    );

    final restored = await JsonProviderConfigRepository(
      filePath: '${temp.path}${Platform.pathSeparator}provider.json',
    ).loadStt();
    expect(restored!.baseUrl, 'https://stt.example.com/v1');
    expect(restored.model, 'whisper-test');
    expect(restored.apiKey, 'stt-secret-value');
    final json =
        jsonDecode(
              await File(
                '${temp.path}${Platform.pathSeparator}provider.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    expect(
      (json['stt']! as Map<String, Object?>)['provider'],
      'openai_compatible',
    );
  });

  test('保存聊天段与 stt 段互不覆盖', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-stt-sections-');
    addTearDown(() => temp.delete(recursive: true));
    final repository = JsonProviderConfigRepository(
      filePath: '${temp.path}${Platform.pathSeparator}provider.json',
    );

    await repository.save(
      const ProviderConfig(
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://chat.example.com/v1',
        model: 'chat-model',
        temperature: 0.6,
        timeoutSeconds: 25,
      ).withApiKey('chat-secret-value'),
    );
    await repository.saveStt(
      const SttConfig(
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-test',
        apiKey: 'stt-secret-value',
      ),
    );
    // 再保存一次聊天段（repository 层不解释 Key 沿用，按传入值写入）：
    // stt 段必须原样保留。
    await repository.save(
      const ProviderConfig(
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://chat.example.com/v1',
        model: 'chat-model-2',
        temperature: 0.7,
        timeoutSeconds: 30,
      ).withApiKey('chat-secret-value'),
    );

    final json =
        jsonDecode(
              await File(
                '${temp.path}${Platform.pathSeparator}provider.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    expect(json['model'], 'chat-model-2');
    final stt = json['stt']! as Map<String, Object?>;
    expect(stt['baseUrl'], 'https://stt.example.com/v1');
    expect(stt['apiKey'], 'stt-secret-value');

    // 保存 stt 段也不抹掉聊天 Key。
    await repository.saveStt(
      const SttConfig(
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-2',
      ),
    );
    final reloaded =
        jsonDecode(
              await File(
                '${temp.path}${Platform.pathSeparator}provider.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    expect(reloaded['apiKey'], 'chat-secret-value');
    expect((reloaded['stt']! as Map<String, Object?>)['model'], 'whisper-2');
  });

  test('只有 stt 段时聊天读取视为未配置而不是损坏', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-stt-only-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    await File(filePath).writeAsString('''
{
  "stt": {
    "provider": "openai_compatible",
    "baseUrl": "https://stt.example.com/v1",
    "model": "whisper-test"
  }
}
''');

    final repository = JsonProviderConfigRepository(filePath: filePath);
    expect(await repository.load(), isNull);
    expect((await repository.loadStt())!.model, 'whisper-test');
  });

  test('tts 段读写往返：音色语速开关与缺省值，Key 只落文件', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-tts-roundtrip-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    final repository = JsonProviderConfigRepository(filePath: filePath);

    await repository.saveTts(
      const TtsConfig(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
        apiKey: 'tts-secret-value',
        voice: 'nova',
        speed: 1.25,
        autoSpeak: false,
      ),
    );
    final loaded = (await repository.loadTts())!;
    expect(loaded.provider, TtsProviderKind.openAiCompatible);
    expect(loaded.voice, 'nova');
    expect(loaded.speed, 1.25);
    expect(loaded.autoSpeak, isFalse);
    expect(loaded.apiKey, 'tts-secret-value');
    // 明文 Key 不进 toJson（HTTP 快照路径），但落在本机文件里。
    expect(loaded.toJson().containsKey('apiKey'), isFalse);
    expect(
      jsonDecode(await File(filePath).readAsString())['tts'],
      containsPair('apiKey', 'tts-secret-value'),
    );

    // 缺省字段：不带 provider/voice/speed/autoSpeak 的手写 tts 段。
    await File(filePath).writeAsString('''
{
  "tts": {
    "baseUrl": "https://tts.example.com/v1",
    "model": "tts-test"
  }
}
''');
    final handwritten = (await repository.loadTts())!;
    expect(handwritten.provider, TtsProviderKind.openAiCompatible);
    expect(handwritten.voice, isNull);
    expect(handwritten.speed, isNull);
    expect(handwritten.autoSpeak, isTrue);
  });

  test('tts 传输方式（票三）：豆包档落盘往返，其余档不写、缺省 http_chunk', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-tts-transport-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    final repository = JsonProviderConfigRepository(filePath: filePath);

    await repository.saveTts(
      const TtsConfig(
        provider: TtsProviderKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        apiKey: 'ark-secret-value',
        transport: TtsTransport.wsBidirection,
      ),
    );
    final loaded = (await repository.loadTts())!;
    expect(loaded.transport, TtsTransport.wsBidirection);
    expect(
      (jsonDecode(await File(filePath).readAsString())
          as Map<String, Object?>)['tts'] as Map<String, Object?>,
      containsPair('transport', 'ws_bidirection'),
    );

    // 非豆包档不落盘 transport：切档即回落缺省 HTTP 分块。
    await repository.saveTts(
      const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl:
            'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
        model: 'qwen3-tts-flash',
        apiKey: 'sk-secret-value',
      ),
    );
    final qwen = (await repository.loadTts())!;
    expect(qwen.transport, TtsTransport.httpChunk);
    expect(
      (jsonDecode(await File(filePath).readAsString())
          as Map<String, Object?>)['tts'] as Map<String, Object?>,
      isNot(contains('transport')),
    );

    // 存量配置（没有该字段）按缺省读取；脏值按配置无法读取拒绝。
    await File(filePath).writeAsString('''
{
  "tts": {
    "provider": "volc_tts",
    "baseUrl": "https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional",
    "model": "seed-tts-2.0"
  }
}
''');
    expect(
      (await repository.loadTts())!.transport,
      TtsTransport.httpChunk,
    );
    await File(filePath).writeAsString('''
{
  "tts": {
    "provider": "volc_tts",
    "baseUrl": "https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional",
    "model": "seed-tts-2.0",
    "transport": "carrier_pigeon"
  }
}
''');
    expect(
      () => repository.loadTts(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '语音合成服务配置无法读取。',
        ),
      ),
    );
  });

  test('聊天、stt、tts、webSearch 四段保存互不覆盖', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-tts-sections-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    final repository = JsonProviderConfigRepository(filePath: filePath);

    await repository.save(
      const ProviderConfig(
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://chat.example.com/v1',
        model: 'chat-model',
        temperature: 0.6,
        timeoutSeconds: 25,
      ).withApiKey('chat-secret-value'),
    );
    await repository.saveStt(
      const SttConfig(
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-test',
        apiKey: 'stt-secret-value',
      ),
    );
    await repository.saveTts(
      const TtsConfig(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
        apiKey: 'tts-secret-value',
      ),
    );
    await repository.saveWebSearch(
      const WebSearchConfig(apiKey: 'any-secret-value'),
    );
    // 各段再各保存一次，其余两段必须原样保留。
    await repository.save(
      const ProviderConfig(
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://chat.example.com/v1',
        model: 'chat-model-2',
        temperature: 0.6,
        timeoutSeconds: 25,
      ).withApiKey('chat-secret-value'),
    );
    await repository.saveStt(
      const SttConfig(
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-2',
      ),
    );
    await repository.saveTts(
      const TtsConfig(baseUrl: 'https://tts.example.com/v1', model: 'tts-2'),
    );

    expect((await repository.load())!.model, 'chat-model-2');
    expect((await repository.loadStt())!.model, 'whisper-2');
    final tts = (await repository.loadTts())!;
    expect(tts.model, 'tts-2');
    // stt/tts 各自的 Key 保存语义独立：stt 保存过 Key，tts 换模型未传
    // Key 时按 repository 层语义（传入什么写什么）为空。
    expect(tts.apiKey, isNull);
    expect((await repository.loadStt())!.apiKey, isNull);
    expect((await repository.loadWebSearch())!.apiKey, 'any-secret-value');
  });

  test('只有 tts 段时聊天与 stt 各自独立判断，不视为损坏', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-tts-only-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    await File(filePath).writeAsString('''
{
  "tts": {
    "baseUrl": "https://tts.example.com/v1",
    "model": "tts-test"
  }
}
''');
    final repository = JsonProviderConfigRepository(filePath: filePath);
    expect(await repository.load(), isNull);
    expect(await repository.loadStt(), isNull);
    expect((await repository.loadTts())!.model, 'tts-test');
  });

  test('损坏的 tts 段只影响语音朗读，不影响聊天与 stt', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-tts-broken-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    await File(filePath).writeAsString('''
{
  "provider": "openai_compatible",
  "baseUrl": "https://chat.example.com/v1",
  "model": "chat-model",
  "temperature": 0.6,
  "timeoutSeconds": 25,
  "stt": {
    "baseUrl": "https://stt.example.com/v1",
    "model": "whisper-test"
  },
  "tts": "not-an-object"
}
''');
    final repository = JsonProviderConfigRepository(filePath: filePath);
    expect((await repository.load())!.model, 'chat-model');
    expect((await repository.loadStt())!.model, 'whisper-test');
    await expectLater(
      repository.loadTts(),
      throwsA(isA<ProviderConfigException>()),
    );
  });

  test('tts 段校验：空地址、脏地址、非法语速、脏音色拒绝保存', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-tts-validate-');
    addTearDown(() => temp.delete(recursive: true));
    final repository = JsonProviderConfigRepository(
      filePath: '${temp.path}${Platform.pathSeparator}provider.json',
    );

    await expectLater(
      () => repository.saveTts(const TtsConfig(baseUrl: '', model: 'm')),
      throwsA(isA<ProviderConfigException>()),
    );
    await expectLater(
      () =>
          repository.saveTts(const TtsConfig(baseUrl: 'ht!tp://x', model: 'm')),
      throwsA(isA<ProviderConfigException>()),
    );
    await expectLater(
      () => repository.saveTts(
        const TtsConfig(
          baseUrl: 'https://tts.example.com/v1',
          model: 'm',
          speed: 9,
        ),
      ),
      throwsA(isA<ProviderConfigException>()),
    );
    await expectLater(
      () => repository.saveTts(
        TtsConfig(
          baseUrl: 'https://tts.example.com/v1',
          model: 'm',
          voice: '暖女声',
        ),
      ),
      throwsA(isA<ProviderConfigException>()),
    );
  });

  test('tts 段 extraParams 支持读取、保存与别名兼容', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-tts-extra-');
    addTearDown(() => temp.delete(recursive: true));
    final filePath = '${temp.path}${Platform.pathSeparator}provider.json';
    final repository = JsonProviderConfigRepository(filePath: filePath);

    await repository.saveTts(
      const TtsConfig(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
        extraParams: {
          'audio_params': {'sample_rate': 16000},
          'additions': {'explicit_dialect': 'sichuan'},
        },
      ),
    );

    final loaded = (await repository.loadTts())!;
    expect(loaded.extraParams, {
      'audio_params': {'sample_rate': 16000},
      'additions': {'explicit_dialect': 'sichuan'},
    });

    // 兼容 extra_params 下划线手写
    await File(filePath).writeAsString('''
{
  "tts": {
    "baseUrl": "https://tts.example.com/v1",
    "model": "tts-test",
    "extra_params": {
      "response_format": "wav"
    }
  }
}
''');
    final loadedAlias = (await repository.loadTts())!;
    expect(loadedAlias.extraParams, {'response_format': 'wav'});

    // 非法 extraParams 格式拒绝
    await File(filePath).writeAsString('''
{
  "tts": {
    "baseUrl": "https://tts.example.com/v1",
    "model": "tts-test",
    "extraParams": "not-a-map"
  }
}
''');
    await expectLater(
      repository.loadTts(),
      throwsA(isA<ProviderConfigException>()),
    );
  });

  test('tts 段 qwen_tts 往返：HTTP scheme 放行、Key 作用域随协议隔离', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-tts-qwen-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}${Platform.pathSeparator}provider.json';
    JsonProviderConfigRepository repository() =>
        JsonProviderConfigRepository(filePath: path);

    await repository().saveTts(
      const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: qwenTtsDefaultEndpoint,
        model: qwenTtsDefaultModel,
        voice: qwenTtsDefaultVoice,
        apiKey: 'qwen-secret-value',
        extraParams: {'instructions': '用温柔的语气'},
      ),
    );
    final restored = await repository().loadTts();
    expect(restored!.provider, TtsProviderKind.qwenTts);
    expect(restored.baseUrl, qwenTtsDefaultEndpoint);
    expect(restored.model, qwenTtsDefaultModel);
    expect(restored.voice, qwenTtsDefaultVoice);
    expect(restored.apiKey, 'qwen-secret-value');
    expect(restored.extraParams, {'instructions': '用温柔的语气'});
    final json =
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    expect((json['tts']! as Map<String, Object?>)['provider'], 'qwen_tts');

    // 手写 provider.json 的 qwen_tts 段照常读取（fromJson 路径）。
    await File(path).writeAsString('''
{
  "tts": {
    "provider": "qwen_tts",
    "baseUrl": "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
    "model": "qwen3-tts-flash",
    "voice": "Cherry"
  }
}
''');
    final handwritten = (await repository().loadTts())!;
    expect(handwritten.provider, TtsProviderKind.qwenTts);
    expect(handwritten.voice, 'Cherry');

    // 千问档 http/https 放行（票 07 起 ws/wss 也放行——地址即用户填的
    // 完整 WS 推理端点，ADR 0020 补篇）；其余 scheme 照旧拒绝。
    expect(
      () => const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: 'http://dashscope.example.com/api/v1',
        model: qwenTtsDefaultModel,
      ).validate(),
      returnsNormally,
    );
    expect(
      () => const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: 'ws://dashscope.example.com/api-ws/v1/inference',
        model: qwenTtsDefaultModel,
      ).validate(),
      returnsNormally,
    );
    expect(
      () => const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
        model: qwenTtsDefaultModel,
      ).validate(),
      returnsNormally,
    );
    expect(
      () => const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: 'ftp://dashscope.example.com/api-ws/v1/inference',
        model: qwenTtsDefaultModel,
      ).validate(),
      throwsA(isA<ProviderConfigException>()),
    );

    // 新协议自然进入「协议 + 规范化地址」作用域：同地址换协议不沿用 Key。
    const openAi = TtsConfig(
      baseUrl: qwenTtsDefaultEndpoint,
      model: 'tts-1',
    );
    const qwen = TtsConfig(
      provider: TtsProviderKind.qwenTts,
      baseUrl: qwenTtsDefaultEndpoint,
      model: qwenTtsDefaultModel,
    );
    expect(openAi.credentialScope, isNot(qwen.credentialScope));
  });

  test('tts 段 custom 往返：旋钮与高级参数落盘、缺省值、非自定义档不落盘旋钮', () async {
    final temp = await Directory.systemTemp.createTemp('qiyu-tts-custom-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}${Platform.pathSeparator}provider.json';
    JsonProviderConfigRepository repository() =>
        JsonProviderConfigRepository(filePath: path);

    // 自定义档完整往返：鉴权头、响应形态、字段名与高级参数逐一读回。
    await repository().saveTts(
      const TtsConfig(
        provider: TtsProviderKind.custom,
        baseUrl: 'https://tts.example.com/v1/audio/speech',
        model: 'tts-test',
        apiKey: 'custom-secret-value',
        authHeader: 'X-Api-Key',
        responseShape: TtsResponseShape.jsonLines,
        responseField: 'result.audio',
        extraParams: {'voice': 'custom-voice'},
      ),
    );
    final restored = await repository().loadTts();
    expect(restored!.provider, TtsProviderKind.custom);
    expect(restored.authHeader, 'X-Api-Key');
    expect(restored.responseShape, TtsResponseShape.jsonLines);
    expect(restored.responseField, 'result.audio');
    expect(restored.extraParams, {'voice': 'custom-voice'});
    expect(restored.apiKey, 'custom-secret-value');
    final json =
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    final section = json['tts']! as Map<String, Object?>;
    expect(section['provider'], 'custom');
    expect(section['authHeader'], 'X-Api-Key');
    expect(section['responseShape'], 'json_lines');
    expect(section['responseField'], 'result.audio');
    expect(section['extraParams'], {'voice': 'custom-voice'});

    // 旋钮缺省值：custom 段不带旋钮时按缺省读（等价默认 Bearer、裸字节
    // 形态与缺省字段 data）。
    await File(path).writeAsString(
      jsonEncode({
        'tts': {
          'provider': 'custom',
          'baseUrl': 'https://tts.example.com/v1/audio/speech',
          'model': 'tts-test',
        },
      }),
    );
    final defaults = await repository().loadTts();
    expect(defaults!.authHeader, isNull);
    expect(defaults.responseShape, TtsResponseShape.rawBytes);
    expect(defaults.responseField, 'data');
    expect(defaults.extraParams, isNull);

    // 非自定义档不落盘旋钮：构造时带上也只在 custom 档生效（extraParams
    // 三档本就消费，落盘口径不动）。
    await repository().saveTts(
      const TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: qwenTtsDefaultEndpoint,
        model: qwenTtsDefaultModel,
        authHeader: 'X-Api-Key',
        responseShape: TtsResponseShape.jsonField,
        responseField: 'result.audio',
      ),
    );
    final qwenJson =
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    final qwenSection = qwenJson['tts']! as Map<String, Object?>;
    expect(qwenSection['provider'], 'qwen_tts');
    expect(qwenSection.containsKey('authHeader'), isFalse);
    expect(qwenSection.containsKey('responseShape'), isFalse);
    expect(qwenSection.containsKey('responseField'), isFalse);

    // 存量配置兼容：不带 provider 与旋钮的老 tts 段照常读为 OpenAI 兼容。
    await File(path).writeAsString(
      jsonEncode({
        'tts': {
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
          'apiKey': 'legacy-secret-value',
        },
      }),
    );
    final legacy = await repository().loadTts();
    expect(legacy!.provider, TtsProviderKind.openAiCompatible);
    expect(legacy.apiKey, 'legacy-secret-value');
    expect(legacy.responseShape, TtsResponseShape.rawBytes);
    expect(legacy.responseField, 'data');
  });

  test('tts 段 custom 校验：HTTP scheme 放行、鉴权头脏字符与空头名人话、Key 作用域随协议隔离', () {
    // 自定义档同属 HTTP 家族：http/https 放行，ws 拒绝。
    expect(
      () => const TtsConfig(
        provider: TtsProviderKind.custom,
        baseUrl: 'http://tts.example.com/v1/audio/speech',
        model: 'tts-test',
      ).validate(),
      returnsNormally,
    );
    expect(
      () => const TtsConfig(
        provider: TtsProviderKind.custom,
        baseUrl: 'ws://tts.example.com/v1/audio/speech',
        model: 'tts-test',
      ).validate(),
      throwsA(isA<ProviderConfigException>()),
    );

    // 鉴权头脏字符与空头名（": Bearer" 这种粘贴事故会让 dart:io 写出
    // 空头名，请求期才炸未分类异常）在保存前拦成人话。
    expect(
      () => const TtsConfig(
        provider: TtsProviderKind.custom,
        baseUrl: 'https://tts.example.com/v1/audio/speech',
        model: 'tts-test',
        authHeader: 'X-Api-Key\u200B',
      ).validate(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '鉴权头里混入了中文或看不见的字符，请重新填写。',
        ),
      ),
    );
    expect(
      () => const TtsConfig(
        provider: TtsProviderKind.custom,
        baseUrl: 'https://tts.example.com/v1/audio/speech',
        model: 'tts-test',
        authHeader: ': Bearer',
      ).validate(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '鉴权头格式不正确，请填写如 Authorization: Bearer 的头名。',
        ),
      ),
    );

    // 保留头名撞名在保存前拦成人话：content-type 撞名会被网关自己写的
    // application/json 头静默覆盖（无鉴权出网），大小写不敏感都拦。
    for (final authHeader in ['Content-Type: Bearer', 'content-length', 'HOST']) {
      expect(
        () => TtsConfig(
          provider: TtsProviderKind.custom,
          baseUrl: 'https://tts.example.com/v1/audio/speech',
          model: 'tts-test',
          authHeader: authHeader,
        ).validate(),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            '鉴权头不能使用 Content-Type、Content-Length 这类保留头名，请重新填写。',
          ),
        ),
        reason: authHeader,
      );
    }

    // 高级参数空键名按格式不正确拒绝（custom 档同样校验）。
    expect(
      () => const TtsConfig(
        provider: TtsProviderKind.custom,
        baseUrl: 'https://tts.example.com/v1/audio/speech',
        model: 'tts-test',
        extraParams: {'': 'value'},
      ).validate(),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '自定义高级参数格式不正确。',
        ),
      ),
    );

    // 新 wire 名自然进入「协议 + 规范化地址」作用域：换协议不沿用 Key。
    const openAi = TtsConfig(
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
    );
    const custom = TtsConfig(
      provider: TtsProviderKind.custom,
      baseUrl: 'https://tts.example.com/v1/audio/speech',
      model: 'tts-test',
    );
    expect(openAi.credentialScope, isNot(custom.credentialScope));
  });

  group('子段读改写现状', () {
    // 票 03 的现状回归夹具：一份规范态（键序显式、两空格缩进、末尾
    // 换行）合成整文件，含聊天字段、四种子段与未知顶层键。所有凭据
    // 都是明显的测试假值，文件只落在专用临时目录，不碰运行目录。
    const fixtureText = '''
{
  "schemaVersion": 1,
  "provider": "openai_compatible",
  "baseUrl": "https://chat.example.com/v1",
  "model": "chat-model",
  "temperature": 0.6,
  "timeoutSeconds": 25,
  "apiKey": "fake-chat-key-not-real",
  "stt": {
    "provider": "openai_compatible",
    "baseUrl": "https://stt.example.com/v1",
    "model": "whisper-fake",
    "apiKey": "fake-stt-key-not-real"
  },
  "tts": {
    "provider": "openai_compatible",
    "baseUrl": "https://tts.example.com/v1",
    "model": "tts-fake",
    "voice": "nova",
    "speed": 1.25,
    "autoSpeak": true,
    "apiKey": "fake-tts-key-not-real"
  },
  "webSearch": {
    "apiKey": "fake-search-key-not-real"
  },
  "proxy": {
    "enabled": true,
    "host": "proxy.example.com",
    "port": 7890
  },
  "unknownObject": {
    "keptByBaseline": "do-not-touch"
  },
  "unknownArray": [
    1,
    "two",
    true
  ]
}
''';
    final fixtureJson = jsonDecode(fixtureText) as Map<String, Object?>;
    final fixtureKeys = fixtureJson.keys.toList();

    late Directory temp;
    late String filePath;
    var attempts = 0;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('qiyu-section-write-');
      filePath = '${temp.path}${Platform.pathSeparator}provider.json';
      attempts = 0;
    });
    tearDown(() async {
      if (temp.existsSync()) {
        await temp.delete(recursive: true);
      }
    });

    // 每个操作都从同一份初始内容开始，避免前一个动作改后一个的前置。
    Future<void> useFixture() => File(filePath).writeAsString(fixtureText);
    Future<String> rawFile() => File(filePath).readAsString();
    Future<Map<String, Object?>> jsonFile() async =>
        jsonDecode(await rawFile()) as Map<String, Object?>;

    // 写入尝试计数沿用既有原子写入注入点：谓词闭包自带计数状态。
    JsonProviderConfigRepository repository() => JsonProviderConfigRepository(
      filePath: filePath,
      writer: FailingAtomicTextWriter(
        shouldFail: (_) {
          attempts += 1;
          return false;
        },
      ),
    );

    // 同一注入点让写回必然失败，用于核对异常包装与「不新增 retry」。
    JsonProviderConfigRepository failingRepository() =>
        JsonProviderConfigRepository(
          filePath: filePath,
          writer: FailingAtomicTextWriter(
            shouldFail: (_) {
              attempts += 1;
              return true;
            },
          ),
        );

    // 写回失败对外只有仓库既有的保存失败包装，cause 保留原始写异常。
    final saveFailureMatcher = isA<ProviderConfigException>()
        .having((error) => error.message, 'message', '本地模型配置无法保存。')
        .having((error) => error.cause, 'cause', isA<FileSystemException>());

    test('夹具本身是规范态：原样重写 stt 段后文件字节不变', () async {
      await useFixture();
      await repository().saveStt(
        const SttConfig(
          baseUrl: 'https://stt.example.com/v1',
          model: 'whisper-fake',
          apiKey: 'fake-stt-key-not-real',
        ),
      );

      expect(attempts, 1);
      expect(await rawFile(), fixtureText);
    });

    test('四种子段分别只替换本段，未知顶层键与其余段原样保留', () async {
      final repo = repository();

      await useFixture();
      await repo.saveStt(
        const SttConfig(
          baseUrl: 'https://stt.example.com/v2',
          model: 'whisper-fake-2',
          apiKey: 'fake-stt-key-2-not-real',
        ),
      );
      var stored = await jsonFile();
      expect(stored['stt'], {
        'provider': 'openai_compatible',
        'baseUrl': 'https://stt.example.com/v2',
        'model': 'whisper-fake-2',
        'apiKey': 'fake-stt-key-2-not-real',
      });
      expect(stored.keys.toList(), fixtureKeys);
      expect({...stored}..remove('stt'), {...fixtureJson}..remove('stt'));

      await useFixture();
      await repo.saveTts(
        const TtsConfig(
          baseUrl: 'https://tts.example.com/v2',
          model: 'tts-fake-2',
          apiKey: 'fake-tts-key-2-not-real',
        ),
      );
      stored = await jsonFile();
      expect(stored['tts'], {
        'provider': 'openai_compatible',
        'baseUrl': 'https://tts.example.com/v2',
        'model': 'tts-fake-2',
        'autoSpeak': true,
        'apiKey': 'fake-tts-key-2-not-real',
      });
      expect(stored.keys.toList(), fixtureKeys);
      expect({...stored}..remove('tts'), {...fixtureJson}..remove('tts'));

      // 联网搜索 Key 先过校验再 trim 落盘。
      await useFixture();
      await repo.saveWebSearch(
        const WebSearchConfig(apiKey: '  fake-search-key-2-not-real  '),
      );
      stored = await jsonFile();
      expect(stored['webSearch'], {'apiKey': 'fake-search-key-2-not-real'});
      expect(stored.keys.toList(), fixtureKeys);
      expect(
        {...stored}..remove('webSearch'),
        {...fixtureJson}..remove('webSearch'),
      );

      // 代理沿用自身序列化：enabled、host、port 三字段。
      await useFixture();
      await repo.saveProxy(
        const ProxyConfig(
          enabled: false,
          host: 'proxy.example.com',
          port: 7890,
        ),
      );
      stored = await jsonFile();
      expect(stored['proxy'], {
        'enabled': false,
        'host': 'proxy.example.com',
        'port': 7890,
      });
      expect(stored.keys.toList(), fixtureKeys);
      expect({...stored}..remove('proxy'), {...fixtureJson}..remove('proxy'));
      // 关闭态仍是「保存一个 disabled 段」，地址端口不丢、读取口径不变。
      final disabled = (await repo.loadProxy())!;
      expect(disabled.enabled, isFalse);
      expect(disabled.host, 'proxy.example.com');
      expect(disabled.port, 7890);
    });

    test('空配置删除本段而非写 null，其余键保留', () async {
      await useFixture();
      final repo = repository();

      await repo.saveWebSearch(null);
      var stored = await jsonFile();
      expect(stored.containsKey('webSearch'), isFalse);
      expect(
        stored.keys.toList(),
        fixtureKeys.where((k) => k != 'webSearch').toList(),
      );
      expect(stored['proxy'], fixtureJson['proxy']);
      expect(stored['stt'], fixtureJson['stt']);
      expect(stored['unknownObject'], fixtureJson['unknownObject']);
      expect(stored['unknownArray'], fixtureJson['unknownArray']);
      expect(await repo.loadWebSearch(), isNull);

      await repo.saveProxy(null);
      stored = await jsonFile();
      expect(stored.containsKey('proxy'), isFalse);
      expect(stored['webSearch'], isNull);
      expect(stored['unknownObject'], fixtureJson['unknownObject']);
      expect(await repo.loadProxy(), isNull);
      // 两次删除各一次写回。
      expect(attempts, 2);
    });

    test('删除本来不存在的段仍执行一次写回且不扰动内容', () async {
      await useFixture();
      final repo = repository();
      await repo.saveWebSearch(null);
      await repo.saveProxy(null);
      final stripped = await rawFile();
      expect(stripped, isNot(contains('webSearch')));
      expect(stripped, isNot(contains('"proxy"')));
      expect(stripped, contains('unknownObject'));
      expect(stripped, contains('fake-stt-key-not-real'));

      attempts = 0;
      await repo.saveWebSearch(null);
      await repo.saveProxy(null);
      expect(attempts, 2);
      expect(await rawFile(), stripped);
    });

    test('整文件缺失时删除创建空对象文件并保留既有格式', () async {
      final repo = repository();
      expect(File(filePath).existsSync(), isFalse);

      await repo.saveWebSearch(null);
      expect(attempts, 1);
      expect(await rawFile(), '{}\n');

      await File(filePath).delete();
      await repo.saveProxy(null);
      expect(attempts, 2);
      expect(await rawFile(), '{}\n');
    });

    test('整文件损坏或顶层非对象时保存按基线整体重建', () async {
      await File(filePath).writeAsString('{ 这不是合法的 JSON');
      await repository().saveStt(
        const SttConfig(
          baseUrl: 'https://stt.example.com/v1',
          model: 'whisper-fake',
        ),
      );
      var stored = await jsonFile();
      expect(stored.keys.toList(), ['stt']);
      expect(stored['stt'], {
        'provider': 'openai_compatible',
        'baseUrl': 'https://stt.example.com/v1',
        'model': 'whisper-fake',
      });

      // 顶层是数组：与损坏同样按整体重建，不沿用读路径的抛错口径。
      await File(filePath).writeAsString('[1, 2, 3]');
      await repository().saveProxy(
        const ProxyConfig(enabled: true, host: 'proxy.example.com', port: 7891),
      );
      stored = await jsonFile();
      expect(stored.keys.toList(), ['proxy']);
      expect(stored['proxy'], {
        'enabled': true,
        'host': 'proxy.example.com',
        'port': 7891,
      });

      // 损坏文件上执行删除：结果同样是空对象文件。
      await File(filePath).writeAsString('{ 这不是合法的 JSON');
      await repository().saveWebSearch(null);
      expect(await rawFile(), '{}\n');
    });

    test('非法配置在写入前抛错且文件字节不变', () async {
      await useFixture();
      final repo = repository();

      await expectLater(
        repo.saveStt(const SttConfig(baseUrl: '', model: 'whisper-fake')),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            '语音服务地址必须是有效的 HTTP 地址。',
          ),
        ),
      );
      await expectLater(
        repo.saveTts(
          const TtsConfig(
            baseUrl: 'https://tts.example.com/v1',
            model: 'tts-fake',
            speed: 9,
          ),
        ),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            '语速必须在 0.25 到 4 之间。',
          ),
        ),
      );
      await expectLater(
        repo.saveWebSearch(const WebSearchConfig(apiKey: '   ')),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            '请填写 ANYSEARCH_API_KEY。',
          ),
        ),
      );
      await expectLater(
        repo.saveProxy(const ProxyConfig(enabled: true, host: '', port: 7890)),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            '请填写代理地址。',
          ),
        ),
      );

      expect(attempts, isZero);
      expect(await rawFile(), fixtureText);
    });

    test('写入器失败保持原有异常包装与文案，替换与删除各一次尝试', () async {
      await useFixture();
      final failingRepo = failingRepository();

      await expectLater(
        failingRepo.saveTts(
          const TtsConfig(
            baseUrl: 'https://tts.example.com/v1',
            model: 'tts-fake',
          ),
        ),
        throwsA(saveFailureMatcher),
      );
      expect(attempts, 1);

      // 删除分支同样抛出原包装文案、只尝试一次，原文件保持。
      await expectLater(
        failingRepo.saveProxy(null),
        throwsA(saveFailureMatcher),
      );
      expect(attempts, 2);
      expect(await rawFile(), fixtureText);
    });

    test('stt 替换写入失败同样是原包装与一次尝试', () async {
      await useFixture();
      final failingRepo = failingRepository();

      await expectLater(
        failingRepo.saveStt(
          const SttConfig(
            baseUrl: 'https://stt.example.com/v2',
            model: 'whisper-fake-2',
          ),
        ),
        throwsA(saveFailureMatcher),
      );
      expect(attempts, 1);
      expect(await rawFile(), fixtureText);
    });

    test('webSearch 替换写入失败同样是原包装与一次尝试', () async {
      await useFixture();
      final failingRepo = failingRepository();

      await expectLater(
        failingRepo.saveWebSearch(
          const WebSearchConfig(apiKey: 'fake-search-key-2-not-real'),
        ),
        throwsA(saveFailureMatcher),
      );
      expect(attempts, 1);
      expect(await rawFile(), fixtureText);
    });

    test('序列化基线字节对照：键序、两空格缩进与末尾换行', () async {
      await useFixture();

      // 替换 tts 段：目标段换成新载荷，其余行逐字不动。
      await repository().saveTts(
        const TtsConfig(
          baseUrl: 'https://tts.example.com/v2',
          model: 'tts-fake-2',
          apiKey: 'fake-tts-key-2-not-real',
        ),
      );
      expect(await rawFile(), '''
{
  "schemaVersion": 1,
  "provider": "openai_compatible",
  "baseUrl": "https://chat.example.com/v1",
  "model": "chat-model",
  "temperature": 0.6,
  "timeoutSeconds": 25,
  "apiKey": "fake-chat-key-not-real",
  "stt": {
    "provider": "openai_compatible",
    "baseUrl": "https://stt.example.com/v1",
    "model": "whisper-fake",
    "apiKey": "fake-stt-key-not-real"
  },
  "tts": {
    "provider": "openai_compatible",
    "baseUrl": "https://tts.example.com/v2",
    "model": "tts-fake-2",
    "autoSpeak": true,
    "apiKey": "fake-tts-key-2-not-real"
  },
  "webSearch": {
    "apiKey": "fake-search-key-not-real"
  },
  "proxy": {
    "enabled": true,
    "host": "proxy.example.com",
    "port": 7890
  },
  "unknownObject": {
    "keptByBaseline": "do-not-touch"
  },
  "unknownArray": [
    1,
    "two",
    true
  ]
}
''');

      // 删除 webSearch 段：整段键消失，缩进与末尾换行照旧。
      await useFixture();
      await repository().saveWebSearch(null);
      expect(await rawFile(), '''
{
  "schemaVersion": 1,
  "provider": "openai_compatible",
  "baseUrl": "https://chat.example.com/v1",
  "model": "chat-model",
  "temperature": 0.6,
  "timeoutSeconds": 25,
  "apiKey": "fake-chat-key-not-real",
  "stt": {
    "provider": "openai_compatible",
    "baseUrl": "https://stt.example.com/v1",
    "model": "whisper-fake",
    "apiKey": "fake-stt-key-not-real"
  },
  "tts": {
    "provider": "openai_compatible",
    "baseUrl": "https://tts.example.com/v1",
    "model": "tts-fake",
    "voice": "nova",
    "speed": 1.25,
    "autoSpeak": true,
    "apiKey": "fake-tts-key-not-real"
  },
  "proxy": {
    "enabled": true,
    "host": "proxy.example.com",
    "port": 7890
  },
  "unknownObject": {
    "keptByBaseline": "do-not-touch"
  },
  "unknownArray": [
    1,
    "two",
    true
  ]
}
''');
    });

    test('压缩写入的文件按基线重新缩进，未知键与新段位置不变', () async {
      await File(filePath).writeAsString(
        '{"zeta":1,"proxy":{"enabled":true,"host":"proxy.example.com","port":7890}}',
      );
      await repository().saveProxy(null);
      expect(await rawFile(), '''
{
  "zeta": 1
}
''');

      // 段不存在时新增：追加在末尾，其余键序不动。
      await File(
        filePath,
      ).writeAsString('{"zeta":1,"webSearch":{"apiKey":"k"}}');
      await repository().saveProxy(
        const ProxyConfig(enabled: true, host: 'proxy.example.com', port: 7890),
      );
      expect(await rawFile(), '''
{
  "zeta": 1,
  "webSearch": {
    "apiKey": "k"
  },
  "proxy": {
    "enabled": true,
    "host": "proxy.example.com",
    "port": 7890
  }
}
''');
    });

    test('读取差异保持：语音坏段抛错，搜索残缺按未配置', () async {
      await File(filePath).writeAsString('{"stt":"not-an-object"}');
      await expectLater(
        repository().loadStt(),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            '语音服务配置无法读取。',
          ),
        ),
      );

      await File(filePath).writeAsString(
        jsonEncode({
          'webSearch': {'apiKey': '   '},
        }),
      );
      expect(await repository().loadWebSearch(), isNull);
    });
  });
}
