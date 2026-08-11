import 'dart:async';

import 'package:flutter/foundation.dart';

import 'provider_settings_client.dart';

final class ProviderSettingsViewModel extends ChangeNotifier {
  ProviderSettingsViewModel(this._gateway, {bool autoStart = true}) {
    if (autoStart) {
      unawaited(initialize());
    }
  }

  final ProviderSettingsGateway _gateway;
  ProviderSettings? _settings;
  ProviderTestResult? _testResult;
  String? _errorMessage;
  bool _loading = false;
  bool _saving = false;
  bool _testing = false;
  bool _initialized = false;

  ProviderSettings? get settings => _settings;
  ProviderTestResult? get testResult => _testResult;
  String? get errorMessage => _errorMessage;
  bool get loading => _loading && !_initialized;
  bool get saving => _saving;
  bool get testing => _testing;

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

  Future<bool> save(ProviderSettingsDraft draft) async {
    if (_saving) {
      return false;
    }
    _saving = true;
    _testResult = null;
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

  Future<void> testConnection() async {
    if (_testing) {
      return;
    }
    _testing = true;
    _testResult = null;
    _errorMessage = null;
    notifyListeners();
    try {
      _testResult = await _gateway.testConnection();
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    } finally {
      _testing = false;
      notifyListeners();
    }
  }

  Future<void> forgetApiKey() async {
    if (_saving) {
      return;
    }
    _saving = true;
    _testResult = null;
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

String _readableError(Object error) => switch (error) {
  ProviderSettingsException() => error.message,
  _ => '模型设置暂时不可用，请稍后重试。',
};
