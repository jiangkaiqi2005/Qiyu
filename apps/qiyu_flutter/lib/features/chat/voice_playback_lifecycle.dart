import 'dart:typed_data';

import 'voice_player_platform.dart';

/// 两条播放调用链共有的活动所有权；业务队列和连接测试结果仍归调用方。
final class VoicePlaybackLifecycle {
  VoicePlaybackLifecycle(
    this._platform, {
    required void Function() onInterrupted,
  }) {
    if (_platform case final InterruptibleVoicePlayerPlatform player) {
      _unsubscribe = player.onOutputInterrupted(onInterrupted);
    }
  }

  final VoicePlayerPlatform _platform;
  void Function()? _unsubscribe;
  int _generation = 0;
  VoicePlayback? _playback;

  bool get interruptible => _platform is InterruptibleVoicePlayerPlatform;

  VoicePlaybackActivity capture() => VoicePlaybackActivity._(this, _generation);

  void prepareForUserGesture() => _platform.prepareForUserGesturePlayback();

  void setVolume(double volume) => _playback?.setVolume(volume);

  void stop() {
    _generation++;
    _playback?.stop();
    _playback = null;
    _endOutput();
  }

  void unsubscribe() => _unsubscribe?.call();

  void _endOutput() {
    if (_platform case final InterruptibleVoicePlayerPlatform player) {
      player.endOutput();
    }
  }
}

/// 异步阶段持有同一活动；停止之后的结果不能占用或释放新活动。
final class VoicePlaybackActivity {
  VoicePlaybackActivity._(this._owner, this._generation);

  final VoicePlaybackLifecycle _owner;
  final int _generation;

  bool get isCurrent => _generation == _owner._generation;

  /// 无焦点能力时返回 null，保留 Web 在合成前不额外 await 的时序。
  Future<bool>? prepare() {
    if (_owner._platform case final InterruptibleVoicePlayerPlatform player) {
      return player.beginOutput();
    }
    return null;
  }

  Future<VoicePlayback?> play(Uint8List audio, {double volume = 1.0}) =>
      _owner._platform.play(audio, mimeType: 'audio/mpeg', volume: volume);

  /// 接收原平台 await 的结果，迟到句柄立即停止，不增加额外异步阶段。
  bool accept(VoicePlayback? playback) {
    if (!isCurrent) {
      playback?.stop();
      return false;
    }
    _owner._playback = playback;
    return true;
  }

  void finish() {
    if (!isCurrent) return;
    _owner._playback = null;
    _owner._endOutput();
  }
}
