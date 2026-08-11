import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

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

  final LocalChatGateway _gateway;
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
  String? _pendingRequestId;
  String? _pendingText;

  List<LocalChatMessage> get messages => List.unmodifiable(_messages);
  String? get errorMessage => _errorMessage;
  bool get loading => _initializing && !_initialized;
  bool get sending => _sending;
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
    notifyListeners();
    try {
      await checkHostNow();
      if (hostStopped) {
        return;
      }
      final snapshot = await _gateway.restore(sessionId: _sessionId);
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
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    } finally {
      _initializing = false;
      notifyListeners();
    }
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
      final exchange = await _gateway.send(
        requestId: requestId,
        text: trimmed,
        sessionId: _sessionId,
      );
      _sessionId = exchange.sessionId;
      if (!_messages.any(
        (message) =>
            message.requestId == requestId &&
            message.speaker == LocalChatSpeaker.user,
      )) {
        _messages.add(
          LocalChatMessage(
            requestId: requestId,
            speaker: LocalChatSpeaker.user,
            text: trimmed,
          ),
        );
      }
      if (!_messages.any(
        (message) =>
            message.requestId == requestId &&
            message.speaker == LocalChatSpeaker.qiyu,
      )) {
        _messages.addAll(
          exchange.messages.map(
            (message) => LocalChatMessage(
              requestId: requestId,
              speaker: LocalChatSpeaker.qiyu,
              text: message,
              source: exchange.source,
              fallbackReason: exchange.fallbackReason,
            ),
          ),
        );
      }
      _pendingRequestId = null;
      _pendingText = null;
      return true;
    } on Object catch (error) {
      _errorMessage = _readableError(error);
      return false;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    super.dispose();
  }
}

String _defaultRequestId() =>
    'chat-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

String _readableError(Object error) => switch (error) {
  LocalChatGatewayException() => error.message,
  _ => '本地聊天暂时不可用，请稍后重试。',
};
