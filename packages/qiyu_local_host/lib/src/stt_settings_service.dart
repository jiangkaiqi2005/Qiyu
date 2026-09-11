import 'dart:typed_data';

import 'model_gateway.dart' show ModelFailureKind;
import 'provider_config.dart';
import 'provider_settings_service.dart'
    show
        ProviderTestResult,
        ProviderTestStatus,
        providerTestMessage,
        providerTestStatusFromFailureKind;
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
    SttProviderKind provider = SttProviderKind.openAiCompatible,
    String? apiKey,
  }) async {
    final config = SttConfig(
      provider: provider,
      baseUrl: baseUrl,
      model: model,
    );
    config.validate();
    final previous = await configRepository.loadStt();
    final persistedKey = _selectApiKey(config, previous, apiKey);
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
    SttProviderKind? provider,
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
    final effectiveProvider =
        provider ?? stored?.provider ?? SttProviderKind.openAiCompatible;
    final config = SttConfig(
      provider: effectiveProvider,
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
    // 在这里提前拦截，人话文案才能到达用户。
    if (effectiveKey != null && containsNonVisibleAscii(effectiveKey)) {
      return const ProviderTestResult(
        status: ProviderTestStatus.contentParsing,
        message: 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
      );
    }
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
      final status = providerTestStatusFromFailureKind(error.kind);
      return ProviderTestResult(
        status: status,
        message: providerTestMessage(
          status,
          serviceLabel: '语音服务',
          successMessage: '连接成功，语音输入可以使用。',
          notConfiguredMessage: '还没有保存语音服务配置。',
        ),
      );
    } on Object {
      return const ProviderTestResult(
        status: ProviderTestStatus.provider,
        message: '语音服务拒绝了测试请求。',
      );
    }
  }

  static String? _selectApiKey(
    SttConfig config,
    SttConfig? stored,
    String? apiKey,
  ) {
    final trimmed = apiKey?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    if (stored != null && stored.credentialScope == config.credentialScope) {
      return stored.apiKey;
    }
    return null;
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
    // 与连接测试同口径：脏 Key 按本地配置错误给可定位文案，出网前先拦
    // （网关层的同名检查保留作防御）。
    if (config.apiKey case final key? when containsNonVisibleAscii(key)) {
      throw const SttServiceException(
        code: 'stt_config_invalid',
        message: 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
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
    } on ProviderConfigException catch (error) {
      // 防御性映射：网关出网前会再校验配置，防的是不做校验的仓库实现
      // （生产链路手改 provider.json 的脏配置在 loadStt() 就被拦，由路由
      // 以 invalid_provider_config 回 400，正常到不了这里）。
      throw SttServiceException(
        code: 'stt_config_invalid',
        message: error.message,
        retryable: false,
      );
    } on SttGatewayException catch (error) {
      throw SttServiceException(
        code: switch (error.kind) {
          ModelFailureKind.dns => 'stt_dns',
          ModelFailureKind.network => 'stt_network',
          ModelFailureKind.timeout => 'stt_timeout',
          ModelFailureKind.tls => 'stt_tls',
          _ => 'stt_service_error',
        },
        message: error.message,
        retryable: true,
      );
    }
  }
}

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
