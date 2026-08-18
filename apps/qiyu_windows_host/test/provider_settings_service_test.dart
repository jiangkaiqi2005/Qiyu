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
    expect(
      await secrets.readApiKey(config.credentialScope),
      'first-private-value',
    );

    // 替换：同一作用域写入新 Key，旧值被覆盖。
    final replaced = await service.save(
      config: config,
      apiKey: 'second-private-value',
    );
    expect(replaced.keySet, isTrue);
    expect(
      await secrets.readApiKey(config.credentialScope),
      'second-private-value',
    );

    // 换地址即换凭据作用域：新 Key 落位后，旧作用域的 Key 被清走，
    // 本机凭据库不留无人读取的废弃 Key。
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
    expect(
      await secrets.readApiKey(switched.credentialScope),
      'third-private-value',
    );
    expect(await secrets.readApiKey(config.credentialScope), isNull);

    // 移除：Key 清空，配置本身保留。
    final forgotten = await service.forgetApiKey();
    expect(forgotten.keySet, isFalse);
    expect(forgotten.configured, isTrue);
    expect(await secrets.readApiKey(switched.credentialScope), isNull);
    expect(repository.config, switched);
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

  @override
  Future<void> writeApiKey(String scope, String value) async {
    values[scope] = value;
  }
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
