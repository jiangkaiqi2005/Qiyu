import 'dart:convert';
import 'dart:typed_data';

import 'big_endian_bytes.dart';
import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'tts_gateway.dart';
import 'tts_ws_session_skeleton.dart';
import 'volc_seed_asr_gateway.dart';
import 'volc_tts_gateway.dart';

// ---------------------------------------------------------------------------
// 豆包双向流式（火山方舟 Agent Plan）
// ---------------------------------------------------------------------------

/// 豆包双向 WS 合成网关（票三）：官方「双向流式」文档端点
/// `wss://openspeech.bytedance.com/api/v3/tts/bidirection`。LLM 出文本
/// 即发 TaskRequest（不等标点），音频帧按到达序转 PCM 块；section_id 按
/// 聊天会话保持，多轮合成上下文在会话间延续（进程内映射，Host 重启即
/// 新值——服务端上下文本就有超时，ADR 0019）。
///
/// 帧位域是推断值（官方精确位域只在依赖 zip 里，页面正文未载）：客户端
/// 事件按官方文档以 JSON 载荷的 EventType 字符串标识；服务端帧按单向
/// V3 帧家族的消息类型分派（1001 JSON 事件 / 1011 裸音频 / 1111 错误）。
/// 假设与待真机验证点见 ADR 0019。
final class VolcBidirectionTtsGateway
    implements TtsSynthesisGateway, VoiceStreamSessionGateway {
  VolcBidirectionTtsGateway(
    this.connector,
    this.httpClient, {
    this.timeout = ttsRequestTimeout,
  });

  final ProviderWebSocketConnector connector;

  /// 整段路径的 E1 回落用：压缩格式覆盖的配置走 HTTP 单向端点（票二既有
  /// 形态，与 WS 供给无关）。
  final ProviderBytesHttpClient httpClient;

  /// 空闲超时预算：含建连、握手、音频间隔与收尾等待（与豆包 ASR 网关
  /// 的可注入超时同律，测试用小值验证超时降级）。
  final Duration timeout;

  /// 聊天会话 → section_id（进程内保持）：同一聊天会话的各轮合成共享
  /// 服务端上下文，换会话即新值。
  final Map<String, String> _sectionIds = {};

  /// 派生 WS 地址：baseUrl 始终是用户填的 HTTP 端点（豆包单向流式端
  /// 点），host/port 保留，路径按协议写死。http→ws、https→wss。
  static Uri deriveWebSocketUri(TtsConfig config) {
    final base = Uri.parse(config.baseUrl.trim());
    return Uri(
      scheme: base.scheme == 'http' ? 'ws' : 'wss',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/api/v3/tts/bidirection',
    );
  }

  @override
  Future<VoiceStreamSession?> openSession({
    required TtsConfig config,
    required String? apiKey,
    required String sessionId,
  }) async {
    final prepared = _prepare(config: config, apiKey: apiKey);
    // E1（票二口径在 WS 供给下不变）：用户经高级参数把 format 覆盖成压缩
    // 格式时，音频帧不能当裸 PCM 交付（会播成噪音）——不开会话，分句层
    // 自然回落票二分句 + 句子级整段朗读。
    if (!VolcTtsGateway.isStreamablePcm(
      VolcTtsGateway.effectiveAudioParams(config),
    )) {
      return null;
    }
    return _openSession(config: config, prepared: prepared, sessionId: sessionId);
  }

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    // 整段路径（设置试听、历史重听、连接测试）：传输选了 WebSocket 双向
    // 时开一个一次性会话收完整 PCM——连接测试由此覆盖用户实际选的传输
    // （选了 WS 却只测 HTTP 会是假绿）。
    if (!VolcTtsGateway.isStreamablePcm(
      VolcTtsGateway.effectiveAudioParams(config),
    )) {
      // E1：压缩格式覆盖的整段路径照旧走 HTTP 单向端点（票二既有形态）。
      return VolcTtsGateway(httpClient).synthesize(
        config: config,
        apiKey: apiKey,
        text: text,
      );
    }
    final session = await _openSession(
      config: config,
      prepared: _prepare(config: config, apiKey: apiKey),
      // 一次性会话不挂聊天会话：多轮上下文对单次整段合成没有意义。
      sessionId: newVolcRequestId(),
    );
    try {
      session.appendText(text);
      await session.close();
      final audio = BytesBuilder(copy: false);
      await for (final chunk in session.chunks) {
        audio.add(chunk.bytes);
      }
      final bytes = audio.takeBytes();
      if (bytes.isEmpty) {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务没有返回音频。',
        );
      }
      return wrapPcmAsWav(bytes, sampleRate: _negotiatedSampleRate(config));
    } finally {
      session.cancel();
    }
  }

  /// 出网前置：配置校验、Key 校验、派生 WS 地址与 SSRF 校验（两条路径
  /// 共用）。
  ({String key, Uri uri}) _prepare({
    required TtsConfig config,
    required String? apiKey,
  }) {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = deriveWebSocketUri(config);
    // 派生出的 WS 地址同样过出网校验（与 HTTP 出网同律）。
    ensureTtsOutboundAllowed(uri);
    return (key: key, uri: uri);
  }

  Future<_VolcBidirectionSession> _openSession({
    required TtsConfig config,
    required ({String key, Uri uri}) prepared,
    required String sessionId,
  }) => guardTtsWebSocket(() async {
    // 建连也包超时：握手等待只覆盖事件回复，端点不响应时上界不能只剩
    // OS/dart:io 默认值。
    final connection = await connector
        .connect(
          uri: prepared.uri,
          headers: {
            'X-Api-Key': prepared.key,
            // 模型名称字段填的就是 Resource-Id（与 HTTP 路径同口径）。
            'X-Api-Resource-Id': config.model.trim(),
            'X-Api-Connect-Id': newVolcRequestId(),
            'X-Control-Require-Usage-Tokens-Return': '*',
          },
        )
        .timeout(timeout);
    final session = _VolcBidirectionSession(
      connection: connection,
      sessionId: newVolcRequestId(),
      startSessionParams: _startSessionParams(config),
      sampleRate: _negotiatedSampleRate(config),
      timeout: timeout,
      diagnosticsSink: stderrDiagnostics,
    );
    session.startReader();
    session.sendStartConnection();
    try {
      await session.awaitEvent(volcTtsEventConnectionStarted).timeout(timeout);
      session.sendStartSession(
        sectionId: _sectionIds.putIfAbsent(sessionId, newVolcRequestId),
      );
      await session.awaitEvent(volcTtsEventSessionStarted).timeout(timeout);
      // 握手完成：会话中途的空闲计时器这才武装（每帧重置）。
      session.onHandshakeComplete();
    } on Object catch (error) {
      // 握手失败：断开连接并把失败如实上报给调用方（调用方按 D1 同口径
      // 提示一次，文字链路不受影响）。
      session.cancel();
      throw fromTtsWebSocketFailure(error);
    }
    return session;
  });

  /// StartSession 的 req_params：音色/语速/方言 additions 与 HTTP 路径
  /// 同一套换算（复用现函数，不另抄）。
  static Map<String, Object?> _startSessionParams(TtsConfig config) {
    final requestAudioParams = <String, Object?>{
      // 流式推荐 pcm：官方明示禁 wav（流式会重复 header）。
      'format': 'pcm',
      'sample_rate': volcTtsDefaultSampleRate,
    };
    final extra = config.extraParams;
    if (extra != null && extra['audio_params'] is Map) {
      requestAudioParams.addAll(
        (extra['audio_params'] as Map).cast<String, Object?>(),
      );
    }
    // 语速换算与 HTTP 路径同口径（audio_params.speech_rate [-50, 100]）。
    if (config.speed != null) {
      requestAudioParams['speech_rate'] =
          ((config.speed! - 1.0) * 100).round().clamp(-50, 100);
    }
    final rawSpeaker = config.voice?.trim();
    final detectedDialect =
        (rawSpeaker == null || rawSpeaker.isEmpty)
        ? null
        : VolcTtsGateway.detectDialect(rawSpeaker);
    final effectiveSpeaker =
        (detectedDialect != null || rawSpeaker == null || rawSpeaker.isEmpty)
        ? VolcTtsGateway.defaultSpeaker
        : rawSpeaker;
    return <String, Object?>{
      'speaker': effectiveSpeaker,
      'audio_params': requestAudioParams,
      'additions': ?VolcTtsGateway.resolveAdditions(
        extra: extra,
        detectedDialect: detectedDialect,
      ),
    };
  }

  static int _negotiatedSampleRate(TtsConfig config) =>
      switch (VolcTtsGateway.effectiveAudioParams(config)['sample_rate']) {
        final num rate => rate.toInt(),
        _ => volcTtsDefaultSampleRate,
      };
}
/// 豆包双向 WS 客户端事件名（官方文档字段值）。
const volcTtsEventStartConnection = 'StartConnection';
const volcTtsEventStartSession = 'StartSession';
const volcTtsEventTaskRequest = 'TaskRequest';
const volcTtsEventCancelSession = 'CancelSession';
const volcTtsEventFinishSession = 'FinishSession';
const volcTtsEventFinishConnection = 'FinishConnection';
const volcTtsEventConnectionStarted = 'ConnectionStarted';
const volcTtsEventSessionStarted = 'SessionStarted';
const volcTtsEventSessionFinished = 'SessionFinished';
const volcTtsEventConnectionFailed = 'ConnectionFailed';
const volcTtsEventSessionFailed = 'SessionFailed';

/// 服务端事件的 header event 号回退映射（推断值，ADR 0019）：载荷里带
/// EventType 字符串时以字符串为准（官方文档的字段形态），本映射只在
/// 字符串缺失时兜底。锚点（2/52/151/152/153/350-352）照单向 V3 与
/// HTTP SSE 两个已公开家族的取值。
const _volcTtsEventNumberNames = <int, String>{
  50: volcTtsEventConnectionStarted,
  51: volcTtsEventSessionStarted,
  52: 'ConnectionFinished',
  151: 'SessionCanceled',
  152: volcTtsEventSessionFinished,
  153: volcTtsEventSessionFailed,
  154: volcTtsEventConnectionFailed,
  350: 'TTSSentenceStart',
  351: 'TTSSentenceEnd',
  352: 'TTSResponse',
  353: 'TTSSubtitle',
};

/// 帧头 byte0：协议版本 1（高 4 位）+ 头长 1（低 4 位，即 4 字节头）。
const _volcTtsHeaderByte0 = 0x11;

/// 消息类型（byte1 高 4 位，照单向 V3 帧家族）：客户端请求 / 服务端全量
/// 响应（JSON 载荷）/ 服务端仅音频（裸字节载荷）/ 错误。
const _volcTtsClientRequestType = 0x1;
const _volcTtsFullServerResponseType = 0x9;
const _volcTtsAudioOnlyServerType = 0xB;
const _volcTtsErrorType = 0xF;

/// byte2：序列化 JSON（高 4 位 0001）+ 无压缩（低 4 位 0000）。
const _volcTtsJsonNoCompression = 0x10;

/// 构造一帧客户端 JSON 事件：4 字节头 + 大端 u32 载荷长度 + 载荷。
/// 客户端事件按官方文档以载荷里的 EventType 字符串标识，头里不带
/// event 字段（推断假设，ADR 0019）。
Uint8List volcTtsJsonClientFrame(String jsonPayload) => (BytesBuilder(
  copy: false,
)
      ..add([_volcTtsHeaderByte0, _volcTtsClientRequestType << 4, _volcTtsJsonNoCompression, 0x00])
      ..add(u32BeBytes(utf8.encode(jsonPayload).length))
      ..add(utf8.encode(jsonPayload)))
    .takeBytes();

/// 解析一帧服务端消息（推断位域，ADR 0019）：header_size = byte0 低 4 位
/// ×4；flags 位 0 跳 4 字节序列号、位 2 跳 4 字节 event；随后按消息类型
/// 读大端 u32 载荷长度 + 载荷。解析失败一律按解析失败处理，不透出原始
/// 字节。
WsServerFrameAction parseVolcTtsServerFrame(List<int> frame) {
  TtsGatewayException parsingFailure() => const TtsGatewayException(
    kind: ModelFailureKind.contentParsing,
    message: '语音合成服务返回的内容无法解析。',
  );
  if (frame.length < 4) {
    throw parsingFailure();
  }
  final headerSize = (frame[0] & 0x0F) * 4;
  if (frame.length < headerSize + 4) {
    throw parsingFailure();
  }
  final messageType = frame[1] >> 4;
  final flags = frame[1] & 0x0F;
  var offset = headerSize;
  void skip(int count) {
    if (offset + count > frame.length) {
      throw parsingFailure();
    }
    offset += count;
  }

  if (flags & 0x01 != 0) {
    skip(4); // 序列号
  }
  int? headerEvent;
  if (flags & 0x04 != 0) {
    skip(4); // event 号
    headerEvent = readU32Be(frame, offset - 4);
  }

  switch (messageType) {
    case _volcTtsFullServerResponseType:
      skip(4);
      final payloadSize = readU32Be(frame, offset - 4);
      if (offset + payloadSize > frame.length) {
        throw parsingFailure();
      }
      final payload = frame.sublist(offset, offset + payloadSize);
      final Map<String, Object?> decoded;
      try {
        final parsed = jsonDecode(utf8.decode(payload));
        if (parsed is! Map<String, Object?>) {
          throw const FormatException('tts event must be an object');
        }
        decoded = parsed;
      } on Object {
        throw parsingFailure();
      }
      // 事件名优先取载荷里的 EventType 字符串（官方字段形态），缺失时
      // 回退推断的 header event 号。
      final eventType = decoded['EventType'];
      final name = eventType is String
          ? eventType
          : headerEvent == null
          ? null
          : _volcTtsEventNumberNames[headerEvent];
      if (name == null || name.isEmpty) {
        throw parsingFailure();
      }
      if (name == volcTtsEventConnectionFailed || name == volcTtsEventSessionFailed) {
        return WsErrorAction(
          const TtsGatewayException(
            kind: ModelFailureKind.provider,
            message: '语音合成服务拒绝了这次请求。',
          ),
        );
      }
      return WsEventAction(name);
    case _volcTtsAudioOnlyServerType:
      skip(4);
      final payloadSize = readU32Be(frame, offset - 4);
      // 与 JSON/错误帧同一口径：长度越界按解析失败拒——静默截断会让半截
      // PCM 播成噪音。
      if (offset + payloadSize > frame.length) {
        throw parsingFailure();
      }
      return WsAudioAction(
        Uint8List.fromList(frame.sublist(offset, offset + payloadSize)),
      );
    case _volcTtsErrorType:
      // error 帧：i32 错误码 + u32 消息长度 + UTF-8 消息（与豆包 ASR
      // 错误帧同族）；消息只用于分类，绝不透出。
      if (offset + 8 > frame.length) {
        throw parsingFailure();
      }
      return WsErrorAction(_volcTtsErrorFailure(readI32Be(frame, offset)));
    default:
      throw parsingFailure();
  }
}

/// error 帧错误码到允许列表文案的映射（与豆包 ASR 错误码同族，官方未
/// 给 TTS 侧码表，未识别码统一按服务拒绝）。
TtsGatewayException _volcTtsErrorFailure(int code) => switch (code) {
  55000031 => const TtsGatewayException(
    kind: ModelFailureKind.rateLimited,
    message: '语音合成服务请求过于频繁。',
  ),
  _ => const TtsGatewayException(
    kind: ModelFailureKind.provider,
    message: '语音合成服务拒绝了这次请求。',
  ),
};

final class _VolcBidirectionSession extends WsVoiceStreamSession {
  _VolcBidirectionSession({
    required ProviderWebSocketConnection connection,
    required this._sessionId,
    required this._startSessionParams,
    required this._sampleRate,
    required Duration timeout,
    required void Function(String message) diagnosticsSink,
  }) : super(connection, timeout, diagnosticsSink);

  final String _sessionId;
  final Map<String, Object?> _startSessionParams;
  final int _sampleRate;

  @override
  int get sampleRate => _sampleRate;

  @override
  Stream<dynamic> get frames => connection.messages;

  @override
  String get finishedEvent => volcTtsEventSessionFinished;

  @override
  WsServerFrameAction handleFrame(Object? frame) =>
      parseVolcTtsServerFrame(frame as List<int>);

  void sendStartConnection() {
    connection.send(
      volcTtsJsonClientFrame(
        jsonEncode({'EventType': volcTtsEventStartConnection}),
      ),
    );
  }

  void sendStartSession({required String sectionId}) {
    connection.send(
      volcTtsJsonClientFrame(
        jsonEncode({
          'EventType': volcTtsEventStartSession,
          'session_id': _sessionId,
          'req_params': {..._startSessionParams, 'section_id': sectionId},
        }),
      ),
    );
  }

  @override
  void sendAppend(String text) {
    connection.send(
      volcTtsJsonClientFrame(
        jsonEncode({
          'EventType': volcTtsEventTaskRequest,
          'session_id': _sessionId,
          'text': text,
        }),
      ),
    );
  }

  @override
  void sendFinish() {
    connection.send(
      volcTtsJsonClientFrame(
        jsonEncode({
          'EventType': volcTtsEventFinishSession,
          'session_id': _sessionId,
        }),
      ),
    );
  }

  @override
  void sendCancel() {
    connection.send(
      volcTtsJsonClientFrame(
        jsonEncode({
          'EventType': volcTtsEventCancelSession,
          'session_id': _sessionId,
        }),
      ),
    );
  }

  @override
  void teardown() {
    // 官方收尾顺序：会话结束后再结束连接。
    connection.send(
      volcTtsJsonClientFrame(
        jsonEncode({'EventType': volcTtsEventFinishConnection}),
      ),
    );
  }
}
