import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../settings/provider_settings_client.dart';
import 'local_chat_view_model.dart';
import 'voice_capture_platform.dart';
import 'voice_player_platform.dart';

/// 前端侧的 Omni 通话阶段（与 Host `state` 事件的 phase 同名同义；
/// 不 import Host 包——本文件必须留在 web 构建里）。
enum OmniCallPhase { idle, connecting, active, reconnecting, ended }

/// 通话没能开始的原因（composer 据此取面向用户的话术，spec:18）。
enum OmniCallStartupFailure { notReady, micUnavailable, connectFailed }

/// 通话显示面的最小接缝（[LocalChatViewModel] 实现）：通话事件进入
/// 普通聊天流（T04:7），复用既有的气泡、流式行与贴底逻辑，不建第二套
/// 消息列表。
abstract interface class OmniCallChatSurface {
  /// 通话开始：清掉上次通话可能残留的显示态。
  void callSessionReset();

  /// 一条用户轮进入消息流（打字轮即真；语音轮以输入转录入列，
  /// 同 requestId 的后到转录整段覆盖——completed 事件是权威全文）。
  void callUserTurn({required String requestId, required String text});

  /// 通话回复增量：进入流式行。
  void callReplyDelta(String text);

  /// 一条回复终态：已显示文本落成气泡；未完成轮如实标记（spec:20）。
  /// 打断（status=cancelled）与失败/超时是两种标记，分别对应
  /// 「被打断」与「未完成」。
  void callReplyDone({required bool incomplete, required bool interrupted});

  /// 通话结束后的落盘对账：从 Host 重新恢复会话快照，以落盘事实
  /// 替换显示态（乐观消息、断连期间的漂移都在这里归真）。
  Future<void> resyncAfterCall();
}

/// 通话 WebSocket 的最小接缝：测试注入 fake，生产走
/// [WebSocketChannel]。
abstract interface class OmniCallSocket {
  /// 文本帧流；连接断开即 done（或 error）。
  Stream<String> get stream;

  /// 连接就绪（握手完成）；失败即抛，调用方按「没能接通」处理。
  Future<void> get ready;

  void send(String frame);

  Future<void> close();
}

typedef OmniCallSocketConnector = OmniCallSocket Function(Uri uri);

/// Omni 双工通话的前端控制器（T04）：一条到 Host `api/omni/call` 的
/// WebSocket 承载上行采集与下行事件。凭据全程留在 Host，前端只看得到
/// 通话状态与文字/音频事件；双方音频只在内存流转（spec:58、spec:78）。
///
/// 线协议（Host 侧 OmniCallRoutes 定档）：
/// - 上行：`start`（首帧）→ `audio`（base64 PCM16 16k）／`text`／
///   `mute`／`end`。
/// - 下行：`state`（phase/reason）、`speechStarted`、`speechStopped`、
///   `inputTranscript`（turnId+权威全文）、`replyDelta`、`replyDone`
///   （status/incomplete，以 `response.done` 的 status 为准，T01 §13）、
///   `audio`（turnId + base64 PCM16 24k）。
///
/// 打断语义（T04:15）：`speechStarted` 即停播清队列，被取消轮进入
/// 死轮集合，其后到的事件（音频/文字）一律丢弃；Provider 终态以
/// `replyDone` 为准，本机播放器播完只用来收「栖语在说话」的指示。
final class OmniCallController extends ChangeNotifier {
  OmniCallController({
    required this._surface,
    required this._providerSettings,
    VoiceCapturePlatform? capture,
    StreamingVoicePlayerPlatform? player,
    OmniCallSocketConnector? connector,
    this._baseUri,
    String Function()? requestIdFactory,
  }) : _capture = capture ?? createVoiceCapturePlatform(),
       _player = player ?? _resolveStreamingPlayer(),
       _connector = connector ?? _defaultConnector,
       _requestIdFactory = requestIdFactory ?? _defaultRequestId;

  final OmniCallChatSurface _surface;
  final ProviderSettingsGateway _providerSettings;
  final VoiceCapturePlatform _capture;
  final StreamingVoicePlayerPlatform? _player;
  final OmniCallSocketConnector _connector;
  final Uri? _baseUri;
  final String Function() _requestIdFactory;

  OmniCallPhase _phase = OmniCallPhase.idle;
  String? _phaseReason;
  bool _muted = false;
  bool _omniReady = false;
  OmniCallStartupFailure? _startupFailure;
  bool _userSpeaking = false;
  bool _qiyuSpeaking = false;
  bool _disposed = false;

  VoiceCaptureSession? _captureSession;
  OmniCallSocket? _socket;
  StreamSubscription<String>? _socketSubscription;

  /// 当前 socket 的 done 信号：挂断后的对账等 Host 收尾落盘完再跑。
  Completer<void>? _socketDone;

  /// 本通通话开始时的会话（通话写进同一段会话，转录进入普通聊天流）。
  String? _callSessionId;

  /// 建连／重连窗口内积攒的上行块（窗口里的开口不丢），上限约 10 秒，
  /// 超出丢最旧——宁可少一声，不让内存无界。
  final List<Uint8List> _uplinkBuffer = [];
  static const int _uplinkBufferByteLimit = 16000 * 2 * 10;

  // ---- 下行播放 ----

  /// 官方默认输出 24 kHz PCM（spec:71，session 输出档 pcm24 已实测）。
  static const int playbackSampleRate = 24000;

  VoiceStreamPlayback? _playback;
  String? _playbackTurnId;
  bool _playbackClosed = true;
  bool _playbackOpening = false;
  final List<Uint8List> _pendingPlaybackChunks = [];

  /// 已终止轮（取消/失败/被打断）：其一切后到事件不再播放、不再追加
  /// 文字（T04:15 旧事件按轮次隔离）。
  final Set<String> _deadTurns = {};

  OmniCallPhase get phase => _phase;
  String? get phaseReason => _phaseReason;
  bool get muted => _muted;

  /// 通话进行中（含接通与重连窗口）：入口与跨页通话条据此显隐；
  /// ended 不是进行中——它只描述「上一通已结束」。
  bool get callInProgress =>
      _phase == OmniCallPhase.connecting ||
      _phase == OmniCallPhase.active ||
      _phase == OmniCallPhase.reconnecting;

  /// 选中 Omni 且凭据齐备：电话入口的显隐依据（T04:16 无需先配 TTS）。
  bool get omniReady => _omniReady;

  /// 当前平台是否具备连续采集能力：不具备（安卓 T05 之前）时不替换
  /// 原录音入口，非 Omni 与未就绪平台的 UI 保持现状。
  bool get captureSupported => _capture.supported;

  OmniCallStartupFailure? get startupFailure => _startupFailure;
  bool get userSpeaking => _userSpeaking;
  bool get qiyuSpeaking => _qiyuSpeaking;

  /// 通话中打字的分流判据（composer 发送起点据此改走通话线协议）。
  bool get acceptsTypedText => _phase == OmniCallPhase.active;

  /// 用户手势同步阶段调用（spec:46 二期事实的前置件）：点击「拨通」
  /// 的同一调用栈里恢复音频输出许可，首块下行音频才有得播。
  void prepareForUserGesture() {
    if (_player case final UserGestureVoicePlayerPlatform player) {
      player.prepareForPlayback();
    }
  }

  /// 刷新「选中 Omni 且已配置」判定（挂载、回页、通话结束后调用；
  /// 通话中的配置切换由 Host 断旧连接兜底，T03:16）。
  Future<void> refreshAvailability() async {
    bool ready = false;
    try {
      final settings = await _providerSettings.read();
      ready = settings.configured &&
          settings.keySet &&
          settings.provider == ProviderKind.qwenOmniRealtime;
    } on Object {
      ready = false;
    }
    if (_omniReady != ready) {
      _omniReady = ready;
      _notify();
    }
  }

  // -------------------------------------------------------------------------
  // 通话生命周期
  // -------------------------------------------------------------------------

  /// 开始一通通话：申请麦克风 → 连接 Host 通话口 → 发 start 首帧。
  /// 返回是否进入接通流程；失败置 [startupFailure] 并回到空闲，
  /// 不抛异常、不偷偷重试（T04:17）。
  Future<bool> startCall({String? sessionId}) async {
    if (callInProgress || _disposed) {
      return false;
    }
    _startupFailure = null;
    if (!_omniReady) {
      _startupFailure = OmniCallStartupFailure.notReady;
      _notify();
      return false;
    }
    _callSessionId = sessionId;
    _deadTurns.clear();
    _teardownPlayback();
    _uplinkBuffer.clear();
    _muted = false;
    _userSpeaking = false;
    _qiyuSpeaking = false;
    _surface.callSessionReset();
    _setPhase(OmniCallPhase.connecting, reason: null);
    final session = await _capture.start(
      onChunk: _onCaptureChunk,
      onUnavailable: _onCaptureUnavailable,
    );
    if (_phase != OmniCallPhase.connecting || _disposed) {
      // 采集等待期间通话已被结束（挂断连点）：收掉采集，不继续接通。
      session?.stop();
      return false;
    }
    if (session == null) {
      _setPhase(OmniCallPhase.idle, reason: null);
      _startupFailure = OmniCallStartupFailure.micUnavailable;
      _notify();
      return false;
    }
    _captureSession = session;
    final OmniCallSocket socket;
    try {
      socket = _connector(_resolveCallUri());
      await socket.ready;
    } on Object {
      await _teardownSocket();
      await _stopCapture();
      _setPhase(OmniCallPhase.idle, reason: null);
      _startupFailure = OmniCallStartupFailure.connectFailed;
      _notify();
      return false;
    }
    if (_phase != OmniCallPhase.connecting || _disposed) {
      await socket.close();
      await _stopCapture();
      return false;
    }
    _socket = socket;
    _socketDone = Completer<void>();
    _socketSubscription = socket.stream.listen(
      _onFrame,
      onDone: () {
        final done = _socketDone;
        if (done != null && !done.isCompleted) {
          done.complete();
        }
        _onSocketDone();
      },
      onError: (Object _) {
        final done = _socketDone;
        if (done != null && !done.isCompleted) {
          done.complete();
        }
        _onSocketDone();
      },
      cancelOnError: true,
    );
    socket.send(jsonEncode({'type': 'start', 'sessionId': ?_callSessionId}));
    return true;
  }

  /// 挂断（spec:24 明确结束）：立即停麦、停声、撤等待；Host 侧按 end
  /// 帧收尾落盘后推 ended 并关连接，对账在其后执行。结束 reason 与
  /// Host stopCall 的缺省同键（omni_call_service.dart），en 会话由
  /// localizeStatus 映射。
  Future<void> end() async {
    if (!callInProgress || _disposed) {
      return;
    }
    _socket?.send(jsonEncode({'type': 'end'}));
    _finishLocally('通话已结束。');
  }

  /// 闭麦／恢复收音（同一通话复用，spec 前端摆放）：平台停发有效音频，
  /// Host 侧同步丢弃上行，回答照常听。
  void toggleMute() {
    if (_phase != OmniCallPhase.active) {
      return;
    }
    _muted = !_muted;
    _captureSession?.setMuted(_muted);
    _socket?.send(jsonEncode({'type': 'mute', 'muted': _muted}));
    _notify();
  }

  /// 通话中打字（新用户轮，沿用真正插话的取消旧回应语义，spec:35）。
  /// 只在活动通话生效；返回是否已受理。
  bool sendTypedText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !acceptsTypedText) {
      return false;
    }
    final socket = _socket;
    if (socket == null) {
      return false;
    }
    final requestId = _requestIdFactory();
    socket.send(
      jsonEncode({'type': 'text', 'requestId': requestId, 'text': trimmed}),
    );
    // 乐观入列：Host 落盘后由 resync 对账；连接失败时对账清掉。
    _surface.callUserTurn(requestId: requestId, text: trimmed);
    return true;
  }

  Uri _resolveCallUri() {
    final base = _baseUri ?? Uri.base;
    final http = base.resolve('api/omni/call');
    return http.replace(scheme: http.scheme == 'https' ? 'wss' : 'ws');
  }

  // -------------------------------------------------------------------------
  // 上行
  // -------------------------------------------------------------------------

  void _onCaptureChunk(Uint8List pcm) {
    if (_phase != OmniCallPhase.active || _muted) {
      // 建连/重连窗口内的开口先攒着，active 后补发；静音期间照常收块
      // 但不上送。
      final buffering =
          (_phase == OmniCallPhase.connecting ||
              _phase == OmniCallPhase.reconnecting) &&
          !_muted;
      if (buffering) {
        if (_uplinkBuffer.length >= _uplinkBufferByteLimit) {
          _uplinkBuffer.removeAt(0);
        }
        _uplinkBuffer.add(pcm);
      }
      return;
    }
    _sendAudioChunk(pcm);
  }

  void _sendAudioChunk(Uint8List pcm) {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    socket.send(jsonEncode({'type': 'audio', 'pcm': base64Encode(pcm)}));
  }

  void _onCaptureUnavailable(String reason) {
    assert(() {
      debugPrint('qiyu omni call: capture unavailable [$reason]');
      return true;
    }());
    // 设备失效：真实结束，不偷偷重开（spec:23、T04:17）。
    unawaited(end());
  }

  // -------------------------------------------------------------------------
  // 下行
  // -------------------------------------------------------------------------

  void _onFrame(String frame) {
    final Map<String, Object?> event;
    try {
      final decoded = jsonDecode(frame);
      if (decoded is! Map<String, Object?>) {
        return;
      }
      event = decoded;
    } on FormatException {
      return;
    }
    switch (event['type']) {
      case 'state':
        _onStateEvent(event);
      case 'speechStarted':
        _onSpeechStarted();
      case 'speechStopped':
        _userSpeaking = false;
        _notify();
      case 'inputTranscript':
        _onInputTranscript(event);
      case 'replyDelta':
        _onReplyDelta(event);
      case 'replyDone':
        _onReplyDone(event);
      case 'audio':
        _onAudioEvent(event);
      default:
        // 只处理已核实的官方事件面，未知类型静默忽略。
        break;
    }
  }

  void _onStateEvent(Map<String, Object?> event) {
    final phaseName = event['phase'];
    final reason = event['reason'] as String?;
    final phase = OmniCallPhase.values.firstWhere(
      (value) => value.name == phaseName,
      orElse: () => _phase,
    );
    if (phase == OmniCallPhase.active && _uplinkBuffer.isNotEmpty) {
      // 补发建连/重连窗口内的开口。
      final buffered = List<Uint8List>.of(_uplinkBuffer);
      _uplinkBuffer.clear();
      for (final chunk in buffered) {
        if (!_muted) {
          _sendAudioChunk(chunk);
        }
      }
    }
    if (phase == OmniCallPhase.ended) {
      _finishLocally(reason ?? '通话已结束。');
      return;
    }
    _setPhase(phase, reason: reason);
  }

  void _onSpeechStarted() {
    _userSpeaking = true;
    // 真正插话：立即停播并清队列（T04:15）。被取消轮等 replyDone
    // （incomplete）来收口显示前缀；这里先按死轮隔离其后到事件。
    final playingTurnId = _playbackTurnId;
    if (playingTurnId != null) {
      _deadTurns.add(playingTurnId);
    }
    _teardownPlayback();
    _qiyuSpeaking = false;
    _notify();
  }

  void _onInputTranscript(Map<String, Object?> event) {
    final turnId = event['turnId'];
    final text = event['text'];
    if (turnId is String && text is String && text.isNotEmpty) {
      _surface.callUserTurn(requestId: turnId, text: text);
    }
  }

  void _onReplyDelta(Map<String, Object?> event) {
    final turnId = event['turnId'];
    final text = event['text'];
    if (turnId is! String || text is! String || _deadTurns.contains(turnId)) {
      return;
    }
    _surface.callReplyDelta(text);
  }

  void _onReplyDone(Map<String, Object?> event) {
    final turnId = event['turnId'];
    final incomplete = event['incomplete'] == true;
    // spec:20 区分两种标记：用户打断（status=cancelled）标记「被打断」，
    // 失败/超时等其余未完成轮标记「未完成」；status 由线协议随 replyDone
    // 携带（omni_call_routes.dart），completed 之外的其余取值不做第二
    // 分档，统一按未完成如实呈现。
    final interrupted = event['status'] == 'cancelled';
    if (turnId is String) {
      if (incomplete) {
        // 取消/失败/超时：轮终局，其后到事件按死轮隔离（T01 §13.4）。
        _deadTurns.add(turnId);
        if (_playbackTurnId == turnId) {
          _teardownPlayback();
          _qiyuSpeaking = false;
        }
      } else if (_playbackTurnId == turnId && !_playbackClosed) {
        // Provider 侧完成：缓冲播完即止（区分 Provider 完成与播放器
        // 排空——播完只收「栖语在说话」指示，T04:15）。
        _endPlaybackDrain();
      }
    }
    _surface.callReplyDone(incomplete: incomplete, interrupted: interrupted);
    _notify();
  }

  void _onAudioEvent(Map<String, Object?> event) {
    final turnId = event['turnId'];
    final pcm = event['pcm'];
    if (turnId is! String || pcm is! String || _deadTurns.contains(turnId)) {
      return;
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(pcm);
    } on FormatException {
      return;
    }
    if (bytes.isEmpty) {
      return;
    }
    if (_playbackOpening) {
      // 开流在途：同轮块排队，异轮块不认。
      if (_playbackTurnId == turnId) {
        _pendingPlaybackChunks.add(bytes);
      }
      return;
    }
    if (_playbackTurnId == turnId) {
      if (!_playbackClosed) {
        _playback?.append(bytes);
      } else {
        // 同轮续答（静默工具轮之后的补充回复）：重开一路继续播。
        _startPlayback(turnId, bytes);
      }
      return;
    }
    if (!_playbackClosed) {
      // 上一路还没收口时的异轮迟到块：丢弃，不让旧回复续声。
      return;
    }
    _startPlayback(turnId, bytes);
  }

  // -------------------------------------------------------------------------
  // 播放
  // -------------------------------------------------------------------------

  void _startPlayback(String turnId, Uint8List firstChunk) {
    final player = _player;
    if (player == null) {
      return;
    }
    _playbackOpening = true;
    _playbackTurnId = turnId;
    _pendingPlaybackChunks
      ..clear()
      ..add(firstChunk);
    unawaited(() async {
      final playback = await player.startStream(
        sampleRate: playbackSampleRate,
        // 通话播放沿用朗读的持久化音量偏好（T04「沿用现有页面、音量」）
        // ：与 VoiceOutputController 同一枚存储键、同一读取入口；每路
        // 新回复开流时取当前值，调节后的下一句即刻生效。
        volume: _resolvePlaybackVolume(),
      );
      _playbackOpening = false;
      if (_disposed ||
          _phase == OmniCallPhase.idle ||
          _phase == OmniCallPhase.ended ||
          _playbackTurnId != turnId) {
        playback?.stop();
        return;
      }
      if (playback == null) {
        // 播不出来（能力缺失/自动播放被拒）：文字照常，声音如实缺席。
        _playbackClosed = true;
        _pendingPlaybackChunks.clear();
        _notify();
        return;
      }
      _playback = playback;
      _playbackClosed = false;
      _qiyuSpeaking = true;
      final pending = List<Uint8List>.of(_pendingPlaybackChunks);
      _pendingPlaybackChunks.clear();
      for (final chunk in pending) {
        playback.append(chunk);
      }
      unawaited(
        playback.done.then((_) {
          if (identical(_playback, playback)) {
            _playbackClosed = true;
            _qiyuSpeaking = false;
            _notify();
          }
        }),
      );
      _notify();
    }());
  }

  /// 缓冲播完即止：end 之后 done 在排空时完成（不丢已在队列的声音）。
  void _endPlaybackDrain() {
    final playback = _playback;
    if (playback != null && !_playbackClosed) {
      _playbackClosed = true;
      playback.end();
    }
  }

  /// 立即停播并清队列（打断与挂断用）。
  void _teardownPlayback() {
    _playback?.stop();
    _playback = null;
    _playbackClosed = true;
    _playbackOpening = false;
    _pendingPlaybackChunks.clear();
    _playbackTurnId = null;
  }

  /// 通话播放音量：读朗读链路持久化的同一份偏好（voice_output_volume
  /// 存储键，VoicePlayerPlatform.getInitialVolume）；不支持读偏好的平台
  /// 恒 1.0。每路新回复开流时取当前值；通话中的即时调节在下一句生效
  /// ——现有音量控件只在配置 TTS 后出现，Omni 无 TTS 的通话本来就没
  /// 有滑杆，不做控件级联动。
  double _resolvePlaybackVolume() {
    final player = _player;
    if (player case final VoicePlayerPlatform volumeSource) {
      return volumeSource.getInitialVolume();
    }
    return 1.0;
  }

  // -------------------------------------------------------------------------
  // 收口
  // -------------------------------------------------------------------------

  /// 就地收尾（挂断／Host ended／连接断开共用同一序列）：停采集、停播
  /// 清队列、清两位说话指示、置 ended（reason 与 Host 同键，en 会话由
  /// localizeStatus 映射）、启动落盘对账。不偷偷重开（T04:17）。
  void _finishLocally(String reason) {
    unawaited(_stopCapture());
    _teardownPlayback();
    _userSpeaking = false;
    _qiyuSpeaking = false;
    _setPhase(OmniCallPhase.ended, reason: reason);
    unawaited(_resyncWhenQuiescent());
  }

  void _onSocketDone() {
    if (_phase != OmniCallPhase.ended) {
      // 前端连接断开即通话结束（Host 侧同一边界），如实呈现。
      _finishLocally('与通话服务的连接中断，通话已结束。');
    }
  }

  /// ended 后等连接真正安静再对账：挂断时 Host 还在收尾落盘在途轮
  /// （T03 stopCall 先落盘再推 ended、再关连接），恢复快照要读到落盘
  /// 后的事实；等不到就按超时对账，不无限等。
  Future<void> _resyncWhenQuiescent() async {
    final done = _socketDone;
    if (done != null && !done.isCompleted) {
      try {
        await done.future.timeout(const Duration(seconds: 2));
      } on Object {
        // 超时/错误都算安静。
      }
    }
    await _teardownSocket();
    try {
      await _surface.resyncAfterCall();
    } on Object {
      // 对账失败保留显示态：错误不该把已看到的内容抹掉。
    }
  }

  Future<void> _teardownSocket() async {
    _socketSubscription?.cancel();
    _socketSubscription = null;
    final socket = _socket;
    _socket = null;
    _socketDone = null;
    await socket?.close();
  }

  Future<void> _stopCapture() async {
    final session = _captureSession;
    _captureSession = null;
    session?.stop();
  }

  void _setPhase(OmniCallPhase phase, {required String? reason}) {
    _phase = phase;
    _phaseReason = reason;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardownSocket());
    unawaited(_stopCapture());
    _teardownPlayback();
    super.dispose();
  }
}

/// 缺省连接器：Host 会话 Cookie 同源随握手带上，CSRF 不适用于 WS 升级
/// （Host 侧 GET 免 CSRF，Origin 同源校验照常生效）。
OmniCallSocket _defaultConnector(Uri uri) {
  final channel = WebSocketChannel.connect(uri);
  return _WebSocketChannelSocket(channel);
}

final class _WebSocketChannelSocket implements OmniCallSocket {
  _WebSocketChannelSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<String> get stream =>
      _channel.stream.where((message) => message is String).cast<String>();

  @override
  Future<void> get ready => _channel.ready;

  @override
  void send(String frame) {
    _channel.sink.add(frame);
  }

  @override
  Future<void> close() => _channel.sink.close();
}

final Uuid _uuid = Uuid();

String _defaultRequestId() => 'omni-call-${_uuid.v4()}';

/// 通话播放器缺省取语音播放平台：Web 与安卓 io 实现都同时实现流式
/// 播放；不支持的测试宿主给 null，声音如实缺席。
StreamingVoicePlayerPlatform? _resolveStreamingPlayer() {
  final platform = createVoicePlayerPlatform();
  if (platform case final StreamingVoicePlayerPlatform streaming) {
    return streaming;
  }
  return null;
}
