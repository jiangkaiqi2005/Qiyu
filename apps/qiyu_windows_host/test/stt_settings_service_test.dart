import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
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
            .having((error) => error.code, 'code', 'stt_service_error')
            .having((error) => error.message, 'message', '语音服务请求过于频繁。')
            .having(
              (error) => error.toString(),
              'redacted',
              isNot(contains('429 Too Many Requests detail')),
            ),
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

final class _StaticSttHttpClient implements ProviderHttpClient {
  _StaticSttHttpClient(this.responseBody, {this.statusCode = 200});

  final String responseBody;
  final int statusCode;
  List<int>? lastBody;
  Map<String, String>? lastHeaders;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    lastBody = body;
    lastHeaders = headers;
    return ProviderHttpResponse(
      statusCode: statusCode,
      body: Stream.value(responseBody),
    );
  }

  @override
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) {
    throw UnsupportedError('STT 测试客户端只使用非流式 POST');
  }
}
