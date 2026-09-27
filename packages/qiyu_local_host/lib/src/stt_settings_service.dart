import 'dart:typed_data';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'model_gateway.dart' show ModelFailureKind;
import 'provider_config.dart';
import 'provider_settings_service.dart'
    show
        ProviderTestResult,
        ProviderTestStatus,
        providerTestMessage,
        providerTestStatusFromFailureKind;
import 'stt_gateway.dart';
import 'voice_tier_mapping.dart';
import 'voice_tier_registry.dart';

/// 语音服务设置快照：经 HTTP 返回时绝不携带明文 Key。档位元数据随快照
/// 下推（票 08，`tiers` 字段）：设置页按数据渲染档位知识，归口行集只有
/// 能力/形状/端点缺省/文案，绝无密钥。
final class SttSettingsSnapshot {
  const SttSettingsSnapshot({required this.config, required this.keySet});

  final SttConfig? config;
  final bool keySet;

  bool get configured => config != null;

  Map<String, Object?> toJson() => {
    'configured': configured,
    'keySet': keySet,
    if (config case final value?) ...value.toJson(),
    'tiers': voiceTierMetadataRows(family: VoiceServiceFamily.transcription),
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
  /// 现值读取与 Key 沿用决定进共享事务：并发保存或遗忘交错时，锁外
  /// 旧 Key 不得复活。自定义档旋钮（authHeader/responseShape/
  /// responseField）与高级参数随保存落盘，只在 custom 档生效。
  Future<SttSettingsSnapshot> save({
    required String baseUrl,
    required String model,
    SttProviderKind provider = SttProviderKind.openAiCompatible,
    String? apiKey,
    String? authHeader,
    SttResponseShape? responseShape,
    String? responseField,
    Map<String, Object?>? extraParams,
  }) async {
    final config = SttConfig(
      provider: provider,
      baseUrl: baseUrl,
      model: model,
      authHeader: authHeader,
      responseShape: responseShape ?? SttResponseShape.jsonPath,
      // 空白字段名归一为缺省 text：落盘的值恒有含义，回显也稳定。
      responseField: _normalizeResponseField(responseField),
      extraParams: extraParams,
    );
    config.validate();
    await configRepository.runTransaction(() async {
      final previous = await configRepository.loadStt();
      final persistedKey = _selectApiKey(config, previous, apiKey);
      await configRepository.saveStt(config.withApiKey(persistedKey));
    });
    return read();
  }

  Future<SttSettingsSnapshot> forgetApiKey() async {
    await configRepository.runTransaction(() async {
      final config = await configRepository.loadStt();
      if (config != null) {
        await configRepository.saveStt(config.withApiKey(null));
      }
    });
    return read();
  }

  /// 连接测试：用一段内置静音音频代发转写请求，HTTP 成功即算连接
  /// 成功（静音本来就识别不出内容，空文本不视为失败）；错误按与
  /// 聊天测试相同的分类枚举上报。表单未填 baseUrl/model 时按已保存
  /// 配置测试。自定义档旋钮随表单走：整份表单为空（测已存配置）时
  /// 回落到已存值，表单填了就以表单为准（用户清空鉴权头即测默认
  /// Bearer，不与已存值混淆）。
  Future<ProviderTestResult> test({
    String? baseUrl,
    String? model,
    SttProviderKind? provider,
    String? apiKey,
    String? authHeader,
    SttResponseShape? responseShape,
    String? responseField,
    Map<String, Object?>? extraParams,
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
    // 整份表单为空（地址与模型都没填）＝测已存配置：旋钮回落已存值。
    final useStoredOptionalSettings =
        (baseUrl == null || baseUrl.trim().isEmpty) &&
        (model == null || model.trim().isEmpty);
    final effectiveProvider =
        provider ?? stored?.provider ?? SttProviderKind.openAiCompatible;
    // 档位映射表（ADR 0020）发请求前查询（票 04 识别侧接线）：命中「应换
    // 档／不支持」直接返回结构化建议，不发转写请求、网关零调用；表 miss
    // 一切照旧。识别族没有新版端点条目，新版地址判定不参与本域查表。表
    // miss 时的分类、错误码与 ADR 0015 文案逐字不变。
    final suggestion = lookupVoiceTierSuggestion(
      family: VoiceServiceFamily.transcription,
      currentProviderWireName: effectiveProvider.wireName,
      model: effectiveModel,
    );
    if (suggestion != null) {
      return ProviderTestResult(
        // 复用「模型与接口不匹配」分类：表命中就是它在出网前的判型，
        // 不新增状态种类（spec 决策 7）。
        status: ProviderTestStatus.modelInterfaceMismatch,
        message: suggestion.reason,
        tierSuggestion: suggestion,
      );
    }
    final config = SttConfig(
      provider: effectiveProvider,
      baseUrl: effectiveBaseUrl,
      model: effectiveModel,
      authHeader: useStoredOptionalSettings
          ? authHeader ?? stored?.authHeader
          : authHeader,
      responseShape:
          (useStoredOptionalSettings
              ? responseShape ?? stored?.responseShape
              : responseShape) ??
          SttResponseShape.jsonPath,
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
      // 模型与接口不匹配显式带 client 类别，但错误码要可区分：前置
      // 分支排除该种类，落 switch 拿 stt_model_interface_mismatch。该
      // 分类落定后查档位映射表（票 05），命中把 ADR 0015 通用文案升级
      // 为精确到档建议（与连接测试引导同源同句）；表 miss 与其他失败
      // 类别沿用网关文案逐字不变。识别族没有新版端点条目，新版地址
      // 判定不参与本域查表（与连接测试同口径）。
      final message = error.kind == ModelFailureKind.modelInterfaceMismatch
          ? lookupVoiceTierFormalMessage(
                family: VoiceServiceFamily.transcription,
                currentProviderWireName: config.provider.wireName,
                model: config.model,
              ) ??
              error.message
          : error.message;
      throw SttServiceException(
        code: error.serviceError == ServiceErrorCategory.client &&
                error.kind != ModelFailureKind.modelInterfaceMismatch
            ? 'stt_client'
            : switch (error.kind) {
          ModelFailureKind.dns => 'stt_dns',
          ModelFailureKind.network => 'stt_network',
          ModelFailureKind.timeout => 'stt_timeout',
          ModelFailureKind.tls => 'stt_tls',
          ModelFailureKind.authentication => 'stt_authentication',
          ModelFailureKind.modelNotFound => 'stt_model_not_found',
          ModelFailureKind.modelInterfaceMismatch =>
            'stt_model_interface_mismatch',
          ModelFailureKind.rateLimited => 'stt_rate_limited',
          _ => 'stt_service_error',
        },
        message: message,
        retryable: true,
      );
    }
  }
}

/// 自定义档字段名/路径归一：去空白、空值回落缺省 text。保存与连接测试
/// 共用同一口径，落盘与出网的值恒有含义。
String _normalizeResponseField(String? responseField) {
  final trimmed = responseField?.trim();
  return trimmed == null || trimmed.isEmpty
      ? sttCustomDefaultResponseField
      : trimmed;
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
