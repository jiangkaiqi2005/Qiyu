import 'dart:typed_data';

import 'voice_player_platform.dart';

/// 非 Web 环境（含 widget 测试）的缺省实现：音频播放不可用，
/// 调用方按 [supported] 如实降级。
final class UnsupportedVoicePlayerPlatform implements VoicePlayerPlatform {
  const UnsupportedVoicePlayerPlatform();

  @override
  bool get supported => false;

  @override
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async => null;
}

VoicePlayerPlatform createVoicePlayerPlatform() =>
    const UnsupportedVoicePlayerPlatform();
