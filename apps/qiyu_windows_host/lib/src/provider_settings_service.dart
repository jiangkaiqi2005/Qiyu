import 'model_gateway.dart';
import 'provider_config.dart';
import 'secret_store.dart';

final class ProviderSettingsSnapshot {
  const ProviderSettingsSnapshot({required this.config, required this.keySet});

  final ProviderConfig? config;
  final bool keySet;

  bool get configured => config != null;

  Map<String, Object?> toJson() => {
    'configured': configured,
    'keySet': keySet,
    if (config case final value?) ...value.toJson(),
  };
}

enum ProviderTestStatus {
  success,
  notConfigured,
  authentication,
  network,
  modelNotFound,
  invalidResponse,
  provider,
}

final class ProviderTestResult {
  const ProviderTestResult({required this.status, required this.message});

  final ProviderTestStatus status;
  final String message;

  bool get succeeded => status == ProviderTestStatus.success;

  Map<String, Object?> toJson() => {
    'ok': succeeded,
    'status': status.name,
    'message': message,
  };
}

final class ModelCompletion {
  const ModelCompletion.reply(String this.text) : failure = null;

  const ModelCompletion.failure(ModelFailureKind this.failure) : text = null;

  final String? text;
  final ModelFailureKind? failure;

  bool get succeeded => text != null;
}

abstract interface class ProviderChatClient {
  Future<ModelCompletion?> complete(List<ModelMessage> messages);
}

final class ProviderSettingsService implements ProviderChatClient {
  const ProviderSettingsService(
    this.configRepository,
    this.secretStore,
    this.modelGateway,
  );

  final ProviderConfigRepository configRepository;
  final SecretStore secretStore;
  final ModelGateway modelGateway;

  Future<ProviderSettingsSnapshot> read() async {
    final config = await configRepository.load();
    final key = await secretStore.readApiKey();
    return ProviderSettingsSnapshot(
      config: config,
      keySet: key != null && key.isNotEmpty,
    );
  }

  Future<ProviderSettingsSnapshot> save({
    required ProviderConfig config,
    String? apiKey,
  }) async {
    config.validate();
    if (apiKey != null) {
      await secretStore.writeApiKey(apiKey);
    }
    await configRepository.save(config);
    return read();
  }

  Future<ProviderSettingsSnapshot> forgetApiKey() async {
    await secretStore.deleteApiKey();
    return read();
  }

  Future<ProviderTestResult> testCurrent() async {
    final completion = await complete(const [
      ModelMessage(ModelMessageRole.system, '你是栖语，回复自然、简短。'),
      ModelMessage(ModelMessageRole.user, '只用一句简短的话回应：在吗'),
    ]);
    if (completion == null) {
      return const ProviderTestResult(
        status: ProviderTestStatus.notConfigured,
        message: '还没有保存模型配置。',
      );
    }
    if (completion.succeeded) {
      return const ProviderTestResult(
        status: ProviderTestStatus.success,
        message: '连接成功，栖语可以使用这个模型。',
      );
    }
    final status = switch (completion.failure!) {
      ModelFailureKind.authentication => ProviderTestStatus.authentication,
      ModelFailureKind.network => ProviderTestStatus.network,
      ModelFailureKind.modelNotFound => ProviderTestStatus.modelNotFound,
      ModelFailureKind.invalidResponse => ProviderTestStatus.invalidResponse,
      ModelFailureKind.provider => ProviderTestStatus.provider,
    };
    return ProviderTestResult(status: status, message: _testMessage(status));
  }

  @override
  Future<ModelCompletion?> complete(List<ModelMessage> messages) async {
    final config = await configRepository.load();
    if (config == null) {
      return null;
    }
    try {
      final text = await modelGateway.complete(
        config: config,
        apiKey: await secretStore.readApiKey(),
        messages: messages,
      );
      return ModelCompletion.reply(text);
    } on ModelGatewayException catch (error) {
      return ModelCompletion.failure(error.kind);
    } on Object {
      return const ModelCompletion.failure(ModelFailureKind.provider);
    }
  }
}

String _testMessage(ProviderTestStatus status) => switch (status) {
  ProviderTestStatus.success => '连接成功，栖语可以使用这个模型。',
  ProviderTestStatus.notConfigured => '还没有保存模型配置。',
  ProviderTestStatus.authentication => 'API Key 没有通过验证。',
  ProviderTestStatus.network => '无法连接模型服务，请检查地址和网络。',
  ProviderTestStatus.modelNotFound => '找不到这个模型，请检查模型名称。',
  ProviderTestStatus.invalidResponse => '模型服务返回了无法读取的内容。',
  ProviderTestStatus.provider => '模型服务拒绝了测试请求。',
};
