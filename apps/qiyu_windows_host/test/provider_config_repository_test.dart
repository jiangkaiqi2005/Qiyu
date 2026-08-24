import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

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
}
