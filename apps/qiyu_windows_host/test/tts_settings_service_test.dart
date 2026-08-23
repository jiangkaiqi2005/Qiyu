import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

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
