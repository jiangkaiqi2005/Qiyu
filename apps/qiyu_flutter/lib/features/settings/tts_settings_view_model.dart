import 'dart:async';

import '../chat/voice_player_platform.dart';
import 'keyed_settings_view_model.dart';
import 'tts_settings_client.dart';

/// 语音朗读设置的视图模型：与模型服务域共用
/// [TestableKeyedSettingsViewModel] 的加载/保存/遗忘/测试状态机；连接
/// 测试成功时用返回的试听音频直接经播放平台播出来（读不出声只影响
/// 试听，不影响连接成功的结论）。
final class TtsSettingsViewModel
    extends
        TestableKeyedSettingsViewModel<
          TtsSettings,
          TtsSettingsDraft,
          TtsConnectionTest
        > {
  TtsSettingsViewModel(
    this._gateway, {
    VoicePlayerPlatform? playerPlatform,
    super.autoStart,
  }) : _playerPlatform = playerPlatform ?? createVoicePlayerPlatform() {
    if (_playerPlatform case final InterruptibleVoicePlayerPlatform player) {
      _unsubscribeInterruption = player.onOutputInterrupted(stopPreview);
    }
  }

  final TtsSettingsGateway _gateway;
  final VoicePlayerPlatform _playerPlatform;
  VoicePlayback? _preview;
  int _generation = 0;
  int _testGeneration = 0;
  bool _disposed = false;
  void Function()? _unsubscribeInterruption;
  Future<bool>? _prepared;

  void _endOutput() {
    if (_playerPlatform case final InterruptibleVoicePlayerPlatform player) {
      player.endOutput();
    }
  }

  void stopPreview({bool discardPreview = false}) {
    if (cancelConnectionTest()) scheduleMicrotask(notifyListeners);
    _generation++;
    _preview?.stop();
    _preview = null;
    _endOutput();
    if (discardPreview) resetTransientResults();
  }

  @override
  void dispose() {
    _unsubscribeInterruption?.call();
    stopPreview(discardPreview: true);
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  String get errorFallback => '语音朗读设置暂时不可用，请稍后重试。';

  @override
  Future<TtsSettings> readSettings() => _gateway.read();

  @override
  Future<TtsSettings> saveSettings(TtsSettingsDraft draft) =>
      _gateway.save(draft);

  @override
  Future<TtsSettings> forgetKeySettings() => _gateway.forgetApiKey();

  @override
  Future<TtsConnectionTest> runConnectionTest(TtsSettingsDraft draft) async {
    final generation = _testGeneration;
    if (_prepared != null) {
      final allowed = await _prepared!;
      if (!allowed || generation != _generation) {
        return const TtsConnectionTest(
          succeeded: false,
          message: '试听已停止，请主动重试。',
        );
      }
    }
    try {
      final result = await _gateway.testConnection(draft);
      if (generation != _generation) {
        return const TtsConnectionTest(
          succeeded: false,
          message: '试听已停止，请主动重试。',
        );
      }
      return result;
    } on Object {
      if (generation == _generation) _endOutput();
      rethrow;
    }
  }

  @override
  void beforeConnectionTest() {
    stopPreview();
    _testGeneration = _generation;
    // 必须在按钮点击后的第一个 await 前同步发生（基类钩子保证时机）。
    _playerPlatform.prepareForUserGesturePlayback();
    _prepared = _playerPlatform is InterruptibleVoicePlayerPlatform
        ? (_playerPlatform as InterruptibleVoicePlayerPlatform).beginOutput()
        : null;
  }

  @override
  Future<void>? afterConnectionTest(TtsConnectionTest? result) =>
      _playPreview(result, _testGeneration);

  /// 再听一次最近一次成功的试听（音频只存在内存，页面离开即丢）。
  Future<void> replayPreview() async {
    if (_disposed) return;
    stopPreview();
    _playerPlatform.prepareForUserGesturePlayback();
    final generation = _generation;
    if (_playerPlatform case final InterruptibleVoicePlayerPlatform player) {
      if (!await player.beginOutput() || generation != _generation) return;
    }
    await _playPreview(testResult, generation);
    notifyListeners();
  }

  Future<void> _playPreview(TtsConnectionTest? result, int generation) async {
    if (_disposed || generation != _generation) return;
    final audio = result?.audio;
    if (audio == null || !result!.succeeded) {
      _endOutput();
      return;
    }
    final playback = await _playerPlatform.play(audio, mimeType: 'audio/mpeg');
    if (_disposed || generation != _generation) {
      playback?.stop();
      return;
    }
    if (playback == null) {
      _endOutput();
      errorMessage = '语音服务已连接，但本机没能播放试听。点「再听一次试听」重试。';
      return;
    }
    errorMessage = null;
    _preview = playback;
    // 读取 done 让平台在播放结束后释放内存音频；试听本身不阻塞设置页交互。
    unawaited(
      playback.done.then((_) {
        if (generation == _generation) {
          _preview = null;
          _endOutput();
        }
      }),
    );
  }
}
