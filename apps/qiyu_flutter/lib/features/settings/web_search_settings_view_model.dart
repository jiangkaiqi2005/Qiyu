import 'dart:async';

import 'package:flutter/foundation.dart';

import '../baseline/host_api_gateway.dart';
import 'web_search_settings_client.dart';

final class WebSearchSettingsViewModel extends ChangeNotifier {
  WebSearchSettingsViewModel(this._gateway, {bool autoStart = true}) {
    if (autoStart) {
      unawaited(initialize());
    }
  }

  final WebSearchSettingsGateway _gateway;
  WebSearchSettings? _settings;
  String? _errorMessage;
  bool _loading = false;
  bool _saving = false;
  bool _initialized = false;

  WebSearchSettings? get settings => _settings;
  String? get errorMessage => _errorMessage;
  bool get loading => _loading && !_initialized;
  bool get saving => _saving;

  Future<void> initialize() async {
    if (_loading || _initialized) {
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      _settings = await _gateway.read();
      _errorMessage = null;
      _initialized = true;
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> save(WebSearchSettingsDraft draft) async {
    if (_saving) {
      return false;
    }
    _saving = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _settings = await _gateway.save(draft);
      return true;
    } on Object catch (error) {
      _errorMessage = _readableError(error);
      return false;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  Future<void> forgetApiKey() async {
    if (_saving) {
      return;
    }
    _saving = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _settings = await _gateway.forgetApiKey();
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}

String _readableError(Object error) =>
    readableError(error, fallback: '联网搜索设置暂时不可用，请稍后重试。');
