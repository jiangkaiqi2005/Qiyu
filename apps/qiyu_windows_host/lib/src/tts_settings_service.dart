import 'dart:convert';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_settings_service.dart' show ProviderTestStatus;
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
  /// 沿用给新服务商。
  Future<TtsSettingsSnapshot> save({
    required String baseUrl,
    required String model,
    TtsProviderKind provider = TtsProviderKind.openAiCompatible,
    String? apiKey,
    String? voice,
    double? speed,
    bool? autoSpeak,
  }) async {
    final previous = await configRepository.loadTts();
    final config = TtsConfig(
      provider: provider,
      baseUrl: baseUrl,
      model: model,
      voice: _normalizeOptional(voice),
      speed: speed,
      autoSpeak: autoSpeak ?? previous?.autoSpeak ?? true,
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
    return read();
  }

  /// 聊天页朗读开关：只改 autoSpeak 位，不动协议、地址、音色与 Key。
  Future<TtsSettingsSnapshot> setAutoSpeak(bool enabled) async {
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
      ),
    );
    return read();
  }

  Future<TtsSettingsSnapshot> forgetApiKey() async {
    final config = await configRepository.loadTts();
    if (config != null) {
      await configRepository.saveTts(config.withApiKey(null));
    }
    return read();
  }

  /// 连接测试 = 真实试听：用表单配置把内置示例句真实合成为音频，
  /// 成功即连接成功并返回音频；错误按与聊天/STT 测试相同的分类枚举
  /// 上报。表单未填 baseUrl/model 时按已保存配置测试。
  Future<TtsTestResult> test({
    String? baseUrl,
    String? model,
    TtsProviderKind? provider,
    String? apiKey,
    String? voice,
    double? speed,
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
          ? _normalizeOptional(voice) ?? stored?.voice
          : _normalizeOptional(voice),
      speed: useStoredOptionalSettings ? speed ?? stored?.speed : speed,
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
      throw TtsServiceException(
        code: failure.code,
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

String? _normalizeOptional(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

const _dirtyApiKeyMessage = 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。';

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
) => switch (kind) {
  ModelFailureKind.dns => (code: 'tts_dns', status: ProviderTestStatus.dns),
  ModelFailureKind.tls => (code: 'tts_tls', status: ProviderTestStatus.tls),
  ModelFailureKind.timeout => (
    code: 'tts_timeout',
    status: ProviderTestStatus.timeout,
  ),
  ModelFailureKind.authentication => (
    code: 'tts_authentication',
    status: ProviderTestStatus.authentication,
  ),
  ModelFailureKind.network => (
    code: 'tts_network',
    status: ProviderTestStatus.network,
  ),
  ModelFailureKind.modelNotFound => (
    code: 'tts_model_not_found',
    status: ProviderTestStatus.modelNotFound,
  ),
  ModelFailureKind.rateLimited => (
    code: 'tts_rate_limited',
    status: ProviderTestStatus.rateLimited,
  ),
  ModelFailureKind.incompatibleResponse => (
    code: 'tts_incompatible_response',
    status: ProviderTestStatus.incompatibleResponse,
  ),
  ModelFailureKind.contentParsing => (
    code: 'tts_content_parsing',
    status: ProviderTestStatus.contentParsing,
  ),
  ModelFailureKind.provider => (
    code: 'tts_provider',
    status: ProviderTestStatus.provider,
  ),
  ModelFailureKind.internal => (
    code: 'tts_internal',
    status: ProviderTestStatus.internal,
  ),
};

String _ttsTestMessage(ProviderTestStatus status) => switch (status) {
  ProviderTestStatus.success => '连接成功，语音朗读可以使用。',
  ProviderTestStatus.notConfigured => '还没有保存语音合成服务配置。',
  ProviderTestStatus.dns => '找不到语音合成服务域名，请检查地址或 DNS。',
  ProviderTestStatus.tls => '语音合成服务的 TLS 安全连接失败。',
  ProviderTestStatus.timeout => '连接语音合成服务超时。',
  ProviderTestStatus.authentication => 'API Key 没有通过验证。',
  ProviderTestStatus.network => '无法连接语音合成服务，请检查地址和网络。',
  ProviderTestStatus.modelNotFound => '找不到这个模型，请检查模型名称。',
  ProviderTestStatus.rateLimited => '语音合成服务请求过于频繁，请稍后再试。',
  ProviderTestStatus.incompatibleResponse => '语音合成服务返回了不兼容的响应格式。',
  ProviderTestStatus.contentParsing => '语音合成服务返回的内容无法解析。',
  ProviderTestStatus.provider => '语音合成服务拒绝了测试请求。',
  ProviderTestStatus.internal => '本机程序内部出错，请重试或重启栖语。',
};
