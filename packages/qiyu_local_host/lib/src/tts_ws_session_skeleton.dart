/// WS 连续供给的共享层：三个协议 adapter（豆包双向、千问 Realtime、
/// 千问经典推理）共用此处的出网异常映射、会话守护、服务端帧动作与
/// 会话骨架，协议差异只由各 adapter 填帧编解码与事件名。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_web_socket.dart';
import 'tts_gateway.dart';

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
abstract class WsVoiceStreamSession implements VoiceStreamSession {
  WsVoiceStreamSession(this.connection, this.timeout, this._diagnosticsSink);

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
