import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:uuid/uuid.dart';

import '../baseline/host_api_gateway.dart';
import '../baseline/host_connection_probe.dart';
import '../baseline/background_status_client.dart';
import '../settings/tts_settings_client.dart';
import '../shell/host_status_monitor.dart';
import 'chat_delivery_assembly.dart';
import 'local_chat_client.dart';
import 'voice_output_controller.dart';

typedef RequestIdFactory = String Function();

enum ChatSendStatus {
  notAccepted,
  acceptedIncomplete,

  /// 沿用交付语义：首段已完成后取消第二段，也保留完成结果。
  completed,
  staleSession,
}

/// 本次发送的草稿归属；拒绝或尚在排队时没有创建请求，requestId 为 null。
final class ChatSendResult {
  const ChatSendResult({required this.status, this.requestId});

  final ChatSendStatus status;
  final String? requestId;
}

/// 一轮聊天事务：从发送到事件流终结。等待指示、流式文本与交付段进度
/// 都属于事务自身；事务失效（新发送 / 恢复 / 丢弃会话）之后，旧流再来
/// 的事件整体丢弃——不写状态、不通知界面。
final class _ChatTurn {
  _ChatTurn({
    required this.generation,
    required this.requestId,
    required this.text,
    required bool accepted,
  }) : assembly = ChatDeliveryAssembly(requestId: requestId, accepted: accepted);

  /// 创建时取得的唯一代际标识：与视图模型的当前代数一致才允许落地。
  final int generation;
  final String requestId;
  final String text;

  bool waiting = false;
  String streamingText = '';
  final ChatDeliveryAssembly assembly;
}

final class LocalChatViewModel extends ChangeNotifier {
  LocalChatViewModel(
    this._gateway, {
    HostConnectionProbe? hostConnectionProbe,
    RequestIdFactory? requestIdFactory,
    TtsSettingsGateway? ttsSettingsGateway,
    BackgroundStatusGateway? backgroundStatusGateway,
    VoiceOutputController? voiceOutput,
    bool autoStart = true,
    Duration monitorInterval = const Duration(seconds: 2),
  }) : _requestIdFactory = requestIdFactory ?? _defaultRequestId,
       // ignore: prefer_initializing_formals
       _ttsSettingsGateway = ttsSettingsGateway,
       // 缺省独立创建朗读网关（与聊天网关同构；widget 测试注入桩）。
       voiceOutput =
           voiceOutput ?? VoiceOutputController(HttpLocalChatGateway()) {
    // 连接探测轮询与后台失败状态的唯一所有者：计时器、重入保护、恢复
    // 提示窗口与对应生命周期都在监控模块内部，聊天事务只读它的结论。
    _hostMonitor = HostStatusMonitor(
      hostConnectionProbe: hostConnectionProbe,
      backgroundStatusGateway: backgroundStatusGateway,
      autoStart: autoStart,
      monitorInterval: monitorInterval,
    );
    _hostMonitor.addListener(_onHostMonitorChanged);
    if (autoStart) {
      unawaited(initialize());
    }
  }

  final StreamingLocalChatGateway _gateway;
  final RequestIdFactory _requestIdFactory;
  final TtsSettingsGateway? _ttsSettingsGateway;

  /// 连接与后台状态监控（阶段 C 收拢）：周期轮询计时器、连接三态、后台
  /// 失败快照与恢复提示窗口的唯一所有者。壳层装配仍经本视图模型读取
  /// （对外 getter 原样保留），内部不存在第二份轮询状态。
  late final HostStatusMonitor _hostMonitor;

  /// 监控的状态变化按原语义透传给界面：监控只在连接三态或后台状态实际
  /// 变化时通知，这里不做第二次去重。
  void _onHostMonitorChanged() {
    notifyListeners();
  }

  /// 语音朗读播放队列（ADR 0002）：view 观察它渲染「正在朗读」指示与
  /// 停止按钮。
  final VoiceOutputController voiceOutput;
  bool _voiceOutputEnabled = false;
  bool _voiceOutputConfigured = false;
  final Map<String, int> _announcedDeliveries = {};
  final List<LocalChatMessage> _messages = [];
  String? _sessionId;
  String? _errorMessage;
  bool _initializing = false;
  bool _initialized = false;

  /// 唯一代数计数器：新发送、会话恢复与丢弃会话都推进它；原恢复代数
  /// 并入这里，不再有两套代际。
  int _generation = 0;

  /// 发送结果与排队语音的会话归属；普通新轮不改变它，恢复/丢弃才使其失效。
  Object _sessionScope = Object();

  /// 当前活跃事务。为 null 即不在发送之中（事务完成、失败或被新一代
  /// 取代都置空），`sending` / `waiting` / `streamingText` 都由它派生。
  _ChatTurn? _activeTurn;
  String? _pendingRequestId;
  String? _pendingText;

  List<LocalChatMessage> get messages => List.unmodifiable(_messages);
  String? get sessionId => _sessionId;
  String? get errorMessage => _errorMessage;
  bool get loading => _initializing && !_initialized;
  bool get sending => _activeTurn != null;
  bool get waiting => _activeTurn?.waiting ?? false;
  String get streamingText => _activeTurn?.streamingText ?? '';
  bool get hostStopped => _hostMonitor.hostAvailable == false;

  /// 最近一次已完成的栖语回复的 fallbackReason。
  FallbackReason? get latestFallbackReason {
    final last = _messages.lastOrNull;
    if (last == null || last.speaker != LocalChatSpeaker.qiyu) {
      return null;
    }
    return last.fallbackReason;
  }

  /// 最近一次已完成回复的安全服务故障类别。
  ServiceErrorCategory? get latestServiceError {
    final last = _messages.lastOrNull;
    return last?.speaker == LocalChatSpeaker.qiyu ? last?.serviceError : null;
  }

  /// 代际归属校验：所有界面状态写入与副作用落地前先过这一关。新发送 /
  /// 恢复 / 丢弃会话推进代数或取代活跃事务后，旧事务的任何事件都整体丢弃。
  bool _belongsToActiveGeneration(_ChatTurn turn) =>
      identical(_activeTurn, turn) && turn.generation == _generation;

  /// 本机 Host 是否**已经探过一次**：true 之后 [hostStopped] 才是可信结论。
  /// 探测结果三态（未探明 / 可用 / 不可用）里只有后两态可以拿去宣称，
  /// 「未探明」既不能说正常、也不能说故障。
  bool get hostStatusKnown => _hostMonitor.hostAvailable != null;

  /// 当前需要提示的后台失败（ticket 21，未恢复才计）：null 即没有，
  /// 壳层安静位整体不出现。
  BackgroundFailureStatus? get backgroundFailure =>
      _hostMonitor.backgroundFailure;

  /// 失败恢复后的短暂提示窗口：「已恢复」展示一会儿再隐去，由监控模块
  /// 计时；窗口只在「此前真的展示过失败」时开启。
  bool get backgroundRecoveredNotice => _hostMonitor.backgroundRecoveredNotice;

  /// 合一页（design-system §5）的**空状态 = 首页**唯一判定：一条消息都还没有、
  /// 不在等待与流式之中，**且会话已经恢复完**。
  ///
  /// `loading` 必须在闸内：旧会话恢复期间 `messages` 暂时为空，如果这时算空态，
  /// 打开应用会先闪一帧首页（背景 + 问候 + 居中 composer）再跳回消息流。
  bool get isHomeState =>
      !loading && messages.isEmpty && !waiting && streamingText.isEmpty;

  /// 「本地规则回复」标识只描述最近一次已完成且未开启新交互的栖语回复：
  /// 在发送与等待流式期间不展示过期的 fallback 状态；仅当最后一条消息
  /// 确为栖语的已完成本地规则回复时才显示。
  bool get hasLocalFallback {
    if (sending) {
      return false;
    }
    final last = _messages.lastOrNull;
    if (last == null || last.speaker != LocalChatSpeaker.qiyu) {
      return false;
    }
    return last.source == ReplySource.local;
  }

  /// 本轮用户 turn 的判定与失败回退：乐观插入去重、accepted 去重与
  /// 异常清理共用同一口径。
  bool _hasUserTurn(String requestId) => _messages.any(
    (message) =>
        message.requestId == requestId &&
        message.speaker == LocalChatSpeaker.user,
  );

  void _removeUserTurn(String requestId) => _messages.removeWhere(
    (message) =>
        message.requestId == requestId &&
        message.speaker == LocalChatSpeaker.user,
  );

  /// 直播流新消息的前端时钟预显时刻：Host 落盘权威值要等刷新或恢复
  /// 才换上来，分钟粒度下两边不会可见地跳变——预显先保住消息在发送
  /// 瞬间就有时刻，不必等落盘往返。
  DateTime get _previewMoment => DateTime.now();

  Future<void> initialize() async {
    if (_initializing || _initialized) {
      return;
    }
    _initializing = true;
    _sessionScope = Object();
    _generation += 1;
    final generation = _generation;
    _activeTurn = null;
    notifyListeners();
    try {
      unawaited(refreshVoiceOutputStatus());
      await checkHostNow();
      if (hostStopped) {
        return;
      }
      await _applyRestore(generation, sessionId: _sessionId);
    } finally {
      if (generation == _generation) {
        _initializing = false;
        notifyListeners();
      }
    }
  }

  /// 朗读可用性：配了语音合成且自动朗读开着才触发（ADR 0002：配置了
  /// 就自动读，聊天页开关写 Host 的 autoSpeak 位）。Host 不可达或未
  /// 配置时按关闭处理——读不出来不影响文字主链路。
  Future<void> refreshVoiceOutputStatus() async {
    final gateway = _ttsSettingsGateway;
    if (gateway == null) {
      return;
    }
    try {
      final settings = await gateway.read();
      _voiceOutputConfigured = settings.configured;
      _voiceOutputEnabled = settings.configured && settings.autoSpeak;
    } on Object {
      _voiceOutputConfigured = false;
      _voiceOutputEnabled = false;
    }
    notifyListeners();
  }

  /// 是否配了语音合成（聊天页据此显示/隐藏朗读开关）。
  bool get voiceOutputConfigured => _voiceOutputConfigured;

  /// 自动朗读开关状态（写 Host 的 tts.autoSpeak，刷新重启都记住）。
  bool get voiceOutputEnabled => _voiceOutputEnabled;

  Future<void> toggleVoiceOutput() async {
    final gateway = _ttsSettingsGateway;
    if (gateway == null || !_voiceOutputConfigured) {
      return;
    }
    try {
      await gateway.setAutoSpeak(!_voiceOutputEnabled);
      await refreshVoiceOutputStatus();
    } on Object {
      // 开关写失败：保持原状态，不打扰聊天主链路。
    }
  }

  /// 气泡重听：与自动朗读复用当前会话定位，避免同一会话因 null
  /// sessionId 被误判成新会话并重置首次失败提示。
  void replayVoiceOutput(LocalChatMessage message) {
    final deliveryIndex = message.deliveryIndex;
    if (message.speaker != LocalChatSpeaker.qiyu || deliveryIndex == null) {
      return;
    }
    voiceOutput.playNow(
      VoiceOutputRequest(
        requestId: message.requestId,
        deliveryIndex: deliveryIndex,
        sessionId: _sessionId,
      ),
    );
  }

  Future<void> _applyRestore(int generation, {String? sessionId}) async {
    try {
      final snapshot = await _gateway.restore(sessionId: sessionId);
      if (generation != _generation) {
        return;
      }
      // 恢复快照定义新一代：仍挂在旧事务上的流式状态随之失效。
      _activeTurn = null;
      _sessionId = snapshot.sessionId;
      // 历史栖语消息也标注 deliveryIndex（同 requestId 内第 N 个栖语
      // turn，与 Host 朗读定位同口径、从 0 起）：恢复的气泡同样能点
      // 小喇叭重听（重听=重新合成，文字都在）。
      final deliveryCounts = <String, int>{};
      final restored = <LocalChatMessage>[];
      for (final message in snapshot.messages) {
        if (message.speaker != LocalChatSpeaker.qiyu) {
          restored.add(message);
          continue;
        }
        final delivery = deliveryCounts[message.requestId] ?? 0;
        deliveryCounts[message.requestId] = delivery + 1;
        restored.add(
          LocalChatMessage(
            requestId: message.requestId,
            speaker: message.speaker,
            text: message.text,
            source: message.source,
            fallbackReason: message.fallbackReason,
            serviceError: message.serviceError,
            deliveryIndex: delivery,
            at: message.at,
          ),
        );
      }
      _messages
        ..clear()
        ..addAll(restored);
      // 交付计数与已展示消息对齐：恢复后同一 requestId 的新交付段接着
      // 计数，朗读定位不撞号。
      _announcedDeliveries
        ..clear()
        ..addAll(deliveryCounts);
      final lastMessage = _messages.isEmpty ? null : _messages.last;
      if (lastMessage?.speaker == LocalChatSpeaker.user) {
        _pendingRequestId = lastMessage!.requestId;
        _pendingText = lastMessage.text;
      } else {
        _pendingRequestId = null;
        _pendingText = null;
      }
      _errorMessage = null;
      _initialized = true;
      notifyListeners();
    } on Object catch (error) {
      if (generation != _generation) {
        return;
      }
      _errorMessage = _readableError(error);
      notifyListeners();
    }
  }

  Future<LocalChatSnapshot> readSession(String sessionId) =>
      _gateway.restore(sessionId: sessionId);

  Future<void> discardSession(String sessionId) async {
    if (_sessionId != sessionId) {
      return;
    }
    _sessionScope = Object();
    _generation += 1;
    final generation = _generation;
    // 旧事务随代数失效：等待指示与流式半句一并消失，发送锁同时释放。
    _activeTurn = null;
    _sessionId = null;
    _messages.clear();
    _pendingRequestId = null;
    _pendingText = null;
    _errorMessage = null;
    notifyListeners();
    await _applyRestore(generation);
  }

  /// 探测一次连接并顺带取后台失败状态：转发给监控模块（手动探测与周期
  /// 轮询共用同一条路径与重入保护），壳层重试入口与测试的既有入口不变。
  Future<void> checkHostNow() => _hostMonitor.checkHostNow();

  Future<ChatSendResult> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || sending || hostStopped) {
      return const ChatSendResult(status: ChatSendStatus.notAccepted);
    }
    final sessionScope = _sessionScope;
    if (_voiceOutputEnabled) {
      // send 由按钮/Enter 同步触发：先保住许可，再跨入聊天事件流。
      voiceOutput.prepareForUserInitiatedPlayback();
    }
    _errorMessage = null;
    final requestId = _pendingText == trimmed && _pendingRequestId != null
        ? _pendingRequestId!
        : _requestIdFactory();
    _pendingRequestId = requestId;
    _pendingText = trimmed;
    // 一轮聊天即一个事务：推进代数、接管活跃事务；此后凡是代际不符的
    // 事件一律整体丢弃。
    _generation += 1;
    final optimisticallyAdded = !_hasUserTurn(requestId);
    final turn = _ChatTurn(
      generation: _generation,
      requestId: requestId,
      text: trimmed,
      // 重试或恢复出的用户轮已经归会话保管，连接失败也不退回草稿。
      accepted: !optimisticallyAdded,
    );
    _activeTurn = turn;
    if (optimisticallyAdded) {
      _messages.add(
        LocalChatMessage(
          requestId: requestId,
          speaker: LocalChatSpeaker.user,
          text: trimmed,
          at: _previewMoment,
        ),
      );
    }
    notifyListeners();
    try {
      await _sendStreaming(
        turn,
        optimisticallyAdded: optimisticallyAdded,
      );
    } on Object catch (error) {
      if (_belongsToActiveGeneration(turn)) {
        _errorMessage = _readableError(error);
      }
    } finally {
      // 只有仍属当前代际的事务收尾：被恢复/丢弃取代后，新一代界面自己
      // 做主，旧事务的尾巴不再写状态、不再通知。
      if (_belongsToActiveGeneration(turn)) {
        _activeTurn = null;
        notifyListeners();
      }
    }
    final ChatSendStatus status;
    if (sessionScope != _sessionScope) {
      status = ChatSendStatus.staleSession;
    } else if (turn.assembly.hasCompleted) {
      status = ChatSendStatus.completed;
    } else if (turn.assembly.accepted) {
      status = ChatSendStatus.acceptedIncomplete;
    } else {
      status = ChatSendStatus.notAccepted;
    }
    return ChatSendResult(requestId: requestId, status: status);
  }

  Future<void> _sendStreaming(
    _ChatTurn turn, {
    required bool optimisticallyAdded,
  }) async {
    try {
      await for (final event in _gateway.deliver(
        requestId: turn.requestId,
        text: turn.text,
        sessionId: _sessionId,
      )) {
        // 写入前校验代际归属：新发送 / 恢复 / 丢弃会话之后，旧事务已经
        // 失效，它余下的事件整体丢弃——不写状态、不通知。
        if (!_belongsToActiveGeneration(turn)) {
          break;
        }
        final delivery = turn.assembly.add(event);
        _sessionId = turn.assembly.sessionId ?? _sessionId;
        switch (event.kind) {
          case LocalChatEventKind.accepted:
            if (!_hasUserTurn(turn.requestId)) {
              _messages.add(
                LocalChatMessage(
                  requestId: turn.requestId,
                  speaker: LocalChatSpeaker.user,
                  text: turn.text,
                  at: _previewMoment,
                ),
              );
            }
          case LocalChatEventKind.waiting:
            turn.waiting = true;
          case LocalChatEventKind.delta:
            turn.waiting = false;
            turn.streamingText += event.text!;
          case LocalChatEventKind.message:
          case LocalChatEventKind.state:
          case LocalChatEventKind.fallback:
            break;
          case LocalChatEventKind.done:
            if (delivery != null) {
              // 该 requestId 的第 N 次交付段（轮内召回的 bubble 2 是
              // 第二段）：朗读定位与气泡的「正在朗读」指示共用。
              final deliveryIndex = _announcedDeliveries[turn.requestId] ?? 0;
              _announcedDeliveries[turn.requestId] = deliveryIndex + 1;
              _messages.addAll(
                delivery.messages.map(
                  (message) => LocalChatMessage(
                    requestId: turn.requestId,
                    speaker: LocalChatSpeaker.qiyu,
                    text: message,
                    source: delivery.source,
                    fallbackReason: delivery.fallbackReason,
                    serviceError: delivery.serviceError,
                    deliveryIndex: deliveryIndex,
                    incomplete: delivery.incomplete,
                    at: _previewMoment,
                  ),
                ),
              );
              turn.streamingText = '';
              turn.waiting = false;
              // ADR 0002：只有完整交付并落盘的栖语 turn 才朗读——
              // done 交付即 Host 落盘完成，此时入队按序读。
              voiceOutput.offer(
                VoiceOutputRequest(
                  requestId: turn.requestId,
                  deliveryIndex: deliveryIndex,
                  sessionId: _sessionId,
                ),
                enabled: _voiceOutputEnabled,
              );
            }
          case LocalChatEventKind.cancelled:
            turn.streamingText = '';
            turn.waiting = false;
          case LocalChatEventKind.error:
            throw LocalChatGatewayException(event.text!);
        }
        notifyListeners();
        // 取消即本轮终态；done 后仍消费可能到来的召回第二段。
        if (turn.assembly.end != null) break;
      }
    } on Object {
      turn.assembly.fail();
      rethrow;
    } finally {
      turn.assembly.close();
      if (_belongsToActiveGeneration(turn)) {
        if (!turn.assembly.accepted && optimisticallyAdded) {
          _removeUserTurn(turn.requestId);
        }
        if (turn.assembly.hasCompleted) {
          _pendingRequestId = null;
          _pendingText = null;
        }
        if (turn.assembly.end == ChatDeliveryEnd.closed &&
            (turn.assembly.hasIncompleteSegment || !turn.assembly.hasCompleted)) {
          _errorMessage = '回复未完成，可以重新发送。';
        }
        turn.streamingText = '';
        turn.waiting = false;
      }
    }
  }

  Future<void> stop() async {
    final requestId = _pendingRequestId;
    if (!sending || requestId == null) {
      return;
    }
    await _gateway.cancel(requestId);
  }

  /// 等正在流式回复的一轮结束后再发送：语音转写完成时栖语可能仍在
  /// 回复，说完的话照常排队发出，不丢也不并发。
  Future<ChatSendResult> sendWhenIdle(
    String text, {
    Future<void>? cancelled,
    bool Function()? isCancelled,
    VoidCallback? onCommitted,
  }) async {
    final sessionScope = _sessionScope;
    while (sending) {
      final idle = Completer<void>();
      void listener() {
        if (!sending && !idle.isCompleted) {
          idle.complete();
        }
      }

      addListener(listener);
      try {
        await (cancelled == null
            ? idle.future
            : Future.any([idle.future, cancelled]));
      } finally {
        removeListener(listener);
      }
      if (sessionScope != _sessionScope) {
        return const ChatSendResult(status: ChatSendStatus.staleSession);
      }
      if (isCancelled?.call() ?? false) {
        return const ChatSendResult(status: ChatSendStatus.notAccepted);
      }
    }
    if (isCancelled?.call() ?? false) {
      return const ChatSendResult(status: ChatSendStatus.notAccepted);
    }
    // 检查与进入 send 之间不让出执行权，取消不能越过提交边界。
    onCommitted?.call();
    return send(text);
  }

  /// 语音转写通道：录音字节经本机程序转成文字，语义与手打输入完全
  /// 一致，成功后由调用方走 [send]/[sendWhenIdle] 现有链路。
  Future<String> transcribeVoice(Uint8List audio, String mimeType) =>
      _gateway.transcribe(audio: audio, mimeType: mimeType);

  @override
  void dispose() {
    // 轮询计时器与恢复提示窗口随监控模块释放；活跃事务随释放失效：尚未
    // 消费完的旧流事件会在代际校验处整体丢弃，不再写入或通知已销毁的
    // 视图模型。
    _hostMonitor.removeListener(_onHostMonitorChanged);
    _hostMonitor.dispose();
    _sessionScope = Object();
    _generation += 1;
    _activeTurn = null;
    super.dispose();
  }
}

final Uuid _requestIdUuid = Uuid();

String _defaultRequestId() => 'chat-${_requestIdUuid.v4()}';

String _readableError(Object error) =>
    readableError(error, fallback: '本地聊天暂时不可用，请稍后重试。');
