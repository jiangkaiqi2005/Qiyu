/// 宿主下推的档位元数据（票 08，ADR 0021）：设置页按数据渲染的唯一档
/// 位知识源。宿主把档位归口里的能力/形状/端点缺省/文案随设置快照的
/// `tiers` 字段下发（绝无密钥），界面不再自备档位 switch、目录与缺省
/// 常量；旧版宿主不下发时回落各设置客户端里的内置降级目录（可用，但
/// 不新增档位知识）。
library;

/// 下拉类选项（传输方式、响应形态）的共用形状：配置 wire 名＋人话标签。
typedef VoiceTierOption = ({String wireName, String label});

/// 音色交互形态：预设目录（下拉＋可选自由输入）、自由输入（任何音色
/// ID 都能填）、无音色位。
enum VoiceTierVoiceMode {
  presets('presets'),
  freeInput('free_input'),
  none('none');

  const VoiceTierVoiceMode(this.wireName);

  final String wireName;

  /// 未知 wire 值按自由输入兜底（确认式降级）：宁可给一个可用的音色
  /// 输入框，也不按预设目录渲染一个猜出来的目录。
  static VoiceTierVoiceMode fromWireName(String? value) =>
      switch (value) {
        'none' => VoiceTierVoiceMode.none,
        'presets' => VoiceTierVoiceMode.presets,
        _ => VoiceTierVoiceMode.freeInput,
      };
}

/// 一个语音档位的下推元数据：宿主档位归口数据行的设置页投影。
final class VoiceTierMetadata {
  const VoiceTierMetadata({
    required this.wireName,
    required this.label,
    required this.description,
    required this.modelLabel,
    required this.defaultEndpoint,
    required this.defaultModel,
    required this.urlHint,
    required this.modelHint,
    required this.addressSchemes,
    this.modelHelperText,
    this.transports = const [],
    this.transportHelperText,
    this.customKnobs = false,
    this.authHeaderHint,
    this.authHeaderHelperText,
    this.responseShapeOptions = const [],
    this.responseShapeHelperText,
    this.responseFieldHint,
    this.responseFieldHelperText,
    this.advancedParams = false,
    this.extraParamsExample,
    this.speedSlider = false,
    this.voiceMode = VoiceTierVoiceMode.none,
    this.defaultVoice,
    this.voiceHint,
    this.realtimeModelSuffix,
    this.realtimeExtraParamsHint,
  });

  factory VoiceTierMetadata.fromJson(Map<String, Object?> json) {
    List<VoiceTierOption> options(Object? raw) => [
      if (raw is List)
        for (final entry in raw)
          if (entry is Map)
            (
              wireName: entry['wireName'] as String? ?? '',
              label: entry['label'] as String? ?? '',
            ),
    ];
    List<String> schemes(Object? raw) => [
      if (raw is List)
        for (final entry in raw)
          if (entry is String) entry,
    ];
    return VoiceTierMetadata(
      wireName: json['wireName'] as String? ?? '',
      label: json['label'] as String? ?? '',
      description: json['description'] as String? ?? '',
      modelLabel: json['modelLabel'] as String? ?? '模型名称',
      defaultEndpoint: json['defaultEndpoint'] as String? ?? '',
      defaultModel: json['defaultModel'] as String? ?? '',
      urlHint: json['urlHint'] as String? ?? '',
      modelHint: json['modelHint'] as String? ?? '',
      addressSchemes: schemes(json['addressSchemes']),
      modelHelperText: json['modelHelperText'] as String?,
      transports: options(json['transports']),
      transportHelperText: json['transportHelperText'] as String?,
      customKnobs: json['customKnobs'] == true,
      authHeaderHint: json['authHeaderHint'] as String?,
      authHeaderHelperText: json['authHeaderHelperText'] as String?,
      responseShapeOptions: options(json['responseShapeOptions']),
      responseShapeHelperText: json['responseShapeHelperText'] as String?,
      responseFieldHint: json['responseFieldHint'] as String?,
      responseFieldHelperText: json['responseFieldHelperText'] as String?,
      advancedParams: json['advancedParams'] == true,
      extraParamsExample: json['extraParamsExample'] as String?,
      speedSlider: json['speedSlider'] == true,
      voiceMode: VoiceTierVoiceMode.fromWireName(
        json['voiceMode'] as String?,
      ),
      defaultVoice: json['defaultVoice'] as String?,
      voiceHint: json['voiceHint'] as String?,
      realtimeModelSuffix: json['realtimeModelSuffix'] as String?,
      realtimeExtraParamsHint: json['realtimeExtraParamsHint'] as String?,
    );
  }

  /// 档位身份（配置 wire 名，如 `qwen_tts`）：与配置解析、凭据作用域
  /// 共用同一字符串。
  final String wireName;

  /// 服务类型下拉与确认对话框里的人话标签。
  final String label;

  /// 设置页简介段落。
  final String description;

  /// 模型名称框的标签（豆包族填 Resource-Id，其余叫模型名称）。
  final String modelLabel;

  /// 模型名称框旁的支持范围说明：null 不显示。
  final String? modelHelperText;

  /// 缺省服务地址（缺省回填）：空串＝无可猜缺省，等用户直填。
  final String defaultEndpoint;

  /// 缺省模型名称。
  final String defaultModel;

  /// 地址输入提示。
  final String urlHint;

  /// 模型输入提示。
  final String modelHint;

  /// 允许的服务地址 scheme：切档时的地址兼容判定。
  final List<String> addressSchemes;

  /// 传输方式选项：空＝本档无传输选择器。
  final List<VoiceTierOption> transports;

  /// 传输方式说明话术。
  final String? transportHelperText;

  /// 自定义档旋钮（鉴权头、响应形态、字段名）是否露出。
  final bool customKnobs;

  /// 鉴权头输入提示（缺省鉴权头整行头名）。
  final String? authHeaderHint;

  /// 鉴权头说明话术。
  final String? authHeaderHelperText;

  /// 响应形态下拉选项（自定义档）。
  final List<VoiceTierOption> responseShapeOptions;

  /// 响应形态说明话术。
  final String? responseShapeHelperText;

  /// 响应字段输入提示。
  final String? responseFieldHint;

  /// 响应字段说明话术。
  final String? responseFieldHelperText;

  /// 高级参数面板是否露出。
  final bool advancedParams;

  /// 高级参数的示例文案。
  final String? extraParamsExample;

  /// 语速滑条是否露出。
  final bool speedSlider;

  /// 音色交互形态。
  final VoiceTierVoiceMode voiceMode;

  /// 缺省音色（缺省回填）：自由输入档给官方示例音色 ID。
  final String? defaultVoice;

  /// 音色 ID 输入框的提示音色。
  final String? voiceHint;

  /// 型号驱动的实时形态后缀（如千问 `-realtime`）：非空时型号草稿以此
  /// 结尾即实时形态，高级参数就地禁用。
  final String? realtimeModelSuffix;

  /// 实时形态下高级参数的禁用提示。
  final String? realtimeExtraParamsHint;

  /// 地址 scheme 是否被本档允许（切档时的地址兼容判定）。
  bool allowsScheme(String scheme) =>
      addressSchemes.contains(scheme.toLowerCase());
}

/// 档位元数据目录：下发行集（新宿主）优先呈现，内置降级行集（旧版宿
/// 主）兜底——目录对渲染方统一给出「可渲染行集」与「档位查询」两个
/// 口径，查询不会落空。
final class VoiceTierCatalog {
  const VoiceTierCatalog({required this.pushed, required this.fallback});

  /// 宿主下发的行集：旧版宿主不下发时为 null（此时呈现的行集就是降级
  /// 目录）。
  final List<VoiceTierMetadata>? pushed;

  /// 内置降级行集：冻结在今天已知的档位集合，可用但不新增档位知识。
  final List<VoiceTierMetadata> fallback;

  /// 渲染方呈现的行集（服务类型下拉按它渲染，顺序即下发顺序）。
  List<VoiceTierMetadata> get rows => pushed ?? fallback;

  /// 在下发行集与降级行集里查档位；查不到返回 null（换档建议对不在
  /// 行集里的目标档保守不回填，与既有兜底同律）。
  VoiceTierMetadata? knownTier(String wireName) {
    for (final tier in rows) {
      if (tier.wireName == wireName) {
        return tier;
      }
    }
    for (final tier in fallback) {
      if (tier.wireName == wireName) {
        return tier;
      }
    }
    return null;
  }

  /// 档位查询的完整口径：[knownTier] 查不到时给未知档最小可用行——
  /// 标签即 wire 名、无缺省知识、按 HTTP 家族语义渲染。用于快照里的
  /// provider 值在下发与降级行集都缺席的防御场景：不崩溃、不静默丢档。
  VoiceTierMetadata tierFor(String wireName) =>
      knownTier(wireName) ??
      VoiceTierMetadata(
        wireName: wireName,
        label: wireName,
        description: '',
        modelLabel: '模型名称',
        defaultEndpoint: '',
        defaultModel: '',
        urlHint: '',
        modelHint: '',
        addressSchemes: const ['http', 'https'],
      );
}
