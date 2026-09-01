import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'provider_config.dart';
import 'secret_store.dart';
import 'web_search.dart';

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
  internal,
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
  /// [maxTokens] 缺省沿用聊天回复护栏；理解类调用要输出长结构 JSON，
  /// 必须显式给足预算，否则输出截断后无法解析。
  Future<ModelCompletion?> complete(
    List<ModelMessage> messages, {
    int? maxTokens,
  });
}

/// 聊天主链的 Provider 统一端口：一次 prepare 完成能力快照。该
/// Provider 支持普通、流式、可取消与 Web Search 中的哪些由网关内部
/// 判定并打包进快照，主链只拿快照对象，不感知 Provider kind、可取消
/// 性或 web-search 能力标记。未配置 Provider 时返回 null。
abstract interface class ProviderChatPort {
  Future<PreparedProviderChatRequest?> prepareChatRequest();
}

/// 单次主聊天的 Provider 能力快照：prepare 一次锁定提示词追加条文与
/// 打开流的方式，open 一次完成流式交付——协议适配（OpenAI SSE、
/// Anthropic SSE、Ollama NDJSON）、终止判定、错误分类与取消下传全部
/// 留在快照与网关内部，主链只消费事件流。
final class PreparedProviderChatRequest {
  const PreparedProviderChatRequest({
    required this.hardRulesAddendum,
    required this._openStream,
  });

  /// prepare 按能力判定打包的硬规则追加条文（如 Web Search 激活时
  /// 的检索纪律）；主链原样注入提示词，不解释内容，无追加时为空串。
  final String hardRulesAddendum;

  /// 打开流的原始句柄。字段刻意走私有具名参数：调用方构造时仍写
  /// `openStream:` 标签（Dart 对私有具名参数剥掉下划线），而句柄
  /// 本身不暴露在快照上——打开流只经 [openStream] 这一个公开入口。
  final Future<Stream<ModelStreamEvent>?> Function(
    List<ModelMessage> messages,
    Future<void>? whenCancelled,
  )
  _openStream;

  Future<Stream<ModelStreamEvent>?> openStream(
    List<ModelMessage> messages, {
    Future<void>? whenCancelled,
  }) => _openStream(messages, whenCancelled);
}

final class ProviderSettingsService
    implements ProviderChatClient, ProviderChatPort {
  const ProviderSettingsService(
    this.configRepository,
    this.secretStore,
    this.modelGateway,
    this.modelPromptBuilder, {
    this.webSearchConfigRepository,
    this.webSearchClient,
    this._behaviorCore = const QiyuBehaviorCore(),
  });

  final ProviderConfigRepository configRepository;
  final SecretStore secretStore;
  final ModelGateway modelGateway;
  final ModelPromptBuilder modelPromptBuilder;
  final WebSearchConfigRepository? webSearchConfigRepository;
  final WebSearchClient? webSearchClient;
  final QiyuBehaviorCore _behaviorCore;

  Future<ProviderSettingsSnapshot> read() async {
    final config = await configRepository.load();
    final key = config == null ? null : await _resolveApiKey(config);
    return ProviderSettingsSnapshot(
      config: config,
      keySet: key != null && key.isNotEmpty,
    );
  }

  /// Key 的解析顺序：provider.json 里用户直接保存/编辑的值优先，
  /// 文件没有时回退读 Windows 凭据管理器（升级前旧数据的迁移兼容）。
  /// [storedConfig] 缺省即 [config]；连接测试传入的是表单配置、从不
  /// 携带 Key，需另传落盘配置，文件 Key 只在作用域一致时采信。
  Future<String?> _resolveApiKey(
    ProviderConfig config, [
    ProviderConfig? storedConfig,
  ]) async {
    final stored = storedConfig ?? config;
    final fileKey = stored.credentialScope == config.credentialScope
        ? ProviderConfig.normalizeKey(stored.apiKey)
        : null;
    if (fileKey != null) {
      return fileKey;
    }
    final current = await secretStore.readApiKey(config.credentialScope);
    if (current != null && current.isNotEmpty) {
      return current;
    }
    // 现行 scope 未命中再按旧版 scope 字符串补读一次：旧安装的 Key
    // 存的是带「?#」尾巴的旧格式，命中即视为当前作用域的 Key。
    final legacy = await secretStore.readApiKey(config.legacyCredentialScope);
    return legacy != null && legacy.isNotEmpty ? legacy : null;
  }

  Future<ProviderSettingsSnapshot> save({
    required ProviderConfig config,
    String? apiKey,
  }) async {
    config.validate();
    final previous = await configRepository.load();
    final trimmed = apiKey?.trim();
    // 传入新 Key 就写入文件；没传时同作用域保留已存 Key，换作用域
    // 则清空——旧目标的 Key 绝不沿用给新目标。
    String? persistedKey;
    if (trimmed != null && trimmed.isNotEmpty) {
      persistedKey = trimmed;
    } else if (previous != null &&
        previous.credentialScope == config.credentialScope) {
      persistedKey = previous.apiKey;
    }
    await configRepository.save(config.withApiKey(persistedKey));
    // 切换 Provider 或地址会更换凭据作用域：旧作用域在凭据管理器里
    // 的遗留 Key 从此无人读取，保存成功后立即清掉（新旧两种 scope
    // 字符串一并清，见 [_deleteStoredApiKeys]）。
    if (previous != null &&
        previous.credentialScope != config.credentialScope) {
      await _deleteStoredApiKeys(previous);
    }
    // 文件一旦接管当前作用域的 Key，凭据管理器里的同作用域旧值即被
    // 取代：立即清掉，避免用户日后手改文件清空 Key 时回退复活陈旧
    // 凭据。纯旧安装（Key 只在凭据库、文件从未存过）不受影响。
    if (persistedKey != null) {
      await _deleteStoredApiKeys(config);
    }
    return read();
  }

  Future<ProviderSettingsSnapshot> forgetApiKey() async {
    final config = await configRepository.load();
    if (config != null) {
      await configRepository.save(config.withApiKey(null));
      // 一并清掉凭据管理器里的旧数据（升级前保存的 Key）。
      await _deleteStoredApiKeys(config);
    }
    return read();
  }

  /// 凭据管理器按 scope 精确匹配：同一配置在旧版本下可能以旧格式
  /// scope（带「?#」尾巴）存过 Key，清理时新旧两个 scope 一并删除，
  /// 与既有「文件接管/换作用域即清理」语义对称。
  Future<void> _deleteStoredApiKeys(ProviderConfig config) async {
    await secretStore.deleteApiKey(config.credentialScope);
    await secretStore.deleteApiKey(config.legacyCredentialScope);
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
        apiKey:
            apiKey ??
            await _resolveApiKey(config, await configRepository.load()),
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
        ModelFailureKind.internal => ProviderTestStatus.internal,
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
  Future<ModelCompletion?> complete(
    List<ModelMessage> messages, {
    int? maxTokens,
  }) async {
    final config = await configRepository.load();
    if (config == null) {
      return null;
    }
    try {
      final text = await modelGateway.complete(
        config: config,
        apiKey: await _resolveApiKey(config),
        messages: messages,
        maxTokens: maxTokens,
      );
      return ModelCompletion.reply(text);
    } on ModelGatewayException catch (error) {
      return ModelCompletion.failure(error.kind);
    } on Object {
      return const ModelCompletion.failure(ModelFailureKind.internal);
    }
  }

  @override
  Future<PreparedProviderChatRequest?> prepareChatRequest() async {
    final config = await configRepository.load();
    if (config == null) {
      return null;
    }
    final apiKey = await _resolveApiKey(config);
    // 能力判定只在网关侧进行：Web Search 需要 Anthropic 协议、
    // AnySearch 客户端与配置三者齐备；主链只看到打包后的追加条文，
    // 普通回退与流式路径的选择同样封在快照内部。
    final webSearchConfig =
        config.kind == ProviderKind.anthropic &&
            webSearchClient != null &&
            modelGateway is WebSearchStreamingModelGateway
        ? await webSearchConfigRepository?.loadWebSearch()
        : null;
    return PreparedProviderChatRequest(
      hardRulesAddendum: webSearchConfig == null
          ? ''
          : webSearchSystemInstruction,
      openStream: (messages, whenCancelled) => _openStreamWithSnapshot(
        config,
        apiKey,
        webSearchConfig,
        messages,
        whenCancelled: whenCancelled,
      ),
    );
  }

  Future<Stream<ModelStreamEvent>?> _openStreamWithSnapshot(
    ProviderConfig config,
    String? apiKey,
    WebSearchConfig? webSearchConfig,
    List<ModelMessage> messages, {
    Future<void>? whenCancelled,
  }) async {
    // webSearchConfig 只在 prepare 判定联网能力齐备时才非空，这里
    // 直接沿快照走对应路径，不再重复类型判断。
    if (webSearchConfig != null) {
      return (modelGateway as WebSearchStreamingModelGateway)
          .streamWithWebSearch(
            config: config,
            apiKey: apiKey,
            messages: messages,
            webSearchApiKey: webSearchConfig.apiKey,
            webSearchClient: webSearchClient!,
            whenCancelled: whenCancelled,
          );
    }
    if (modelGateway case final StreamingModelGateway streamingGateway) {
      return streamingGateway.stream(
        config: config,
        apiKey: apiKey,
        messages: messages,
      );
    }
    return _singleCompletionStream(config, apiKey, messages);
  }

  Stream<ModelStreamEvent> _singleCompletionStream(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
  ) async* {
    try {
      final text = await modelGateway.complete(
        config: config,
        apiKey: apiKey,
        messages: messages,
      );
      yield ModelStreamEvent.delta(text);
      yield const ModelStreamEvent.done();
    } on ModelGatewayException catch (error) {
      yield ModelStreamEvent.failure(error.kind, error.message);
    } on Object {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.internal,
        '本机程序内部出错。',
      );
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
  ProviderTestStatus.internal => '本机程序内部出错，请重试或重启栖语。',
};
