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

  test('设置快照只返回 Key 是否存在且重启后配置仍可用', () async {
    final repository = _MemoryProviderConfigRepository();
    final secrets = _MemorySecretStore();
    final gateway = _FakeModelGateway(reply: '连接成功');
    final service = ProviderSettingsService(repository, secrets, gateway);

    final saved = await service.save(config: config, apiKey: 'private-value');
    final restarted = ProviderSettingsService(repository, secrets, gateway);
    final restored = await restarted.read();

    expect(saved.keySet, isTrue);
    expect(restored.config, config);
    expect(restored.keySet, isTrue);
    expect(saved.toJson(), isNot(contains('apiKey')));
    expect(saved.toJson().toString(), isNot(contains('private-value')));
  });

  test('测试当前配置返回成功结果且不会回传 Key', () async {
    final repository = _MemoryProviderConfigRepository()..config = config;
    final secrets = _MemorySecretStore()..value = 'private-value';
    final gateway = _FakeModelGateway(reply: '在。');
    final service = ProviderSettingsService(repository, secrets, gateway);

    final result = await service.testCurrent();

    expect(result.status, ProviderTestStatus.success);
    expect(result.toJson().toString(), isNot(contains('private-value')));
    expect(gateway.apiKey, 'private-value');
  });

  test('测试当前配置保留鉴权和网络错误类别', () async {
    for (final kind in [
      ModelFailureKind.authentication,
      ModelFailureKind.network,
      ModelFailureKind.modelNotFound,
    ]) {
      final service = ProviderSettingsService(
        _MemoryProviderConfigRepository()..config = config,
        _MemorySecretStore()..value = 'private-value',
        _FakeModelGateway(failure: kind),
      );

      final result = await service.testCurrent();

      expect(result.status.name, kind.name);
      expect(result.toJson().toString(), isNot(contains('private-value')));
    }
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
  String? value;

  @override
  Future<void> deleteApiKey() async => value = null;

  @override
  Future<String?> readApiKey() async => value;

  @override
  Future<void> writeApiKey(String value) async => this.value = value;
}

final class _FakeModelGateway implements ModelGateway {
  _FakeModelGateway({this.reply, this.failure});

  final String? reply;
  final ModelFailureKind? failure;
  String? apiKey;

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
  }) async {
    this.apiKey = apiKey;
    if (failure case final kind?) {
      throw ModelGatewayException(kind: kind, message: '测试失败');
    }
    return reply!;
  }
}
