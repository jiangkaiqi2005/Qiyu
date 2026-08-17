import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:uuid/uuid.dart';

import '../baseline/host_connection_probe.dart';
import 'local_chat_client.dart';

typedef RequestIdFactory = String Function();

final class LocalChatViewModel extends ChangeNotifier {
  LocalChatViewModel(
    this._gateway, {
    HostConnectionProbe? hostConnectionProbe,
    RequestIdFactory? requestIdFactory,
    bool autoStart = true,
    Duration monitorInterval = const Duration(seconds: 2),
  }) : _hostConnectionProbe = hostConnectionProbe ?? HttpHostConnectionProbe(),
       _requestIdFactory = requestIdFactory ?? _defaultRequestId {
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
  bool get sending => _sending;
  bool get waiting => _waiting;
  String get streamingText => _streamingText;
  bool get hostStopped => _hostAvailable == false;
  bool get hasLocalFallback => _messages.any(
    (message) =>
        message.speaker == LocalChatSpeaker.qiyu &&
        message.source == ReplySource.local,
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

  Future<void> _applyRestore(int generation, {String? sessionId}) async {
    try {
      final snapshot = await _gateway.restore(sessionId: sessionId);
      if (generation != _restoreGeneration) {
        return;
      }
      _sessionId = snapshot.sessionId;
      _messages
        ..clear()
        ..addAll(snapshot.messages);
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
    _sending = true;
    _errorMessage = null;
    notifyListeners();
    final requestId = _pendingText == trimmed && _pendingRequestId != null
        ? _pendingRequestId!
        : _requestIdFactory();
    _pendingRequestId = requestId;
    _pendingText = trimmed;
    try {
      return await _sendStreaming(requestId: requestId, text: trimmed);
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
  }) async {
    final generation = _restoreGeneration;
    List<String>? finalMessages;
    ReplySource? source;
    FallbackReason? fallbackReason;
    var completed = false;
    var committed = false;
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
          if (generation == _restoreGeneration &&
              !_messages.any(
                (message) =>
                    message.requestId == requestId &&
                    message.speaker == LocalChatSpeaker.user,
              )) {
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
            if (generation == _restoreGeneration) {
              _messages.addAll(
                messages.map(
                  (message) => LocalChatMessage(
                    requestId: requestId,
                    speaker: LocalChatSpeaker.qiyu,
                    text: message,
                    source: replySource,
                    fallbackReason: fallbackReason,
                  ),
                ),
              );
              _streamingText = '';
              _waiting = false;
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
    if (!completed || !committed) {
      if (generation == _restoreGeneration) {
        _streamingText = '';
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
