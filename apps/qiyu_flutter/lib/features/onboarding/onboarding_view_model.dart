import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/provider_settings_client.dart';
import 'onboarding_client.dart';

final class OnboardingViewModel extends ChangeNotifier {
  OnboardingViewModel(
    this._onboardingGateway,
    this._providerSettingsGateway, {
    bool autoStart = true,
  }) {
    if (autoStart) {
      unawaited(initialize());
    }
  }

  final OnboardingGateway _onboardingGateway;
  final ProviderSettingsGateway _providerSettingsGateway;

  bool _completed = false;
  bool _providerConfigured = false;
  bool _loading = false;
  bool _initialized = false;
  bool _completing = false;
  String? _errorMessage;
  String? _completeError;

  bool get completed => _completed;
  bool get providerConfigured => _providerConfigured;
  bool get loading => _loading && !_initialized;
  bool get completing => _completing;
  String? get errorMessage => _errorMessage;
  String? get completeError => _completeError;

  Future<void> initialize() async {
    if (_loading || _initialized) {
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      final (onboardingState, settings) = await (
        _onboardingGateway.read(),
        _providerSettingsGateway.read(),
      ).wait;
      _completed = onboardingState.completed;
      _providerConfigured = settings.configured;
      _errorMessage = null;
      _initialized = true;
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 重读初见状态（ticket 23）：清除产品数据会删掉本机初见记录，
  /// 清除成功后调用本方法回到「未完成」，根路由随即重走初见引导。
  Future<void> reload() async {
    _initialized = false;
    await initialize();
  }

  Future<bool> complete() async {
    if (_completing) {
      return false;
    }
    _completing = true;
    _completeError = null;
    try {
      await _onboardingGateway.complete();
      _completed = true;
      return true;
    } on Object catch (error) {
      // 写入失败不阻塞根路由：留在首次见面页内联提示，用户可直接重试。
      _completeError = _readableError(error);
      return false;
    } finally {
      _completing = false;
      notifyListeners();
    }
  }
}

String _readableError(Object error) => switch (error) {
  OnboardingGatewayException() => error.message,
  ProviderSettingsException() => error.message,
  _ => '本机程序暂时不可用，请稍后重试。',
};
