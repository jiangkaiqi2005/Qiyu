import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'voice_tier_registry.dart';

/// TTS 出网异常：kind 与聊天 Provider、STT 出网错误共用同一套分类
/// （域名解析/TLS/超时/鉴权/网络/模型不存在/限流/响应不兼容/解析
/// 失败/服务拒绝/内部错误），文案说「语音合成服务」。
final class TtsGatewayException implements Exception {
  const TtsGatewayException({
    required this.kind, required this.message, this.serviceError,
  });

  final ModelFailureKind kind;
  final String message;
  final ServiceErrorCategory? serviceError;

  @override
  String toString() => message;
}

/// TTS 协议网关的公共调用面：服务层（设置、朗读、连接测试）只认这个
/// 形状，协议分支不出 Provider 层。ADR 0002 的整段合成语义（只做「一段
/// 已定稿文字 → 一段完整音频」）对本接口继续有效；分句流式合成走
/// [TtsStreamSynthesisGateway]，由 Host 行为层的分句层驱动（ADR 0018：
/// ADR 0002「完整交付后整段合成、不在增量流上分句合成」的结论已由
/// 流式交付架构推翻，播放队列/停播/前台/一律朗读语义延续）。
abstract interface class TtsSynthesisGateway {
  /// 把一段完整文字合成为完整音频字节。音频只在内存里流转，Host 不
  /// 落盘。请求 PCM 的档位（豆包、OpenAI 兼容）由网关在本地包 WAV 头
  /// 后返回——现有整段播放器（decodeAudioData / MediaPlayer）零改动。
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  });
}

/// 一个流式音频块（票二）：PCM16 单声道字节 + 本块的协商采样率。块
/// 边界即 Provider 分块边界（PCM 无帧对齐问题：16-bit 样本完整、有序
/// 连续即可，OpenAI 官方明示 chunk 边界任意）。
final class VoiceAudioChunk {
  const VoiceAudioChunk({
    required this.bytes,
    this.sampleRate,
    this.mimeType,
  }) : isWhole = mimeType != null;

  /// 裸 PCM16 单声道字节 + 协商采样率（流式块）。
  final Uint8List bytes;
  final int? sampleRate;

  /// 完整音频容器的 MIME（E1 降级的句子级整段块）：非空即这是一段
  /// 已合成完的完整音频（容器由服务定义，不包 WAV 头），播放端走既有
  /// 整段播放器；为空即 PCM 流式块，走流式播放器。
  final String? mimeType;

  /// 是否是完整容器块（E1）：与 [mimeType] 同义，读侧少一次空判断。
  final bool isWhole;
}

/// 流式合成网关（票二）：一段文字 → 音频块流。与整段接口并存——整段
/// 路径（设置试听、历史重听、连接测试）继续一问一答；分句层按完整句
/// 逐句请求，块直接转交付事件推给前端（Host 行为层持有分句，网关与
/// UI 都不分句）。
///
/// 拿不到音频块的档位不抛「不支持」：按 E1 降级返回**一个完整容器块**
/// （[VoiceAudioChunk.isWhole]），分句层靠「一句一块」获得句子级顺序
/// 播放——现有配置全部保留、不淘汰在用型号。
abstract interface class TtsStreamSynthesisGateway {
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  });
}

/// 分句流式合成的服务层接缝（票二）：Host 行为层的分句层只认这个
/// 形状，由 TtsSettingsService 实现（配置加载、Key 归一与文本校验与
/// 整段路径同源）。LocalChatService 不直接认识 TTS 协议档位。
abstract interface class VoiceStreamSynthesizer {
  /// 能否启动分句层：未配置合成服务或自动朗读关着（不白烧配额）时
  /// 如实报告 false——那些轮次就是纯文字流式，done 时的整段朗读路径
  /// 不受影响。档位拿不到音频块不算否决（E1 句子级降级照常跑）。
  Future<bool> canStream();

  /// 合成一句完整文字为音频块流。失败抛 [TtsGatewayException]（分句层
  /// 按 D1 降级：一句失败即本段语音结束）。
  Stream<VoiceAudioChunk> synthesizeStream(String text);
}

/// 连续供给的语音合成会话（票三）：打开一个跨轮次的合成会话——增量
/// 原文直接进 WebSocket（不按标点切句、不受在途上限约束），音频块按
/// 到达序流出。协议档位不支持 WS 时不开会话（返回 null），分句层维持
/// 票二的分句模式。会话失败经 [chunks] 的流错误上报（分句层按 D1
/// 降级：本段语音结束，已播句子 standing）。
abstract interface class VoiceStreamSession {
  /// 追加一段增量文本（可见原文，不切句）：空段忽略，收尾后忽略。
  void appendText(String text);

  /// 收尾：不再来新文本，等在途音频播完（协议层发结束事件）。本身不
  /// 抛异常——结束/失败都经 [chunks] 上报。
  Future<void> close();

  /// 音频块流（按到达序）。
  Stream<VoiceAudioChunk> get chunks;

  /// 作废（停止信号/轮取消）：断开连接，块流就此结束。
  void cancel();
}

/// 服务层的会话能力（票三）：由 TtsSettingsService 实现——按配置的
/// 协议/传输/型号决定开不开连续供给会话（档位不支持 WS 时返回 null）。
/// [sessionId] 是聊天会话标识：多轮合成上下文（豆包 section_id）按它
/// 保持，进程内有效（Host 重启即新值）。
abstract interface class VoiceStreamSessionOpener {
  Future<VoiceStreamSession?> openSession({required String sessionId});
}

/// 协议网关的会话分派面（票三）：TtsModelGateway 实现，协议分支不出
/// Provider 层（与 synthesize/synthesizeStream 同一张分派表）。
abstract interface class VoiceStreamSessionGateway {
  Future<VoiceStreamSession?> openSession({
    required TtsConfig config,
    required String? apiKey,
    required String sessionId,
  });
}

/// OpenAI-compatible `/audio/speech` 的 Host 中介客户端：一次性 POST
/// 全文，整段音频响应字节返回（OpenAI、硅基流动等）。流式合成走
/// chunked 传输（`stream_format=audio` + `response_format=pcm`，官方
/// 明示 chunk 边界任意、PCM 为 24kHz 16-bit 小端无头裸样本）。
final class OpenAiSpeechGateway
    implements TtsSynthesisGateway, TtsStreamSynthesisGateway {
  const OpenAiSpeechGateway(this.httpClient);

  final ProviderBytesHttpClient httpClient;

  /// OpenAI 协议的 voice 是必填字段：用户没填音色时用协议通用缺省。
  static const defaultVoice = 'alloy';

  /// 英文模式下的智能推荐音色（ADR 0023）：未手动覆盖音色且文本主要为英文时采用。
  static const defaultVoiceEn = 'nova';

  /// 判定文本是否为英文主导（含英文字母且不含 CJK 汉字）。
  static bool _isMainlyEnglish(String text) {
    var latinCount = 0;
    var cjkCount = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
          (rune >= 0x3400 && rune <= 0x4DBF)) {
        cjkCount++;
      } else if ((rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A)) {
        latinCount++;
      }
    }
    return latinCount > 0 && cjkCount == 0;
  }

  /// OpenAI pcm 的协商采样率：官方定义「24kHz 16-bit 有符号小端、无
  /// 容器头」的裸样本，WAV 包装与播放端初始化都用它。
  static const pcmSampleRate = 24000;

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = appendProviderEndpoint(config.baseUrl, 'audio/speech');
    // TTS 是新增出网路径：出网前统一过 SSRF 校验（与 STT 共用判定）。
    ensureTtsOutboundAllowed(uri);
    final voice = config.voice?.trim();
    final effectiveVoice = (voice == null || voice.isEmpty)
        ? (_isMainlyEnglish(text) ? defaultVoiceEn : defaultVoice)
        : voice;
    final body = jsonEncode({
      'model': config.model.trim(),
      'input': text,
      'voice': effectiveVoice,
      // 音频格式统一 PCM（票二）：裸样本由网关包 WAV 头，播放端零改动。
      // extraParams 展平在后再合并——用户在高级参数里显式写的
      // response_format 覆盖协议缺省（覆盖成压缩格式时原样返回，见
      // wholeResponseAudio）。
      'response_format': 'pcm',
      if (config.speed != null) 'speed': config.speed,
      if (config.extraParams != null) ...config.extraParams!,
    });
    final response = await postTtsBytes(
      httpClient: httpClient,
      uri: uri,
      headers: {
        'authorization': 'Bearer $key',
        'content-type': 'application/json',
      },
      body: utf8.encode(body),
    );
    final bytes = await consumeTtsBytesResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 错误体是文本 JSON：latin1 保留字节可读性，只用于错误分类。
      throw fromTtsModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(bytes, allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    if (bytes.isEmpty) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务没有返回音频。',
      );
    }
    return wholeResponseAudio(
      bytes,
      format:
          _effectiveTextValue(config.extraParams, 'response_format') ?? 'pcm',
      channels: 1,
      bitsPerSample: 16,
      sampleRate: pcmSampleRate,
    );
  }

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) => guardTtsAudioStream(() async* {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = appendProviderEndpoint(config.baseUrl, 'audio/speech');
    ensureTtsOutboundAllowed(uri);
    final voice = config.voice?.trim();
    final effectiveVoice = (voice == null || voice.isEmpty)
        ? (_isMainlyEnglish(text) ? defaultVoiceEn : defaultVoice)
        : voice;
    final body = jsonEncode({
      'model': config.model.trim(),
      'input': text,
      'voice': effectiveVoice,
      'response_format': 'pcm',
      // 官方流式开关：chunked 原始音频字节（非 SSE 事件）。用户经高级
      // 参数覆盖成非 PCM 时不走块流（服务返回压缩字节，PCM 播放器会
      // 播成噪音）——按 E1 降级成整响应当一块。
      'stream_format': 'audio',
      if (config.speed != null) 'speed': config.speed,
      if (config.extraParams != null) ...config.extraParams!,
    });
    final response = await postTtsBytes(
      httpClient: httpClient,
      uri: uri,
      headers: {
        'authorization': 'Bearer $key',
        'content-type': 'application/json',
      },
      body: utf8.encode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorBytes = await consumeTtsBytesResponse(response);
      throw fromTtsModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(errorBytes, allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    final negotiatedPcm =
        (_effectiveTextValue(config.extraParams, 'response_format') ?? 'pcm')
                .toLowerCase() ==
            'pcm';
    if (!negotiatedPcm) {
      // E1：拿不到 PCM 块——整响应当一块，容器原样（不包 WAV 头）。
      final whole = await consumeTtsBytesResponse(response);
      if (whole.isEmpty) {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务没有返回音频。',
        );
      }
      yield VoiceAudioChunk(
        bytes: Uint8List.fromList(whole),
        mimeType: voiceWholeContainerMime,
      );
      return;
    }
    var produced = false;
    await for (final chunk in response.body) {
      if (chunk.isEmpty) {
        continue;
      }
      produced = true;
      yield VoiceAudioChunk(
        bytes: Uint8List.fromList(chunk),
        sampleRate: pcmSampleRate,
      );
    }
    if (!produced) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务没有返回音频。',
      );
    }
  });
}

/// E1 整段块的 MIME 标注：容器由服务定义，两种播放端都按字节嗅探
/// （web 的 decodeAudioData 与安卓 MediaPlayer 都不看这个值），用中性
/// 标注而不是冒充某种具体格式。
const voiceWholeContainerMime = 'application/octet-stream';

// ---------------------------------------------------------------------------
// 纯停顿回复判定（票 02，ADR 0024「顺带发现的两个既存问题」第 2 条的
// 独立修正）：只有省略号、停顿标记或标点的回复是栖语的合法输出形态
// （「少回应」写在产品灵魂里），但沉默被念出来本身就是错的——这类文
// 本不送任何合成请求，与用哪个 TTS 无关。
// ---------------------------------------------------------------------------

/// 停顿标记词干：与行为核心 bracketed pause 的词干同形（等了一会儿/
/// 想了想/沉默了一下/停顿了一下及其可省「了」与「儿」的形态）。「轻
/// 声说」是说话方式不是沉默，行为核心也未把它算进括号停顿，这里同律。
const _pauseStemSource = '等了?一会儿?|等了一下|想了?想|沉默了?一下|停顿了?一下';

/// 括号停顿标记（全角/半角/方头括号，允许内部与尾缀标点空白）。
final _bracketedPauseTokenPattern = RegExp(
  '[（(【\\[]\\s*(?:$_pauseStemSource)[。.!！?？,，、\\s]*[）)】\\]]',
);

/// 裸停顿标记（无括号的舞台提示词干，如整条回复只有「等了一下」）。
final _barePauseTokenPattern = RegExp('(?:$_pauseStemSource)');

/// 剩余字符全为空白/标点/符号（Unicode P* 与 S*，省略号、破折号、
/// 全角句读都在其中）即没有可朗读的内容。
final _nonspeakableRestPattern = RegExp(r'^[\s\p{P}\p{S}]*$', unicode: true);

/// 判定一段待朗读文本是否纯停顿/只有标点（没有可朗读的内容）：整条
/// 只有省略号、只有停顿标记（括号或裸形式）、或只有标点符号与空白。
/// 判定先剥停顿标记再检查剩余字符——有任何一个实词、字母或数字（危
/// 机兜底的热线号码 12356、988，时间与称呼）都判可朗读。空文本没有
/// 可朗读的内容，返回 true。
bool isPurePauseReplyText(String text) {
  final withoutPauses = text
      .replaceAll(_bracketedPauseTokenPattern, '')
      .replaceAll(_barePauseTokenPattern, '');
  return _nonspeakableRestPattern.hasMatch(withoutPauses);
}

/// 整段响应归一（票二）：仅当确实是裸 PCM 单声道 16-bit 时才在 Host
/// 本地包 WAV 头（现有整段播放器零改动）；用户经高级参数覆盖成压缩
/// 格式或多声道/别的位深时**原样返回**——那些配置在统一 PCM 之前就能
/// 播，不能因为我们改协议而破坏（现有配置全部保留）。
Uint8List wholeResponseAudio(
  Uint8List bytes, {
  required String? format,
  required int channels,
  required int bitsPerSample,
  required int sampleRate,
}) {
  final normalized = format?.trim().toLowerCase();
  final isRawPcm =
      normalized == null || normalized.isEmpty || normalized == 'pcm';
  if (!isRawPcm || channels != 1 || bitsPerSample != 16) {
    return bytes;
  }
  return wrapPcmAsWav(bytes, sampleRate: sampleRate);
}

/// 高级参数里取一个文本值的生效结果（用户显式覆盖优先，协议缺省由
/// 调用方给）。仅用于整段/流式路径回读用户覆盖的格式类参数。
String? _effectiveTextValue(Map<String, Object?>? extra, String key) {
  final value = extra?[key];
  return value is String ? value : null;
}

/// 语音朗读的出网入口（票 08）：三张分派表（整段合成、流式合成、开会
/// 话）退化为档位归口查表——[resolveSynthesisShape] 按档位归口里该档
/// 形状行的排列顺序解析请求形状，三种能力从同一形状行取处理网关。一
/// 致性（三张表同一形状）与优先级（千问档型号驱动先于地址判定，豆包
/// 档 WebSocket 双向先于 HTTP 分块）由构造保证；新增协议档只加档位归
/// 口的数据行，本类零改动。
final class TtsModelGateway
    implements
        TtsSynthesisGateway,
        TtsStreamSynthesisGateway,
        VoiceStreamSessionGateway {
  TtsModelGateway(
    this.httpClient, {
    ProviderWebSocketConnector? webSocketConnector,
  }) : _env = TtsGatewayEnv(httpClient, webSocketConnector);

  final ProviderBytesHttpClient httpClient;

  /// 装配环境：WS 网关每环境一份（豆包双向网关持有跨轮次的 section_id
  /// 上下文，装配口径与构造一次、整生命周期复用一致）。
  final TtsGatewayEnv _env;

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) => resolveSynthesisShape(
    config,
  ).whole(_env).synthesize(config: config, apiKey: apiKey, text: text);

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) => resolveSynthesisShape(
    config,
  ).stream(_env).synthesizeStream(config: config, apiKey: apiKey, text: text);

  @override
  Future<VoiceStreamSession?> openSession({
    required TtsConfig config,
    required String? apiKey,
    required String sessionId,
  }) async {
    // 连续供给只对开了 WS 的形状生效（票三）：形状行没有会话通道即返
    // 回 null，分句层维持票二的分句模式。
    final gateway = resolveSynthesisShape(config).session;
    if (gateway == null) {
      return null;
    }
    return gateway(
      _env,
    ).openSession(config: config, apiKey: apiKey, sessionId: sessionId);
  }
}

/// 高级参数深合并进请求体的 input：同名字段两边都是对象时逐层合并，
/// 其余以 extraParams 为准（用户在高级参数里显式写的值优先，厂商自有
/// 参数由此兜住）。千问与自定义两个网关的 input 都是这一个形状，合并
/// 口径收口在这里，不要再各写一份。
Map<String, Object?> mergeTtsExtraIntoInput(
  Map<String, Object?> input,
  Map<String, Object?> extra,
) {
  final merged = Map<String, Object?>.from(input);
  for (final entry in extra.entries) {
    final current = merged[entry.key];
    final value = entry.value;
    if (current is Map && value is Map) {
      merged[entry.key] = mergeTtsExtraIntoInput(
        current.cast<String, Object?>(),
        value.cast<String, Object?>(),
      );
    } else {
      merged[entry.key] = value;
    }
  }
  return merged;
}

/// 语音合成的出网预算：整段文字上送 + 等待完整音频下载，与转写同级。
const ttsRequestTimeout = Duration(seconds: 60);

/// TTS 出网前的统一 SSRF 校验：公共判定在 provider_config 的
/// speechOutboundRefusalReason（与 STT 共用），这里只负责包装成本
/// 通道的异常类型。
void ensureTtsOutboundAllowed(Uri uri) {
  if (speechOutboundRefusalReason(uri) case final reason?) {
    throw TtsGatewayException(kind: ModelFailureKind.provider, message: reason);
  }
}

/// 把 ModelGatewayException 转写成本通道的 TtsGatewayException（kind、
/// message、serviceError 原样搬运）。合成 POST 的非 2xx 与音频地址下载跳
/// 两条路径都要用它，故公开共享；各网关文件里曾逐份私抄，新增路径直接
/// 复用本函数，不要再复制。
TtsGatewayException fromTtsModelFailure(ModelGatewayException failure) =>
    TtsGatewayException(
      kind: failure.kind, message: failure.message,
      serviceError: failure.serviceError,
    );

/// TTS 家族（OpenAI 兼容与豆包）共用的 Key 前置校验：返回 trim 后的
/// Key。空按未保存鉴权失败；脏字符（粘贴进表单常带零宽空格/中文，会
/// 让 dart:io 写头时抛未分类异常，STT 联调踩过的黑盒坑）按本通道人话
/// 文案拦截。
String requireTtsApiKey(String? apiKey) {
  final key = apiKey?.trim();
  if (key == null || key.isEmpty) {
    throw const TtsGatewayException(
      kind: ModelFailureKind.authentication,
      message: '还没有保存语音合成服务的 API Key。',
    );
  }
  if (containsNonVisibleAscii(key)) {
    throw const TtsGatewayException(
      kind: ModelFailureKind.provider,
      message: 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
    );
  }
  return key;
}

/// TTS 家族共用的出网调用包装：合成 POST 与音频地址下载（GET）两条出网
/// 路径的异常映射链逐字一致（含 unclassified 诊断标签），在这里收口。
/// 仅限 TTS 家族内部使用。
Future<T> guardTtsOutbound<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on TimeoutException {
    throw const TtsGatewayException(
      kind: ModelFailureKind.timeout,
      message: '连接语音合成服务超时。',
    );
  } on HandshakeException {
    throw const TtsGatewayException(
      kind: ModelFailureKind.tls,
      message: '语音合成服务的 TLS 安全连接失败。',
    );
  } on SocketException catch (error) {
    throw fromTtsModelFailure(
      providerSocketFailure(error, serviceLabel: '语音合成服务'),
    );
  } on HttpException {
    throw const TtsGatewayException(
      kind: ModelFailureKind.network,
      message: '语音合成服务连接中断。',
    );
  } on Object catch (error) {
    // 只打异常类型不打消息：消息可能嵌着用户输入（Key/地址/模型名）。
    stderrDiagnostics('tts unclassified exception: ${error.runtimeType}');
    throw const TtsGatewayException(
      kind: ModelFailureKind.internal,
      message: '本机程序内部出错。',
    );
  }
}

/// TTS 家族共用的出网 POST：两协议网关的调用形状一致，在这里收口。
/// 仅限 TTS 家族内部使用。
Future<ProviderBytesHttpResponse> postTtsBytes({
  required ProviderBytesHttpClient httpClient,
  required Uri uri,
  required Map<String, String> headers,
  required List<int> body,
}) => guardTtsOutbound(
  () => httpClient.postBytes(
    uri: uri,
    headers: headers,
    body: body,
    timeout: ttsRequestTimeout,
  ),
);

/// TTS 家族共用的响应字节消费：读完全量音频字节再返回，响应期超时与
/// 连接中断按本通道文案映射。
Future<Uint8List> consumeTtsBytesResponse(ProviderBytesHttpResponse response) async {
  final buffer = BytesBuilder(copy: false);
  try {
    await for (final chunk in response.body) {
      buffer.add(chunk);
    }
  } on TimeoutException {
    throw const TtsGatewayException(
      kind: ModelFailureKind.timeout,
      message: '语音合成服务响应超时。',
    );
  } on Object {
    throw const TtsGatewayException(
      kind: ModelFailureKind.network,
      message: '语音合成服务连接中断。',
    );
  }
  return buffer.takeBytes();
}

/// 流式合成的统一收口（票二）：块边到达边消费，每块重置空闲超时
/// （[ttsRequestTimeout] 内没有任何新块即按超时失败——半截音频不能
/// 当完整回复，与 volc 结束码断流即失败同构）；异常按本通道既有分类
/// 说话，绝不让裸异常越过 Provider 层。
Stream<VoiceAudioChunk> guardTtsAudioStream(
  Stream<VoiceAudioChunk> Function() open,
) async* {
  try {
    yield* open().timeout(ttsRequestTimeout);
  } on TtsGatewayException {
    rethrow;
  } on TimeoutException {
    throw const TtsGatewayException(
      kind: ModelFailureKind.timeout,
      message: '语音合成服务响应超时。',
    );
  } on Object {
    throw const TtsGatewayException(
      kind: ModelFailureKind.network,
      message: '语音合成服务连接中断。',
    );
  }
}

/// 裸 PCM16 单声道字节 → WAV 容器字节（44 字节 RIFF 头 + 数据）。
/// 音频格式统一 PCM（票二）：流式通道直接送裸样本（容器头在流式下会
/// 重复出现，官方明示流式禁用 wav），整段通道在 Host 本地补一个头，
/// 让现有整段播放器（浏览器 decodeAudioData / 安卓 MediaPlayer）零
/// 改动继续播。只在内存里拼接，不落盘。
Uint8List wrapPcmAsWav(Uint8List pcm, {required int sampleRate}) {
  const channels = 1;
  const bitsPerSample = 16;
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final header = BytesBuilder(copy: false);
  void tag(String value) => header.add(ascii.encode(value));
  void u32(int value) => header.add([
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]);
  void u16(int value) => header.add([value & 0xff, (value >> 8) & 0xff]);
  tag('RIFF');
  u32(36 + pcm.length);
  tag('WAVE');
  tag('fmt ');
  u32(16); // PCM fmt 块长度
  u16(1); // audioFormat = PCM
  u16(channels);
  u32(sampleRate);
  u32(byteRate);
  u16(channels * bitsPerSample ~/ 8); // blockAlign
  u16(bitsPerSample);
  tag('data');
  u32(pcm.length);
  final wav = BytesBuilder(copy: false)
    ..add(header.takeBytes())
    ..add(pcm);
  return wav.takeBytes();
}
