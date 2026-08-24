import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:uuid/uuid.dart';

import '../baseline/host_connection_probe.dart';
import '../settings/tts_settings_client.dart';
import 'local_chat_client.dart';
import 'voice_output_controller.dart';

typedef RequestIdFactory = String Function();

final class LocalChatViewModel extends ChangeNotifier {
  LocalChatViewModel(
    this._gateway, {
    HostConnectionProbe? hostConnectionProbe,
    RequestIdFactory? requestIdFactory,
    TtsSettingsGateway? ttsSettingsGateway,
    VoiceOutputController? voiceOutput,
    bool autoStart = true,
    Duration monitorInterval = const Duration(seconds: 2),
  }) : _hostConnectionProbe = hostConnectionProbe ?? HttpHostConnectionProbe(),
       _requestIdFactory = requestIdFactory ?? _defaultRequestId,
       // ignore: prefer_initializing_formals
       _ttsSettingsGateway = ttsSettingsGateway,
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
  bool _sending = false;
  bool _waiting = false;
  String _streamingText = '';
  String? _pendingRequestId;
  String? _pendingText;
  int _restoreGeneration = 0;

  List<LocalChatMessage> get messages => List.unmodifiable(_messages);
  String? get errorMessage => _errorMessage;
  bool get loading => _initializing && !_initialized;
  bool get initialized => _initialized;
  bool get sending => _sending;
  bool get waiting => _waiting;
  String get streamingText => _streamingText;
  bool get hostStopped => _hostAvailable == false;

  /// 「本地规则回复」标识只描述最近一次已完成的栖语回复：最后一条
  /// 栖语消息来自本地规则才显示；之后模型恢复正常即消失。流式等待
  /// 与半句候选不进 [_messages]，天然保持上一次的状态。
  bool get hasLocalFallback {
    for (final message in _messages.reversed) {
      if (message.speaker == LocalChatSpeaker.qiyu) {
        return message.source == ReplySource.local;
      }
    }
    return false;
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

  Future<void> initialize() async {
    if (_initializing || _initialized) {
      return;
    }
    _initializing = true;
    _restoreGeneration += 1;
    final generation = _restoreGeneration;
    notifyListeners();
    try {
      unawaited(refreshVoiceOutputStatus());
      await checkHostNow();
      if (hostStopped) {
        return;
      }
      await _applyRestore(generation, sessionId: _sessionId);
    } finally {
      if (generation == _restoreGeneration) {
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
      if (generation != _restoreGeneration) {
        return;
      }
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
      if (generation != _restoreGeneration) {
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
    _restoreGeneration += 1;
    final generation = _restoreGeneration;
    _sessionId = null;
    _messages.clear();
    _pendingRequestId = null;
    _pendingText = null;
    _streamingText = '';
    _waiting = false;
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
    } finally {
      _checkingHost = false;
    }
  }

  Future<bool> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending || hostStopped) {
      return false;
    }
    if (_voiceOutputEnabled) {
      // send 由按钮/Enter 同步触发：先保住许可，再跨入聊天事件流。
      voiceOutput.prepareForUserInitiatedPlayback();
    }
    _sending = true;
    _errorMessage = null;
    final requestId = _pendingText == trimmed && _pendingRequestId != null
        ? _pendingRequestId!
        : _requestIdFactory();
    _pendingRequestId = requestId;
    _pendingText = trimmed;
    final optimisticallyAdded = !_hasUserTurn(requestId);
    if (optimisticallyAdded) {
      _messages.add(
        LocalChatMessage(
          requestId: requestId,
          speaker: LocalChatSpeaker.user,
          text: trimmed,
        ),
      );
    }
    notifyListeners();
    try {
      return await _sendStreaming(
        requestId: requestId,
        text: trimmed,
        optimisticallyAdded: optimisticallyAdded,
      );
    } on Object catch (error) {
      _streamingText = '';
      _waiting = false;
      _errorMessage = _readableError(error);
      return false;
    } finally {
      _sending = false;
      _waiting = false;
      notifyListeners();
    }
  }

  Future<bool> _sendStreaming({
    required String requestId,
    required String text,
    required bool optimisticallyAdded,
  }) async {
    final generation = _restoreGeneration;
    List<String>? finalMessages;
    ReplySource? source;
    FallbackReason? fallbackReason;
    var completed = false;
    var committed = false;
    var accepted = false;
    try {
      await for (final event in _gateway.deliver(
        requestId: requestId,
        text: text,
        sessionId: _sessionId,
      )) {
        if (generation == _restoreGeneration) {
          _sessionId = event.sessionId ?? _sessionId;
        }
        switch (event.kind) {
          case LocalChatEventKind.accepted:
            accepted = true;
            if (generation == _restoreGeneration && !_hasUserTurn(requestId)) {
              _messages.add(
                LocalChatMessage(
                  requestId: requestId,
                  speaker: LocalChatSpeaker.user,
                  text: text,
                ),
              );
            }
          case LocalChatEventKind.waiting:
            _waiting = true;
          case LocalChatEventKind.delta:
            _waiting = false;
            if (generation == _restoreGeneration) {
              _streamingText += event.text ?? '';
            }
          case LocalChatEventKind.message:
            finalMessages = event.messages;
          case LocalChatEventKind.state:
            source = event.source;
            fallbackReason = event.fallbackReason;
          case LocalChatEventKind.fallback:
            fallbackReason = event.fallbackReason;
          case LocalChatEventKind.done:
            completed = true;
            // 轮内召回的 bubble 2 会在同一条事件流里带来第二段
            // message/state/done：每个 done 提交已收齐的一段，
            // 而不是等流结束只保留最后一段。
            final messages = finalMessages;
            final replySource = source;
            if (messages != null && replySource != null) {
              committed = true;
              // 该 requestId 的第 N 次交付段（轮内召回的 bubble 2 是
              // 第二段）：朗读定位与气泡的「正在朗读」指示共用。
              final delivery = _announcedDeliveries[requestId] ?? 0;
              _announcedDeliveries[requestId] = delivery + 1;
              if (generation == _restoreGeneration) {
                _messages.addAll(
                  messages.map(
                    (message) => LocalChatMessage(
                      requestId: requestId,
                      speaker: LocalChatSpeaker.qiyu,
                      text: message,
                      source: replySource,
                      fallbackReason: fallbackReason,
                      deliveryIndex: delivery,
                    ),
                  ),
                );
                _streamingText = '';
                _waiting = false;
                // ADR 0002：只有完整交付并落盘的栖语 turn 才朗读——
                // done 交付即 Host 落盘完成，此时入队按序读。
                voiceOutput.offer(
                  VoiceOutputRequest(
                    requestId: requestId,
                    deliveryIndex: delivery,
                    sessionId: _sessionId,
                  ),
                  enabled: _voiceOutputEnabled,
                );
              }
              finalMessages = null;
              source = null;
              fallbackReason = null;
            }
          case LocalChatEventKind.cancelled:
            _streamingText = '';
            _waiting = false;
          case LocalChatEventKind.error:
            throw LocalChatGatewayException(event.text ?? '本地聊天暂时不可用，请稍后重试。');
        }
        notifyListeners();
      }
    } on Object {
      if (!accepted &&
          optimisticallyAdded &&
          generation == _restoreGeneration) {
        _removeUserTurn(requestId);
        notifyListeners();
      }
      rethrow;
    }
    if (!completed || !committed) {
      if (generation == _restoreGeneration) {
        _streamingText = '';
        if (!accepted && optimisticallyAdded) {
          _removeUserTurn(requestId);
        }
      }
      return false;
    }
    if (generation != _restoreGeneration) {
      return false;
    }
    _streamingText = '';
    _pendingRequestId = null;
    _pendingText = null;
    return true;
  }

  Future<void> stop() async {
    final requestId = _pendingRequestId;
    if (!_sending || requestId == null) {
      return;
    }
    await _gateway.cancel(requestId);
  }

  /// 等正在流式回复的一轮结束后再发送：语音转写完成时栖语可能仍在
  /// 回复，说完的话照常排队发出，不丢也不并发。
  Future<bool> sendWhenIdle(String text) async {
    if (_sending) {
      final idle = Completer<void>();
      void listener() {
        if (!_sending && !idle.isCompleted) {
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
    super.dispose();
  }
}

final Uuid _requestIdUuid = Uuid();

String _defaultRequestId() => 'chat-${_requestIdUuid.v4()}';

String _readableError(Object error) => switch (error) {
  LocalChatGatewayException() => error.message,
  _ => '本地聊天暂时不可用，请稍后重试。',
};
