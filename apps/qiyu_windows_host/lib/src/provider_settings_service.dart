import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'model_gateway.dart';
import 'model_prompt_builder.dart';
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
  dns,
  tls,
  timeout,
  authentication,
  network,
  modelNotFound,
  rateLimited,
  incompatibleResponse,
  contentParsing,
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
    this.modelPromptBuilder, {
    this._behaviorCore = const QiyuBehaviorCore(),
  });

  final ProviderConfigRepository configRepository;
  final SecretStore secretStore;
  final ModelGateway modelGateway;
  final ModelPromptBuilder modelPromptBuilder;
  final QiyuBehaviorCore _behaviorCore;

  Future<ProviderSettingsSnapshot> read() async {
    final config = await configRepository.load();
    final key = config == null
        ? null
        : await secretStore.readApiKey(config.credentialScope);
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
      await secretStore.writeApiKey(config.credentialScope, apiKey);
    }
    await configRepository.save(config);
    return read();
  }

  Future<ProviderSettingsSnapshot> forgetApiKey() async {
    final config = await configRepository.load();
    if (config != null) {
      await secretStore.deleteApiKey(config.credentialScope);
    }
    return read();
  }

  Future<ProviderTestResult> test({
    required ProviderConfig config,
    String? apiKey,
  }) async {
    config.validate();
    final state = StateSnapshot.initial('provider-connection-test');
    const request = ChatRequest(
      requestId: 'provider-connection-test',
      text: '在吗',
    );
    try {
      final candidate = await modelGateway.complete(
        config: config,
        apiKey: apiKey ?? await secretStore.readApiKey(config.credentialScope),
        messages: modelPromptBuilder.build(state, request.text),
      );
      final outcome = _behaviorCore.reply(
        request,
        state,
        candidateReply: candidate,
      );
      if (outcome is! ChatResult || outcome.source != ReplySource.llm) {
        return const ProviderTestResult(
          status: ProviderTestStatus.contentParsing,
          message: '模型回复未通过栖语的完整输出检查。',
        );
      }
      return const ProviderTestResult(
        status: ProviderTestStatus.success,
        message: '连接成功，栖语可以使用这个模型。',
      );
    } on ModelGatewayException catch (error) {
      final status = switch (error.kind) {
        ModelFailureKind.dns => ProviderTestStatus.dns,
        ModelFailureKind.tls => ProviderTestStatus.tls,
        ModelFailureKind.timeout => ProviderTestStatus.timeout,
        ModelFailureKind.authentication => ProviderTestStatus.authentication,
        ModelFailureKind.network => ProviderTestStatus.network,
        ModelFailureKind.modelNotFound => ProviderTestStatus.modelNotFound,
        ModelFailureKind.rateLimited => ProviderTestStatus.rateLimited,
        ModelFailureKind.incompatibleResponse =>
          ProviderTestStatus.incompatibleResponse,
        ModelFailureKind.contentParsing => ProviderTestStatus.contentParsing,
        ModelFailureKind.provider => ProviderTestStatus.provider,
      };
      return ProviderTestResult(status: status, message: _testMessage(status));
    } on Object {
      return const ProviderTestResult(
        status: ProviderTestStatus.provider,
        message: '模型服务拒绝了测试请求。',
      );
    }
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
        apiKey: await secretStore.readApiKey(config.credentialScope),
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
  ProviderTestStatus.dns => '找不到模型服务域名，请检查地址或 DNS。',
  ProviderTestStatus.tls => '模型服务的 TLS 安全连接失败。',
  ProviderTestStatus.timeout => '连接模型服务超时。',
  ProviderTestStatus.authentication => 'API Key 没有通过验证。',
  ProviderTestStatus.network => '无法连接模型服务，请检查地址和网络。',
  ProviderTestStatus.modelNotFound => '找不到这个模型，请检查模型名称。',
  ProviderTestStatus.rateLimited => '模型服务请求过于频繁，请稍后再试。',
  ProviderTestStatus.incompatibleResponse => '模型服务返回了不兼容的响应格式。',
  ProviderTestStatus.contentParsing => '模型服务返回的内容无法解析。',
  ProviderTestStatus.provider => '模型服务拒绝了测试请求。',
};
