import '../baseline/host_api_gateway.dart';
import 'provider_settings_client.dart'
    show ProviderTestResult, ProviderSettingsGatewayException;
import 'voice_tier_metadata.dart';

/// 语音转写（STT）的服务类型：与 Host 的 stt 段 provider 字段对应，
/// 缺省 openai_compatible（存量配置不带该字段）。这是快照 provider 值
/// 的类型化视图：未知 wire 名按缺省档呈现（防御旧版 Host 的响应），
/// 原始 wire 名由 [SttSettings.providerWire] 保留、设置页按元数据渲染
/// （票 08，未知档位不静默丢档）。
enum SttServiceKind {
  openaiCompatible,
  volcSeedAsr,
  /// 千问语音识别：DashScope 多模态接口，同为 HTTP(S) 家族。
  qwenAsr,
  /// 自定义转写服务：普通 HTTP POST + multipart 表单，完整地址直填。
  custom;

  /// 与 Host `SttProviderKind.wireName` 对应的配置 wire 名。
  String get wireName => switch (this) {
    SttServiceKind.openaiCompatible => 'openai_compatible',
    SttServiceKind.volcSeedAsr => 'volc_seed_asr',
    SttServiceKind.qwenAsr => 'qwen_asr',
    SttServiceKind.custom => 'custom',
  };

  /// wire 名 → 档位；未知 wire 名返回 null（元数据下推的档位集可以比
  /// 本枚举大，表单按元数据渲染，只在需要类型化视图时回落）。
  static SttServiceKind? maybeFromWireName(String value) {
    for (final kind in values) {
      if (kind.wireName == value) {
        return kind;
      }
    }
    return null;
  }
}

/// 自定义转写服务的响应形态：与 Host `SttResponseShape` 的 wire 名对应，
/// 缺省 json_path。
enum SttResponseShape {
  /// JSON 字段路径：整段响应按点号路径取文本（缺省 text）。
  jsonPath('json_path'),

  /// SSE 流式：逐行 data 事件拼字。
  sse('sse');

  const SttResponseShape(this.wireName);

  final String wireName;
}

/// 千问语音识别的服务地址缺省值：DashScope 多模态完整端点。生产链路
/// 的缺省值由宿主档位归口随 `tiers` 元数据下推（票 08，ADR 0021），本
/// 常量退役为内置降级目录（[builtinSttTierCatalog]）的数据行与测试参
/// 照——只服务旧版 Host 的降级形态；与宿主包 `provider_config.dart`
/// 同名常量同值，改动需两边同步。
const qwenAsrDefaultEndpoint =
    'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';

/// 千问语音识别的模型名称缺省值：生产链路经元数据下推，本常量退役为
/// 内置降级目录的数据行与测试参照（与宿主包侧同名常量同值）。
const qwenAsrDefaultModel = 'qwen3-asr-flash';

/// 内置降级目录（票 08，ADR 0021）：旧版 Host 不下发档位元数据时的最
/// 小缺省形态。冻结在今天已知的四个档位——可用，但不新增档位知识；新
/// 档位知识一律经快照 `tiers` 行集进来。上面的缺省常量由此引用：降级
/// 数据与测试参照同源，不会各改各的。
const builtinSttTierCatalog = <VoiceTierMetadata>[
  VoiceTierMetadata(
    wireName: 'openai_compatible',
    label: 'OpenAI 兼容转写',
    description:
        '把说的话转成文字的服务（OpenAI 兼容转写，如 whisper 系列）。'
        'Key 只保存在本机 provider.json；录音只存在内存里，'
        '转写完成即丢弃，不会进入会话与记忆。',
    modelLabel: '模型名称',
    defaultEndpoint: '',
    defaultModel: '',
    urlHint: 'https://api.example.com/v1',
    modelHint: 'whisper-1',
    addressSchemes: ['http', 'https'],
  ),
  VoiceTierMetadata(
    wireName: 'volc_seed_asr',
    label: '豆包流式语音识别',
    description:
        '把说的话转成文字。豆包走官方语音识别协议；'
        'Key 只保存在本机 provider.json；录音只存在内存里，'
        '转写完成即丢弃，不会进入会话与记忆。',
    modelLabel: 'Resource-Id',
    defaultEndpoint:
        'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    defaultModel: 'volc.seedasr.sauc.duration',
    urlHint:
        'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    modelHint: 'volc.seedasr.sauc.duration',
    addressSchemes: ['ws', 'wss'],
  ),
  VoiceTierMetadata(
    wireName: 'qwen_asr',
    label: '千问语音识别',
    description:
        '把说的话转成文字的服务（千问语音识别，走阿里云百炼）。'
        'Key 只保存在本机 provider.json；录音只存在内存里，'
        '转写完成即丢弃，不会进入会话与记忆。',
    modelLabel: '模型名称',
    modelHelperText: '支持 HTTP 非流式识别模型，如 $qwenAsrDefaultModel',
    defaultEndpoint: qwenAsrDefaultEndpoint,
    defaultModel: qwenAsrDefaultModel,
    urlHint: qwenAsrDefaultEndpoint,
    modelHint: qwenAsrDefaultModel,
    addressSchemes: ['http', 'https'],
  ),
  VoiceTierMetadata(
    wireName: 'custom',
    label: '自定义转写服务',
    description:
        '把说的话转成文字的服务（自定义转写服务）。'
        'POST 填写的完整地址，录音按 multipart 表单上传；'
        'Key 只保存在本机 provider.json；录音只存在内存里，'
        '转写完成即丢弃，不会进入会话与记忆。',
    modelLabel: '模型名称',
    defaultEndpoint: '',
    defaultModel: '',
    urlHint: 'https://api.example.com/v1/audio/transcriptions',
    modelHint: 'whisper-1',
    addressSchemes: ['http', 'https'],
    customKnobs: true,
    authHeaderHint: 'Authorization: Bearer',
    authHeaderHelperText: '留空按默认 Authorization: Bearer 发送',
    responseShapeOptions: [
      (wireName: 'json_path', label: 'JSON 字段路径'),
      (wireName: 'sse', label: 'SSE 流式'),
    ],
    responseFieldHint: 'text',
    responseFieldHelperText: 'JSON 字段路径形态生效，点号路径，如 result.text',
    advancedParams: true,
    extraParamsExample:
        '配置自定义转写服务的 multipart 额外表单字段，例如：\n'
        '{\n'
        '  "speaker": "zh",\n'
        '  "enable_punctuation": true\n'
        '}',
  ),
];

/// 语音转写（STT）服务设置：与聊天 Provider 设置同一套读回口径——
/// 永不回明文 Key，只回 keySet 布尔。自定义档另带回显用旋钮
/// （authHeader/responseShape/responseField）与高级参数 extraParams。
/// 档位元数据（[tiers]）随快照下推（票 08），设置页按它渲染档位知识。
final class SttSettings {
  const SttSettings({
    required this.configured,
    required this.keySet,
    this.provider = SttServiceKind.openaiCompatible,
    this.providerWire,
    this.tiers,
    this.baseUrl,
    this.model,
    this.authHeader,
    this.responseShape = SttResponseShape.jsonPath,
    this.responseField,
    this.extraParams,
  });

  factory SttSettings.fromJson(Map<String, Object?> json) {
    final rawExtra = json['extraParams'] ?? json['extra_params'];
    final extraParams = rawExtra is Map
        ? Map<String, Object?>.from(
            rawExtra.map((k, v) => MapEntry(k.toString(), v)),
          )
        : null;
    return SttSettings(
      configured: json['configured']! as bool,
      keySet: json['keySet']! as bool,
      // 快照 provider 字段缺失或未知值一律按缺省协议呈现（Host 只会回
      // 这四种 wire 名，未知值只可能是旧版 Host 的响应，防御性回落）；
      // 原始 wire 名由 [providerWire] 保留，未知档位照常按元数据渲染、
      // 不静默丢档（票 08）。
      provider: switch (json['provider']) {
        'volc_seed_asr' => SttServiceKind.volcSeedAsr,
        'qwen_asr' => SttServiceKind.qwenAsr,
        'custom' => SttServiceKind.custom,
        _ => SttServiceKind.openaiCompatible,
      },
      providerWire: json['provider'] is String ? json['provider'] as String : null,
      baseUrl: json['baseUrl'] as String?,
      model: json['model'] as String?,
      authHeader: json['authHeader'] as String?,
      // 响应形态缺省 json_path；缺失或未知值都按缺省形态呈现。
      responseShape: switch (json['responseShape']) {
        'sse' => SttResponseShape.sse,
        _ => SttResponseShape.jsonPath,
      },
      responseField: json['responseField'] as String?,
      extraParams: extraParams,
      // 档位元数据（票 08）：缺失＝旧版 Host，设置页回落内置降级目录。
      tiers: switch (json['tiers']) {
        final List rows => [
          for (final row in rows)
            if (row is Map<String, Object?> &&
                (row['wireName'] as String? ?? '').isNotEmpty)
              VoiceTierMetadata.fromJson(row),
        ],
        _ => null,
      },
    );
  }

  final bool configured;
  final bool keySet;
  final SttServiceKind provider;

  /// 快照里的原始 provider wire 名（票 08）：元数据下推的档位集可以比
  /// [SttServiceKind] 大，未知档位在类型化视图（[provider]）里按缺省档
  /// 呈现，原始身份在这里保留、设置页按元数据渲染。
  final String? providerWire;

  /// 宿主下推的档位元数据行集：null＝旧版 Host（回落内置降级目录）。
  final List<VoiceTierMetadata>? tiers;

  final String? baseUrl;
  final String? model;

  /// 自定义档的鉴权头（整行头名）：空表示按默认 Bearer 发。
  final String? authHeader;

  /// 自定义档的响应形态。
  final SttResponseShape responseShape;

  /// 自定义档的响应字段名/路径（点号路径）：空表示缺省 text。
  final String? responseField;

  /// 自定义档的高级参数（multipart 额外表单字段）。
  final Map<String, Object?>? extraParams;

  /// 豆包与千问协议只吃 16kHz/16-bit 单声道 WAV：聊天页据此决定录音是否
  /// 要在浏览器端转换后再上送。自定义档录音原样上送（服务端解码）。
  bool get wantsWavAudio =>
      provider == SttServiceKind.volcSeedAsr ||
      provider == SttServiceKind.qwenAsr;

  /// 当前生效的 provider wire 名：原始值优先，缺省时按类型化视图。
  String get providerWireName => providerWire ?? provider.wireName;

  /// 档位元数据目录：下发行集优先呈现，旧版 Host 回落内置降级目录；
  /// 查询口径（[VoiceTierCatalog.tierFor]）不会落空。
  VoiceTierCatalog get tierCatalog =>
      VoiceTierCatalog(pushed: tiers, fallback: builtinSttTierCatalog);
}

final class SttSettingsDraft {
  const SttSettingsDraft({
    required this.baseUrl,
    required this.model,
    this.provider = SttServiceKind.openaiCompatible,
    this.providerWireName,
    this.apiKey,
    this.authHeader,
    this.responseShape,
    this.responseField,
    this.extraParams,
  });

  final SttServiceKind provider;

  /// 未知档位（不在 [SttServiceKind] 里）的原始 wire 名（票 08）：非空
  /// 时上送它保存，档位身份不因界面枚举封闭而丢失。
  final String? providerWireName;
  final String baseUrl;
  final String model;
  final String? apiKey;

  /// 自定义档旋钮：非旋钮档恒为 null，不上送（Host 侧也只对 custom
  /// 档校验与落盘）。
  final String? authHeader;
  final SttResponseShape? responseShape;
  final String? responseField;
  final Map<String, Object?>? extraParams;

  Map<String, Object?> toJson() => {
    'provider': providerWireName ?? provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': ?apiKey,
    // 旋钮的取舍按档位能力门控：已知档沿用既有口径（非旋钮档不上送，
    // Host 侧也只对 custom 档校验与落盘）；未知档位（票 08，不在枚举
    // 里）由表单按元数据能力填充，非空即上送，旋钮不丢失。
    if (_carriesCustomKnobs) ...{
      if (authHeader != null && authHeader!.trim().isNotEmpty)
        'authHeader': authHeader,
      if (responseShape != null) 'responseShape': responseShape!.wireName,
      if (responseField != null && responseField!.trim().isNotEmpty)
        'responseField': responseField,
      if (extraParams != null && extraParams!.isNotEmpty)
        'extraParams': extraParams,
    },
  };

  /// 草稿是否承载自定义旋钮：显式 custom 档，或未知档位（不在枚举里，
  /// 表单按元数据能力填充）。
  bool get _carriesCustomKnobs =>
      provider == SttServiceKind.custom || providerWireName != null;
}

/// 独立小接口：不往聊天 ProviderSettingsGateway 塞方法，STT 设置可
/// 单独注入与测试。
abstract interface class SttSettingsGateway {
  Future<SttSettings> read();

  Future<SttSettings> save(SttSettingsDraft draft);

  Future<SttSettings> forgetApiKey();

  Future<ProviderTestResult> testConnection(SttSettingsDraft draft);
}

final class HttpSttSettingsGateway extends HostApiGateway
    implements SttSettingsGateway {
  HttpSttSettingsGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => ProviderSettingsGatewayException(message);

  @override
  String get unavailableMessage => '语音设置暂时不可用，请稍后重试。';

  @override
  Future<SttSettings> read() =>
      getJson('/api/provider/stt', SttSettings.fromJson);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) =>
      putJson('/api/provider/stt', draft.toJson(), SttSettings.fromJson);

  @override
  Future<SttSettings> forgetApiKey() =>
      deleteJson('/api/provider/stt/key', SttSettings.fromJson);

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) => postJson(
    '/api/provider/stt/test',
    draft.toJson(),
    ProviderTestResult.fromJson,
  );
}
