/// 语音档位映射表（ADR 0020）：随包内置的常量数据表＋查询纯函数。
/// 已知千问语音型号 →「应走哪个档＋缺省地址与型号」或「栖语不支持＋原因」；
/// 查不到的型号返回 null，行为一字不变（ADR 0015 表 miss 语义照旧）。
///
/// 边界（ADR 0020 映射表边界节）：新模型发版＝在本文件加数据行随版本
/// 发布；不做运行时拉取（表决定端点与档位，表被篡改即请求与密钥外泄）、
/// 不做用户自填、名字推断只保留型号驱动的 `-realtime` 后缀规则
/// （`isQwenRealtimeTtsModel`），不按名字猜协议。豆包型号暂不收。
///
/// 单一真相：表与查询只在本包；浏览器侧只消费连接测试结果里的结构化
/// 建议字段，不复制表（spec 决策 11）。
library;

import 'provider_config.dart';

/// 语音服务族：转写（用户说话 → 文字）与朗读（栖语文字 → 声音）。
/// 同一个型号名在两个族里落位不同，查询必须带族。
enum VoiceServiceFamily { transcription, synthesis }

/// 千问 3.1／3.0 新形状型号的官方地址模板：`{业务空间ID}` 是给用户看的
/// 拼接占位，栖语不代填、不做占位符替换（ADR 0020 决定 2）。与 Flutter
/// 侧 `qwenTtsMaasAddressTemplate` 双源同值，改动需两边同步。
const voiceTierMaasAddressTemplate =
    'https://{业务空间ID}.cn-beijing.maas.aliyuncs.com'
    '/api/v1/services/audio/tts/SpeechSynthesizer';

/// 新版端点的拼接指引话术：说清空间 ID 替换、Key 要求，并把型号支持
/// 范围指向阿里云百炼官方模型页（spec 决策 9；聚合站域名不入代码）。
const voiceTierMaasAddressGuidance =
    '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID 后整条填入服务地址，'
    '新版端点需要自有百炼 Key。型号支持范围见阿里云百炼官方模型页：'
    'https://help.aliyun.com/zh/model-studio/qwen-tts';

/// 查询命中后的三态之二：应换档（含同档内换新版端点）或不支持。未知态
/// 由查询返回 null 表达，不建对象。
///
/// [targetFamily]/[targetProviderWireName]/[targetModel] 统一描述「建议
/// 的落位」：应换档时是目标档与目标型号；不支持时是建议替代型号所属的
/// 族与档（替代型号在哪个档能用，就指到哪里）。
sealed class VoiceTierSuggestion {
  const VoiceTierSuggestion({
    required this.targetFamily,
    required this.targetProviderWireName,
    required this.targetModel,
    required this.reason,
    this.defaultEndpoint,
  });

  /// 建议落位所属的服务族：与当前族不同即跨族指引（如朗读档里填了
  /// 识别型号），调用方据此只给说明、不做本域回填。
  final VoiceServiceFamily targetFamily;

  /// 建议落位的协议档 wire 名（如 `qwen_tts`）。
  final String targetProviderWireName;

  /// 应换档时为该型号本身；不支持时为建议替代型号。
  final String targetModel;

  /// 人话结论：三处调用（连接测试、设置页卡片、正式路径文案——正式
  /// 路径接线在票 05）同源，改话术只改这一处。
  final String reason;

  /// 建议落位的可代填缺省端点：现行形状条目才有（含替代型号落位）；
  /// 新版端点条目为 null——业务空间 ID 只有用户知道，栖语不代填。
  final String? defaultEndpoint;

  Map<String, Object?> toJson() => {
    'targetFamily': targetFamily.wireName,
    'targetProvider': targetProviderWireName,
    'targetModel': targetModel,
    'reason': reason,
    'defaultEndpoint': ?defaultEndpoint,
  };
}

/// 应换档：有 [defaultEndpoint]（基类字段）就代填缺省端点；只有
/// [addressTemplate]（配合 [addressGuidance]）时端点由用户自己拼
/// （新版端点含业务空间 ID，栖语不代填）。
final class VoiceTierSwitchSuggestion extends VoiceTierSuggestion {
  const VoiceTierSwitchSuggestion({
    required super.targetFamily,
    required super.targetProviderWireName,
    required super.targetModel,
    required super.reason,
    super.defaultEndpoint,
    this.addressTemplate,
    this.addressGuidance,
  });

  /// 官方地址模板（含拼接占位）：只给指引不代填时非 null。
  final String? addressTemplate;

  /// 模板拼接指引话术。
  final String? addressGuidance;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'kind': 'switchTier',
    'addressTemplate': ?addressTemplate,
    'addressGuidance': ?addressGuidance,
  };
}

/// 不支持：栖语没接这个型号的协议家族，给原因话术与建议替代型号
/// （替代型号的落位在继承字段里，缺省端点随替代型号的支持条目走）。
final class VoiceTierUnsupportedSuggestion extends VoiceTierSuggestion {
  const VoiceTierUnsupportedSuggestion({
    required super.targetFamily,
    required super.targetProviderWireName,
    required super.targetModel,
    required super.reason,
    required super.defaultEndpoint,
  });

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'kind': 'unsupported'};
}

extension on VoiceServiceFamily {
  String get wireName =>
      this == VoiceServiceFamily.transcription ? 'transcription' : 'synthesis';
}

/// 支持条目：型号在其所属档的正确落位，含缺省端点（现行形状）或
/// 新版端点模板（[usesMaasAddress]）。
final class _SupportedVoiceModel {
  const _SupportedVoiceModel(
    this.model,
    this.family,
    this.providerWireName, {
    this.defaultEndpoint,
    this.usesMaasAddress = false,
  });

  /// 小写归一后的精确型号名。
  final String model;
  final VoiceServiceFamily family;
  final String providerWireName;

  /// 现行形状条目的可代填缺省端点。
  final String? defaultEndpoint;

  /// 新版端点条目：只给模板与指引，不代填。
  final bool usesMaasAddress;
}

/// 不支持条目（spec 决策 8）：栖语没接的协议家族，各带原因话术与建议
/// 替代型号。型号名以官方文档与 ADR 0015 诊断实录为准；3.1 ASR/实时族
/// 三个型号名来自 spec 调研核实（官方页 2026-09-21~24），本票按原文收录。
///
/// 行集公开即测试锁定的表面（无 meta 直接依赖，以文档契约代替
/// `@visibleForTesting`）：话术与替代型号逐字锁定、结构完整性遍历都走
/// 这份常量——**新增或修改一行必须同票补齐两处测试**（用户故事 26），
/// 加行漏测过不了映射表测试文件的遍历断言。
const unsupportedVoiceModelRows = <({String model, String reason, String replacement})>[
  // 统一音频生成：官方无朗读用的流式通道、请求体全新形状，朗读场景
  // 收益低（spec 决策 8）。
  (
    model: 'qwen-audio-3.1-tts-next',
    reason: '这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。',
    replacement: 'qwen3-tts-flash',
  ),
  // 端到端语音对话：会绕开人格 prompt 管线，与行为红线冲突。
  (
    model: 'qwen-audio-3.1-realtime-plus',
    reason: '这个型号是端到端语音对话型号，不归转写或朗读用，栖语接不了它。',
    replacement: 'qwen3-tts-flash',
  ),
  // 流式输入型识别：需要边说边传的 WS 转写管线，现有整段录音链路接不了。
  (
    model: 'qwen-audio-3.1-asr-flash-message',
    reason: '这个型号要边说边传的流式识别通道，栖语暂不支持。',
    replacement: 'qwen3-asr-flash',
  ),
  (
    model: 'qwen-audio-3.0-asr-flash-streaming',
    reason: '这个型号要边说边传的流式识别通道，栖语暂不支持。',
    replacement: 'qwen3-asr-flash',
  ),
  (
    model: 'qwen3-asr-flash-realtime',
    reason: '这个型号要边说边传的流式识别通道，栖语暂不支持。',
    replacement: 'qwen3-asr-flash',
  ),
  // 异步文件转写：上传通道缺失，ADR 0015 已裁定不做。
  (
    model: 'qwen-audio-3.1-asr-flash-filetrans',
    reason: '这是录音文件转写型号，栖语不支持。',
    replacement: 'qwen3-asr-flash',
  ),
  (
    model: 'qwen-audio-3.0-asr-flash-filetrans',
    reason: '这是录音文件转写型号，栖语不支持。',
    replacement: 'qwen3-asr-flash',
  ),
  (
    model: 'qwen3-asr-flash-filetrans',
    reason: '这是录音文件转写型号，栖语不支持。',
    replacement: 'qwen3-asr-flash',
  ),
];

/// 替代型号的落位从支持表派生：替代型号在哪个档能用，就按它自己的
/// 支持条目给目标族、目标档与缺省端点——落位与支持表单一真相，不另写
/// 一份映射。替代型号不在支持表里属表配置错误：带型号名人话抛出
/// （结构完整性测试会在合入前拦住），不让 StateError 逃进服务层。
VoiceTierUnsupportedSuggestion _unsupportedSuggestion(
  ({String model, String reason, String replacement}) row,
) {
  final replacement = _supportedVoiceModels.firstWhere(
    (supported) => supported.model == row.replacement,
    orElse: () => throw ProviderConfigException(
      '档位映射表配置错误：${row.model} 的建议替代型号 '
      '${row.replacement} 不在支持表里，请修正映射表数据。',
    ),
  );
  return VoiceTierUnsupportedSuggestion(
    targetFamily: replacement.family,
    targetProviderWireName: replacement.providerWireName,
    targetModel: row.replacement,
    reason: row.reason,
    defaultEndpoint: replacement.defaultEndpoint,
  );
}

/// 千问语音现行形状条目：走 DashScope multimodal 端点，缺省端点可代填。
/// 型号名以官方文档与 probe 实测为准（qwen-tts / qwen-tts-realtime /
/// qwen3-asr 官方页，2026-09-24 核对；qwen3-tts-flash 另有 probe 01
/// 200 基线），不凭空造型号名。
const List<_SupportedVoiceModel> _supportedVoiceModels = [
  // 朗读族：qwen3 现行合成型号（HTTP SSE；-realtime 系在档内由型号驱动
  // 分派到 WS，映射表只在跨档时给建议）。
  _SupportedVoiceModel(
    'qwen3-tts-flash',
    VoiceServiceFamily.synthesis,
    'qwen_tts',
    defaultEndpoint: qwenTtsDefaultEndpoint,
  ),
  _SupportedVoiceModel(
    'qwen3-tts-flash-realtime',
    VoiceServiceFamily.synthesis,
    'qwen_tts',
    defaultEndpoint: qwenTtsDefaultEndpoint,
  ),
  _SupportedVoiceModel(
    'qwen3-tts-instruct-flash-realtime',
    VoiceServiceFamily.synthesis,
    'qwen_tts',
    defaultEndpoint: qwenTtsDefaultEndpoint,
  ),
  // 朗读族：Qwen-Audio-TTS 家族（3.0 与 3.1），官方端点为要拼业务空间
  // ID 的新版 SpeechSynthesizer 端点（probe 01 官方文档核查）：现行地址
  // 调不到（probe 1.3 实测 400 url error），只给模板指引。
  _SupportedVoiceModel(
    'qwen-audio-3.1-tts-flash',
    VoiceServiceFamily.synthesis,
    'qwen_tts',
    usesMaasAddress: true,
  ),
  _SupportedVoiceModel(
    'qwen-audio-3.0-tts-flash',
    VoiceServiceFamily.synthesis,
    'qwen_tts',
    usesMaasAddress: true,
  ),
  _SupportedVoiceModel(
    'qwen-audio-3.0-tts-plus',
    VoiceServiceFamily.synthesis,
    'qwen_tts',
    usesMaasAddress: true,
  ),
  // 转写族：qwen3 现行识别型号（识别档网关按地址路径派形状，缺省端点
  // 可代填；引导接线在票 04）。
  _SupportedVoiceModel(
    'qwen3-asr-flash',
    VoiceServiceFamily.transcription,
    'qwen_asr',
    defaultEndpoint: qwenAsrDefaultEndpoint,
  ),
];

/// 档位映射查询（纯函数）：入参服务族、当前协议档 wire 名、型号名
/// （去空白、小写归一、精确匹配）。当前协议档以 wire 名传入
/// （`TtsProviderKind.wireName` / `SttProviderKind.wireName`），查询不
/// 与具体枚举耦合，转写与朗读两个设置域共用同一函数。
///
/// [currentAddressUsesMaasShape] 只在千问朗读档有意义：地址主机含
/// `maas.aliyuncs.com`（`qwenTtsUsesMaasShape`）即为 true。新版端点
/// 型号（3.1／3.0 Qwen-Audio-TTS 家族）在千问朗读档配了新版地址时是
/// 正确落位、不干预；配现行地址则引导换新版端点——业务空间 ID 只有
/// 用户知道，只给官方地址模板与拼接指引，不代填（ADR 0020 决定 2）。
///
/// 返回 null＝表 miss，不干预，调用方行为一字不变。
VoiceTierSuggestion? lookupVoiceTierSuggestion({
  required VoiceServiceFamily family,
  required String currentProviderWireName,
  required String model,
  bool currentAddressUsesMaasShape = false,
}) {
  final normalized = model.trim().toLowerCase();
  if (normalized.isEmpty) {
    return null;
  }
  for (final row in unsupportedVoiceModelRows) {
    if (row.model == normalized) {
      return _unsupportedSuggestion(row);
    }
  }
  for (final row in _supportedVoiceModels) {
    if (row.model != normalized) {
      continue;
    }
    final placedRight =
        family == row.family && currentProviderWireName == row.providerWireName;
    if (placedRight) {
      // 正确落位里唯一的干预点：新版端点型号配着现行地址——实测该组合
      // 必被 400 拒绝（probe 1.3），引导换新版端点比让用户撞墙更有用。
      // 反向组合（现行型号配新版地址）不在本票用户故事内，照旧不干预。
      if (row.usesMaasAddress && !currentAddressUsesMaasShape) {
        return VoiceTierSwitchSuggestion(
          targetFamily: row.family,
          targetProviderWireName: row.providerWireName,
          targetModel: row.model,
          reason: '这个型号要走千问朗读档的新版千问端点。',
          addressTemplate: voiceTierMaasAddressTemplate,
          addressGuidance: voiceTierMaasAddressGuidance,
        );
      }
      return null;
    }
    return row.usesMaasAddress
        ? VoiceTierSwitchSuggestion(
            targetFamily: row.family,
            targetProviderWireName: row.providerWireName,
            targetModel: row.model,
            reason: '这个型号要走千问朗读档的新版千问端点。',
            addressTemplate: voiceTierMaasAddressTemplate,
            addressGuidance: voiceTierMaasAddressGuidance,
          )
        : VoiceTierSwitchSuggestion(
            targetFamily: row.family,
            targetProviderWireName: row.providerWireName,
            targetModel: row.model,
            // 话术按目标族说：型号该去哪个档，就说哪个档的名字。
            reason: row.family == VoiceServiceFamily.synthesis
                ? '这个型号要走千问朗读档。'
                : '这个型号要走千问识别档。',
            defaultEndpoint: row.defaultEndpoint,
          );  }
  return null;
}
