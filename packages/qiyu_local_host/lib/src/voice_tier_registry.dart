/// 语音档位归口（票 08，ADR 0021）：「一个档位 = 请求形状 + 端点 + 鉴权
/// + 能力 + 缺省配置」在全仓库唯一的知识家。本文件随包内置一份可枚举的
/// 档位目录（[shipVoiceTiers]），三个消费面都从它查表：
///
/// - **分派**：合成网关的三张分派表（整段合成、流式合成、开会话）退化为
///   [resolveSynthesisShape] 的查表结果——一致性由构造保证（三张表共用
///   同一次形状解析），千问档「型号驱动先于地址判定」的优先级由形状行的
///   排列顺序表达（ADR 0020 补篇）。
/// - **下推**：档位元数据（文案、缺省端点与型号、能力开关）经既有设置
///   HTTP 接口随快照下发（`tiers` 字段），设置页按数据渲染、不再自备
///   档位知识。下推内容只有能力/形状/端点缺省/文案，绝不含任何密钥。
/// - **缺省配置**：设置页缺省回填的唯一来源——千问两族的缺省端点/型号/
///   音色、豆包端点与 Resource-Id 全部以宿主常量为真相（此前的
///   「宿主常量 ↔ 界面同名常量」双源同值就此退役）。
///
/// 边界（与 ADR 0020 映射表边界同律）：数据随发版更新，不做运行时拉取。
/// 新档位发版＝在本文件加一份数据行（请求形状行 + 元数据）；复用既有
/// 请求形状的档位到此为止，新协议形状才需要配一个新网关实现。
library;

import 'custom_tts_gateway.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'qwen_realtime_tts_gateway.dart';
import 'qwen_tts_gateway.dart';
import 'qwen_ws_inference_tts_gateway.dart';
import 'tts_gateway.dart';
import 'voice_tier_mapping.dart';
import 'volc_bidirection_tts_gateway.dart';
import 'volc_tts_gateway.dart';

/// 服务族 wire 名（元数据下推用）：与连接测试建议里的 `targetFamily`
/// 同一口径。
String voiceServiceFamilyWireName(VoiceServiceFamily family) =>
    family == VoiceServiceFamily.transcription ? 'transcription' : 'synthesis';

/// 音色交互形态（元数据下推）：预设目录（下拉＋可选自由输入）、自由输入
/// （千问族，任何音色 ID 都能填）、无音色位（自定义档，Spec 只给四件套）。
enum VoiceTierVoiceMode {
  presets('presets'),
  freeInput('free_input'),
  none('none');

  const VoiceTierVoiceMode(this.wireName);

  final String wireName;

  static VoiceTierVoiceMode fromWireName(String value) =>
      values.firstWhere(
        (mode) => mode.wireName == value,
        orElse: () => VoiceTierVoiceMode.presets,
      );
}

/// 下拉类选项（传输方式、响应形态）的共用形状：配置 wire 名＋人话标签。
typedef VoiceTierOption = ({String wireName, String label});

/// 合成网关装配环境：形状行的网关工厂按需取用 HTTP 客户端与 WS 连接器。
/// WS 网关每环境一份（`late final` 缓存）——豆包双向网关持有跨轮次的
/// section_id 上下文，装配口径与既有「构造一次、整生命周期复用」一致。
final class TtsGatewayEnv {
  TtsGatewayEnv(
    this.httpClient,
    ProviderWebSocketConnector? webSocketConnector,
  ) : webSocketConnector =
          webSocketConnector ?? const DartIoProviderWebSocketConnector();

  final ProviderBytesHttpClient httpClient;
  final ProviderWebSocketConnector webSocketConnector;

  late final VolcBidirectionTtsGateway volcBidirection =
      VolcBidirectionTtsGateway(webSocketConnector, httpClient);
  late final QwenRealtimeTtsGateway qwenRealtime =
      QwenRealtimeTtsGateway(webSocketConnector);
  late final QwenWsInferenceTtsGateway qwenWsInference =
      QwenWsInferenceTtsGateway(webSocketConnector);
}

typedef TtsWholeGatewayFactory =
    TtsSynthesisGateway Function(TtsGatewayEnv env);
typedef TtsStreamGatewayFactory =
    TtsStreamSynthesisGateway Function(TtsGatewayEnv env);
typedef TtsSessionGatewayFactory =
    VoiceStreamSessionGateway Function(TtsGatewayEnv env);

/// 一个请求形状行（票 08）：档位内按优先级判定的请求形态，三种合成能力
/// （整段、流式、会话）各自的处理网关都挂在同一行上——三张分派表共用
/// 这份行集，一致性与优先级由构造保证，不再各写一张 switch。
///
/// 形状行的排列顺序即分派优先级（先到先得）。[matches] 恒为真的兜底行
/// 必须收尾（结构完整性由档位归口测试锁定），解析因此不会落空。
///
/// 能力为 null 的语义：该形状没有这项能力的通道——会话 null＝不开连续
/// 供给会话（分句层回落票二分句模式）；流式恒非 null（E1 句子级降级是
/// 每个形状都有的保底语义，实时形状的句级回落是现行 multimodal 通道）。
final class TtsTierShape {
  const TtsTierShape({
    required this.id,
    required this.matches,
    required this.whole,
    required this.stream,
    this.session,
  });

  /// 形状名：诊断与对拍测试用（如 `qwen_realtime_ws`）。
  final String id;

  /// 形状判定：按配置的传输/型号/地址辨认本形状（纯函数，不出网）。
  final bool Function(TtsConfig config) matches;

  /// 整段合成（试听、历史重听、连接测试）。
  final TtsWholeGatewayFactory whole;

  /// 分句流式合成（票二）。
  final TtsStreamGatewayFactory stream;

  /// 连续供给会话（票三）：null＝该形状不开会话。
  final TtsSessionGatewayFactory? session;
}

/// 一个语音档位的完整知识行：身份、设置页元数据（下推）、能力开关与
/// 缺省配置，合成族另带按优先级排列的请求形状行。字段即票面定义——
/// 请求形状（[synthesisShapes]）、端点（[defaultEndpoint] 等）、鉴权
/// （[authHeaderHint]，自定义档的缺省鉴权头）、能力（传输/旋钮/音色/
/// 语速/实时形态）、缺省配置（地址、型号、音色与输入提示）。
final class VoiceTierDescriptor {
  const VoiceTierDescriptor({
    required this.family,
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
    this.advancedParams = true,
    this.extraParamsExample,
    this.speedSlider = false,
    this.voiceMode = VoiceTierVoiceMode.none,
    this.defaultVoice,
    this.voiceHint,
    this.realtimeModelSuffix,
    this.realtimeExtraParamsHint,
    this.synthesisShapes = const [],
  });

  /// 所属服务族：转写或朗读。同族内 wire 名唯一。
  final VoiceServiceFamily family;

  /// 档位身份（配置 wire 名，如 `qwen_tts`）：与配置解析、凭据作用域
  /// 共用同一字符串。
  final String wireName;

  /// 设置页人话标签（服务类型下拉、确认对话框档位名）。
  final String label;

  /// 设置页简介段落（按档说明协议、地址、Key 与音频内存语义）。
  final String description;

  /// 模型名称框的标签：豆包族填 Resource-Id，其余叫模型名称。
  final String modelLabel;

  /// 模型名称框旁的支持范围说明：null 不显示。
  final String? modelHelperText;

  /// 缺省服务地址（设置页缺省回填）：空串＝无可猜缺省，等用户直填。
  final String defaultEndpoint;

  /// 缺省模型名称（设置页缺省回填）。
  final String defaultModel;

  /// 地址输入提示（草稿态展示的示例地址）。
  final String urlHint;

  /// 模型输入提示。
  final String modelHint;

  /// 允许的服务地址 scheme：切档时的地址兼容判定与配置校验同口径。
  final List<String> addressSchemes;

  /// 传输方式选项（票三，只归豆包档）：空＝本档无传输选择器。
  final List<VoiceTierOption> transports;

  /// 传输方式下拉的说明话术。
  final String? transportHelperText;

  /// 自定义档旋钮（鉴权头、响应形态、字段名）：只归 custom 档。
  final bool customKnobs;

  /// 鉴权头输入提示（缺省鉴权头整行头名）：[customKnobs] 时非空。
  final String? authHeaderHint;

  /// 鉴权头说明话术。
  final String? authHeaderHelperText;

  /// 响应形态下拉选项（自定义档）。
  final List<VoiceTierOption> responseShapeOptions;

  /// 响应形态说明话术。
  final String? responseShapeHelperText;

  /// 响应字段输入提示（缺省字段名）。
  final String? responseFieldHint;

  /// 响应字段说明话术。
  final String? responseFieldHelperText;

  /// 高级参数面板：TTS 四档全露（实时形态下就地禁用），STT 只归自定义档。
  final bool advancedParams;

  /// 高级参数的示例文案。
  final String? extraParamsExample;

  /// 语速滑条：千问与自定义档没有语速参数。
  final bool speedSlider;

  /// 音色交互形态。
  final VoiceTierVoiceMode voiceMode;

  /// 缺省音色（设置页缺省回填）：自由输入档给官方示例音色 ID；预设档
  /// 回填预设目录首档（目录留在界面侧，随界面版本发布）。
  final String? defaultVoice;

  /// 音色 ID 自由输入框的提示音色。
  final String? voiceHint;

  /// 型号驱动的实时形态后缀（千问 `-realtime`，ADR 0018）：非空时该档
  /// 型号草稿以此结尾即实时形态，高级参数就地禁用（网关不吃 extraParams）。
  final String? realtimeModelSuffix;

  /// 实时形态下高级参数的禁用提示。
  final String? realtimeExtraParamsHint;

  /// 合成形状行（按分派优先级排列）：只归合成族，转写族为空。
  final List<TtsTierShape> synthesisShapes;

  /// 元数据下推载荷：设置页按它渲染。只有能力/形状/端点缺省/文案，
  /// 绝无密钥；形状行（[synthesisShapes] 的网关工厂）是宿主内部装配
  /// 知识，不下发。
  Map<String, Object?> get metadataJson => {
    'wireName': wireName,
    'label': label,
    'description': description,
    'modelLabel': modelLabel,
    'modelHelperText': ?modelHelperText,
    'defaultEndpoint': defaultEndpoint,
    'defaultModel': defaultModel,
    'urlHint': urlHint,
    'modelHint': modelHint,
    'addressSchemes': addressSchemes,
    'transports': [
      for (final option in transports)
        {'wireName': option.wireName, 'label': option.label},
    ],
    'transportHelperText': ?transportHelperText,
    'customKnobs': customKnobs,
    'authHeaderHint': ?authHeaderHint,
    'authHeaderHelperText': ?authHeaderHelperText,
    'responseShapeOptions': [
      for (final option in responseShapeOptions)
        {'wireName': option.wireName, 'label': option.label},
    ],
    'responseShapeHelperText': ?responseShapeHelperText,
    'responseFieldHint': ?responseFieldHint,
    'responseFieldHelperText': ?responseFieldHelperText,
    'advancedParams': advancedParams,
    'extraParamsExample': ?extraParamsExample,
    'speedSlider': speedSlider,
    'voiceMode': voiceMode.wireName,
    'defaultVoice': ?defaultVoice,
    'voiceHint': ?voiceHint,
    'realtimeModelSuffix': ?realtimeModelSuffix,
    'realtimeExtraParamsHint': ?realtimeExtraParamsHint,
  };
}

// ---------------------------------------------------------------------------
// 随船档位目录（数据行）
// ---------------------------------------------------------------------------

/// 自定义档旋钮的响应形态选项：与宿主 `TtsResponseShape` 的 wire 名一
/// 一对应，标签与设置页既有文案逐字一致。
const _ttsResponseShapeOptions = <VoiceTierOption>[
  (wireName: 'raw_bytes', label: '裸音频字节'),
  (wireName: 'json_field', label: 'JSON 字段'),
  (wireName: 'json_lines', label: '逐行 JSON'),
];

/// 转写自定义档的响应形态选项：与宿主 `SttResponseShape` 对应。
const _sttResponseShapeOptions = <VoiceTierOption>[
  (wireName: 'json_path', label: 'JSON 字段路径'),
  (wireName: 'sse', label: 'SSE 流式'),
];

/// 千问朗读档的模型支持范围说明：从宿主常量现场拼装（缺省型号、官方
/// WS 推理端点与 maas 模板同源，spec 决策 9 聚合站域名不入代码），随
/// 元数据下推——设置页不再自备这段双源文案。
final qwenTtsModelHelperText =
    '流式合成型号：$qwenTtsDefaultModel（HTTP SSE，边出文字边出声）'
    '；$qwenTtsDefaultModel-realtime（WebSocket，前几个字就出声）\n'
    '3.x 新型号（qwen-audio-3.1-tts-flash 等）走官方新版语音通道：'
    '服务地址直接填 $qwenTtsWsInferenceEndpoint（推理通道按句流式）；'
    '也可填官方 maas HTTP 端点 $voiceTierMaasAddressTemplate，'
    '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID'
    '（栖语不代填，按句等整段返回）；型号支持范围见'
    '官方模型页：https://help.aliyun.com/zh/model-studio/qwen-tts';

/// 千问识别档的模型支持范围说明：从宿主常量现场拼装。
final qwenAsrModelHelperText = '支持 HTTP 非流式识别模型，如 $qwenAsrDefaultModel';

/// 随船档位目录：当前全部四个合成档与三个转写档。**新档位发版＝在本
/// 列表加数据行**（复用既有请求形状时无需其他代码改动）。
final List<VoiceTierDescriptor> shipVoiceTiers = [
  // ---- 朗读族（合成）----
  VoiceTierDescriptor(
    family: VoiceServiceFamily.synthesis,
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
    extraParamsExample:
        '配置 OpenAI 兼容语音合成的顶层扩展参数，例如：\n'
        '{\n'
        '  "response_format": "mp3"\n'
        '}\n'
        '覆盖成压缩格式将按句子级整段朗读。',
    speedSlider: true,
    voiceMode: VoiceTierVoiceMode.presets,
    voiceHint: 'alloy',
    synthesisShapes: [
      TtsTierShape(
        id: 'openai_http',
        matches: (_) => true,
        whole: (env) => OpenAiSpeechGateway(env.httpClient),
        stream: (env) => OpenAiSpeechGateway(env.httpClient),
      ),
    ],
  ),
  VoiceTierDescriptor(
    family: VoiceServiceFamily.synthesis,
    wireName: 'volc_tts',
    label: '豆包语音合成',
    description:
        '把栖语写完的话读出来。豆包语音合成走火山方舟接口，'
        '传输方式见下方下拉（HTTP 分块逐句合成，或 WebSocket '
        '双向边出文本边合成）；模型名称填 Resource-Id；'
        'Key 只存本机 provider.json；音频只存在内存，播完即丢。',
    modelLabel: 'Resource-Id',
    defaultEndpoint: volcTtsDefaultEndpoint,
    defaultModel: volcTtsDefaultResourceId,
    urlHint: volcTtsDefaultEndpoint,
    modelHint: volcTtsDefaultResourceId,
    addressSchemes: ['http', 'https'],
    transports: const [
      (wireName: 'http_chunk', label: 'HTTP 分块'),
      (wireName: 'ws_bidirection', label: 'WebSocket 双向'),
    ],
    transportHelperText:
        'HTTP 分块：每写好一句合成一句；'
        'WebSocket 双向：前几个字一出就开始合成，多轮对话音色语调更连贯。'
        '地址栏仍填 HTTP 端点，WebSocket 地址由本机自动派生',
    extraParamsExample:
        '配置豆包语音合成的深合并参数，例如：\n'
        '{\n'
        '  "audio_params": { "sample_rate": 16000 },\n'
        '  "additions": { "explicit_dialect": "sichuan" }\n'
        '}',
    speedSlider: true,
    voiceMode: VoiceTierVoiceMode.presets,
    voiceHint: 'zh_female_vv_uranus_bigtts',
    synthesisShapes: [
      // 豆包档按传输选择分派（票三）：WebSocket 双向走连续供给网关——
      // 整段路径（试听、历史重听、连接测试）也开一次性 WS 会话，连接
      // 测试由此覆盖用户实际选的传输（选了 WS 却只测 HTTP 会是假绿）。
      // 流式能力的回落行是 HTTP 分块网关：会话开不了（E1 压缩覆盖）时
      // 分句层回落逐句 HTTP，与既有分派表「流式不看传输」一字不差。
      TtsTierShape(
        id: 'volc_bidirection_ws',
        matches: (config) => config.transport == TtsTransport.wsBidirection,
        whole: (env) => env.volcBidirection,
        stream: (env) => VolcTtsGateway(env.httpClient),
        session: (env) => env.volcBidirection,
      ),
      TtsTierShape(
        id: 'volc_http_chunk',
        matches: (_) => true,
        whole: (env) => VolcTtsGateway(env.httpClient),
        stream: (env) => VolcTtsGateway(env.httpClient),
      ),
    ],
  ),
  VoiceTierDescriptor(
    family: VoiceServiceFamily.synthesis,
    wireName: 'qwen_tts',
    label: '千问语音合成',
    description:
        '把栖语写完的话读出来的服务（千问语音合成，走阿里云百炼）。'
        '她先把每句完整写好、过了安全检查才开口读；服务端返回音频地址'
        '后由本机取回完整的一段；音频只存在内存，播完即丢，'
        '本机不留声音文件。',
    modelLabel: '模型名称',
    modelHelperText: qwenTtsModelHelperText,
    defaultEndpoint: qwenTtsDefaultEndpoint,
    defaultModel: qwenTtsDefaultModel,
    urlHint: qwenTtsDefaultEndpoint,
    modelHint: qwenTtsDefaultModel,
    addressSchemes: ['http', 'https', 'ws', 'wss'],
    extraParamsExample:
        '配置千问语音合成的扩展参数，深合并进 input，例如：\n'
        '{\n'
        '  "instructions": "用温柔的语气慢慢读"\n'
        '}',
    voiceMode: VoiceTierVoiceMode.freeInput,
    defaultVoice: qwenTtsDefaultVoice,
    voiceHint: qwenTtsDefaultVoice,
    realtimeModelSuffix: '-realtime',
    realtimeExtraParamsHint: '该档不支持自定义高级参数',
    synthesisShapes: [
      // 千问档形状分派按 ADR 0020 补篇的优先级落序：型号驱动（-realtime，
      // ADR 0018）→ 地址 scheme 为 ws/wss（经典 WS 推理，票 07）→ 兜底
      // 现行 multimodal（maas 形状在 QwenTtsGateway 内按主机判定）。三张
      // 分派表共用这份行集。实时形状没有句级流式通道：会话开不了时整轮
      // 不开语音（D1 口径），流式回落行只是形状解析的保底——现行
      // multimodal 网关。与退化前旧表的唯一落点差在「realtime 型号配
      // wss 推理地址」组合：旧表按地址判型落 WS 推理网关，新表按型号
      // 驱动落实时形状、句级流式随之走现行 multimodal。该组合产品链路
      // 不可达（realtime 恒先开会话且 D1 下不回落分句），落点差没有行为
      // 后果，现行为由档位归口测试锁死。
      TtsTierShape(
        id: 'qwen_realtime_ws',
        matches: (config) => isQwenRealtimeTtsModel(config.model),
        whole: (env) => env.qwenRealtime,
        stream: (env) => QwenTtsGateway(env.httpClient),
        session: (env) => env.qwenRealtime,
      ),
      TtsTierShape(
        id: 'qwen_ws_inference',
        matches: (config) => qwenTtsUsesWsInference(config.baseUrl),
        whole: (env) => env.qwenWsInference,
        stream: (env) => env.qwenWsInference,
        session: (env) => env.qwenWsInference,
      ),
      TtsTierShape(
        id: 'qwen_multimodal_http',
        matches: (_) => true,
        whole: (env) => QwenTtsGateway(env.httpClient),
        stream: (env) => QwenTtsGateway(env.httpClient),
      ),
    ],
  ),
  VoiceTierDescriptor(
    family: VoiceServiceFamily.synthesis,
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
    authHeaderHint: ttsCustomDefaultAuthHeader,
    authHeaderHelperText: '留空按默认 Authorization: Bearer 发送',
    responseShapeOptions: _ttsResponseShapeOptions,
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
    voiceMode: VoiceTierVoiceMode.none,
    synthesisShapes: [
      TtsTierShape(
        id: 'custom_http',
        matches: (_) => true,
        whole: (env) => CustomTtsGateway(env.httpClient),
        stream: (env) => CustomTtsGateway(env.httpClient),
      ),
    ],
  ),
  // ---- 转写族（识别）----
  VoiceTierDescriptor(
    family: VoiceServiceFamily.transcription,
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
    advancedParams: false,
  ),
  VoiceTierDescriptor(
    family: VoiceServiceFamily.transcription,
    wireName: 'volc_seed_asr',
    label: '豆包流式语音识别',
    description:
        '把说的话转成文字。豆包走官方语音识别协议；'
        'Key 只保存在本机 provider.json；录音只存在内存里，'
        '转写完成即丢弃，不会进入会话与记忆。',
    modelLabel: 'Resource-Id',
    defaultEndpoint: sttVolcDefaultEndpoint,
    defaultModel: sttVolcDefaultResourceId,
    urlHint: sttVolcDefaultEndpoint,
    modelHint: sttVolcDefaultResourceId,
    addressSchemes: ['ws', 'wss'],
    advancedParams: false,
  ),
  VoiceTierDescriptor(
    family: VoiceServiceFamily.transcription,
    wireName: 'qwen_asr',
    label: '千问语音识别',
    description:
        '把说的话转成文字的服务（千问语音识别，走阿里云百炼）。'
        'Key 只保存在本机 provider.json；录音只存在内存里，'
        '转写完成即丢弃，不会进入会话与记忆。',
    modelLabel: '模型名称',
    modelHelperText: qwenAsrModelHelperText,
    defaultEndpoint: qwenAsrDefaultEndpoint,
    defaultModel: qwenAsrDefaultModel,
    urlHint: qwenAsrDefaultEndpoint,
    modelHint: qwenAsrDefaultModel,
    addressSchemes: ['http', 'https'],
    advancedParams: false,
  ),
  VoiceTierDescriptor(
    family: VoiceServiceFamily.transcription,
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
    authHeaderHint: sttCustomDefaultAuthHeader,
    authHeaderHelperText: '留空按默认 Authorization: Bearer 发送',
    responseShapeOptions: _sttResponseShapeOptions,
    responseFieldHint: 'text',
    responseFieldHelperText: 'JSON 字段路径形态生效，点号路径，如 result.text',
    extraParamsExample:
        '配置自定义转写服务的 multipart 额外表单字段，例如：\n'
        '{\n'
        '  "speaker": "zh",\n'
        '  "enable_punctuation": true\n'
        '}',
  ),
];

/// 豆包流式语音识别的官方 wss 端点（设置页缺省值）：地址即完整端点。
/// 此前只在 Flutter 侧 `_sttProtocolDefaults` 以字面量存在，票 08 收进
/// 归口作单一真相。
const sttVolcDefaultEndpoint =
    'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream';

/// 豆包流式语音识别的模型名称缺省值（设置页缺省值）。
const sttVolcDefaultResourceId = 'volc.seedasr.sauc.duration';

// ---------------------------------------------------------------------------
// 查表入口
// ---------------------------------------------------------------------------

/// 按服务族与 wire 名查档位行（元数据下推与测试遍历用）。查不到返回
/// null：随船目录是封闭集合，配置层只可能送来目录内的 wire 名。
VoiceTierDescriptor? voiceTierByWireName(
  VoiceServiceFamily family,
  String wireName,
) {
  for (final tier in shipVoiceTiers) {
    if (tier.family == family && tier.wireName == wireName) {
      return tier;
    }
  }
  return null;
}

/// 查合成档位行：配置层的协议枚举是封闭集合，随船目录覆盖它的每个值
/// （结构完整性测试锁定）；缺行属表配置错误，带 wire 名人话抛出。
VoiceTierDescriptor synthesisVoiceTier(TtsProviderKind provider) =>
    shipVoiceTiers.firstWhere(
      (tier) =>
          tier.family == VoiceServiceFamily.synthesis &&
          tier.wireName == provider.wireName,
      orElse: () => throw ProviderConfigException(
        '档位归口配置错误：合成目录缺少 ${provider.wireName} 档的数据行。',
      ),
    );

/// 查转写档位行：与合成侧同律。
VoiceTierDescriptor transcriptionVoiceTier(SttProviderKind provider) =>
    shipVoiceTiers.firstWhere(
      (tier) =>
          tier.family == VoiceServiceFamily.transcription &&
          tier.wireName == provider.wireName,
      orElse: () => throw ProviderConfigException(
        '档位归口配置错误：转写目录缺少 ${provider.wireName} 档的数据行。',
      ),
    );

/// 解析合成配置的请求形状（票 08）：按档位行的形状排列顺序取首个命中
/// 行——三张分派表（整段、流式、会话）都经这里查表，优先级（型号驱动
/// 先于地址判定）与既有分派表一字不差。
TtsTierShape resolveSynthesisShape(TtsConfig config) {
  final tier = synthesisVoiceTier(config.provider);
  for (final shape in tier.synthesisShapes) {
    if (shape.matches(config)) {
      return shape;
    }
  }
  // 不可达：每档形状行以恒真兜底行收尾（结构完整性测试锁定）。
  throw ProviderConfigException(
    '档位归口配置错误：${tier.wireName} 档没有可匹配的请求形状行。',
  );
}

/// 档位元数据下推（票 08）：按服务族导出元数据行集，随既有设置快照的
/// `tiers` 字段下发。[tiers] 供测试注入演示行；随船路径用缺省目录。
List<Map<String, Object?>> voiceTierMetadataRows({
  required VoiceServiceFamily family,
  List<VoiceTierDescriptor>? tiers,
}) => [
  for (final tier in tiers ?? shipVoiceTiers)
    if (tier.family == family) tier.metadataJson,
];
