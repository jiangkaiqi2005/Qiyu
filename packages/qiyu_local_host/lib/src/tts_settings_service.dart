import 'dart:convert';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_settings_service.dart'
    show ProviderTestStatus, providerTestMessage, providerTestStatusFromFailureKind;
import 'qwen_tts_gateway.dart'
    show qwenTtsUsesMaasShape, qwenTtsUsesWsInference;
import 'tts_gateway.dart';
import 'voice_tier_mapping.dart';
import 'voice_tier_registry.dart';

/// 语音合成设置快照：经 HTTP 返回时绝不携带明文 Key。档位元数据随快照
/// 下推（票 08，`tiers` 字段）：设置页按数据渲染档位知识，归口行集只有
/// 能力/形状/端点缺省/文案，绝无密钥。
final class TtsSettingsSnapshot {
  const TtsSettingsSnapshot({required this.config, required this.keySet});

  final TtsConfig? config;

  final bool keySet;

  bool get configured => config != null;

  Map<String, Object?> toJson() => {
    'configured': configured,
    'keySet': keySet,
    if (config case final value?) ...value.toJson(),
    'tiers': voiceTierMetadataRows(family: VoiceServiceFamily.synthesis),
  };
}

/// 语音朗读服务层错误：路由据此回允许列表诊断码，不透出服务商原文。
final class TtsServiceException implements Exception {
  const TtsServiceException({
    required this.code,
    required this.message,
    required this.retryable,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

/// TTS 连接测试结果：与聊天/STT 的测试同口径（ok/status/message），
/// 成功时附带真实合成的试听音频（base64；PCM 档已由网关包 WAV 头），
/// 设置页直接播放。命中档位映射表（ADR 0020）时 [tierSuggestion] 带结
/// 构化建议：此时从未出网（不发计费请求），设置页当场给引导卡片。
final class TtsTestResult {
  const TtsTestResult({
    required this.status,
    required this.message,
    this.audioBase64,
    this.tierSuggestion,
  });

  final ProviderTestStatus status;
  final String message;

  /// 试听音频（内置示例句用表单协议、音色与语速真实合成）；失败时
  /// 恒为 null。
  final String? audioBase64;

  /// 档位映射表的结构化建议（应换档／不支持）；表 miss 或测试成功时
  /// 为 null。
  final VoiceTierSuggestion? tierSuggestion;

  bool get succeeded => status == ProviderTestStatus.success;

  Map<String, Object?> toJson() => {
    'ok': succeeded,
    'status': status.name,
    'message': message,
    'audioBase64': ?audioBase64,
    'suggestion': ?tierSuggestion?.toJson(),
  };
}

/// 语音朗读（TTS）设置与调用服务：与 SttSettingsService 同构，Key 只
/// 存 provider.json 的 tts 段。整段合成（设置试听、历史重听、连接测试）
/// 沿用 ADR 0002 语义；分句流式合成（票二，ADR 0018）由
/// [VoiceStreamSynthesizer] 接缝暴露给 Host 行为层的分句层，连续供给
/// 会话（票三，ADR 0019）由 [VoiceStreamSessionOpener] 暴露——配置加载、
/// Key 归一与文本校验与整段路径同源。
final class TtsSettingsService
    implements VoiceStreamSynthesizer, VoiceStreamSessionOpener {
  const TtsSettingsService(this.configRepository, this.ttsGateway);

  final TtsConfigRepository configRepository;
  final TtsSynthesisGateway ttsGateway;

  Future<TtsSettingsSnapshot> read() async {
    final config = await configRepository.loadTts();
    final key = config?.apiKey;
    return TtsSettingsSnapshot(
      config: config,
      keySet: key != null && key.trim().isNotEmpty,
    );
  }

  /// 与聊天/STT Key 同律但作用域独立：传入新 Key 就写入；没传时同
  /// 地址保留已存 Key，换地址（或换协议）则清空——旧服务商的 Key 不
  /// 沿用给新服务商。现值读取与 Key 沿用决定进共享事务：并发保存或
  /// 遗忘交错时，锁外旧 Key 不得复活。自定义档旋钮（authHeader/
  /// responseShape/responseField）随保存落盘，只在 custom 档生效。
  Future<TtsSettingsSnapshot> save({
    required String baseUrl,
    required String model,
    TtsProviderKind provider = TtsProviderKind.openAiCompatible,
    String? apiKey,
    String? voice,
    double? speed,
    bool? autoSpeak,
    String? authHeader,
    TtsResponseShape? responseShape,
    String? responseField,
    Map<String, Object?>? extraParams,
    TtsTransport? transport,
  }) async {
    await configRepository.runTransaction(() async {
      final previous = await configRepository.loadTts();
      final config = TtsConfig(
        provider: provider,
        baseUrl: baseUrl,
        model: model,
        voice: ProviderConfig.normalizeKey(voice),
        speed: speed,
        autoSpeak: autoSpeak ?? previous?.autoSpeak ?? true,
        authHeader: authHeader,
        responseShape: responseShape ?? TtsResponseShape.rawBytes,
        // 空白字段名归一为缺省 data：落盘的值恒有含义，回显也稳定。
        responseField: _normalizeResponseField(responseField),
        extraParams: extraParams,
        // 传输方式只归豆包档：切到别的档恒回落缺省 HTTP 分块（配置不
        // 落盘、网关不分派），切回豆包档没显式选时沿用已存值。
        transport:
            provider == TtsProviderKind.volcTts
            ? (transport ?? previous?.transport ?? TtsTransport.httpChunk)
            : TtsTransport.httpChunk,
      );
      config.validate();
      final normalizedKey = _normalizeApiKey(apiKey);
      String? persistedKey;
      if (normalizedKey != null) {
        persistedKey = normalizedKey;
      } else if (previous != null &&
          previous.credentialScope == config.credentialScope) {
        persistedKey = _normalizeApiKey(previous.apiKey);
      }
      // Key 作用域没变时，音色/语速/开关沿用已存值之外的字段更新。
      await configRepository.saveTts(config.withApiKey(persistedKey));
    });
    return read();
  }

  /// 聊天页朗读开关：只改 autoSpeak 位，不动协议、地址、音色与 Key。
  /// 读改写进共享事务，避免并发保存或遗忘把整段旧配置写回。
  Future<TtsSettingsSnapshot> setAutoSpeak(bool enabled) async {
    await configRepository.runTransaction(() async {
      final config = await configRepository.loadTts();
      if (config == null) {
        throw const TtsServiceException(
          code: 'tts_not_configured',
          message: '还没有配置语音合成服务，请先在设置页填写。',
          retryable: false,
        );
      }
      await configRepository.saveTts(
        TtsConfig(
          provider: config.provider,
          baseUrl: config.baseUrl,
          model: config.model,
          apiKey: config.apiKey,
          voice: config.voice,
          speed: config.speed,
          autoSpeak: enabled,
          authHeader: config.authHeader,
          responseShape: config.responseShape,
          responseField: config.responseField,
          extraParams: config.extraParams,
          transport: config.transport,
        ),
      );
    });
    return read();
  }

  Future<TtsSettingsSnapshot> forgetApiKey() async {
    await configRepository.runTransaction(() async {
      final config = await configRepository.loadTts();
      if (config != null) {
        await configRepository.saveTts(config.withApiKey(null));
      }
    });
    return read();
  }

  /// 连接测试 = 真实试听：用表单配置把内置示例句真实合成为音频，
  /// 成功即连接成功并返回音频；错误按与聊天/STT 测试相同的分类枚举
  /// 上报。表单未填 baseUrl/model 时按已保存配置测试。自定义档旋钮随
  /// 表单走：整份表单为空（测已存配置）时回落到已存值，表单填了就以
  /// 表单为准（与转写自定义档同律）。传输方式（票三）同样随表单走——
  /// 选了 WebSocket 双向就实测 WS 路径，不拿 HTTP 假绿。
  Future<TtsTestResult> test({
    String? baseUrl,
    String? model,
    TtsProviderKind? provider,
    String? apiKey,
    String? voice,
    double? speed,
    String? authHeader,
    TtsResponseShape? responseShape,
    String? responseField,
    Map<String, Object?>? extraParams,
    TtsTransport? transport,
  }) async {
    final stored = await configRepository.loadTts();
    final useStoredOptionalSettings = baseUrl == null && model == null;
    final effectiveBaseUrl = baseUrl == null || baseUrl.trim().isEmpty
        ? stored?.baseUrl
        : baseUrl.trim();
    final effectiveModel = model == null || model.trim().isEmpty
        ? stored?.model
        : model.trim();
    if (effectiveBaseUrl == null || effectiveModel == null) {
      return const TtsTestResult(
        status: ProviderTestStatus.notConfigured,
        message: '还没有保存语音合成服务配置。',
      );
    }
    final effectiveProvider =
        provider ?? stored?.provider ?? TtsProviderKind.openAiCompatible;
    final addressShapes = _effectiveAddressShapes(
      provider: effectiveProvider,
      baseUrl: effectiveBaseUrl,
    );
    // 档位映射表（ADR 0020）发请求前查询：命中「应换档／不支持」直接
    // 返回结构化建议，不发计费请求、网关零调用；表 miss 一切照旧。新版
    // 语音通道型号（3.x）配 maas 地址或 wss 推理地址（票 07）才算正确
    // 落位；配现行地址则引导换通道——建议带可代填的官方推理地址，maas
    // 模板与拼接指引为备选信息（业务空间 ID 只有用户知道）。表 miss 时的
    // 分类、错误码与 ADR 0015 文案逐字不变。
    final suggestion = lookupVoiceTierSuggestion(
      family: VoiceServiceFamily.synthesis,
      currentProviderWireName: effectiveProvider.wireName,
      model: effectiveModel,
      currentAddressUsesMaasShape: addressShapes.maasShape,
      currentAddressUsesWsInference: addressShapes.wsInference,
    );
    if (suggestion != null) {
      return TtsTestResult(
        // 复用「模型与接口不匹配」分类：表命中就是它在出网前的判型，
        // 不新增状态种类（spec 决策 7）。
        status: ProviderTestStatus.modelInterfaceMismatch,
        message: suggestion.reason,
        tierSuggestion: suggestion,
      );
    }
    final config = TtsConfig(
      provider: effectiveProvider,
      baseUrl: effectiveBaseUrl,
      model: effectiveModel,
      voice: useStoredOptionalSettings
          ? ProviderConfig.normalizeKey(voice) ?? stored?.voice
          : ProviderConfig.normalizeKey(voice),
      speed: useStoredOptionalSettings ? speed ?? stored?.speed : speed,
      authHeader: useStoredOptionalSettings
          ? authHeader ?? stored?.authHeader
          : authHeader,
      responseShape:
          (useStoredOptionalSettings
              ? responseShape ?? stored?.responseShape
              : responseShape) ??
          TtsResponseShape.rawBytes,
      responseField: _normalizeResponseField(
        useStoredOptionalSettings
            ? responseField ?? stored?.responseField
            : responseField,
      ),
      extraParams: useStoredOptionalSettings
          ? extraParams ?? stored?.extraParams
          : extraParams,
      // 传输方式只有豆包档消费（WS 双向的整段路径与连接测试按它分派），
      // 其余档恒缺省。
      transport:
          (useStoredOptionalSettings
              ? transport ?? stored?.transport
              : transport) ??
          TtsTransport.httpChunk,
    );
    try {
      config.validate();
    } on ProviderConfigException catch (error) {
      return TtsTestResult(
        status: ProviderTestStatus.contentParsing,
        message: error.message,
      );
    }
    final String? effectiveKey;
    try {
      final normalizedKey = _normalizeApiKey(apiKey);
      effectiveKey =
          normalizedKey ??
          (stored != null && stored.credentialScope == config.credentialScope
              ? _normalizeApiKey(stored.apiKey)
              : null);
    } on ProviderConfigException {
      return const TtsTestResult(
        status: ProviderTestStatus.contentParsing,
        message: _dirtyApiKeyMessage,
      );
    }
    // 网关异常只按 kind 映射固定文案（message 被丢弃）；Key 脏字符已
    // 由 _normalizeApiKey 在出网前统一拦截。
    try {
      final audio = await ttsGateway.synthesize(
        config: config,
        apiKey: effectiveKey,
        text: ttsConnectionTestSentence,
      );
      return TtsTestResult(
        status: ProviderTestStatus.success,
        message: '连接成功，点「听试听」可以听听栖语的声音。',
        audioBase64: base64Encode(audio),
      );
    } on TtsGatewayException catch (error) {
      final status = _ttsFailureDetails(error.kind).status;
      return TtsTestResult(status: status, message: _ttsTestMessage(status));
    } on Object {
      return const TtsTestResult(
        status: ProviderTestStatus.provider,
        message: '语音合成服务拒绝了测试请求。',
      );
    }
  }

  /// 正式合成（朗读与重听共用）：[text] 必须来自已完整交付并落盘的
  /// 栖语 turn（ADR 0002），空文本与超长文本直接拒绝，不出网。
  Future<List<int>> synthesize(String text) async {
    final config = await configRepository.loadTts();
    if (config == null) {
      throw const TtsServiceException(
        code: 'tts_not_configured',
        message: '还没有配置语音合成服务，请先在设置页填写。',
        retryable: false,
      );
    }
    final String? apiKey;
    try {
      apiKey = _normalizeApiKey(config.apiKey);
    } on ProviderConfigException {
      throw const TtsServiceException(
        code: 'tts_config_invalid',
        message: _dirtyApiKeyMessage,
        retryable: false,
      );
    }
    if (text.trim().isEmpty) {
      throw const TtsServiceException(
        code: 'tts_empty_text',
        message: '这段话没有可以朗读的内容。',
        retryable: false,
      );
    }
    if (text.length > ttsMaxTextLength) {
      throw const TtsServiceException(
        code: 'tts_text_too_long',
        message: '这段话太长了，栖语读不完。',
        retryable: false,
      );
    }
    try {
      return await ttsGateway.synthesize(
        config: config,
        apiKey: apiKey,
        text: text,
      );
    } on ProviderConfigException catch (error) {
      // 防御性映射：生产链路手改 provider.json 的脏配置在 loadTts() 就
      // 被拦（路由以 invalid_provider_config 回 400），到不了这里。
      throw TtsServiceException(
        code: 'tts_config_invalid',
        message: error.message,
        retryable: false,
      );
    } on TtsGatewayException catch (error) {
      final failure = _ttsFailureDetails(error.kind);
      // 模型与接口不匹配显式带 client 类别，但错误码要可区分：前置
      // 分支排除该种类，落 tts_model_interface_mismatch。该分类落定后
      // 查档位映射表（票 05），命中把 ADR 0015 通用文案升级为精确到档
      // 建议（与连接测试引导同源同句）；表 miss 与其他失败类别沿用既有
      // 文案逐字不变。
      final formalAddressShapes = _effectiveAddressShapes(
        provider: config.provider,
        baseUrl: config.baseUrl,
      );
      throw TtsServiceException(
        code: error.serviceError == ServiceErrorCategory.client &&
                error.kind != ModelFailureKind.modelInterfaceMismatch
            ? 'tts_client'
            : failure.code,
        message: error.kind == ModelFailureKind.modelInterfaceMismatch
            ? lookupVoiceTierFormalMessage(
                  family: VoiceServiceFamily.synthesis,
                  currentProviderWireName: config.provider.wireName,
                  model: config.model,
                  currentAddressUsesMaasShape: formalAddressShapes.maasShape,
                  currentAddressUsesWsInference: formalAddressShapes.wsInference,
                ) ??
                _ttsTestMessage(failure.status)
            : _ttsTestMessage(failure.status),
        retryable: true,
      );
    }
  }

  /// 分句层能否启动（票二）。两个否决都是「不启动」而不是「失败」：
  /// 未配置与自动朗读关闭时文字链路照常，整段朗读路径的既有降级不变。
  /// 档位拿不到音频块不算否决——按 E1 句子级降级照常跑（每句独立整段
  /// 合成、按序播放），现有配置全部保留、不淘汰在用型号。
  @override
  Future<bool> canStream() async {
    final config = await configRepository.loadTts();
    if (config == null || !config.autoSpeak) {
      return false;
    }
    return true;
  }

  /// 分句流式合成（票二）：一句完整文字 → 音频块流。配置、Key 与文本
  /// 校验口径与 [synthesize] 逐条一致；网关异常原样上抛，由分句层按
  /// D1 降级（一句失败即本段语音结束，已播句子 standing）。
  @override
  Stream<VoiceAudioChunk> synthesizeStream(String text) async* {
    final config = await configRepository.loadTts();
    if (config == null) {
      throw const TtsServiceException(
        code: 'tts_not_configured',
        message: '还没有配置语音合成服务，请先在设置页填写。',
        retryable: false,
      );
    }
    final String? apiKey;
    try {
      apiKey = _normalizeApiKey(config.apiKey);
    } on ProviderConfigException {
      throw const TtsServiceException(
        code: 'tts_config_invalid',
        message: _dirtyApiKeyMessage,
        retryable: false,
      );
    }
    if (text.trim().isEmpty) {
      throw const TtsServiceException(
        code: 'tts_empty_text',
        message: '这段话没有可以朗读的内容。',
        retryable: false,
      );
    }
    if (text.length > ttsMaxTextLength) {
      throw const TtsServiceException(
        code: 'tts_text_too_long',
        message: '这句话太长了，栖语读不完。',
        retryable: false,
      );
    }
    // 防御性：装配的网关不支持流式（组合根只会装配支持的一份）。类型
    // 匹配直接绑定强类型变量，不依赖跨接口的类型提升。
    if (ttsGateway case final TtsStreamSynthesisGateway gateway) {
      yield* gateway.synthesizeStream(
        config: config,
        apiKey: apiKey,
        text: text,
      );
    } else {
      throw const TtsServiceException(
        code: 'tts_stream_unavailable',
        message: '这个语音合成服务不支持流式朗读。',
        retryable: false,
      );
    }
  }

  /// 连续供给会话（票三）：按配置的协议/传输/型号决定开不开 WS 会话
  /// ——豆包档 transport=ws_bidirection（且生效音频参数可流式 PCM）或
  /// 千问档 -realtime 型号开会话，其余组合返回 null（分句层回落票二的
  /// 分句模式，一个字节的网络请求都不发）。建连/握手失败的异常原样上抛，
  /// 由调用方在会话挂载时按 D1 同口径处理（failedSession 形态 + 一次
  /// voiceError，文字链路完全不受影响，见 ADR 0019 裁定 A）。[sessionId]
  /// 是聊天会话标识：多轮合成上下文（豆包 section_id）按它保持。
  @override
  Future<VoiceStreamSession?> openSession({required String sessionId}) async {
    final config = await configRepository.loadTts();
    if (config == null) {
      return null;
    }
    final String? apiKey;
    try {
      apiKey = _normalizeApiKey(config.apiKey);
    } on ProviderConfigException {
      throw const TtsServiceException(
        code: 'tts_config_invalid',
        message: _dirtyApiKeyMessage,
        retryable: false,
      );
    }
    if (ttsGateway case final VoiceStreamSessionGateway gateway) {
      return gateway.openSession(
        config: config,
        apiKey: apiKey,
        sessionId: sessionId,
      );
    }
    return null;
  }
}

/// 单次合成的文字上限：栖语「默认少说」，正常回复远短于此；超限
/// 直接拒绝，防把整段历史当朗读文本。
const ttsMaxTextLength = 4000;

/// 连接测试（试听）的内置示例句：有栖语味的一句话。
const ttsConnectionTestSentence = '你好，我是栖语。今晚也想陪你慢慢说话。';

const _dirtyApiKeyMessage = 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。';

/// 自定义档字段名归一：去空白、空值回落缺省 data。保存与连接测试共用
/// 同一口径，落盘与出网的值恒有含义。与转写侧的 _normalizeResponseField
/// 同律（缺省值各按各段：转写取 text，合成取 data）。
String _normalizeResponseField(String? responseField) {
  final trimmed = responseField?.trim();
  return trimmed == null || trimmed.isEmpty
      ? ttsCustomDefaultResponseField
      : trimmed;
}

String? _normalizeApiKey(String? value) {
  if (value == null) {
    return null;
  }
  if (value.isNotEmpty && containsNonVisibleAscii(value)) {
    throw const ProviderConfigException(_dirtyApiKeyMessage);
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 连接测试表单地址的形状判定（ADR 0020 地址派形状＋票 07 第三形状）：
/// 只在千问朗读档有意义；表查询在配置校验之前跑，地址可能是任意草稿，
/// 解析不出或不是千问朗读档一律按现行形状对待。
({bool maasShape, bool wsInference}) _effectiveAddressShapes({
  required TtsProviderKind provider,
  required String baseUrl,
}) {
  if (provider != TtsProviderKind.qwenTts) {
    return (maasShape: false, wsInference: false);
  }
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null) {
    return (maasShape: false, wsInference: false);
  }
  return (
    maasShape: qwenTtsUsesMaasShape(uri),
    wsInference: qwenTtsUsesWsInference(baseUrl),
  );
}

({String code, ProviderTestStatus status}) _ttsFailureDetails(
  ModelFailureKind kind,
) => (code: _ttsFailureCode(kind), status: providerTestStatusFromFailureKind(kind));

String _ttsFailureCode(ModelFailureKind kind) => switch (kind) {
  ModelFailureKind.dns => 'tts_dns',
  ModelFailureKind.tls => 'tts_tls',
  ModelFailureKind.timeout => 'tts_timeout',
  ModelFailureKind.authentication => 'tts_authentication',
  ModelFailureKind.network => 'tts_network',
  ModelFailureKind.modelNotFound => 'tts_model_not_found',
  ModelFailureKind.modelInterfaceMismatch => 'tts_model_interface_mismatch',
  ModelFailureKind.rateLimited => 'tts_rate_limited',
  ModelFailureKind.incompatibleResponse => 'tts_incompatible_response',
  ModelFailureKind.contentParsing => 'tts_content_parsing',
  ModelFailureKind.provider => 'tts_provider',
  ModelFailureKind.internal => 'tts_internal',
};

String _ttsTestMessage(ProviderTestStatus status) => providerTestMessage(
  status,
  serviceLabel: '语音合成服务',
  successMessage: '连接成功，语音朗读可以使用。',
  notConfiguredMessage: '还没有保存语音合成服务配置。',
);
