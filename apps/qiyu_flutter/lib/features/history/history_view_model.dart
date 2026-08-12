import 'dart:async';

import 'package:flutter/foundation.dart';

import 'history_client.dart';

final class HistoryViewModel extends ChangeNotifier {
  HistoryViewModel(
    this._gateway, {
    required this.onSessionDeleted,
    bool autoStart = true,
  }) {
    if (autoStart) {
      unawaited(refresh());
    }
  }

  final HistoryGateway _gateway;
  final void Function(String sessionId) onSessionDeleted;

  HistoryListing? _listing;
  bool _loading = false;
  bool _refreshed = false;
  bool _deleting = false;
  String? _errorMessage;

  HistoryListing? get listing => _listing;
  bool get loading => _loading && !_refreshed;
  bool get deleting => _deleting;
  String? get errorMessage => _errorMessage;

  Future<void> refresh() async {
    if (_loading) {
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      _listing = await _gateway.fetchHistory();
      _errorMessage = null;
      _refreshed = true;
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> deleteSession(String sessionId) async {
    if (_deleting) {
      return false;
    }
    _deleting = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _gateway.deleteSession(sessionId);
      onSessionDeleted(sessionId);
      _listing = await _gateway.fetchHistory();
      _refreshed = true;
      return true;
    } on Object catch (error) {
      _errorMessage = _readableError(error);
      return false;
    } finally {
      _deleting = false;
      notifyListeners();
    }
  }
}

String _readableError(Object error) => switch (error) {
  HistoryGatewayException() => error.message,
  _ => '历史记录暂时不可用，请稍后重试。',
};
