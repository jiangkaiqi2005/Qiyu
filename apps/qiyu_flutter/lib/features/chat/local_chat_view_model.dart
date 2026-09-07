import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:uuid/uuid.dart';

import '../baseline/host_api_gateway.dart';
import '../baseline/host_connection_probe.dart';
import '../baseline/background_status_client.dart';
import '../settings/tts_settings_client.dart';
import 'local_chat_client.dart';
import 'voice_output_controller.dart';

typedef RequestIdFactory = String Function();

/// 一轮聊天事务：从发送到事件流终结。等待指示、流式文本与交付段进度
/// 都属于事务自身；事务失效（新发送 / 恢复 / 丢弃会话）之后，旧流再来
/// 的事件整体丢弃——不写状态、不通知界面。
final class _ChatTurn {
  _ChatTurn({
    required this.generation,
    required this.requestId,
    required this.text,
  });

  /// 创建时取得的唯一代际标识：与视图模型的当前代数一致才允许落地。
  final int generation;
  final String requestId;
  final String text;

  bool waiting = false;
  String streamingText = '';
  bool accepted = false;

  /// 收到过 done。
  bool completed = false;

  /// 至少一段交付成功落进气泡。
  bool committed = false;

  List<String>? finalMessages;
  ReplySource? source;
  FallbackReason? fallbackReason;
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
  }) : _hostConnectionProbe = hostConnectionProbe ?? HttpHostConnectionProbe(),
       _requestIdFactory = requestIdFactory ?? _defaultRequestId,
       // ignore: prefer_initializing_formals
       _ttsSettingsGateway = ttsSettingsGateway,
       // ignore: prefer_initializing_formals
       _backgroundStatusGateway = backgroundStatusGateway,
       // 缺省独立创建朗读网关（与聊天网关同构；widget 测试注入桩）。
       voiceOutput =
           voiceOutput ?? VoiceOutputController(HttpLocalChatGateway()) {
    if (autoStart) {
      unawaited(initialize());
      _monitorTimer = Timer.periodic(
        monitorInterval,
        (_) => unawaited(checkHostNow()),
      );
    }
  }

  final StreamingLocalChatGateway _gateway;
  final HostConnectionProbe _hostConnectionProbe;
  final RequestIdFactory _requestIdFactory;
  final TtsSettingsGateway? _ttsSettingsGateway;

  /// 后台失败状态网关（ticket 21）：null 时安静位整体不工作（缺省关闭）。
  final BackgroundStatusGateway? _backgroundStatusGateway;

  /// 语音朗读播放队列（ADR 0002）：view 观察它渲染「正在朗读」指示与
  /// 停止按钮。
  final VoiceOutputController voiceOutput;
  bool _voiceOutputEnabled = false;
  bool _voiceOutputConfigured = false;
  final Map<String, int> _announcedDeliveries = {};
  final List<LocalChatMessage> _messages = [];
  Timer? _monitorTimer;
  String? _sessionId;
  String? _errorMessage;
  bool? _hostAvailable;
  bool _checkingHost = false;
  bool _initializing = false;
  bool _initialized = false;

  /// 后台失败状态（ticket 21）：随既有连接探测轮询取用的只读快照；
  /// 取不到时保持原样，绝不打扰聊天主链路。
  BackgroundFailureStatus? _backgroundFailure;
  bool _backgroundFailureChecking = false;
  bool _backgroundRecoveredNotice = false;
  Timer? _backgroundRecoveredTimer;

  /// 「已恢复」提示的停留时长：够读到一句话，不久留成常驻。
  static const Duration _backgroundRecoveredNoticeDuration = Duration(
    seconds: 4,
  );

  /// 唯一代数计数器：新发送、会话恢复与丢弃会话都推进它；原恢复代数
  /// 并入这里，不再有两套代际。
  int _generation = 0;

  /// 当前活跃事务。为 null 即不在发送之中（事务完成、失败或被新一代
  /// 取代都置空），`sending` / `waiting` / `streamingText` 都由它派生。
  _ChatTurn? _activeTurn;
  String? _pendingRequestId;
  String? _pendingText;

  List<LocalChatMessage> get messages => List.unmodifiable(_messages);
  String? get errorMessage => _errorMessage;
  bool get loading => _initializing && !_initialized;
  bool get sending => _activeTurn != null;
  bool get waiting => _activeTurn?.waiting ?? false;
  String get streamingText => _activeTurn?.streamingText ?? '';
  bool get hostStopped => _hostAvailable == false;

  /// 代际归属校验：所有界面状态写入与副作用落地前先过这一关。新发送 /
  /// 恢复 / 丢弃会话推进代数或取代活跃事务后，旧事务的任何事件都整体丢弃。
  bool _belongsToActiveGeneration(_ChatTurn turn) =>
      identical(_activeTurn, turn) && turn.generation == _generation;

  /// 本机 Host 是否**已经探过一次**：true 之后 [hostStopped] 才是可信结论。
  /// 探测结果三态（未探明 / 可用 / 不可用）里只有后两态可以拿去宣称，
  /// 「未探明」既不能说正常、也不能说故障。
  bool get hostStatusKnown => _hostAvailable != null;

  /// 当前需要提示的后台失败（ticket 21，未恢复才计）：null 即没有，
  /// 壳层安静位整体不出现。
  BackgroundFailureStatus? get backgroundFailure =>
      _backgroundFailure == null || _backgroundFailure!.recovered
      ? null
      : _backgroundFailure;

  /// 失败恢复后的短暂提示窗口：「已恢复」展示一会儿再隐去，由视图模型
  /// 计时；窗口只在「此前真的展示过失败」时开启。
  bool get backgroundRecoveredNotice => _backgroundRecoveredNotice;

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

  Future<void> checkHostNow() async {
    if (_checkingHost) {
      return;
    }
    _checkingHost = true;
    try {
      final available = await _hostConnectionProbe.isHostAvailable();
      if (_hostAvailable != available) {
        _hostAvailable = available;
        notifyListeners();
      }
      // Host 可达时顺带取一次后台失败状态（ticket 21）：不新开轮询，
      // 随既有探测节奏走。
      if (available) {
        await _refreshBackgroundFailure();
      }
    } finally {
      _checkingHost = false;
    }
  }

  /// 取一次后台失败状态并推进安静位的显示状态（ticket 21）：有失败未
  /// 恢复时持续展示；该任务重试成功时回报一次「已恢复」，短暂展示后
  /// 隐去；无失败时整块不占位。状态取不到时保持原样。
  Future<void> _refreshBackgroundFailure() async {
    final gateway = _backgroundStatusGateway;
    if (gateway == null || _backgroundFailureChecking) {
      return;
    }
    _backgroundFailureChecking = true;
    try {
      final status = await gateway.read();
      final previous = _backgroundFailure;
      _backgroundFailure = status;
      if (status != null && !status.recovered) {
        // 有失败未恢复：撤掉恢复提示（若有），安静位持续展示失败。
        _backgroundRecoveredTimer?.cancel();
        _backgroundRecoveredTimer = null;
        _backgroundRecoveredNotice = false;
      } else if (previous != null &&
          !previous.recovered &&
          status != null &&
          status.recovered) {
        // 该任务重试成功：回报一次「已恢复」，短暂展示后隐去。
        _backgroundRecoveredNotice = true;
        _backgroundRecoveredTimer?.cancel();
        _backgroundRecoveredTimer = Timer(
          _backgroundRecoveredNoticeDuration,
          () {
            _backgroundRecoveredNotice = false;
            notifyListeners();
          },
        );
      } else if (status == null) {
        _backgroundRecoveredTimer?.cancel();
        _backgroundRecoveredTimer = null;
        _backgroundRecoveredNotice = false;
      }
      if (previous != status) {
        notifyListeners();
      }
    } on Object {
      // 安静提示是旁路：状态取不到时保持原样。
    } finally {
      _backgroundFailureChecking = false;
    }
  }

  Future<bool> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || sending || hostStopped) {
      return false;
    }
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
    final turn = _ChatTurn(
      generation: _generation,
      requestId: requestId,
      text: trimmed,
    );
    _activeTurn = turn;
    final optimisticallyAdded = !_hasUserTurn(requestId);
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
      return await _sendStreaming(
        turn,
        optimisticallyAdded: optimisticallyAdded,
      );
    } on Object catch (error) {
      if (_belongsToActiveGeneration(turn)) {
        _errorMessage = _readableError(error);
      }
      return false;
    } finally {
      // 只有仍属当前代际的事务收尾：被恢复/丢弃取代后，新一代界面自己
      // 做主，旧事务的尾巴不再写状态、不再通知。
      if (_belongsToActiveGeneration(turn)) {
        _activeTurn = null;
        notifyListeners();
      }
    }
  }

  Future<bool> _sendStreaming(
    _ChatTurn turn, {
    required bool optimisticallyAdded,
  }) async {
    try {
      turnLoop:
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
        _sessionId = event.sessionId ?? _sessionId;
        switch (event.kind) {
          case LocalChatEventKind.accepted:
            turn.accepted = true;
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
            turn.streamingText += event.text ?? '';
          case LocalChatEventKind.message:
            turn.finalMessages = event.messages;
          case LocalChatEventKind.state:
            turn.source = event.source;
            turn.fallbackReason = event.fallbackReason;
          case LocalChatEventKind.fallback:
            turn.fallbackReason = event.fallbackReason;
          case LocalChatEventKind.done:
            turn.completed = true;
            // 轮内召回的 bubble 2 会在同一条事件流里带来第二段
            // message/state/done：每个 done 提交已收齐的一段，
            // 而不是等流结束只保留最后一段。
            final messages = turn.finalMessages;
            final replySource = turn.source;
            if (messages != null && replySource != null) {
              turn.committed = true;
              // 该 requestId 的第 N 次交付段（轮内召回的 bubble 2 是
              // 第二段）：朗读定位与气泡的「正在朗读」指示共用。
              final delivery = _announcedDeliveries[turn.requestId] ?? 0;
              _announcedDeliveries[turn.requestId] = delivery + 1;
              _messages.addAll(
                messages.map(
                  (message) => LocalChatMessage(
                    requestId: turn.requestId,
                    speaker: LocalChatSpeaker.qiyu,
                    text: message,
                    source: replySource,
                    fallbackReason: turn.fallbackReason,
                    deliveryIndex: delivery,
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
                  deliveryIndex: delivery,
                  sessionId: _sessionId,
                ),
                enabled: _voiceOutputEnabled,
              );
              turn.finalMessages = null;
              turn.source = null;
              turn.fallbackReason = null;
            }
          case LocalChatEventKind.cancelled:
            turn.streamingText = '';
            turn.waiting = false;
            notifyListeners();
            // 取消即本轮终态：立刻停止消费，Host 缓冲里后续的到达都算
            // 迟到事件，整体丢弃。
            break turnLoop;
          case LocalChatEventKind.error:
            throw LocalChatGatewayException(event.text ?? '本地聊天暂时不可用，请稍后重试。');
        }
        notifyListeners();
      }
    } on Object {
      if (!turn.accepted &&
          optimisticallyAdded &&
          _belongsToActiveGeneration(turn)) {
        _removeUserTurn(turn.requestId);
      }
      rethrow;
    }
    if (!turn.completed || !turn.committed) {
      if (_belongsToActiveGeneration(turn) &&
          !turn.accepted &&
          optimisticallyAdded) {
        _removeUserTurn(turn.requestId);
      }
      return false;
    }
    if (!_belongsToActiveGeneration(turn)) {
      return false;
    }
    turn.streamingText = '';
    _pendingRequestId = null;
    _pendingText = null;
    return true;
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
  Future<bool> sendWhenIdle(String text) async {
    if (sending) {
      final idle = Completer<void>();
      void listener() {
        if (!sending && !idle.isCompleted) {
          idle.complete();
        }
      }

      addListener(listener);
      try {
        await idle.future;
      } finally {
        removeListener(listener);
      }
    }
    return send(text);
  }

  /// 语音转写通道：录音字节经本机程序转成文字，语义与手打输入完全
  /// 一致，成功后由调用方走 [send]/[sendWhenIdle] 现有链路。
  Future<String> transcribeVoice(Uint8List audio, String mimeType) =>
      _gateway.transcribe(audio: audio, mimeType: mimeType);

  @override
  void dispose() {
    _monitorTimer?.cancel();
    _backgroundRecoveredTimer?.cancel();
    // 活跃事务随释放失效：尚未消费完的旧流事件会在代际校验处整体丢弃，
    // 不再写入或通知已销毁的视图模型。
    _activeTurn = null;
    super.dispose();
  }
}

final Uuid _requestIdUuid = Uuid();

String _defaultRequestId() => 'chat-${_requestIdUuid.v4()}';

String _readableError(Object error) =>
    readableError(error, fallback: '本地聊天暂时不可用，请稍后重试。');
