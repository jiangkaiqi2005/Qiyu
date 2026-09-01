import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

void main() {
  const config = ProviderConfig(
    kind: ProviderKind.anthropic,
    baseUrl: 'https://api.anthropic.com/v1',
    model: 'claude-test',
    temperature: 0.7,
    timeoutSeconds: 30,
  );
  const promptBuilder = ModelPromptBuilder('测试人格宪法');

  test('只有 Anthropic 与 AnySearch 工具都就绪时报告联网能力', () async {
    final repository = _MemoryProviderConfigRepository()
      ..config = config.withApiKey('provider-key');
    final webSearch = _MemoryWebSearchRepository()
      ..config = const WebSearchConfig(apiKey: 'any-key');
    final gateway = _RecordingWebSearchGateway();
    final service = ProviderSettingsService(
      repository,
      _MemorySecretStore(),
      gateway,
      promptBuilder,
      webSearchConfigRepository: webSearch,
      webSearchClient: _NoopWebSearchClient(),
    );

    final messages = promptBuilder.build(
      StateSnapshot.initial('local-user'),
      '现在几点',
      hardRulesAddendum: webSearchSystemInstruction,
    );
    final request = await service.prepareChatRequest();
    expect(request!.hardRulesAddendum, webSearchSystemInstruction);
    await (await request.openStream(messages))!.drain<void>();

    final prompt = gateway.messages!.first.content;
    expect(
      RegExp(RegExp.escape(webSearchSystemInstruction)).allMatches(prompt),
      hasLength(1),
    );
    expect(prompt, isNot(contains('get_local_time')));
    expect(prompt, isNot(contains('searched_at')));
    expect(gateway.webSearchApiKey, 'any-key');
  });

  test('同一聊天请求的提示与工具始终使用同一配置快照', () async {
    final repository = _MemoryProviderConfigRepository()
      ..config = config.withApiKey('provider-key');
    final webSearch = _MemoryWebSearchRepository()
      ..config = const WebSearchConfig(apiKey: 'any-key');
    final gateway = _RecordingWebSearchGateway();
    final service = ProviderSettingsService(
      repository,
      _MemorySecretStore(),
      gateway,
      promptBuilder,
      webSearchConfigRepository: webSearch,
      webSearchClient: _NoopWebSearchClient(),
    );

    final request = await service.prepareChatRequest();
    repository.config = const ProviderConfig(
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'https://api.example.com/v1',
      model: 'changed-between-reads',
      temperature: 0.7,
      timeoutSeconds: 30,
      apiKey: 'changed-key',
    );
    webSearch.config = null;
    final messages = promptBuilder.build(
      StateSnapshot.initial('local-user'),
      '今天新闻',
      hardRulesAddendum: request!.hardRulesAddendum,
    );
    await (await request.openStream(messages))!.drain<void>();

    expect(gateway.config, config.withApiKey('provider-key'));
    expect(gateway.webSearchApiKey, 'any-key');
    expect(
      gateway.messages!.first.content,
      contains(webSearchSystemInstruction),
    );
  });

  test('后台 complete 调用不注入联网提示也不声明搜索工具', () async {
    final repository = _MemoryProviderConfigRepository()
      ..config = config.withApiKey('provider-key');
    final webSearch = _MemoryWebSearchRepository()
      ..config = const WebSearchConfig(apiKey: 'any-key');
    final gateway = _RecordingWebSearchGateway();
    final service = ProviderSettingsService(
      repository,
      _MemorySecretStore(),
      gateway,
      promptBuilder,
      webSearchConfigRepository: webSearch,
      webSearchClient: _NoopWebSearchClient(),
    );
    final messages = promptBuilder.build(
      StateSnapshot.initial('background'),
      '整理每日状态',
    );

    await service.complete(messages, maxTokens: 8192);

    expect(gateway.messages!.first.content, isNot(contains('web_search')));
    expect(gateway.webSearchApiKey, isNull);
  });

  test('AnySearch Key 缺失或 Provider 非 Anthropic 时不报告联网能力', () async {
    final repository = _MemoryProviderConfigRepository()
      ..config = config.withApiKey('provider-key');
    final webSearch = _MemoryWebSearchRepository();
    final gateway = _RecordingWebSearchGateway();
    final service = ProviderSettingsService(
      repository,
      _MemorySecretStore(),
      gateway,
      promptBuilder,
      webSearchConfigRepository: webSearch,
      webSearchClient: _NoopWebSearchClient(),
    );
    const messages = [
      ModelMessage(ModelMessageRole.system, 'system'),
      ModelMessage(ModelMessageRole.user, '普通聊天'),
    ];

    var request = await service.prepareChatRequest();
    expect(request!.hardRulesAddendum, isEmpty);
    await (await request.openStream(messages))!.drain<void>();
    expect(gateway.messages!.first.content, isNot(contains('web_search')));

    webSearch.config = const WebSearchConfig(apiKey: 'any-key');
    repository.config = const ProviderConfig(
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'https://api.example.com/v1',
      model: 'chat-model',
      temperature: 0.7,
      timeoutSeconds: 30,
      apiKey: 'provider-key',
    );
    request = await service.prepareChatRequest();
    expect(request!.hardRulesAddendum, isEmpty);
    await (await request.openStream(messages))!.drain<void>();
    expect(gateway.messages!.first.content, isNot(contains('web_search')));
  });

  test('设置快照只返回 Key 是否存在且重启后配置仍可用', () async {
    final repository = _MemoryProviderConfigRepository();
    final secrets = _MemorySecretStore();
    final gateway = _FakeModelGateway(reply: '连接成功');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );

    final saved = await service.save(config: config, apiKey: 'private-value');
    final restarted = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );
    final restored = await restarted.read();

    expect(saved.keySet, isTrue);
    expect(restored.config, config);
    expect(restored.keySet, isTrue);
    expect(saved.toJson(), isNot(contains('apiKey')));
    expect(saved.toJson().toString(), isNot(contains('private-value')));
  });

  test('complete 透传 per-call 输出预算，缺省回落聊天护栏', () async {
    final repository = _MemoryProviderConfigRepository()..config = config;
    final secrets = _MemorySecretStore();
    final gateway = _FakeModelGateway(reply: '{}');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );

    await service.complete([
      const ModelMessage(ModelMessageRole.user, '理解'),
    ], maxTokens: 8192);
    expect(gateway.maxTokens, 8192);

    await service.complete([const ModelMessage(ModelMessageRole.user, '在吗')]);
    expect(gateway.maxTokens, isNull);
  });

  test('测试当前配置返回成功结果且不会回传 Key', () async {
    final repository = _MemoryProviderConfigRepository()..config = config;
    final secrets = _MemorySecretStore()
      ..values[config.credentialScope] = 'private-value';
    final gateway = _FakeModelGateway(reply: '在。');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );

    final result = await service.test(config: config);

    expect(result.status, ProviderTestStatus.success);
    expect(result.toJson().toString(), isNot(contains('private-value')));
    expect(gateway.apiKey, 'private-value');
    expect(gateway.messages!.first.content, contains('测试人格宪法'));
  });

  test('切换 Provider 或 URL 时不会把旧配置的 Key 发给新目标', () async {
    final repository = _MemoryProviderConfigRepository();
    final secrets = _MemorySecretStore();
    final gateway = _FakeModelGateway(reply: '在。');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );
    await service.save(config: config, apiKey: 'old-private-value');
    const switched = ProviderConfig(
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'https://different.example/v1',
      model: 'new-model',
      temperature: 0.5,
      timeoutSeconds: 20,
    );

    await service.save(config: switched);
    final result = await service.test(config: switched);

    expect(result.status, ProviderTestStatus.success);
    expect(gateway.apiKey, isNull);
    // 换作用域保存后旧 Key 已被清理，更不会发给新目标。
    expect(await secrets.readApiKey(config.credentialScope), isNull);
  });

  test('测试当前表单保留所有连接错误类别', () async {
    for (final kind in [
      ModelFailureKind.dns,
      ModelFailureKind.tls,
      ModelFailureKind.timeout,
      ModelFailureKind.authentication,
      ModelFailureKind.network,
      ModelFailureKind.modelNotFound,
      ModelFailureKind.rateLimited,
      ModelFailureKind.incompatibleResponse,
      ModelFailureKind.contentParsing,
      ModelFailureKind.internal,
    ]) {
      final service = ProviderSettingsService(
        _MemoryProviderConfigRepository()..config = config,
        _MemorySecretStore()..values[config.credentialScope] = 'private-value',
        _FakeModelGateway(failure: kind),
        promptBuilder,
      );

      final result = await service.test(config: config);

      expect(result.status.name, kind.name);
      expect(result.toJson().toString(), isNot(contains('private-value')));
    }
  });

  test('测试连接会经过栖语完整输出检查', () async {
    final service = ProviderSettingsService(
      _MemoryProviderConfigRepository()..config = config,
      _MemorySecretStore()..values[config.credentialScope] = 'private-value',
      _FakeModelGateway(reply: '我理解你的感受'),
      promptBuilder,
    );

    final result = await service.test(config: config);

    expect(result.status, ProviderTestStatus.contentParsing);
    expect(result.succeeded, isFalse);
  });

  test('Key 替换覆盖旧值、移除后配置仍在但 Key 清空', () async {
    final repository = _MemoryProviderConfigRepository();
    final secrets = _MemorySecretStore();
    final gateway = _FakeModelGateway(reply: '在。');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );

    await service.save(config: config, apiKey: 'first-private-value');
    expect(repository.config!.apiKey, 'first-private-value');

    // 替换：同一作用域写入新 Key，旧值被覆盖。
    final replaced = await service.save(
      config: config,
      apiKey: 'second-private-value',
    );
    expect(replaced.keySet, isTrue);
    expect(repository.config!.apiKey, 'second-private-value');

    // 换地址即换凭据作用域：新 Key 落位后，旧作用域在凭据管理器里的
    // 遗留 Key 被清走，本机不留无人读取的废弃凭据。
    const switched = ProviderConfig(
      kind: ProviderKind.anthropic,
      baseUrl: 'https://other.anthropic.example/v1',
      model: 'claude-test',
      temperature: 0.7,
      timeoutSeconds: 30,
    );
    final afterSwitch = await service.save(
      config: switched,
      apiKey: 'third-private-value',
    );
    expect(afterSwitch.keySet, isTrue);
    expect(repository.config!.apiKey, 'third-private-value');
    expect(await secrets.readApiKey(config.credentialScope), isNull);

    // 移除：文件与凭据管理器都清空，配置本身保留。
    secrets.values[switched.credentialScope] = 'legacy-leftover';
    final forgotten = await service.forgetApiKey();
    expect(forgotten.keySet, isFalse);
    expect(forgotten.configured, isTrue);
    expect(repository.config!.apiKey, isNull);
    expect(await secrets.readApiKey(switched.credentialScope), isNull);
    expect(repository.config, switched);
  });

  test('provider.json 里的 Key 优先于凭据管理器中的旧值', () async {
    final repository =
        _MemoryProviderConfigRepository()..config = config.withApiKey(
          'file-private-value',
        );
    final secrets = _MemorySecretStore()
      ..values[config.credentialScope] = 'legacy-credential-value';
    final gateway = _FakeModelGateway(reply: '在。');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );

    final snapshot = await service.read();
    expect(snapshot.keySet, isTrue);

    final result = await service.test(config: config);
    expect(result.status, ProviderTestStatus.success);
    expect(gateway.apiKey, 'file-private-value');
  });

  test('保存新 Key 后凭据管理器同作用域旧值被清除，不再回退复活', () async {
    final repository = _MemoryProviderConfigRepository();
    final secrets = _MemorySecretStore()
      ..values[config.credentialScope] = 'stale-credential-value';
    final gateway = _FakeModelGateway(reply: '在。');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );

    // 文件接管 Key 的那一刻，同作用域的凭据库旧值即被取代清走。
    await service.save(config: config, apiKey: 'fresh-private-value');
    expect(await secrets.readApiKey(config.credentialScope), isNull);

    // 用户日后手改 provider.json 清空 Key：不回退到陈旧凭据。
    await repository.save(config.withApiKey(null));
    final result = await service.test(config: config);
    expect(result.status, ProviderTestStatus.success);
    expect(gateway.apiKey, isNull);
  });

  test('纯旧安装（Key 只在凭据库）改模型名保存后 Key 仍可用', () async {
    final repository = _MemoryProviderConfigRepository()..config = config;
    final secrets = _MemorySecretStore()
      ..values[config.credentialScope] = 'legacy-only-value';
    final gateway = _FakeModelGateway(reply: '在。');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );

    // 同作用域只改模型名且未输入新 Key：文件不接管，凭据库回退保持。
    final kept = await service.save(
      config: ProviderConfig(
        kind: config.kind,
        baseUrl: config.baseUrl,
        model: 'another-model',
        temperature: config.temperature,
        timeoutSeconds: config.timeoutSeconds,
      ),
    );
    expect(kept.keySet, isTrue);
    expect(repository.config!.apiKey, isNull);
    expect(await secrets.readApiKey(config.credentialScope), 'legacy-only-value');

    final result = await service.test(config: repository.config!);
    expect(result.status, ProviderTestStatus.success);
    expect(gateway.apiKey, 'legacy-only-value');
  });

  test('旧版 scope 字符串（带「?#」尾巴）下的凭据回退仍可读取使用', () async {
    final repository = _MemoryProviderConfigRepository()..config = config;
    // 只在旧格式 scope 下有 Key：模拟升级前的纯旧安装。
    final secrets = _MemorySecretStore()
      ..values[config.legacyCredentialScope] = 'legacy-scope-value';
    final gateway = _FakeModelGateway(reply: '在。');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );

    final snapshot = await service.read();
    expect(snapshot.keySet, isTrue);

    final result = await service.test(config: config);
    expect(result.status, ProviderTestStatus.success);
    expect(gateway.apiKey, 'legacy-scope-value');
  });

  test('文件接管 Key 后旧格式 scope 的凭据条目一并被清理', () async {
    final repository = _MemoryProviderConfigRepository()..config = config;
    final secrets = _MemorySecretStore()
      ..values[config.legacyCredentialScope] = 'legacy-scope-value';
    final service = ProviderSettingsService(
      repository,
      secrets,
      _FakeModelGateway(reply: '在。'),
      promptBuilder,
    );

    await service.save(config: config, apiKey: 'fresh-private-value');

    expect(await secrets.readApiKey(config.legacyCredentialScope), isNull);
    expect(await secrets.readApiKey(config.credentialScope), isNull);

    // 换作用域保存也把旧格式的旧作用域条目清走。
    final secrets2 = _MemorySecretStore()
      ..values[config.legacyCredentialScope] = 'legacy-scope-value';
    final service2 = ProviderSettingsService(
      _MemoryProviderConfigRepository()..config = config,
      secrets2,
      _FakeModelGateway(reply: '在。'),
      promptBuilder,
    );
    const switched = ProviderConfig(
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'https://different.example/v1',
      model: 'new-model',
      temperature: 0.5,
      timeoutSeconds: 20,
    );
    await service2.save(config: switched, apiKey: 'new-private-value');
    expect(await secrets2.readApiKey(config.legacyCredentialScope), isNull);

    // 忘记 Key 同样覆盖旧格式条目。
    final secrets3 = _MemorySecretStore()
      ..values[switched.legacyCredentialScope] = 'legacy-scope-value';
    final service3 = ProviderSettingsService(
      _MemoryProviderConfigRepository()..config = switched,
      secrets3,
      _FakeModelGateway(reply: '在。'),
      promptBuilder,
    );
    final forgotten = await service3.forgetApiKey();
    expect(forgotten.keySet, isFalse);
    expect(await secrets3.readApiKey(switched.legacyCredentialScope), isNull);
  });

  test('同作用域保存其他字段保留已存 Key，换作用域不带新 Key 则清空', () async {
    final repository = _MemoryProviderConfigRepository();
    final secrets = _MemorySecretStore();
    final gateway = _FakeModelGateway(reply: '在。');
    final service = ProviderSettingsService(
      repository,
      secrets,
      gateway,
      promptBuilder,
    );
    await service.save(config: config, apiKey: 'kept-private-value');

    // 同作用域只改模型名：已存 Key 原样保留。
    final kept = await service.save(
      config: ProviderConfig(
        kind: config.kind,
        baseUrl: config.baseUrl,
        model: 'another-model',
        temperature: config.temperature,
        timeoutSeconds: config.timeoutSeconds,
      ),
    );
    expect(kept.keySet, isTrue);
    expect(repository.config!.model, 'another-model');
    expect(repository.config!.apiKey, 'kept-private-value');

    // 换作用域且未提供新 Key：不把旧目标的 Key 沿用给新目标。
    const switched = ProviderConfig(
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'https://different.example/v1',
      model: 'new-model',
      temperature: 0.5,
      timeoutSeconds: 20,
    );
    final cleared = await service.save(config: switched);
    expect(cleared.keySet, isFalse);
    expect(repository.config!.apiKey, isNull);
  });
}

final class _MemoryProviderConfigRepository
    implements ProviderConfigRepository {
  ProviderConfig? config;

  @override
  Future<ProviderConfig?> load() async => config;

  @override
  Future<void> save(ProviderConfig config) async {
    this.config = config;
  }
}

final class _MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> deleteApiKey(String scope) async => values.remove(scope);

  @override
  Future<String?> readApiKey(String scope) async => values[scope];
}

final class _FakeModelGateway implements ModelGateway {
  _FakeModelGateway({this.reply, this.failure});

  final String? reply;
  final ModelFailureKind? failure;
  String? apiKey;
  List<ModelMessage>? messages;
  int? maxTokens;

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) async {
    this.apiKey = apiKey;
    this.messages = messages;
    this.maxTokens = maxTokens;
    if (failure case final kind?) {
      throw ModelGatewayException(kind: kind, message: '测试失败');
    }
    return reply!;
  }
}

final class _MemoryWebSearchRepository implements WebSearchConfigRepository {
  WebSearchConfig? config;

  @override
  Future<WebSearchConfig?> loadWebSearch() async => config;

  @override
  Future<void> saveWebSearch(WebSearchConfig? config) async {
    this.config = config;
  }
}

final class _NoopWebSearchClient implements WebSearchClient {
  @override
  Future<List<WebSearchResult>> search({
    required String apiKey,
    required String query,
    Future<void>? whenCancelled,
  }) async => const [];
}

final class _RecordingWebSearchGateway
    implements ModelGateway, WebSearchStreamingModelGateway {
  ProviderConfig? config;
  List<ModelMessage>? messages;
  String? webSearchApiKey;

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) async {
    this.config = config;
    this.messages = messages;
    return '普通回复';
  }

  @override
  Stream<ModelStreamEvent> streamWithWebSearch({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    required String webSearchApiKey,
    required WebSearchClient webSearchClient,
    Future<void>? whenCancelled,
    int? maxTokens,
  }) async* {
    this.config = config;
    this.messages = messages;
    this.webSearchApiKey = webSearchApiKey;
    yield const ModelStreamEvent.delta('在。');
    yield const ModelStreamEvent.done();
  }
}
