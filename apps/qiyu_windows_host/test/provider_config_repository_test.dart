import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
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
    await File(
      filePath,
    ).writeAsString('''
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
    final blank = await JsonProviderConfigRepository(
      filePath: filePath,
    ).load();
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
        ) as Map<String, Object?>;
    expect((json['stt']! as Map<String, Object?>)['provider'],
        'openai_compatible');
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
        ) as Map<String, Object?>;
    expect(json['model'], 'chat-model-2');
    final stt = json['stt']! as Map<String, Object?>;
    expect(stt['baseUrl'], 'https://stt.example.com/v1');
    expect(stt['apiKey'], 'stt-secret-value');

    // 保存 stt 段也不抹掉聊天 Key。
    await repository.saveStt(
      const SttConfig(baseUrl: 'https://stt.example.com/v1', model: 'whisper-2'),
    );
    final reloaded =
        jsonDecode(
          await File(
            '${temp.path}${Platform.pathSeparator}provider.json',
          ).readAsString(),
        ) as Map<String, Object?>;
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
}
