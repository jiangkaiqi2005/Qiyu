import 'dart:async';

import 'package:flutter/foundation.dart';

import '../baseline/host_api_gateway.dart';
import '../chat/voice_player_platform.dart';
import 'tts_settings_client.dart';

/// 语音朗读设置的视图模型：与 SttSettingsViewModel 同构；连接测试成功
/// 时用返回的试听音频直接经播放平台播出来（读不出声只影响试听，不
/// 影响连接成功的结论）。
final class TtsSettingsViewModel extends ChangeNotifier {
  TtsSettingsViewModel(
    this._gateway, {
    VoicePlayerPlatform? playerPlatform,
    bool autoStart = true,
  }) : _playerPlatform = playerPlatform ?? createVoicePlayerPlatform() {
    if (autoStart) {
      unawaited(initialize());
    }
  }

  final TtsSettingsGateway _gateway;
  final VoicePlayerPlatform _playerPlatform;
  TtsSettings? _settings;
  TtsConnectionTest? _testResult;
  String? _errorMessage;
  bool _loading = false;
  bool _saving = false;
  bool _testing = false;
  bool _initialized = false;

  TtsSettings? get settings => _settings;
  TtsConnectionTest? get testResult => _testResult;
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

  Future<bool> save(TtsSettingsDraft draft) async {
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

  Future<void> testConnection(TtsSettingsDraft draft) async {
    if (_testing) {
      return;
    }
    _testing = true;
    _testResult = null;
    _errorMessage = null;
    notifyListeners();
    try {
      _testResult = await _gateway.testConnection(draft);
      await _playPreview(_testResult);
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    } finally {
      _testing = false;
      notifyListeners();
    }
  }

  /// 再听一次最近一次成功的试听（音频只存在内存，页面离开即丢）。
  Future<void> replayPreview() async {
    await _playPreview(_testResult);
    notifyListeners();
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

  Future<void> _playPreview(TtsConnectionTest? result) async {
    final audio = result?.audio;
    if (audio == null || !result!.succeeded) {
      return;
    }
    await _playerPlatform.play(audio, mimeType: 'audio/mpeg');
  }
}

String _readableError(Object error) =>
    readableError(error, fallback: '语音朗读设置暂时不可用，请稍后重试。');
