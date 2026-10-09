import 'dart:convert';
import 'dart:typed_data';

import '../baseline/host_api_gateway.dart';
import 'provider_settings_client.dart' show ProviderSettingsGatewayException;
import 'voice_tier_metadata.dart';
import 'voice_tier_suggestion.dart';

/// 语音合成（TTS）的服务类型：与 Host 的 tts 段 provider 字段对应，
/// 缺省 openai_compatible（存量配置不带该字段）。这是快照 provider 值
/// 的类型化视图：未知 wire 名按缺省档呈现（防御旧版 Host 的响应），
/// 原始 wire 名由 [TtsSettings.providerWire] 保留、设置页按元数据渲染
/// （票 08，未知档位不静默丢档）。
enum TtsServiceKind {
  openAiCompatible,
  volcTts,
  /// 千问语音合成：DashScope 多模态接口，同为 HTTP(S) 家族。
  qwenTts,
  /// 自定义语音合成服务：普通 HTTP POST + JSON 请求体，完整地址直填。
  custom;

  /// 与 Host `TtsProviderKind.wireName` 对应的配置 wire 名。
  String get wireName => switch (this) {
    TtsServiceKind.openAiCompatible => 'openai_compatible',
    TtsServiceKind.volcTts => 'volc_tts',
    TtsServiceKind.qwenTts => 'qwen_tts',
    TtsServiceKind.custom => 'custom',
  };

  /// wire 名 → 档位；未知 wire 名返回 null（元数据下推的档位集可以比
  /// 本枚举大，表单按元数据渲染，只在需要类型化视图时回落）。
  static TtsServiceKind? maybeFromWireName(String value) {
    for (final kind in values) {
      if (kind.wireName == value) {
        return kind;
      }
    }
    return null;
  }
}

/// 自定义语音合成服务的响应形态：与 Host `TtsResponseShape` 的 wire 名
/// 对应，缺省 raw_bytes（裸音频字节）。
enum TtsResponseShape {
  /// 裸音频字节：响应体原样当音频。
  rawBytes('raw_bytes'),

  /// JSON 字段：字段里是 base64 或 http(s) 音频地址。
  jsonField('json_field'),

  /// 逐行 JSON：一行一块 base64 按序拼接。
  jsonLines('json_lines');

  const TtsResponseShape(this.wireName);

  final String wireName;
}

/// 语音合成的传输方式（票三）：与 Host `TtsTransport` 的 wire 名对应，
/// 只对豆包档有意义——HTTP 分块（缺省，逐句合成）或 WebSocket 双向
/// （边出文本边合成）。千问档按型号驱动（型号名以 -realtime 结尾走
/// WebSocket），自定义档不动，两档都恒为缺省值、不上送。
enum TtsTransport {
  httpChunk('http_chunk'),
  wsBidirection('ws_bidirection');

  const TtsTransport(this.wireName);

  final String wireName;
}

/// 千问语音合成的服务地址缺省值：DashScope 多模态完整端点（与千问识别
/// 同端点，地址栏填完整端点、不拼后缀）。
///
/// 生产链路的缺省值由宿主档位归口随 `tiers` 元数据下推（票 08，ADR
/// 0021），本常量退役为内置降级目录（[builtinTtsTierCatalog]）的数据
/// 行与测试参照——只服务旧版 Host 的降级形态，不再进主链路；与宿主包
/// `provider_config.dart` 同名常量同值，改动需两边同步。
const qwenTtsDefaultEndpoint =
    'wss://dashscope.aliyuncs.com/api-ws/v1/inference';

/// 千问语音合成的模型名称缺省值：生产链路经元数据下推，本常量退役为
/// 内置降级目录的数据行与测试参照（与宿主包侧同名常量同值）。
const qwenTtsDefaultModel = 'qwen-audio-3.1-tts-flash';

/// 千问语音合成的音色缺省值（官方示例音色）：音色是自由输入框，任何
/// 千问音色 ID 都能填。生产链路经元数据下推，本常量退役为内置降级目
/// 录的数据行与测试参照（与宿主包侧同名常量同值）。
const qwenTtsDefaultVoice = 'longanhuan_v3.1';

/// 千问 3.1 新型号（qwen-audio-3.1-tts-flash）的官方新版地址模板
/// （ADR 0020）：地址主机含 maas.aliyuncs.com 时 Host 按官方
/// SpeechSynthesizer 形状合成。`{业务空间ID}` 是给用户看的拼接占位——
/// 用户把它替换成自己的阿里云百炼业务空间 ID 后整条填入地址栏，栖语
/// 不代填、Host 也不做占位符替换。票 07 起降为备选信息（推理地址可代
/// 填，见 [qwenTtsWsInferenceEndpoint]），仅作设置页说明文案；票 08 起
/// 只进内置降级目录的数据行（生产链路经元数据下推）。
const qwenTtsMaasAddressTemplate =
    'https://{业务空间ID}.cn-beijing.maas.aliyuncs.com'
    '/api/v1/services/audio/tts/SpeechSynthesizer';

/// 千问 3.1／3.0 新版语音通道的官方 WS 推理端点（probe 实测全链路成功，
/// 票 07）：3.x 新型号的主推落位，地址栏直接填。生产链路经元数据下推
/// （票 08），本常量退役为内置降级目录的数据行与测试参照（与宿主包
/// `voice_tier_mapping.dart` 同名常量同值）。
const qwenTtsWsInferenceEndpoint =
    'wss://dashscope.aliyuncs.com/api-ws/v1/inference';

/// 内置降级目录（票 08，ADR 0021）：旧版 Host 不下发档位元数据时的最
/// 小缺省形态。冻结在今天已知的四个档位——可用，但不新增档位知识；新
/// 档位知识一律经快照 `tiers` 行集进来。上面的缺省常量由此引用：降级
/// 数据与测试参照同源，不会各改各的。
const builtinTtsTierCatalog = <VoiceTierMetadata>[
  VoiceTierMetadata(
    wireName: 'openai_compatible',
    label: 'OpenAI 兼容语音合成',
    description:
        '把栖语写完的话读出来的服务（OpenAI 兼容语音合成，如 tts-1）。'
        '她先把每句完整写好、过了安全检查才开口读；音频只存在内存，'
        '播完即丢，本机不留声音文件。',
    modelLabel: '模型名称',
    defaultEndpoint: '',
    defaultModel: '',
    urlHint: 'https://api.example.com/v1',
    modelHint: 'tts-1',
    addressSchemes: ['http', 'https'],
    advancedParams: true,
    extraParamsExample:
        '配置 OpenAI 兼容语音合成的顶层扩展参数，例如：\n'
        '{\n'
        '  "response_format": "mp3"\n'
        '}\n'
        '覆盖成压缩格式将按句子级整段朗读。',
    speedSlider: true,
    voiceMode: VoiceTierVoiceMode.presets,
    voiceHint: 'alloy',
  ),
  VoiceTierMetadata(
    wireName: 'volc_tts',
    label: '豆包语音合成',
    description:
        '把栖语写完的话读出来。豆包语音合成走火山方舟接口，'
        '传输方式见下方下拉（HTTP 分块逐句合成，或 WebSocket '
        '双向边出文本边合成）；模型名称填 Resource-Id；'
        'Key 只存本机 provider.json；音频只存在内存，播完即丢。',
    modelLabel: 'Resource-Id',
    defaultEndpoint:
        'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    defaultModel: 'seed-tts-2.0',
    urlHint: 'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    modelHint: 'seed-tts-2.0',
    addressSchemes: ['http', 'https'],
    transports: [
      (wireName: 'http_chunk', label: 'HTTP 分块'),
      (wireName: 'ws_bidirection', label: 'WebSocket 双向'),
    ],
    transportHelperText:
        'HTTP 分块：每写好一句合成一句；'
        'WebSocket 双向：前几个字一出就开始合成，多轮对话音色语调更连贯。'
        '地址栏仍填 HTTP 端点，WebSocket 地址由本机自动派生',
    advancedParams: true,
    extraParamsExample:
        '配置豆包语音合成的深合并参数，例如：\n'
        '{\n'
        '  "audio_params": { "sample_rate": 16000 },\n'
        '  "additions": { "explicit_dialect": "sichuan" }\n'
        '}',
    speedSlider: true,
    voiceMode: VoiceTierVoiceMode.presets,
    voiceHint: 'zh_female_vv_uranus_bigtts',
  ),
  VoiceTierMetadata(
    wireName: 'qwen_tts',
    label: '千问语音合成',
    description:
        '把栖语写完的话读出来的服务（千问语音合成，走阿里云百炼）。'
        '她先把每句完整写好、过了安全检查才开口读；服务端返回音频地址'
        '后由本机取回完整的一段；音频只存在内存，播完即丢，'
        '本机不留声音文件。',
    modelLabel: '模型名称',
    modelHelperText:
        '千问 3.1 语音合成型号（如 $qwenTtsDefaultModel）：'
        '服务地址直接填 $qwenTtsWsInferenceEndpoint（推理通道按句流式，'
        '默认音色 $qwenTtsDefaultVoice）；'
        '也可填官方 maas HTTP 端点 $qwenTtsMaasAddressTemplate，'
        '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID'
        '（栖语不代填，按句等整段返回）；型号支持范围见'
        '官方模型页：https://help.aliyun.com/zh/model-studio/qwen-tts',
    defaultEndpoint: qwenTtsDefaultEndpoint,
    defaultModel: qwenTtsDefaultModel,
    urlHint: qwenTtsDefaultEndpoint,
    modelHint: qwenTtsDefaultModel,
    addressSchemes: ['http', 'https', 'ws', 'wss'],
    advancedParams: true,
    extraParamsExample:
        '配置千问语音合成的扩展参数，深合并进 input，例如：\n'
        '{\n'
        '  "instructions": "用温柔的语气慢慢读"\n'
        '}',
    voiceMode: VoiceTierVoiceMode.freeInput,
    defaultVoice: qwenTtsDefaultVoice,
    voiceHint: qwenTtsDefaultVoice,
  ),
  VoiceTierMetadata(
    wireName: 'custom',
    label: '自定义合成服务',
    description:
        '把栖语写完的话读出来的服务（自定义语音合成服务）。'
        'POST 填写的完整地址，请求体固定 {model, input}，'
        '响应按所选形态取音频；Key 只存本机 provider.json；'
        '音频只存在内存，播完即丢，本机不留声音文件。',
    modelLabel: '模型名称',
    defaultEndpoint: '',
    defaultModel: '',
    urlHint: 'https://api.example.com/v1/audio/speech',
    modelHint: 'tts-1',
    addressSchemes: ['http', 'https'],
    customKnobs: true,
    advancedParams: true,
    authHeaderHint: 'Authorization: Bearer',
    authHeaderHelperText: '留空按默认 Authorization: Bearer 发送',
    responseShapeOptions: [
      (wireName: 'raw_bytes', label: '裸音频字节'),
      (wireName: 'json_field', label: 'JSON 字段'),
      (wireName: 'json_lines', label: '逐行 JSON'),
    ],
    responseShapeHelperText:
        '裸音频字节（且未覆盖成压缩格式）走流式分块合成；'
        '逐行 JSON 与 JSON 字段按句子级整段朗读',
    responseFieldHint: 'data',
    responseFieldHelperText: 'JSON 字段与逐行 JSON 形态生效，留取缺省 data',
    extraParamsExample:
        '配置自定义语音合成服务的扩展参数，深合并进 input，例如：\n'
        '{\n'
        '  "voice": "custom-voice"\n'
        '}',
  ),
];

/// 语音合成（TTS）服务设置：与聊天 Provider、语音转写设置同一套读回
/// 口径——永不回明文 Key，只回 keySet 布尔。自定义档另带回显用旋钮
/// （authHeader/responseShape/responseField）与高级参数 extraParams。
/// 档位元数据（[tiers]）随快照下推（票 08），设置页按它渲染档位知识。
final class TtsSettings {
  const TtsSettings({
    required this.configured,
    required this.keySet,
    this.provider = TtsServiceKind.openAiCompatible,
    this.providerWire,
    this.tiers,
    this.baseUrl,
    this.model,
    this.voice,
    this.speed,
    this.autoSpeak = true,
    this.authHeader,
    this.responseShape = TtsResponseShape.rawBytes,
    this.responseField,
    this.extraParams,
    this.transport = TtsTransport.httpChunk,
  });

  factory TtsSettings.fromJson(Map<String, Object?> json) {
    final rawExtra = json['extraParams'] ?? json['extra_params'];
    final extraParams = rawExtra is Map
        ? Map<String, Object?>.from(
            rawExtra.map((k, v) => MapEntry(k.toString(), v)),
          )
        : null;
    return TtsSettings(
      configured: json['configured']! as bool,
      keySet: json['keySet']! as bool,
      // 快照 provider 字段缺失或未知值一律按缺省协议呈现（Host 只会回
      // 已支持的值，防御旧版 Host 的响应）；原始 wire 名由 [providerWire]
      // 保留，未知档位照常按元数据渲染、不静默丢档（票 08）。
      provider: switch (json['provider']) {
        'volc_tts' => TtsServiceKind.volcTts,
        'qwen_tts' => TtsServiceKind.qwenTts,
        'custom' => TtsServiceKind.custom,
        _ => TtsServiceKind.openAiCompatible,
      },
      providerWire: json['provider'] is String ? json['provider'] as String : null,
      baseUrl: json['baseUrl'] as String?,
      model: json['model'] as String?,
      voice: json['voice'] as String?,
      speed: (json['speed'] as num?)?.toDouble(),
      autoSpeak: json['autoSpeak'] == false ? false : true,
      authHeader: json['authHeader'] as String?,
      // 响应形态缺省 raw_bytes；缺失或未知值都按缺省形态呈现。
      responseShape: switch (json['responseShape']) {
        'json_field' => TtsResponseShape.jsonField,
        'json_lines' => TtsResponseShape.jsonLines,
        _ => TtsResponseShape.rawBytes,
      },
      responseField: json['responseField'] as String?,
      extraParams: extraParams,
      // 传输方式缺省 http_chunk；缺失或未知值都按缺省呈现（Host 只会
      // 回已支持的值，防御旧版 Host 的响应）。
      transport: switch (json['transport']) {
        'ws_bidirection' => TtsTransport.wsBidirection,
        _ => TtsTransport.httpChunk,
      },
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
  final TtsServiceKind provider;

  /// 快照里的原始 provider wire 名（票 08）：元数据下推的档位集可以比
  /// [TtsServiceKind] 大，未知档位在类型化视图（[provider]）里按缺省档
  /// 呈现，原始身份在这里保留、设置页按元数据渲染。
  final String? providerWire;

  /// 宿主下推的档位元数据行集：null＝旧版 Host（回落内置降级目录）。
  final List<VoiceTierMetadata>? tiers;

  final String? baseUrl;
  final String? model;
  final String? voice;
  final double? speed;
  final bool autoSpeak;

  /// 自定义档的鉴权头（整行头名）：空表示按默认 Bearer 发。
  final String? authHeader;

  /// 自定义档的响应形态。
  final TtsResponseShape responseShape;

  /// 自定义档的响应字段名：空表示缺省 data。
  final String? responseField;

  final Map<String, Object?>? extraParams;

  /// 传输方式（票三）：只对豆包档有意义，其余档恒为缺省值。
  final TtsTransport transport;

  /// 当前生效的 provider wire 名：原始值优先，缺省时按类型化视图。
  String get providerWireName => providerWire ?? provider.wireName;

  /// 档位元数据目录：下发行集优先呈现，旧版 Host 回落内置降级目录；
  /// 查询口径（[VoiceTierCatalog.tierFor]）不会落空。
  VoiceTierCatalog get tierCatalog =>
      VoiceTierCatalog(pushed: tiers, fallback: builtinTtsTierCatalog);
}

final class TtsSettingsDraft {
  const TtsSettingsDraft({
    required this.baseUrl,
    required this.model,
    this.provider = TtsServiceKind.openAiCompatible,
    this.providerWireName,
    this.apiKey,
    this.voice,
    this.speed,
    this.autoSpeak,
    this.authHeader,
    this.responseShape,
    this.responseField,
    this.extraParams,
    this.transport,
  });

  final TtsServiceKind provider;

  /// 未知档位（不在 [TtsServiceKind] 里）的原始 wire 名（票 08）：非空
  /// 时上送它保存，档位身份不因界面枚举封闭而丢失。
  final String? providerWireName;
  final String baseUrl;
  final String model;
  final String? apiKey;
  final String? voice;
  final double? speed;
  final bool? autoSpeak;

  /// 自定义档旋钮：非旋钮档恒为 null，不上送（Host 侧也只对 custom
  /// 档校验与落盘）。
  final String? authHeader;
  final TtsResponseShape? responseShape;
  final String? responseField;

  final Map<String, Object?>? extraParams;

  /// 传输方式（票三）：非传输档恒为 null，不上送（Host 侧也只对豆包档
  /// 落盘，其余档归一为缺省 HTTP 分块）。
  final TtsTransport? transport;

  Map<String, Object?> toJson() => {
    'provider': providerWireName ?? provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': ?apiKey,
    if (voice != null && voice!.trim().isNotEmpty) 'voice': voice,
    'speed': ?speed,
    'autoSpeak': ?autoSpeak,
    // 旋钮与传输方式的取舍按档位能力门控：已知档沿用既有口径（非旋钮
    // 档不上送，Host 侧也只对 custom/豆包档校验与落盘）；未知档位（票
    // 08，不在枚举里）由表单按元数据能力填充，非空即上送，旋钮不丢失。
    if (_carriesCustomKnobs) ...{
      if (authHeader != null && authHeader!.trim().isNotEmpty)
        'authHeader': authHeader,
      if (responseShape != null) 'responseShape': responseShape!.wireName,
      if (responseField != null && responseField!.trim().isNotEmpty)
        'responseField': responseField,
    },
    if (_carriesTransport && transport != null)
      'transport': transport!.wireName,
    if (extraParams != null && extraParams!.isNotEmpty)
      'extraParams': extraParams,
  };

  /// 草稿是否承载自定义旋钮：显式 custom 档，或未知档位（不在枚举里，
  /// 表单按元数据能力填充）。
  bool get _carriesCustomKnobs =>
      provider == TtsServiceKind.custom || providerWireName != null;

  /// 草稿是否承载传输方式：显式豆包档，或未知档位（同上）。
  bool get _carriesTransport =>
      provider == TtsServiceKind.volcTts || providerWireName != null;
}

/// TTS 连接测试结果：成功时附带试听音频（内存字节，随页面丢弃）。
/// Host 命中档位映射表（ADR 0020）时 [tierSuggestion] 带结构化建议：
/// 此时 Host 从未出网，设置页当场给引导卡片。
final class TtsConnectionTest {
  const TtsConnectionTest({
    required this.succeeded,
    required this.message,
    this.audio,
    this.tierSuggestion,
  });

  factory TtsConnectionTest.fromJson(Map<String, Object?> json) {
    final audioBase64 = json['audioBase64'] as String?;
    final rawSuggestion = json['suggestion'];
    return TtsConnectionTest(
      succeeded: json['ok'] == true,
      message: json['message']! as String,
      audio: audioBase64 == null ? null : base64Decode(audioBase64),
      tierSuggestion: rawSuggestion is Map
          ? VoiceTierSuggestionData.fromJson(
              Map<String, Object?>.from(
                rawSuggestion.map((k, v) => MapEntry(k.toString(), v)),
              ),
            )
          : null,
    );
  }

  final bool succeeded;
  final String message;
  final Uint8List? audio;

  /// 档位映射建议（应换档／不支持）：表 miss 或成功时为 null。
  final VoiceTierSuggestionData? tierSuggestion;
}

/// 独立小接口：不往聊天 ProviderSettingsGateway 塞方法，TTS 设置可
/// 单独注入与测试。
abstract interface class TtsSettingsGateway {
  Future<TtsSettings> read();

  Future<TtsSettings> save(TtsSettingsDraft draft);

  /// 聊天页朗读开关：只写 autoSpeak 位（Host 独立路由，不动协议、
  /// 地址、音色与 Key）。
  Future<TtsSettings> setAutoSpeak(bool enabled);

  Future<TtsSettings> forgetApiKey();

  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft);
}

final class HttpTtsSettingsGateway extends HostApiGateway
    implements TtsSettingsGateway {
  HttpTtsSettingsGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => ProviderSettingsGatewayException(message);

  @override
  String get unavailableMessage => '语音朗读设置暂时不可用，请稍后重试。';

  @override
  Future<TtsSettings> read() =>
      getJson('/api/provider/tts', TtsSettings.fromJson);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) =>
      putJson('/api/provider/tts', draft.toJson(), TtsSettings.fromJson);

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) => putJson(
    '/api/provider/tts/auto-speak',
    {'enabled': enabled},
    TtsSettings.fromJson,
  );

  @override
  Future<TtsSettings> forgetApiKey() =>
      deleteJson('/api/provider/tts/key', TtsSettings.fromJson);

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) => postJson(
    '/api/provider/tts/test',
    draft.toJson(),
    TtsConnectionTest.fromJson,
  );
}
