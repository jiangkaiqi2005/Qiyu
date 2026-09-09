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
  }) : _playerPlatform = playerPlatform ?? createVoicePlayerPlatform();

  final TtsSettingsGateway _gateway;
  final VoicePlayerPlatform _playerPlatform;

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
  Future<TtsConnectionTest> runConnectionTest(TtsSettingsDraft draft) =>
      _gateway.testConnection(draft);

  @override
  void beforeConnectionTest() {
    // 必须在按钮点击后的第一个 await 前同步发生（基类钩子保证时机）。
    _playerPlatform.prepareForUserGesturePlayback();
  }

  @override
  Future<void>? afterConnectionTest(TtsConnectionTest? result) =>
      _playPreview(result);

  /// 再听一次最近一次成功的试听（音频只存在内存，页面离开即丢）。
  Future<void> replayPreview() async {
    _playerPlatform.prepareForUserGesturePlayback();
    await _playPreview(testResult);
    notifyListeners();
  }

  Future<void> _playPreview(TtsConnectionTest? result) async {
    final audio = result?.audio;
    if (audio == null || !result!.succeeded) {
      return;
    }
    final playback = await _playerPlatform.play(audio, mimeType: 'audio/mpeg');
    if (playback == null) {
      errorMessage = '语音服务已连接，但本机没能播放试听。点「再听一次试听」重试。';
      return;
    }
    errorMessage = null;
    // 读取 done 让平台在播放结束后释放内存音频；试听本身不阻塞设置页交互。
    unawaited(playback.done);
  }
}
