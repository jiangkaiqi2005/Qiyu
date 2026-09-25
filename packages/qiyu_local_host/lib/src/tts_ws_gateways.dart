import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'qwen_tts_gateway.dart';
import 'tts_gateway.dart';
import 'volc_seed_asr_gateway.dart';
import 'volc_tts_gateway.dart';

/// 连续喂文本的 WebSocket 合成网关（票三）：豆包双向流式（逐段发文本）
/// 与千问 Qwen-TTS Realtime（流式追加文本）两个协议。音频块走票二的
/// 搭车通道（[VoiceAudioChunk]），播放与降级语义不变。
///
/// 服务地址始终是用户在设置页填的 HTTP 端点，WS 地址由 Host 按协议派生
/// （host/port 保留，路径与 query 按协议写死）——地址栏不存在「两种
/// 含义」，试听、历史重听等整段路径不受传输选择影响。派生地址同样过
/// 出网 SSRF 校验（[ensureTtsOutboundAllow] 同律，复用同一判定）。

/// 千问 Realtime WS 型号判定（票三）：型号名以 `-realtime` 结尾即
/// Realtime API 家族（官方仅列 `qwen3-tts-flash-realtime` 与
/// `qwen3-tts-instruct-flash-realtime`），其余千问型号继续走 HTTP SSE
/// （型号驱动，ADR 0018）。
bool isQwenRealtimeTtsModel(String model) =>
    model.trim().toLowerCase().endsWith('-realtime');

/// WS 出网异常到本通道异常的映射（票三）：与豆包 ASR 网关同律（超时/
/// TLS/Socket/握手状态/未分类），文案说「语音合成服务」。只打异常类型
/// 不打消息——消息可能嵌着用户输入或第三方错误原文。
TtsGatewayException fromTtsWebSocketFailure(Object error) {
  if (error is TtsGatewayException) {
    return error;
  }
  if (error is TimeoutException) {
    return const TtsGatewayException(
      kind: ModelFailureKind.timeout,
      message: '连接语音合成服务超时。',
    );
  }
  if (error is HandshakeException) {
    return const TtsGatewayException(
      kind: ModelFailureKind.tls,
      message: '语音合成服务的 TLS 安全连接失败。',
    );
  }
  if (error is SocketException) {
    return fromTtsModelFailure(
      providerSocketFailure(error, serviceLabel: '语音合成服务'),
    );
  }
  if (error is WebSocketException) {
    final status = error.httpStatusCode;
    if (status != null && status != HttpStatus.switchingProtocols) {
      return fromTtsModelFailure(
        providerStatusFailure(status, '', serviceLabel: '语音合成服务'),
      );
    }
    return const TtsGatewayException(
      kind: ModelFailureKind.network,
      message: '无法连接语音合成服务。',
    );
  }
  stderrDiagnostics('tts ws unclassified exception: ${error.runtimeType}');
  return const TtsGatewayException(
    kind: ModelFailureKind.internal,
    message: '本机程序内部出错。',
  );
}

/// WS 会话生命周期的统一守护：建连、握手与收尾的异常一律经
/// [fromTtsWebSocketFailure] 说话，绝不让裸异常越过 Provider 层。
Future<T> guardTtsWebSocket<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on Object catch (error) {
    throw fromTtsWebSocketFailure(error);
  }
}

/// 一帧服务端消息的解析结果（票三）。
sealed class WsServerFrameAction {
  const WsServerFrameAction();
}

/// 音频块：裸 PCM 字节（豆包二进制帧）/ base64 解码后的 PCM（千问）。
final class WsAudioAction extends WsServerFrameAction {
  const WsAudioAction(this.bytes);

  final Uint8List bytes;
}

/// 服务端事件（按官方事件名登记：握手等待与终态判定都查它）。
final class WsEventAction extends WsServerFrameAction {
  const WsEventAction(this.name);

  final String name;
}

/// 服务端错误：已按允许列表映射，不透第三方原文。
final class WsErrorAction extends WsServerFrameAction {
  const WsErrorAction(this.failure);

  final TtsGatewayException failure;
}

/// WS 连续供给会话的公共骨架（票三）：读者循环从建连起持续消费服务端
/// 帧——协议各自的帧编解码经 [handleFrame] 交回，音频块进块流、控制
/// 事件登记供握手等待、终态事件收束块流。豆包（二进制帧）与千问
/// （JSON 文本帧）只差帧的编解码与事件名。
abstract class _WsVoiceStreamSession implements VoiceStreamSession {
  _WsVoiceStreamSession(this.connection, this.timeout, this._diagnosticsSink);

  final ProviderWebSocketConnection connection;

  /// 空闲超时预算：每帧重置，握手等待与收尾等待共用（与豆包 ASR 网关
  /// 的可注入超时同律，测试用小值验证超时降级）。
  final Duration timeout;
  final void Function(String message) _diagnosticsSink;

  final _chunks = StreamController<VoiceAudioChunk>();

  /// 已登记的服务端事件名：握手等待（awaitEvent）与终态判定都查它。用
  /// Set 而非 List——同一事件名重复到达（服务端重发、多分片）只登记一次，既是行为修正（去重后 contains 判定不受重复帧干扰）也让长连接下的查询保持 O(1)；登记顺序不影响判定（只查“出现过没有”）。
  final Set<String> _events = {};
  Completer<void>? _eventWaiter;
  TtsGatewayException? _failure;
  bool _ended = false;
  bool _cancelled = false;
  bool _finishSent = false;

  /// 会话中途的空闲计时器：握手完成后才武装（[armIdleTimer]），每来一
  /// 帧重置。握手阶段不挂它——两个计时器同时到点会把「连接超时」误报
  /// 成「响应超时」。
  Timer? _idleTimer;
  Timer? _deadlineTimer;
  bool _handshakeComplete = false;

  /// 协商采样率（块上标注，播放端按它初始化，不猜）。
  int get sampleRate;

  /// 服务端帧流：二进制协议取 [ProviderWebSocketConnection.messages]，
  /// JSON 文本协议取 [ProviderWebSocketConnection.textMessages]。
  Stream<dynamic> get frames;

  /// 正常终态事件名（音频已到齐，块流可以收束）。
  String get finishedEvent;

  /// 解析一帧服务端消息；解析失败抛 [TtsGatewayException]。
  WsServerFrameAction handleFrame(Object? frame);

  /// 协议层发送增量文本 / 收尾 / 取消（取消帧缺失的协议留空）。
  void sendAppend(String text);
  void sendFinish();
  void sendCancel();

  /// 正常收尾时的协议层道别（如豆包的 FinishConnection）：默认不发。
  void teardown() {}

  @override
  Stream<VoiceAudioChunk> get chunks => _chunks.stream;

  @override
  void appendText(String text) {
    if (text.isEmpty || _ended || _failure != null || _finishSent || _cancelled) {
      return;
    }
    try {
      sendAppend(text);
    } on Object catch (error) {
      // 连接已断：追加失败即本段语音结束（D1），绝不向上抛——文字链路
      // 不能被语音发送失败打断。
      _fail(fromTtsWebSocketFailure(error));
    }
  }

  @override
  Future<void> close() async {
    if (_finishSent || _ended || _failure != null || _cancelled) {
      return;
    }
    _finishSent = true;
    try {
      sendFinish();
    } on Object catch (error) {
      _fail(fromTtsWebSocketFailure(error));
    }
    // 结束/失败都经块流上报：close 本身不抛（分句层的 close 驱动点是
    // 同步的，失败由 D1 路径说话）。
  }

  @override
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    // 正常收尾/失败后不再发取消帧：连接已经断了，发出去只会留一条无意义
    // 的诊断噪音（停止与取消路径 _ended 为 false，仍会发，D1 与停止语义
    // 不变）。
    if (!_ended) {
      try {
        sendCancel();
      } on Object catch (error) {
        _diagnosticsSink('voice stream cancel failed [${error.runtimeType}]');
      }
    }
    // 作废：块流就此结束（管线已丢弃后续块），不按失败上报。
    _endStream(graceful: false);
    unawaited(_closeConnection());
  }

  /// 等待某个服务端事件登记（握手用）：失败与连接中断如实抛出，超时由
  /// 调用方包络（网关按各自的 [timeout] 预算等待）。
  Future<void> awaitEvent(String name) async {
    while (true) {
      if (_events.contains(name)) {
        return;
      }
      if (_failure case final failure?) {
        throw failure;
      }
      if (_ended) {
        throw const TtsGatewayException(
          kind: ModelFailureKind.network,
          message: '语音合成服务连接中断。',
        );
      }
      await (_eventWaiter ??= Completer<void>()).future;
    }
  }

  /// 启动读者循环（建连后立即开始，握手事件与音频都经它）。
  void startReader() {
    unawaited(_readLoop());
  }

  Future<void> _readLoop() async {
    try {
      await for (final frame in frames) {
        switch (handleFrame(frame)) {
          case WsAudioAction(:final bytes):
            // 空 PCM 块（纯容器头帧、0 长度音频载荷）不上屏：播放侧收
            // 0 字节块没有意义，三路径（会话/整段/流式）口径对齐（票 07
            // 评审收口）。
            if (bytes.isNotEmpty && !_ended && _failure == null && !_cancelled) {
              _chunks.add(VoiceAudioChunk(bytes: bytes, sampleRate: sampleRate));
            }
          case WsEventAction(:final name):
            _events.add(name);
            _notifyEvent();
            if (name == finishedEvent) {
              _endStream();
              return;
            }
          case WsErrorAction(:final failure):
            _fail(failure);
            return;
        }
        // 握手完成后每来一帧重置空闲计时器（半截音频不能当完整回复）。
        // 握手帧不武装它——握手等待自带预算，两个计时器同时到点会把
        // 「连接超时」误报成「响应超时」。
        if (_handshakeComplete) {
          armIdleTimer();
        }
      }
      // 连接在没有终态事件的情况下关闭：半截音频不能用（作废路径已在
      // cancel 里收束，不会走到这里）。
      _fail(
        const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务返回的音频不完整。',
        ),
      );
    } on Object catch (error) {
      _fail(fromTtsWebSocketFailure(error));
    }
  }

  /// 握手完成（网关在最后一道握手事件后调用）：武装会话中途的空闲计时器
  /// 与绝对截止计时器。空闲计时器每帧重置；绝对截止自此刻起有界——服务端
  /// 持续涓流却永不停发终态事件时，该轮 done 不能被无限期拖住（到点按会话
  /// 失败走 D1：文字不受影响、轮次正常收尾）。
  void onHandshakeComplete() {
    if (_handshakeComplete) {
      return;
    }
    _handshakeComplete = true;
    armIdleTimer();
    _deadlineTimer = Timer(timeout * _sessionDeadlineMultiplier, () {
      _fail(
        const TtsGatewayException(
          kind: ModelFailureKind.timeout,
          message: '语音合成服务响应超时。',
        ),
      );
    });
  }

  /// 绝对截止相对于空闲预算的倍数：空闲预算 60s，绝对截止 10 分钟——
  /// 远大于正常轮次（栖语「默认少说」），又不把用户锁死在涓流会话上。
  static const _sessionDeadlineMultiplier = 10;

  /// 武装/重置会话中途的空闲计时器（握手成功后由网关调用，之后每帧重置）。
  void armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(timeout, () {
      _fail(
        const TtsGatewayException(
          kind: ModelFailureKind.timeout,
          message: '语音合成服务响应超时。',
        ),
      );
    });
  }

  void _disarmTimers() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
  }

  void _endStream({bool graceful = true}) {
    if (_ended) {
      return;
    }
    _ended = true;
    if (graceful) {
      try {
        teardown();
      } on Object catch (error) {
        _diagnosticsSink('voice stream teardown failed [${error.runtimeType}]');
      }
    }
    // 唤醒可能在等事件的握手：失败与中断都由 awaitEvent 如实抛出。
    _notifyEvent();
    _disarmTimers();
    unawaited(_closeConnection());
    unawaited(_chunks.close());
  }

  void _fail(TtsGatewayException failure) {
    if (_ended) {
      return;
    }
    _ended = true;
    _failure = failure;
    _diagnosticsSink('voice stream session failed [${failure.kind.name}]');
    _notifyEvent();
    _disarmTimers();
    unawaited(_closeConnection());
    _chunks.addError(failure);
    unawaited(_chunks.close());
  }

  Future<void> _closeConnection() async {
    try {
      await connection.close();
    } on Object catch (error) {
      _diagnosticsSink('voice stream close failed [${error.runtimeType}]');
    }
  }

  void _notifyEvent() {
    final waiter = _eventWaiter;
    _eventWaiter = null;
    waiter?.complete();
  }
}

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
      ..add(_u32Be(utf8.encode(jsonPayload).length))
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
    headerEvent = _readU32Be(frame, offset - 4);
  }

  switch (messageType) {
    case _volcTtsFullServerResponseType:
      skip(4);
      final payloadSize = _readU32Be(frame, offset - 4);
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
      final payloadSize = _readU32Be(frame, offset - 4);
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
      return WsErrorAction(_volcTtsErrorFailure(_readI32Be(frame, offset)));
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

final class _VolcBidirectionSession extends _WsVoiceStreamSession {
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

// ---------------------------------------------------------------------------
// 千问 Qwen-TTS Realtime（阿里云百炼）
// ---------------------------------------------------------------------------

/// 千问 Realtime WS 合成网关（票三）：官方 Realtime 风格 JSON 事件协议，
/// 端点 `wss://<host>/api-ws/v1/realtime?model=<型号>`。流式追加文本
/// （`input_text_buffer.append`），`server_commit` 分段模式由服务端决定
/// 合成时机；PCM delta 事件（base64）转块。
///
/// realtime 型号没有 HTTP 整段接口：整段路径（试听、历史重听、连接测试）
/// 开一个一次性会话收完整 PCM，在 Host 本地包 WAV 头后走既有整段播放器。
///
/// 注意：本协议不吃 extraParams（音色走 session.update 的 voice 字段，
/// 没有 instructions 类控制字段的文档入口）——用户在高级参数里给千问
/// realtime 档写的字段不会生效，写不写都不报错。
final class QwenRealtimeTtsGateway
    implements TtsSynthesisGateway, VoiceStreamSessionGateway {
  QwenRealtimeTtsGateway(this.connector, {this.timeout = ttsRequestTimeout});

  final ProviderWebSocketConnector connector;

  /// 空闲超时预算：含握手、音频间隔与收尾等待。
  final Duration timeout;

  /// 派生 WS 地址：baseUrl 是 DashScope HTTP 端点，host/port 保留，路径
  /// 与 model query 按协议写死。http→ws、https→wss。
  static Uri deriveWebSocketUri(TtsConfig config) {
    final base = Uri.parse(config.baseUrl.trim());
    return Uri(
      scheme: base.scheme == 'http' ? 'ws' : 'wss',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/api-ws/v1/realtime',
      queryParameters: {'model': config.model.trim()},
    );
  }

  @override
  Future<VoiceStreamSession?> openSession({
    required TtsConfig config,
    required String? apiKey,
    required String sessionId,
  }) async => _openSession(config: config, apiKey: apiKey);

  Future<_QwenRealtimeSession> _openSession({
    required TtsConfig config,
    required String? apiKey,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = deriveWebSocketUri(config);
    // 派生出的 WS 地址同样过出网校验（与 HTTP 出网同律）。
    ensureTtsOutboundAllowed(uri);
    return guardTtsWebSocket(() async {
      // 建连也包超时（与豆包双向同律）：端点不响应时上界不能只剩 OS/
      // dart:io 默认值。
      final connection = await connector
          .connect(uri: uri, headers: {'authorization': 'Bearer $key'})
          .timeout(timeout);
      final session = _QwenRealtimeSession(
        connection: connection,
        config: config,
        timeout: timeout,
        diagnosticsSink: stderrDiagnostics,
      );
      session.startReader();
      try {
        // 官方生命周期：建连后服务端先回 session.created，客户端再发
        // session.update 配置音色/格式/分段模式。
        await session
            .awaitEvent(qwenRealtimeEventSessionCreated)
            .timeout(timeout);
        session.sendSessionUpdate();
        // 握手完成：会话中途的空闲计时器这才武装（每帧重置）。
        session.onHandshakeComplete();
      } on Object catch (error) {
        session.cancel();
        throw fromTtsWebSocketFailure(error);
      }
      return session;
    });
  }

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    // realtime 型号没有 HTTP 整段接口：一次性会话收完整 PCM，本地包
    // WAV 头（现有整段播放器零改动）。
    final session = await _openSession(config: config, apiKey: apiKey);
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
      return wrapPcmAsWav(bytes, sampleRate: qwenTtsPcmSampleRate);
    } finally {
      session.cancel();
    }
  }
}

/// 千问 Realtime 客户端事件名（官方文档 type 字段值）。
const qwenRealtimeEventSessionUpdate = 'session.update';
const qwenRealtimeEventInputTextBufferAppend = 'input_text_buffer.append';
const qwenRealtimeEventSessionFinish = 'session.finish';

/// 千问 Realtime 服务端事件名（官方文档 type 字段值）。
const qwenRealtimeEventSessionCreated = 'session.created';
const qwenRealtimeEventAudioDelta = 'response.audio.delta';
const qwenRealtimeEventSessionFinished = 'session.finished';

final class _QwenRealtimeSession extends _WsVoiceStreamSession {
  _QwenRealtimeSession({
    required ProviderWebSocketConnection connection,
    required this._config,
    required Duration timeout,
    required void Function(String message) diagnosticsSink,
  }) : super(connection, timeout, diagnosticsSink);

  final TtsConfig _config;

  @override
  int get sampleRate => qwenTtsPcmSampleRate;

  @override
  Stream<dynamic> get frames => connection.textMessages;

  @override
  String get finishedEvent => qwenRealtimeEventSessionFinished;

  @override
  WsServerFrameAction handleFrame(Object? frame) {
    final Map<String, Object?> event;
    try {
      final decoded = jsonDecode(frame as String);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('realtime event must be an object');
      }
      event = decoded;
    } on Object {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
    final type = event['type'];
    if (type is! String) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
    if (type == qwenRealtimeEventAudioDelta) {
      final delta = event['delta'];
      if (delta is! String || delta.isEmpty) {
        return WsEventAction(type);
      }
      try {
        return WsAudioAction(base64.decode(delta));
      } on Object {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务返回的内容无法解析。',
        );
      }
    }
    // 错误事件按允许列表文案映射（鉴权/限流/服务拒绝），不透第三方原文。
    // 事件名官方未给全表，按 Realtime 家族常见形态识别（推断，ADR 0019）。
    if (type == 'error' || type.endsWith('failed')) {
      return WsErrorAction(_qwenErrorFailure(event));
    }
    return WsEventAction(type);
  }

  void sendSessionUpdate() {
    final voice = _config.voice?.trim();
    connection.sendText(
      jsonEncode({
        'type': qwenRealtimeEventSessionUpdate,
        'session': {
          // 服务端决定分段与合成时机：边喂文本边出音（票三目标形态）。
          'mode': 'server_commit',
          'voice': (voice == null || voice.isEmpty)
              ? qwenTtsDefaultVoice
              : voice,
          'language_type': 'Chinese',
          'response_format': 'pcm',
          'sample_rate': qwenTtsPcmSampleRate,
        },
      }),
    );
  }

  @override
  void sendAppend(String text) {
    connection.sendText(
      jsonEncode({
        'type': qwenRealtimeEventInputTextBufferAppend,
        'text': text,
      }),
    );
  }

  @override
  void sendFinish() {
    connection.sendText(jsonEncode({'type': qwenRealtimeEventSessionFinish}));
  }

  @override
  void sendCancel() {
    // 协议没有会话取消事件：断开连接即作废（基类负责断链）。
  }
}

/// 千问 Realtime 错误事件的允许列表映射：鉴权/限流/服务拒绝三档，第三
/// 方错误原文绝不透出。
TtsGatewayException _qwenErrorFailure(Map<String, Object?> event) {
  final error = event['error'];
  final code = error is Map<String, Object?> ? error['code'] : null;
  if (code is String) {
    final normalized = code.toLowerCase();
    if (normalized.contains('auth') ||
        normalized.contains('api_key') ||
        normalized.contains('permission')) {
      return const TtsGatewayException(
        kind: ModelFailureKind.authentication,
        message: 'API Key 未通过语音合成服务验证。',
      );
    }
    if (normalized.contains('rate') ||
        normalized.contains('quota') ||
        normalized.contains('limit') ||
        normalized.contains('throttl')) {
      return const TtsGatewayException(
        kind: ModelFailureKind.rateLimited,
        message: '语音合成服务请求过于频繁。',
      );
    }
  }
  return const TtsGatewayException(
    kind: ModelFailureKind.provider,
    message: '语音合成服务拒绝了这次请求。',
  );
}

// ---------------------------------------------------------------------------
// 千问 DashScope 经典 WS 推理（SpeechSynthesizer，票 07）
// ---------------------------------------------------------------------------

/// DashScope 经典推理协议（SpeechSynthesizer）的客户端动作名（官方文档
/// header.action 字段值，probe 02 实测形状）。
const qwenWsInferenceActionRunTask = 'run-task';
const qwenWsInferenceActionContinueTask = 'continue-task';
const qwenWsInferenceActionFinishTask = 'finish-task';

/// DashScope 经典推理协议的服务端事件名（官方文档 header.event 字段值）。
const qwenWsInferenceEventTaskStarted = 'task-started';
const qwenWsInferenceEventTaskFinished = 'task-finished';
const qwenWsInferenceEventTaskFailed = 'task-failed';

/// 经典推理端点的默认路径：用户填的地址缺路径（`wss://host`）时补上，
/// 路径齐全的地址原样使用（服务商自建网关的路径不一，Host 不改写）。
const qwenWsInferenceDefaultPath = '/api-ws/v1/inference';

/// 文本与二进制两路帧流的合并视图：DashScope 经典推理的控制事件走 JSON
/// 文本帧、音频走二进制帧，两路同源于一条 WebSocket 连接（豆包把两者
/// 复用在二进制流里、千问 Realtime 只有文本，本协议是第一条需要两路
/// 同听的）。单订阅转发——会话读循环是唯一消费者；两路都结束（连接
/// 关闭）后合并流才结束，错误原样转发由读循环按既有分类说话。
Stream<dynamic> mergeWsFrameStreams(Stream<dynamic> text, Stream<dynamic> binary) {
  late final StreamController<dynamic> controller;
  final subscriptions = <StreamSubscription<dynamic>>[];
  var open = 2;
  void onDone() {
    open -= 1;
    if (open == 0 && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  controller = StreamController<dynamic>(
    onListen: () {
      subscriptions
        ..add(
          text.listen(
            controller.add,
            onError: controller.addError,
            onDone: onDone,
          ),
        )
        ..add(
          binary.listen(
            controller.add,
            onError: controller.addError,
            onDone: onDone,
          ),
        );
    },
    onPause: () {
      for (final subscription in subscriptions) {
        subscription.pause();
      }
    },
    onResume: () {
      for (final subscription in subscriptions) {
        subscription.resume();
      }
    },
    onCancel: () {
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
    },
  );
  return controller.stream;
}

/// task-failed 的允许列表映射（票 07）：错误码只用于分类，第三方错误
/// 原文绝不透出。auth/rate 指纹沿用千问 Realtime 错误事件的口径，
/// ModelNotFound 是该协议的结构化信号（probe 1.1 实测形状），按既有
/// 「找不到模型」分类说话——不新增分类与错误码，其余一律按服务拒绝。
TtsGatewayException _qwenInferenceTaskFailedFailure(Map<String, Object?> event) {
  final header = event['header'];
  final code = header is Map<String, Object?> ? header['error_code'] : null;
  if (code is String) {
    final normalized = code.toLowerCase();
    if (normalized.contains('modelnotfound')) {
      return const TtsGatewayException(
        kind: ModelFailureKind.modelNotFound,
        message: '找不到这个模型，请检查模型名称。',
      );
    }
    if (normalized.contains('auth') ||
        normalized.contains('api_key') ||
        normalized.contains('permission')) {
      return const TtsGatewayException(
        kind: ModelFailureKind.authentication,
        message: 'API Key 未通过语音合成服务验证。',
      );
    }
    if (normalized.contains('rate') ||
        normalized.contains('quota') ||
        normalized.contains('limit') ||
        normalized.contains('throttl')) {
      return const TtsGatewayException(
        kind: ModelFailureKind.rateLimited,
        message: '语音合成服务请求过于频繁。',
      );
    }
  }
  return const TtsGatewayException(
    kind: ModelFailureKind.provider,
    message: '语音合成服务拒绝了这次请求。',
  );
}

/// 千问 DashScope 经典 WS 推理合成网关（票 07，ADR 0020 补篇）：官方
/// SpeechSynthesizer 协议，端点 `wss://…/api-ws/v1/inference`。地址即
/// 用户在设置页填的完整 ws/wss 端点（路径空缺时补默认推理路径，不再由
/// Host 派生——服务商网关路径不一）。生命周期：run-task → task-started
/// → continue-task（流式按 ADR 0019 增量喂文本）→ finish-task →
/// task-finished 收束；音频走 binary 帧，实测每帧自带完整 WAV 容器头
/// （probe 02/03 基线形状），按既有剥头口径归一成裸 PCM——整段路径拼
/// PCM 后在 Host 包一次 WAV 头，流式路径按既有 PCM 块通道交付。
///
/// 3.1（qwen-audio-3.1-tts-flash）服务端引擎层稳定故障（Engine error
/// 411，probe 02/03 实测），与本网关实现无关：如实按 task-failed 的
/// 既有分类报错，不做特殊处理。
final class QwenWsInferenceTtsGateway
    implements
        TtsSynthesisGateway,
        TtsStreamSynthesisGateway,
        VoiceStreamSessionGateway {
  QwenWsInferenceTtsGateway(this.connector, {this.timeout = ttsRequestTimeout});

  final ProviderWebSocketConnector connector;

  /// 空闲超时预算：含建连、握手、音频间隔与收尾等待（与豆包/千问
  /// Realtime 网关同律，测试用小值验证超时降级）。
  final Duration timeout;

  /// 推理地址：用户填的完整 ws/wss 端点，host/port/path/query 原样
  /// 保留，只在路径空缺时补默认推理路径。
  static Uri resolveInferenceUri(TtsConfig config) {
    final base = Uri.parse(config.baseUrl.trim());
    final path = base.path.isEmpty || base.path == '/'
        ? qwenWsInferenceDefaultPath
        : base.path;
    return base.replace(path: path);
  }

  /// run-task 的 payload（官方文档逐字段，probe 02 实测）：task_group/
  /// task/function 固定，音色空缺回落本家族官方示例音色，format/
  /// sample_rate 缺省 wav/24000（与票 02 maas 形状同律）；高级参数深
  /// 合并进 parameters——用户显式写的字段覆盖缺省。
  static Map<String, Object?> runTaskPayload(TtsConfig config) {
    final voice = config.voice?.trim();
    final parameters = <String, Object?>{
      'text_type': 'PlainText',
      'voice': voice == null || voice.isEmpty ? qwenTtsMaasDefaultVoice : voice,
      'format': 'wav',
      'sample_rate': qwenTtsPcmSampleRate,
    };
    final extra = config.extraParams;
    return {
      'task_group': 'audio',
      'task': 'tts',
      'function': 'SpeechSynthesizer',
      'model': config.model.trim(),
      'parameters':
          extra == null ? parameters : mergeTtsExtraIntoInput(parameters, extra),
      'input': <String, Object?>{},
    };
  }

  /// 协商采样率（块上标注，播放端按它初始化）：parameters 里经高级参数
  /// 覆盖后的生效值，缺省 24kHz——请求送的就是它，服务端 WAV 帧头与
  /// 之一致（probe 基线）。
  static int negotiatedSampleRate(TtsConfig config) =>
      switch (runTaskPayload(config)['parameters']) {
        final Map parameters =>
          switch (parameters['sample_rate']) {
            final num rate => rate.toInt(),
            _ => qwenTtsPcmSampleRate,
          },
        _ => qwenTtsPcmSampleRate,
      };

  /// 压缩格式覆盖的 E1 守卫（票 07 评审收口）：高级参数可把
  /// parameters.format 覆盖成 mp3/opus（官方协议支持），此后 binary 帧
  /// 是压缩字节——流式被当 PCM 播噪音、整段被包出无效 WAV。与豆包网关
  /// isStreamablePcm 同律对深合并后的生效 format 判定，只放行 wav/pcm
  /// （wav 帧剥头即裸 PCM，pcm 帧原样透传）；本通道没有 HTTP 回落（地址
  /// 即 WS 端点），压缩值在开会话/合成入口按人话拒绝、不出网。
  static bool isDeliverableAudioFormat(TtsConfig config) =>
      switch (runTaskPayload(config)['parameters']) {
        final Map parameters => switch (parameters['format']) {
          final String format =>
            switch (format.trim().toLowerCase()) {
              'wav' || 'pcm' => true,
              _ => false,
            },
          // 非字符串 format 属脏参数，交给服务端参数校验说话。
          _ => true,
        },
        _ => true,
      };

  @override
  Future<VoiceStreamSession?> openSession({
    required TtsConfig config,
    required String? apiKey,
    required String sessionId,
  }) async => _openSession(config: config, apiKey: apiKey);

  Future<_QwenWsInferenceSession> _openSession({
    required TtsConfig config,
    required String? apiKey,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    // E1 守卫（与豆包网关 isStreamablePcm 同律）：压缩格式覆盖在本通道
    // 交付不了，出网前按人话拒绝——连接子一个字节都不发。
    if (!isDeliverableAudioFormat(config)) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.provider,
        message: '高级参数把音频格式覆盖成了压缩格式，本通道只支持 wav 或 '
            'pcm，请改回后再试。',
      );
    }
    final uri = resolveInferenceUri(config);
    // 用户填的 WS 地址照常过出网 SSRF 校验（与派生地址同律）。
    ensureTtsOutboundAllowed(uri);
    return guardTtsWebSocket(() async {
      // 建连也包超时（与豆包双向/千问 Realtime 同律）：端点不响应时
      // 上界不能只剩 OS/dart:io 默认值。
      final connection = await connector
          .connect(uri: uri, headers: {'authorization': 'Bearer $key'})
          .timeout(timeout);
      final session = _QwenWsInferenceSession(
        connection: connection,
        taskId: newVolcRequestId(),
        runTaskPayload: runTaskPayload(config),
        sampleRate: negotiatedSampleRate(config),
        timeout: timeout,
        diagnosticsSink: stderrDiagnostics,
      );
      session.startReader();
      try {
        // 官方生命周期：run-task 先行，服务端 task-started 后才喂文本
        // （probe 实测 run-task 与 task-started 之间的合法等待形状）。
        session.sendRunTask();
        await session
            .awaitEvent(qwenWsInferenceEventTaskStarted)
            .timeout(timeout);
        // 握手完成：会话中途的空闲计时器这才武装（每帧重置）。
        session.onHandshakeComplete();
      } on Object catch (error) {
        session.cancel();
        throw fromTtsWebSocketFailure(error);
      }
      return session;
    });
  }

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    // 一次性会话收完整 PCM，本地包 WAV 头（现有整段播放器零改动）。
    final session = await _openSession(config: config, apiKey: apiKey);
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
      return wrapPcmAsWav(bytes, sampleRate: negotiatedSampleRate(config));
    } finally {
      session.cancel();
    }
  }

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async* {
    // 句子级流式：本句开一个一次性会话，binary 帧边到边转 PCM 块（帧
    // 已剥 WAV 头），不等整句合成完——与现行千问 SSE 档的按句流式同
    // 口径。失败经块流的错误上报，由分句层按 D1 降级。
    final session = await _openSession(config: config, apiKey: apiKey);
    try {
      session.appendText(text);
      await session.close();
      var produced = false;
      // 空 PCM 块已在会话读循环统一跳过（纯容器头帧不上屏）。
      await for (final chunk in session.chunks) {
        produced = true;
        yield chunk;
      }
      if (!produced) {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务没有返回音频。',
        );
      }
    } finally {
      session.cancel();
    }
  }
}

final class _QwenWsInferenceSession extends _WsVoiceStreamSession {
  _QwenWsInferenceSession({
    required ProviderWebSocketConnection connection,
    required this._taskId,
    required this._runTaskPayload,
    required this._sampleRate,
    required Duration timeout,
    required void Function(String message) diagnosticsSink,
  }) : super(connection, timeout, diagnosticsSink);

  final String _taskId;
  final Map<String, Object?> _runTaskPayload;
  final int _sampleRate;

  @override
  int get sampleRate => _sampleRate;

  @override
  Stream<dynamic> get frames => _frames ??= mergeWsFrameStreams(
    connection.textMessages,
    connection.messages,
  );

  Stream<dynamic>? _frames;

  @override
  String get finishedEvent => qwenWsInferenceEventTaskFinished;

  @override
  WsServerFrameAction handleFrame(Object? frame) => switch (frame) {
    final String text => _handleTextEvent(text),
    final List<int> audio => _handleAudioFrame(audio),
    _ => throw const TtsGatewayException(
      kind: ModelFailureKind.contentParsing,
      message: '语音合成服务返回的内容无法解析。',
    ),
  };

  /// 服务端事件（JSON 文本帧）：header.event 命名；task-failed 按允许
  /// 列表映射，其余事件登记（task-started 供握手等待、task-finished
  /// 由基类收束块流），result-generated 等中间事件不参与判定。
  WsServerFrameAction _handleTextEvent(String text) {
    final Map<String, Object?> event;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('inference event must be an object');
      }
      event = decoded;
    } on TtsGatewayException {
      rethrow;
    } on Object {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
    final header = event['header'];
    final name = header is Map<String, Object?> ? header['event'] : null;
    if (name is! String || name.isEmpty) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
    if (name == qwenWsInferenceEventTaskFailed) {
      return WsErrorAction(_qwenInferenceTaskFailedFailure(event));
    }
    return WsEventAction(name);
  }

  /// 音频帧（binary）：实测每帧自带完整 WAV 容器头（probe 02/03），按
  /// 既有剥头口径归一成裸 PCM；裸样本帧（用户经高级参数覆盖 format=pcm）
  /// 不以 RIFF 开头，原样通过。
  WsServerFrameAction _handleAudioFrame(List<int> audio) =>
      WsAudioAction(qwenTtsNormalizeWavChunk(Uint8List.fromList(audio)).pcm);

  void sendRunTask() => _sendAction(qwenWsInferenceActionRunTask, _runTaskPayload);

  @override
  void sendAppend(String text) => _sendAction(qwenWsInferenceActionContinueTask, {
    'input': {'text': text},
  });

  @override
  void sendFinish() =>
      _sendAction(qwenWsInferenceActionFinishTask, {'input': <String, Object?>{}});

  @override
  void sendCancel() =>
      // 协议取消：finish-task 带 directive=cancel（官方文档字段值）。
      _sendAction(qwenWsInferenceActionFinishTask, {
        'input': {'directive': 'cancel'},
      });

  void _sendAction(String action, Map<String, Object?> payload) {
    connection.sendText(
      jsonEncode({
        'header': {
          'action': action,
          'task_id': _taskId,
          'streaming': 'duplex',
        },
        'payload': payload,
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// 帧编解码共用小工具（与豆包 ASR 网关的字节序口径一致）
// ---------------------------------------------------------------------------

Uint8List _u32Be(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

int _readU32Be(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _readI32Be(List<int> bytes, int offset) {
  final raw = _readU32Be(bytes, offset);
  return raw >= 0x80000000 ? raw - 0x100000000 : raw;
}
