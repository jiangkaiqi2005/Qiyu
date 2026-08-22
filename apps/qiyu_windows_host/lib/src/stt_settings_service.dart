import 'dart:typed_data';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_settings_service.dart' show ProviderTestResult, ProviderTestStatus;
import 'stt_gateway.dart';

/// 语音服务设置快照：经 HTTP 返回时绝不携带明文 Key。
final class SttSettingsSnapshot {
  const SttSettingsSnapshot({required this.config, required this.keySet});

  final SttConfig? config;
  final bool keySet;

  bool get configured => config != null;

  Map<String, Object?> toJson() => {
    'configured': configured,
    'keySet': keySet,
    if (config case final value?) ...value.toJson(),
  };
}

/// 语音输入服务层错误：路由据此回允许列表诊断码，不透出服务商原文。
final class SttServiceException implements Exception {
  const SttServiceException({
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

/// 语音转写（STT）设置与调用服务：与聊天 ProviderSettingsService 同构，
/// 但 Key 只存 provider.json 的 stt 段，无凭据管理器回退。
final class SttSettingsService {
  const SttSettingsService(this.configRepository, this.sttGateway);

  final SttConfigRepository configRepository;
  final SttModelGateway sttGateway;

  Future<SttSettingsSnapshot> read() async {
    final config = await configRepository.loadStt();
    final key = config?.apiKey;
    return SttSettingsSnapshot(
      config: config,
      keySet: key != null && key.trim().isNotEmpty,
    );
  }

  /// 与聊天 Key 同律但作用域独立：传入新 Key 就写入；没传时同地址保留
  /// 已存 Key，换地址则清空——旧服务商的 Key 不沿用给新服务商。
  Future<SttSettingsSnapshot> save({
    required String baseUrl,
    required String model,
    String? apiKey,
  }) async {
    final config = SttConfig(baseUrl: baseUrl, model: model);
    config.validate();
    final previous = await configRepository.loadStt();
    final trimmed = apiKey?.trim();
    String? persistedKey;
    if (trimmed != null && trimmed.isNotEmpty) {
      persistedKey = trimmed;
    } else if (previous != null &&
        previous.credentialScope == config.credentialScope) {
      persistedKey = previous.apiKey;
    }
    await configRepository.saveStt(config.withApiKey(persistedKey));
    return read();
  }

  Future<SttSettingsSnapshot> forgetApiKey() async {
    final config = await configRepository.loadStt();
    if (config != null) {
      await configRepository.saveStt(config.withApiKey(null));
    }
    return read();
  }

  /// 连接测试：用一段内置静音音频代发转写请求，HTTP 成功即算连接
  /// 成功（静音本来就识别不出内容，空文本不视为失败）；错误按与
  /// 聊天测试相同的分类枚举上报。表单未填 baseUrl/model 时按已保存
  /// 配置测试。
  Future<ProviderTestResult> test({
    String? baseUrl,
    String? model,
    String? apiKey,
  }) async {
    final stored = await configRepository.loadStt();
    final effectiveBaseUrl =
        baseUrl == null || baseUrl.trim().isEmpty
        ? stored?.baseUrl
        : baseUrl.trim();
    final effectiveModel =
        model == null || model.trim().isEmpty ? stored?.model : model.trim();
    if (effectiveBaseUrl == null || effectiveModel == null) {
      return const ProviderTestResult(
        status: ProviderTestStatus.notConfigured,
        message: '还没有保存语音服务配置。',
      );
    }
    final config = SttConfig(baseUrl: effectiveBaseUrl, model: effectiveModel);
    try {
      config.validate();
    } on ProviderConfigException catch (error) {
      return ProviderTestResult(
        status: ProviderTestStatus.contentParsing,
        message: error.message,
      );
    }
    final trimmedKey = apiKey?.trim();
    final effectiveKey =
        trimmedKey != null && trimmedKey.isNotEmpty
        ? trimmedKey
        : (stored != null &&
              stored.credentialScope == config.credentialScope
          ? stored.apiKey
          : null);
    try {
      await sttGateway.transcribe(
        config: config,
        apiKey: effectiveKey,
        audio: sttConnectionTestAudio,
        mimeType: 'audio/wav',
      );
      return const ProviderTestResult(
        status: ProviderTestStatus.success,
        message: '连接成功，语音输入可以使用。',
      );
    } on SttGatewayException catch (error) {
      final status = _sttTestStatus(error.kind);
      return ProviderTestResult(status: status, message: _sttTestMessage(status));
    } on Object {
      return const ProviderTestResult(
        status: ProviderTestStatus.provider,
        message: '语音服务拒绝了测试请求。',
      );
    }
  }

  /// 正式转写：识别文本为空视为失败（「没有识别到语音」），录音留在
  /// 浏览器内存里可重试。
  Future<String> transcribe({
    required List<int> audio,
    required String mimeType,
  }) async {
    final config = await configRepository.loadStt();
    if (config == null) {
      throw const SttServiceException(
        code: 'stt_not_configured',
        message: '还没有配置语音服务，请先在设置页填写。',
        retryable: false,
      );
    }
    try {
      final text = (await sttGateway.transcribe(
        config: config,
        apiKey: config.apiKey,
        audio: audio,
        mimeType: mimeType,
      )).trim();
      if (text.isEmpty) {
        throw const SttServiceException(
          code: 'stt_no_speech',
          message: '没有识别到语音，可以再说一次。',
          retryable: true,
        );
      }
      return text;
    } on SttGatewayException catch (error) {
      throw SttServiceException(
        code: 'stt_service_error',
        message: error.message,
        retryable: true,
      );
    }
  }
}

ProviderTestStatus _sttTestStatus(ModelFailureKind kind) => switch (kind) {
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

String _sttTestMessage(ProviderTestStatus status) => switch (status) {
  ProviderTestStatus.success => '连接成功，语音输入可以使用。',
  ProviderTestStatus.notConfigured => '还没有保存语音服务配置。',
  ProviderTestStatus.dns => '找不到语音服务域名，请检查地址或 DNS。',
  ProviderTestStatus.tls => '语音服务的 TLS 安全连接失败。',
  ProviderTestStatus.timeout => '连接语音服务超时。',
  ProviderTestStatus.authentication => 'API Key 没有通过验证。',
  ProviderTestStatus.network => '无法连接语音服务，请检查地址和网络。',
  ProviderTestStatus.modelNotFound => '找不到这个模型，请检查模型名称。',
  ProviderTestStatus.rateLimited => '语音服务请求过于频繁，请稍后再试。',
  ProviderTestStatus.incompatibleResponse => '语音服务返回了不兼容的响应格式。',
  ProviderTestStatus.contentParsing => '语音服务返回的内容无法解析。',
  ProviderTestStatus.provider => '语音服务拒绝了测试请求。',
  ProviderTestStatus.internal => '本机程序内部出错，请重试或重启栖语。',
};

/// 内置静音音频（16kHz、16-bit 单声道 WAV，约 0.25 秒）：连接测试代发
/// 转写请求用。内容为纯静音，服务返回空文本属于正常结果。
final List<int> sttConnectionTestAudio = () {
  const sampleRate = 16000;
  const sampleCount = sampleRate ~/ 4;
  final data = Uint8List(sampleCount * 2);
  final header = BytesBuilder(copy: false);
  final riffSize = 36 + data.length;
  final sizeBytes = Uint8List.fromList(
    List.generate(4, (i) => (riffSize >> (8 * i)) & 0xFF),
  );
  final dataSizeBytes = Uint8List.fromList(
    List.generate(4, (i) => (data.length >> (8 * i)) & 0xFF),
  );
  void ascii(String text) => header.add(text.codeUnits);
  void le16(int value) => header.add(
    Uint8List.fromList([value & 0xFF, (value >> 8) & 0xFF]),
  );

  ascii('RIFF');
  header.add(sizeBytes);
  ascii('WAVE');
  ascii('fmt ');
  le16(16); // fmt 块长度
  le16(1); // PCM
  le16(1); // 单声道
  le16(sampleRate);
  le16(sampleRate * 2); // 字节率 = 采样率 × 块对齐
  le16(2); // 块对齐 = 2 字节
  le16(16); // 位深
  ascii('data');
  header.add(dataSizeBytes);
  header.add(data);
  return header.takeBytes();
}();
