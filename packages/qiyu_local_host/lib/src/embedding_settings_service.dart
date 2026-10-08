import 'provider_config.dart';
import 'provider_settings_service.dart'
    show ProviderTestResult, ProviderTestStatus, providerTestMessage,
    providerTestStatusFromFailureKind;
import 'embedding_gateway.dart';

/// 记忆召回（Episode RAG）embedding 服务设置快照：经 HTTP 返回时绝不
/// 携带明文 Key，只回 keySet 布尔（与聊天、语音、联网搜索设置同一套
/// 读回口径）。本票只交付保存／测试／忘记 Key：快照不含启用位，不伪
/// 装已就绪——真正启用、索引状态与召回由后续票接入。
final class EmbeddingSettingsSnapshot {
  const EmbeddingSettingsSnapshot({required this.config, required this.keySet});

  final EmbeddingConfig? config;
  final bool keySet;

  bool get configured => config != null;

  Map<String, Object?> toJson() => {
    'configured': configured,
    'keySet': keySet,
    if (config case final value?) ...value.toJson(),
  };
}

/// 记忆召回 embedding 设置与连接测试服务：与语音设置服务同构，但 Key
/// 只存 provider.json 的 embedding 段，绝不借用聊天或语音凭据；用户可
/// 以主动填写相同 Key，那也是一次显式输入。
final class EmbeddingSettingsService {
  const EmbeddingSettingsService(this.configRepository, this.embeddingClient);

  final EmbeddingConfigRepository configRepository;
  final EmbeddingClient embeddingClient;

  Future<EmbeddingSettingsSnapshot> read() async {
    final config = await configRepository.loadEmbedding();
    final key = config?.apiKey;
    return EmbeddingSettingsSnapshot(
      config: config,
      keySet: key != null && key.trim().isNotEmpty,
    );
  }

  /// 与聊天、语音 Key 同律但作用域独立：传入新 Key 就写入；没传时同
  /// 协议与规范化地址作用域保留已存 Key，换地址（作用域变化）则清空
  /// ——旧服务商的 Key 不沿用给新服务商。模型名不参与作用域：同一地
  /// 址换模型名留空 Key 时照常沿用（模型对索引身份的影响由后续票的
  /// 重建流程处理，与本票凭据事务无关）。现值读取与 Key 沿用决定进
  /// 共享事务：并发保存或遗忘交错时，锁外旧 Key 不得复活。
  Future<EmbeddingSettingsSnapshot> save({
    required String baseUrl,
    required String model,
    String? apiKey,
  }) async {
    final config = EmbeddingConfig(baseUrl: baseUrl, model: model);
    config.validate();
    await configRepository.runTransaction(() async {
      final previous = await configRepository.loadEmbedding();
      final persistedKey = _selectApiKey(config, previous, apiKey);
      // 保存不改启用位（Spec：保存配置与启用分开）：启用状态原样保留，
      // 由显式的启用/停用操作改写。
      await configRepository.saveEmbedding(
        config
            .withApiKey(persistedKey)
            .withEnabled(previous?.enabled ?? false),
      );
    });
    return read();
  }

  /// 忘记 Key：明确清除已存凭据，配置本身保留。
  Future<EmbeddingSettingsSnapshot> forgetApiKey() async {
    await configRepository.runTransaction(() async {
      final config = await configRepository.loadEmbedding();
      if (config != null) {
        await configRepository.saveEmbedding(config.withApiKey(null));
      }
    });
    return read();
  }

  /// 连接测试：只发送一条固定的非私人文本（Spec 用户故事 17），绝不
  /// 携带真实记忆或历史对话；embedding 响应经网关的有效向量校验（条
  /// 目数量、维度一致性、有限数值与零范数），不合法响应不可当作连接
  /// 成功。表单未填 baseUrl/model 时按已保存配置测试。Key 的取舍与保
  /// 存同口径：传入新 Key 优先；换地址且没填 Key 时不沿用旧服务商的
  /// Key，按未保存鉴权失败报告——旧 Key 不会被发送给新地址。
  Future<ProviderTestResult> test({
    String? baseUrl,
    String? model,
    String? apiKey,
  }) async {
    final stored = await configRepository.loadEmbedding();
    final effectiveBaseUrl =
        baseUrl == null || baseUrl.trim().isEmpty
        ? stored?.baseUrl
        : baseUrl.trim();
    final effectiveModel =
        model == null || model.trim().isEmpty
        ? stored?.model
        : model.trim();
    if (effectiveBaseUrl == null || effectiveModel == null) {
      return const ProviderTestResult(
        status: ProviderTestStatus.notConfigured,
        message: '还没有保存记忆召回服务配置。',
      );
    }
    final config = EmbeddingConfig(
      baseUrl: effectiveBaseUrl,
      model: effectiveModel,
    );
    try {
      config.validate();
    } on ProviderConfigException catch (error) {
      return ProviderTestResult(
        status: ProviderTestStatus.contentParsing,
        message: error.message,
      );
    }
    final effectiveKey = _selectApiKey(config, stored, apiKey);
    // 网关异常只按 kind 映射固定文案（message 被丢弃），Key 脏字符必须
    // 在这里提前拦截，人话文案才能到达用户（与语音连接测试同律）。
    if (effectiveKey != null && containsNonVisibleAscii(effectiveKey)) {
      return const ProviderTestResult(
        status: ProviderTestStatus.contentParsing,
        message: 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
      );
    }
    try {
      await embeddingClient.embed(
        config: config,
        apiKey: effectiveKey,
        inputs: [embeddingConnectionTestText],
      );
      return const ProviderTestResult(
        status: ProviderTestStatus.success,
        message: '连接成功，记忆召回服务可以使用。',
      );
    } on EmbeddingGatewayException catch (error) {
      final status = providerTestStatusFromFailureKind(error.kind);
      return ProviderTestResult(
        status: status,
        message: providerTestMessage(
          status,
          serviceLabel: '记忆召回服务',
          successMessage: '连接成功，记忆召回服务可以使用。',
          notConfiguredMessage: '还没有保存记忆召回服务配置。',
        ),
      );
    } on Object {
      return const ProviderTestResult(
        status: ProviderTestStatus.provider,
        message: '记忆召回服务拒绝了测试请求。',
      );
    }
  }

  static String? _selectApiKey(
    EmbeddingConfig config,
    EmbeddingConfig? stored,
    String? apiKey,
  ) => selectScopedApiKey(
    apiKeyInput: apiKey,
    storedKey: stored?.apiKey,
    sameCredentialScope:
        stored != null && stored.credentialScope == config.credentialScope,
  );
}

/// 连接测试的固定文本：非私人、与真实记忆无关，只用于验证服务可达且
/// 返回有效向量。内容是写死的常量，不读任何会话或记忆文件。
const embeddingConnectionTestText = '这是一条记忆召回服务的连接测试消息。';
