import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('qiyu-embedding-settings-');
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

  /// 服务 + 真 OpenAI 兼容网关 + 记录型 HTTP：连接测试路径全链路真实，
  /// 只有出网端口可编排。
  EmbeddingSettingsService service(_RecordingEmbeddingHttp http) =>
      EmbeddingSettingsService(repository(), OpenAiEmbeddingGateway(http));

  test('保存往返：configured/keySet 准确且快照永不包含明文 Key', () async {
    final saved = await service(_RecordingEmbeddingHttp()).save(
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'embedding-secret-value',
    );

    expect(saved.configured, isTrue);
    expect(saved.keySet, isTrue);
    expect(saved.toJson(), isNot(contains('embedding-secret-value')));
    expect(saved.toJson(), isNot(contains('apiKey')));
    // Key 随 embedding 段落盘：用户可直接编辑该文件更换。
    final stored =
        jsonDecode(await File(configPath()).readAsString())
            as Map<String, Object?>;
    expect(
      (stored['embedding']! as Map<String, Object?>)['apiKey'],
      'embedding-secret-value',
    );
  });

  test('重新读取只回 keySet：明文 Key 不出现在任何读取快照', () async {
    final svc = service(_RecordingEmbeddingHttp());
    await svc.save(
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'embedding-secret-value',
    );

    final read = await svc.read();
    expect(read.keySet, isTrue);
    expect(read.toJson(), isNot(contains('embedding-secret-value')));
  });

  test('同地址保存不带 Key 沿用旧 Key；换地址不沿用', () async {
    final svc = service(_RecordingEmbeddingHttp());
    await svc.save(
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'embedding-secret-value',
    );

    // 同一规范化地址、换了模型名：凭据作用域不含模型名，留空沿用。
    final sameAddress = await svc.save(
      baseUrl: 'https://embedding.example.com/v1/',
      model: 'text-embedding-v2',
    );
    expect(sameAddress.keySet, isTrue);
    expect(sameAddress.config!.model, 'text-embedding-v2');

    final moved = await svc.save(
      baseUrl: 'https://other.example.com/v1',
      model: 'text-embedding-test',
    );
    expect(moved.keySet, isFalse);
    expect(moved.configured, isTrue);
  });

  test('模型名不改变凭据作用域：换模型留空 Key 时旧 Key 照常沿用', () async {
    final stored = _StaticEmbeddingConfigRepository(
      const EmbeddingConfig(
        baseUrl: 'https://embedding.example.com/v1',
        model: 'old-model',
        apiKey: 'old-key',
      ),
    );
    final http = _RecordingEmbeddingHttp();
    final result = await EmbeddingSettingsService(
      stored,
      OpenAiEmbeddingGateway(http),
    ).save(baseUrl: 'https://embedding.example.com/v1', model: 'new-model');

    expect(result.keySet, isTrue);
    expect(result.config!.apiKey, 'old-key');
  });

  test('忘记 Key 只清 Key，地址与模型保留', () async {
    final svc = service(_RecordingEmbeddingHttp());
    await svc.save(
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'embedding-secret-value',
    );

    final forgotten = await svc.forgetApiKey();

    expect(forgotten.configured, isTrue);
    expect(forgotten.keySet, isFalse);
    expect(forgotten.config!.baseUrl, 'https://embedding.example.com/v1');
  });

  test('连接测试只发送固定的非私人文本与 Bearer 鉴权，不携带任何历史', () async {
    final http = _RecordingEmbeddingHttp();
    final svc = service(http);
    await svc.save(
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'embedding-secret-value',
    );

    final result = await svc.test();

    expect(result.succeeded, isTrue);
    expect(result.message, '连接成功，记忆召回服务可以使用。');
    expect(http.postCalls, 1);
    // embeddings 端点由地址拼接而来。
    expect(http.lastUri!.path, '/v1/embeddings');
    expect(http.lastHeaders!['authorization'], 'Bearer embedding-secret-value');
    // 请求体只含模型名与固定测试句：绝无会话或记忆内容。
    final body = jsonDecode(utf8.decode(http.lastBody!))
        as Map<String, Object?>;
    expect(body['model'], 'text-embedding-test');
    expect(body['input'], [embeddingConnectionTestText]);
    // 固定测试句是写死的常量，不读任何会话或记忆文件。
    expect(embeddingConnectionTestText, isNotEmpty);
  });

  test('未保存配置时测试返回 notConfigured', () async {
    final http = _RecordingEmbeddingHttp();
    final result = await service(http).test();
    expect(result.status, ProviderTestStatus.notConfigured);
    expect(result.message, '还没有保存记忆召回服务配置。');
    expect(http.postCalls, 0);
  });

  test('换地址测试不发送旧服务商的 Key', () async {
    final http = _RecordingEmbeddingHttp();
    final stored = _StaticEmbeddingConfigRepository(
      const EmbeddingConfig(
        baseUrl: 'https://old.example.com/v1',
        model: 'old-model',
        apiKey: 'old-secret-key',
      ),
    );
    final result = await EmbeddingSettingsService(
      stored,
      OpenAiEmbeddingGateway(http),
    ).test(baseUrl: 'https://new.example.com/v1', model: 'new-model');

    // 作用域变化不沿用：按未保存鉴权失败报告，旧 Key 一个字节都不出网。
    expect(result.status, ProviderTestStatus.authentication);
    expect(http.postCalls, 0);
    expect(http.lastHeaders, isNull);
  });

  test('沿用的 Key 保留脏字符并在出网前拒绝', () async {
    final http = _RecordingEmbeddingHttp();
    final stored = _StaticEmbeddingConfigRepository(
      const EmbeddingConfig(
        baseUrl: 'https://embedding.example.com/v1',
        model: 'text-embedding-test',
        apiKey: '\told-key\t',
      ),
    );
    final result = await EmbeddingSettingsService(
      stored,
      OpenAiEmbeddingGateway(http),
    ).test(apiKey: ' ');

    expect(result.status, ProviderTestStatus.contentParsing);
    expect(result.message, 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。');
    expect(http.postCalls, 0);
    expect(stored.config!.apiKey, '\told-key\t');
  });

  test('测试失败按分类映射为允许列表文案：鉴权、限流与网络', () async {
    // 先落一份配置，让测试走到出网与分类映射（而非 notConfigured）。
    final bootstrap = service(_RecordingEmbeddingHttp());
    await bootstrap.save(
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'embedding-secret-value',
    );

    final unauthorizedHttp = _RecordingEmbeddingHttp(
      statusCode: 401,
      responseBody: '{"error":{"message":"invalid key 42.3.8.1 internal"}}',
    );
    final unauthorized = await EmbeddingSettingsService(
      repository(),
      OpenAiEmbeddingGateway(unauthorizedHttp),
    ).test();
    expect(unauthorized.succeeded, isFalse);
    expect(unauthorized.status, ProviderTestStatus.authentication);
    expect(unauthorized.message, 'API Key 没有通过验证。');
    // 服务商原文（含地址样文本）不出现在诊断里。
    expect(unauthorized.message, isNot(contains('42.3.8.1')));

    final limitedHttp = _RecordingEmbeddingHttp(statusCode: 429);
    final limited = await EmbeddingSettingsService(
      repository(),
      OpenAiEmbeddingGateway(limitedHttp),
    ).test();
    expect(limited.status, ProviderTestStatus.rateLimited);
    expect(limited.message, '记忆召回服务请求过于频繁，请稍后再试。');

    final offlineHttp = _RecordingEmbeddingHttp(
      postError: const SocketException('connection refused'),
    );
    final offline = await EmbeddingSettingsService(
      repository(),
      OpenAiEmbeddingGateway(offlineHttp),
    ).test();
    expect(offline.status, ProviderTestStatus.network);
    expect(offline.message, '无法连接记忆召回服务，请检查地址和网络。');
  });

  test('无效向量响应不可当作连接成功：数量、维度、非有限值与零向量', () async {
    final svc = service(_RecordingEmbeddingHttp());
    await svc.save(
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'embedding-secret-value',
    );

    // 每次用全新仓储先落同一份配置，再以可编排的响应体出网。
    Future<ProviderTestResult> testWith(String responseBody) async {
      final http = _RecordingEmbeddingHttp(responseBody: responseBody);
      final prepared = EmbeddingSettingsService(
        repository(),
        OpenAiEmbeddingGateway(_RecordingEmbeddingHttp()),
      );
      await prepared.save(
        baseUrl: 'https://embedding.example.com/v1',
        model: 'text-embedding-test',
        apiKey: 'embedding-secret-value',
      );
      return EmbeddingSettingsService(
        repository(),
        OpenAiEmbeddingGateway(http),
      ).test();
    }

    // 数量不符：请求 1 条，返回 2 条。服务层按共享文案表把
    // incompatibleResponse 统一为一条固定话术（与聊天、语音同律），
    // 网关层的细分类在网关测试里单独锁定。
    final extra = await testWith(
      jsonEncode({
        'data': [
          {'index': 0, 'embedding': [0.1, 0.2]},
          {'index': 1, 'embedding': [0.1, 0.2]},
        ],
      }),
    );
    expect(extra.succeeded, isFalse);
    expect(extra.status, ProviderTestStatus.incompatibleResponse);
    expect(extra.message, '记忆召回服务返回了不兼容的响应格式。');

    // 维度一致性属批量路径（多条输入），连接测试恒为单条输入、无法
    // 触发；该分支在网关测试里以两条输入直接锁定。
    // 非有限数值：JSON 数字 1e999 解析为 double.infinity。
    final nonFinite = await testWith(
      '{"data":[{"index":0,"embedding":[0.1,1e999]}]}',
    );
    expect(nonFinite.succeeded, isFalse);
    expect(nonFinite.status, ProviderTestStatus.incompatibleResponse);

    // 零向量：精确余弦不可计算。
    final zero = await testWith(
      jsonEncode({
        'data': [
          {'index': 0, 'embedding': [0.0, 0.0, 0.0]},
        ],
      }),
    );
    expect(zero.succeeded, isFalse);
    expect(zero.status, ProviderTestStatus.incompatibleResponse);

    // 非 JSON 响应：内容解析失败单独分类。
    final garbage = await testWith('not json at all');
    expect(garbage.succeeded, isFalse);
    expect(garbage.status, ProviderTestStatus.contentParsing);
    expect(garbage.message, '记忆召回服务返回的内容无法解析。');
  });

  test('保存 embedding 段不丢失聊天、STT、TTS、联网搜索与未知段', () async {
    await File(configPath()).writeAsString(jsonEncode({
      'provider': 'openai_compatible',
      'baseUrl': 'https://chat.example.com/v1',
      'model': 'chat-model',
      'temperature': 0.6,
      'timeoutSeconds': 25,
      'apiKey': 'chat-secret',
      'stt': {'baseUrl': 'https://stt.example.com/v1', 'model': 'whisper'},
      'tts': {'baseUrl': 'https://tts.example.com/v1', 'model': 'tts-model'},
      'webSearch': {'apiKey': 'search-secret'},
      'unknownSection': {'keep': true},
    }));

    final saved = await service(_RecordingEmbeddingHttp()).save(
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'embedding-secret-value',
    );

    expect(saved.configured, isTrue);
    final stored =
        jsonDecode(await File(configPath()).readAsString())
            as Map<String, Object?>;
    expect(stored['baseUrl'], 'https://chat.example.com/v1');
    expect(stored['apiKey'], 'chat-secret');
    expect(stored['stt'], isA<Map<String, Object?>>());
    expect(stored['tts'], isA<Map<String, Object?>>());
    expect(
      (stored['webSearch']! as Map<String, Object?>)['apiKey'],
      'search-secret',
    );
    expect(stored['unknownSection'], {'keep': true});
    expect(stored['embedding'], isA<Map<String, Object?>>());
  });

  test('聊天与语音等其余段的保存与读取不受 embedding 段影响', () async {
    final repo = repository();
    final svc = EmbeddingSettingsService(
      repo,
      OpenAiEmbeddingGateway(_RecordingEmbeddingHttp()),
    );
    await svc.save(
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      apiKey: 'embedding-secret-value',
    );

    await repo.save(
      const ProviderConfig(
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://chat.example.com/v1',
        model: 'chat-model',
        temperature: 0.6,
        timeoutSeconds: 25,
      ),
    );
    await repo.saveStt(
      const SttConfig(
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper',
      ),
    );

    final read = await svc.read();
    expect(read.keySet, isTrue);
    expect((await repo.loadStt())!.baseUrl, 'https://stt.example.com/v1');
    final stored =
        jsonDecode(await File(configPath()).readAsString())
            as Map<String, Object?>;
    expect(
      (stored['embedding']! as Map<String, Object?>)['apiKey'],
      'embedding-secret-value',
    );
  });

  test('损坏的 embedding 段按配置无法读取暴露，不影响其余段', () async {
    await File(configPath()).writeAsString(jsonEncode({
      'embedding': {'baseUrl': 42},
      'stt': {'baseUrl': 'https://stt.example.com/v1', 'model': 'whisper'},
    }));

    final repo = repository();
    await expectLater(
      repo.loadEmbedding(),
      throwsA(isA<ProviderConfigException>()),
    );
    expect((await repo.loadStt())!.baseUrl, 'https://stt.example.com/v1');
  });

  test('保存校验失败：非法地址与空模型被驳回，不落盘', () async {
    final svc = service(_RecordingEmbeddingHttp());

    await expectLater(
      svc.save(baseUrl: 'ftp://embedding.example.com', model: 'm'),
      throwsA(isA<ProviderConfigException>()),
    );
    await expectLater(
      svc.save(baseUrl: 'https://embedding.example.com/v1', model: ' '),
      throwsA(isA<ProviderConfigException>()),
    );

    // 两次失败保存都不产生 embedding 段。
    if (await File(configPath()).exists()) {
      final stored =
          jsonDecode(await File(configPath()).readAsString())
              as Map<String, Object?>;
      expect(stored.containsKey('embedding'), isFalse);
    }
  });
}

/// 记录型 embedding 出网 HTTP：成功返回单条有效向量，状态码与异常可编
/// 排，供真网关全链路验证请求形状与错误分类。
final class _RecordingEmbeddingHttp implements ProviderHttpClient {
  _RecordingEmbeddingHttp({
    this.statusCode = 200,
    String? responseBody,
    this.postError,
  }) : responseBody =
           responseBody ??
           jsonEncode({
             'data': [
               {
                 'index': 0,
                 'embedding': [0.1, 0.2, 0.3],
               },
             ],
           });

  final int statusCode;
  final String responseBody;
  final Object? postError;
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
    if (postError case final error?) {
      throw error;
    }
    lastUri = uri;
    lastBody = body;
    lastHeaders = headers;
    return ProviderHttpResponse(
      statusCode: statusCode,
      body: Stream.value(responseBody),
    );
  }
}

/// 静态 embedding 仓储：内存现值，供「已存配置」场景直接播种。
final class _StaticEmbeddingConfigRepository
    implements EmbeddingConfigRepository {
  _StaticEmbeddingConfigRepository(this.config);

  EmbeddingConfig? config;

  @override
  Future<EmbeddingConfig?> loadEmbedding() async => config;

  @override
  Future<void> saveEmbedding(EmbeddingConfig config) async =>
      this.config = config;

  @override
  Future<T> runTransaction<T>(Future<T> Function() action) => action();
}
