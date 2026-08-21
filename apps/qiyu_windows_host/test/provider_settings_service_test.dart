import 'package:qiyu_windows_host/qiyu_windows_host.dart';
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

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
  }) async {
    this.apiKey = apiKey;
    this.messages = messages;
    if (failure case final kind?) {
      throw ModelGatewayException(kind: kind, message: '测试失败');
    }
    return reply!;
  }
}
