import 'dart:async';

import '../chat/voice_player_platform.dart';
import '../chat/voice_playback_lifecycle.dart';
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
  }) {
    _playback = VoicePlaybackLifecycle(
      playerPlatform ?? createVoicePlayerPlatform(),
      onInterrupted: stopPreview,
    );
    _testActivity = _playback.capture();
  }

  final TtsSettingsGateway _gateway;
  late final VoicePlaybackLifecycle _playback;
  late VoicePlaybackActivity _testActivity;
  bool _disposed = false;
  Future<bool>? _prepared;

  void stopPreview({bool discardPreview = false}) {
    if (cancelConnectionTest()) scheduleMicrotask(notifyListeners);
    _playback.stop();
    if (discardPreview) resetTransientResults();
  }

  @override
  void dispose() {
    _playback.unsubscribe();
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
    final activity = _testActivity;
    if (_prepared != null) {
      final allowed = await _prepared!;
      if (!allowed || !activity.isCurrent) {
        return const TtsConnectionTest(
          succeeded: false,
          message: '试听已停止，请主动重试。',
        );
      }
    }
    try {
      final result = await _gateway.testConnection(draft);
      if (!activity.isCurrent) {
        return const TtsConnectionTest(
          succeeded: false,
          message: '试听已停止，请主动重试。',
        );
      }
      return result;
    } on Object {
      activity.finish();
      rethrow;
    }
  }

  @override
  void beforeConnectionTest() {
    stopPreview();
    _testActivity = _playback.capture();
    // 必须在按钮点击后的第一个 await 前同步发生（基类钩子保证时机）。
    _playback.prepareForUserGesture();
    _prepared = _testActivity.prepare();
  }

  @override
  Future<void>? afterConnectionTest(TtsConnectionTest? result) =>
      _playPreview(result, _testActivity);

  /// 再听一次最近一次成功的试听（音频只存在内存，页面离开即丢）。
  Future<void> replayPreview() async {
    if (_disposed) return;
    stopPreview();
    _playback.prepareForUserGesture();
    final activity = _playback.capture();
    final prepared = activity.prepare();
    if (prepared != null) {
      if (!await prepared || !activity.isCurrent) return;
    }
    await _playPreview(testResult, activity);
    notifyListeners();
  }

  Future<void> _playPreview(
    TtsConnectionTest? result,
    VoicePlaybackActivity activity,
  ) async {
    if (_disposed || !activity.isCurrent) return;
    final audio = result?.audio;
    if (audio == null || !result!.succeeded) {
      activity.finish();
      return;
    }
    final playback = await activity.play(audio);
    if (!activity.accept(playback)) {
      return;
    }
    if (playback == null) {
      activity.finish();
      errorMessage = '语音服务已连接，但本机没能播放试听。点「再听一次试听」重试。';
      return;
    }
    errorMessage = null;
    // 读取 done 让平台在播放结束后释放内存音频；试听本身不阻塞设置页交互。
    unawaited(
      playback.done.then((_) => activity.finish()),
    );
  }
}
