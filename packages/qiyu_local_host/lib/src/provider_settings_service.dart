import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'cleartext_policy.dart';
import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'provider_config.dart';
import 'qwen_omni_realtime_gateway.dart';
import 'secret_store.dart';
import 'voice_tier_mapping.dart';
import 'web_search.dart';

/// 后台整理调用的模型期限（秒）。Dream、日终理解与轮内召回都经
/// [ProviderSettingsService.complete] 出网：提示长、输出预算大，实测
/// 同配置下 Dream 近三分钟、日终理解亦可超过一分钟，而配置里的期限
/// 表达的是用户等待聊天回复的耐心（聊天链路照旧沿用），后台任务没有
/// 人等。取值与请求超时的允许上限一致——后台调用再慢也慢不过产品允许
/// 的最慢聊天配置；超时才按失败降级，未完成的整理由补跑机制在下次
/// 启动或空闲时继续。
const backgroundModelTimeoutSeconds = maxConfiguredTimeoutSeconds;

final class ProviderSettingsSnapshot {
  const ProviderSettingsSnapshot({required this.config, required this.keySet});

  final ProviderConfig? config;
  final bool keySet;

  bool get configured => config != null;

  Map<String, Object?> toJson() => {
    'configured': configured,
    'keySet': keySet,
    'callStartupMode':
        (config?.callStartupMode ?? CallStartupMode.manual).wireName,
    if (config case final value?) ...value.toJson(),
  };
}

/// 一次 Omni 实时连接的已解析凭据（T03 通话接线）：配置与 Key 成对
/// 解析、只在本机 Host 内流转，绝不进事件流、日志或诊断。字段完全同
/// 名拷贝自 provider.json / 凭据仓的现行值。
final class OmniRealtimeCredentials {
  const OmniRealtimeCredentials({required this.config, required this.apiKey});

  final ProviderConfig config;
  final String apiKey;

  /// Provider 切换判据：作用域、地址与型号任一变化都视为已切换
  /// （T03:16 切换必须停旧连接，不得沿用另一作用域的旧 Key）。
  bool matches(OmniRealtimeCredentials other) =>
      config.credentialScope == other.config.credentialScope &&
      config.baseUrl == other.config.baseUrl &&
      config.model == other.config.model;
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
  modelInterfaceMismatch,
  rateLimited,
  incompatibleResponse,
  contentParsing,
  provider,
  internal,
}

final class ProviderTestResult {
  const ProviderTestResult({
    required this.status,
    required this.message,
    this.tierSuggestion,
  });

  final ProviderTestStatus status;
  final String message;

  /// 档位映射表（ADR 0020）的结构化建议：只有语音设置域的连接测试在
  /// 出网前查表命中时置值（聊天域的测试从不查表，恒为 null，wire 形状
  /// 一字不变）。
  final VoiceTierSuggestion? tierSuggestion;

  bool get succeeded => status == ProviderTestStatus.success;

  Map<String, Object?> toJson() => {
    'ok': succeeded,
    'status': status.name,
    'message': message,
    'suggestion': ?tierSuggestion?.toJson(),
  };
}

final class ModelCompletion {
  const ModelCompletion.reply(String this.text)
    : failure = null, _serviceError = null;

  const ModelCompletion.failure(
    ModelFailureKind this.failure, {
    this._serviceError,
  }) : text = null;

  final String? text;
  final ModelFailureKind? failure;
  final ServiceErrorCategory? _serviceError;
  ServiceErrorCategory? get serviceError =>
      _serviceError ?? serviceErrorForModelFailure(failure);

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
    this.omniRealtimeGateway,
    this._behaviorCore = const QiyuBehaviorCore(),
  });

  final ProviderConfigRepository configRepository;
  final SecretStore secretStore;
  final ModelGateway modelGateway;
  final ModelPromptBuilder modelPromptBuilder;
  final WebSearchConfigRepository? webSearchConfigRepository;
  final WebSearchClient? webSearchClient;

  /// Omni 实时会话网关（qwen_omni_realtime 档）：选中 Omni 后的文字接线
  /// （记忆维护等）与连接测试经它出网。缺省 null＝未装配，选中 Omni 时
  /// 相关调用按内部错误如实失败，不悄悄换模型。
  final QwenOmniRealtimeGateway? omniRealtimeGateway;
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
    bool updateCallStartupMode = true,
  }) async {
    config.validate();
    _refusePublicCleartextTarget(config);
    // 读取现值、Key 去留决定、写回与旧凭据清理同处一个共享事务：
    // 并发保存或遗忘交错时，锁外读到的旧值与旧 Key 不得回灌。
    await configRepository.runTransaction(() async {
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
      // 旧客户端和只改其他设置的请求不携带启动方式；在同一事务中
      // 沿用现值，切换 Provider 也不会丢掉 Omni 的偏好。
      final mode = updateCallStartupMode
          ? config.callStartupMode
          : previous?.callStartupMode ?? CallStartupMode.manual;
      await configRepository.save(
        config.withCallStartupMode(mode).withApiKey(persistedKey),
      );
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
    });
    return read();
  }

  Future<ProviderSettingsSnapshot> forgetApiKey() async {
    // 遗忘同样经共享事务：写回的配置以事务内现值为准，不会把锁外读
    // 到的整份旧配置写回，覆盖并发保存的结果或复活已删的 Key。
    await configRepository.runTransaction(() async {
      final config = await configRepository.load();
      if (config != null) {
        await configRepository.save(config.withApiKey(null));
        // 一并清掉凭据管理器里的旧数据（升级前保存的 Key）。
        await _deleteStoredApiKeys(config);
      }
    });
    return read();
  }

  /// 凭据管理器按 scope 精确匹配：同一配置在旧版本下可能以旧格式
  /// scope（带「?#」尾巴）存过 Key，清理时新旧两个 scope 一并删除，
  /// 与既有「文件接管/换作用域即清理」语义对称。
  Future<void> _deleteStoredApiKeys(ProviderConfig config) async {
    await secretStore.deleteApiKey(config.credentialScope);
    await secretStore.deleteApiKey(config.legacyCredentialScope);
  }

  /// 明文 HTTP 允许列表的保存口（ticket 08）：公网网段的 http 地址
  /// 直接拒绝保存，给出人话（允许列表矩阵见 cleartext_policy）。
  void _refusePublicCleartextTarget(ProviderConfig config) {
    final refusal = _chatCleartextRefusal(config);
    if (refusal != null) {
      throw ProviderConfigException(refusal);
    }
  }

  /// 出网目标地址的明文拒绝原因：端点路径只由网关拼接，scheme 与
  /// 主机在 base 地址上判定即可。Omni 实时档走 WebSocket 出网，明文
  /// HTTP 允许列表不适用——出网校验由实时网关的 SSRF 检查承担（ws/wss
  /// 限公网目标，见 qwen_omni_realtime_gateway）。
  static String? _chatCleartextRefusal(ProviderConfig config) {
    if (config.kind == ProviderKind.qwenOmniRealtime) {
      return null;
    }
    final uri = Uri.tryParse(config.baseUrl.trim());
    if (uri == null || !uri.hasAuthority) {
      return null;
    }
    return chatCleartextRefusalReason(uri);
  }

  Future<ProviderTestResult> test({
    required ProviderConfig config,
    String? apiKey,
  }) async {
    config.validate();
    // 明文公网目标在出网前拒绝并给出具体原因（网关侧同律兜底，这里
    // 提前拦截是为了让测试结果携带完整文案而非笼统的 network 状态）。
    final refusal = _chatCleartextRefusal(config);
    if (refusal != null) {
      return ProviderTestResult(
        status: ProviderTestStatus.network,
        message: refusal,
      );
    }
    final state = StateSnapshot.initial('provider-connection-test');
    const request = ChatRequest(
      requestId: 'provider-connection-test',
      text: '在吗',
    );
    try {
      final messages = modelPromptBuilder.build(state, request.text);
      final resolvedKey =
          apiKey ??
          await _resolveApiKey(config, await configRepository.load());
      final candidate = switch (config.kind) {
        ProviderKind.qwenOmniRealtime => await _completeViaOmniRealtime(
          config: config,
          apiKey: resolvedKey,
          messages: messages,
        ),
        _ => await modelGateway.complete(
          config: config,
          apiKey: resolvedKey,
          messages: messages,
        ),
      };
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
      final status = providerTestStatusFromFailureKind(error.kind);
      return ProviderTestResult(
        status: status,
        message: providerTestMessage(
          status,
          serviceLabel: '模型服务',
          successMessage: '连接成功，栖语可以使用这个模型。',
          notConfiguredMessage: '还没有保存模型配置。',
        ),
      );
    } on Object {
      return const ProviderTestResult(
        status: ProviderTestStatus.provider,
        message: '模型服务拒绝了测试请求。',
      );
    }
  }

  /// 通话接线（T03）：解析当前选中 Omni 实时档的连接凭据。未配置、
  /// 选中的不是 Omni 实时档或 Key 缺失都返回 null（调用方按可理解
  /// 原因结束/拒绝），不抛凭据、不降级到别的模型。
  Future<OmniRealtimeCredentials?> resolveRealtimeCredentials() async {
    final config = await configRepository.load();
    if (config == null || config.kind != ProviderKind.qwenOmniRealtime) {
      return null;
    }
    final apiKey = await _resolveApiKey(config);
    if (apiKey == null || apiKey.isEmpty) {
      return null;
    }
    return OmniRealtimeCredentials(config: config, apiKey: apiKey);
  }

  /// Omni 实时档的文字调用：经实时网关跑纯文字会话轮（T01 §10 已核实
  /// 形状，选中 Omni 后不悄悄沿用旧聊天模型）。网关未装配按内部错误
  /// 如实失败。
  Future<String> _completeViaOmniRealtime({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
  }) async {
    final gateway = omniRealtimeGateway;
    if (gateway == null) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.internal,
        message: '本机程序内部出错。',
      );
    }
    return gateway.completeText(
      config: config,
      apiKey: apiKey,
      messages: messages,
    );
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
      // 后台整理调用按后台期限出网：聊天期限是用户等回复的耐心上限，
      // 而 Dream 与日终理解没人等，链路只在超时后降级并留待补跑。实时
      // 协议侧没有 maxTokens 的已核实字段，输出预算不随传。
      final backgroundConfig = config.withTimeoutSeconds(
        backgroundModelTimeoutSeconds,
      );
      final text = switch (config.kind) {
        ProviderKind.qwenOmniRealtime => await _completeViaOmniRealtime(
          config: backgroundConfig,
          apiKey: await _resolveApiKey(config),
          messages: messages,
        ),
        _ => await modelGateway.complete(
          config: backgroundConfig,
          apiKey: await _resolveApiKey(config),
          messages: messages,
          maxTokens: maxTokens,
        ),
      };
      return ModelCompletion.reply(text);
    } on ModelGatewayException catch (error) {
      return ModelCompletion.failure(error.kind, serviceError: error.serviceError);
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
    // Omni 实时档不走 Chat Completions（spec:17）：通话外打字的实时
    // 接线（T03）以一次纯文字实时轮（T01 §10 已核实 response.text 形状）
    // 充当流式源——整段回复作为单个 delta 交给主链流式状态机，清洗、
    // 校验、隐藏块解析与落盘沿用聊天同一条管线，不另起一套。
    if (config.kind == ProviderKind.qwenOmniRealtime) {
      final apiKey = await _resolveApiKey(config);
      return PreparedProviderChatRequest(
        hardRulesAddendum: '',
        openStream: (messages, whenCancelled) async =>
            _openOmniTextStream(config, apiKey, messages),
      );
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

  /// 通话外打字的实时文字流（T03）：一次 [QwenOmniRealtimeGateway.completeText]
  /// 纯文字轮（T01 §10 已核实 response.text 形状）充当流式源。实时协议
  /// 侧没有已核实的逐 token 增量，整段回复作为单个 delta 交给主链流式
  /// 状态机，清洗、校验、隐藏块解析与落盘沿用聊天同一条管线。取消不
  /// 中断在途轮（单轮有界，会话在轮末必关），失败按失败事件如实降级
  /// 本地兜底；网关未装配同样如实失败，不悄悄换模型。
  Future<Stream<ModelStreamEvent>?> _openOmniTextStream(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
  ) async {
    final gateway = omniRealtimeGateway;
    if (gateway == null) {
      return Stream<ModelStreamEvent>.fromIterable([
        const ModelStreamEvent.failure(
          ModelFailureKind.internal,
          '本机程序内部出错。',
        ),
      ]);
    }
    try {
      final reply = await gateway.completeText(
        config: config,
        apiKey: apiKey,
        messages: messages,
      );
      return Stream<ModelStreamEvent>.fromIterable([
        ModelStreamEvent.delta(reply),
        const ModelStreamEvent.done(),
      ]);
    } on ModelGatewayException catch (error) {
      return Stream<ModelStreamEvent>.fromIterable([
        ModelStreamEvent.failure(error.kind, error.message),
      ]);
    } on Object {
      return Stream<ModelStreamEvent>.fromIterable([
        const ModelStreamEvent.failure(
          ModelFailureKind.internal,
          '本机程序内部出错。',
        ),
      ]);
    }
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
      yield ModelStreamEvent.failure(
        error.kind, error.message, serviceError: error.serviceError,
      );
    } on Object {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.internal,
        '本机程序内部出错。',
      );
    }
  }
}

/// 网关失败种类到连接测试状态的映射：聊天与语音输入、语音合成的
/// 连接测试共用同一套 12 分支。
ProviderTestStatus providerTestStatusFromFailureKind(ModelFailureKind kind) =>
    switch (kind) {
      ModelFailureKind.dns => ProviderTestStatus.dns,
      ModelFailureKind.tls => ProviderTestStatus.tls,
      ModelFailureKind.timeout => ProviderTestStatus.timeout,
      ModelFailureKind.authentication => ProviderTestStatus.authentication,
      ModelFailureKind.network => ProviderTestStatus.network,
      ModelFailureKind.modelNotFound => ProviderTestStatus.modelNotFound,
      ModelFailureKind.modelInterfaceMismatch =>
        ProviderTestStatus.modelInterfaceMismatch,
      ModelFailureKind.rateLimited => ProviderTestStatus.rateLimited,
      ModelFailureKind.incompatibleResponse =>
        ProviderTestStatus.incompatibleResponse,
      ModelFailureKind.contentParsing => ProviderTestStatus.contentParsing,
      ModelFailureKind.provider => ProviderTestStatus.provider,
      ModelFailureKind.internal => ProviderTestStatus.internal,
    };

/// 三处连接测试（聊天/语音输入/语音合成）共享的状态文案表：除成功
/// 与未配置两条各说各话外，其余 11 条只差服务标签（模型服务/语音
/// 服务/语音合成服务），按标签逐字拼装；模型与接口不匹配一条直说模型
/// 与服务地址的配合关系，不带服务标签。
String providerTestMessage(
  ProviderTestStatus status, {
  required String serviceLabel,
  required String successMessage,
  required String notConfiguredMessage,
}) => switch (status) {
  ProviderTestStatus.success => successMessage,
  ProviderTestStatus.notConfigured => notConfiguredMessage,
  ProviderTestStatus.dns => '找不到$serviceLabel域名，请检查地址或 DNS。',
  ProviderTestStatus.tls => '$serviceLabel的 TLS 安全连接失败。',
  ProviderTestStatus.timeout => '连接$serviceLabel超时。',
  ProviderTestStatus.authentication => 'API Key 没有通过验证。',
  ProviderTestStatus.network => '无法连接$serviceLabel，请检查地址和网络。',
  ProviderTestStatus.modelNotFound => '找不到这个模型，请检查模型名称。',
  ProviderTestStatus.modelInterfaceMismatch =>
    modelInterfaceMismatchMessage,
  ProviderTestStatus.rateLimited => '$serviceLabel请求过于频繁，请稍后再试。',
  ProviderTestStatus.incompatibleResponse =>
    '$serviceLabel返回了不兼容的响应格式。',
  ProviderTestStatus.contentParsing => '$serviceLabel返回的内容无法解析。',
  ProviderTestStatus.provider => '$serviceLabel拒绝了测试请求。',
  ProviderTestStatus.internal => '本机程序内部出错，请重试或重启栖语。',
};
