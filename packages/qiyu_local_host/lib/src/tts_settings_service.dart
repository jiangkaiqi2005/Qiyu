import 'dart:convert';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_settings_service.dart'
    show ProviderTestStatus, providerTestMessage, providerTestStatusFromFailureKind;
import 'tts_gateway.dart';

/// 语音合成设置快照：经 HTTP 返回时绝不携带明文 Key。
final class TtsSettingsSnapshot {
  const TtsSettingsSnapshot({required this.config, required this.keySet});

  final TtsConfig? config;

  final bool keySet;

  bool get configured => config != null;

  Map<String, Object?> toJson() => {
    'configured': configured,
    'keySet': keySet,
    if (config case final value?) ...value.toJson(),
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
/// 成功时附带真实合成的试听音频（base64 mp3），设置页直接播放。
final class TtsTestResult {
  const TtsTestResult({
    required this.status,
    required this.message,
    this.audioBase64,
  });

  final ProviderTestStatus status;
  final String message;

  /// 试听音频（内置示例句用表单协议、音色与语速真实合成）；失败时
  /// 恒为 null。
  final String? audioBase64;

  bool get succeeded => status == ProviderTestStatus.success;

  Map<String, Object?> toJson() => {
    'ok': succeeded,
    'status': status.name,
    'message': message,
    'audioBase64': ?audioBase64,
  };
}

/// 语音朗读（TTS）设置与调用服务：与 SttSettingsService 同构，Key 只
/// 存 provider.json 的 tts 段。ADR 0002：只合成「已完整交付并落盘」的
/// 文字，本服务不做流式分句。
final class TtsSettingsService {
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
  /// 表单为准（与转写自定义档同律）。
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
      // 分支排除该种类，落 tts_model_interface_mismatch。
      throw TtsServiceException(
        code: error.serviceError == ServiceErrorCategory.client &&
                error.kind != ModelFailureKind.modelInterfaceMismatch
            ? 'tts_client'
            : failure.code,
        message: _ttsTestMessage(failure.status),
        retryable: true,
      );
    }
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
