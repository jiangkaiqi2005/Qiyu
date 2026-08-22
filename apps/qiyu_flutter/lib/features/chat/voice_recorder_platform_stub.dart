import 'voice_recorder_platform.dart';

/// 非 Web 环境（含 widget 测试）的缺省实现：麦克风录音不可用，
/// 调用方必须按 [supported] 如实呈现置灰。
final class UnsupportedVoiceRecorderPlatform implements VoiceRecorderPlatform {
  const UnsupportedVoiceRecorderPlatform();

  @override
  bool get supported => false;

  @override
  Future<VoiceRecordingSession?> start() async => null;
}

VoiceRecorderPlatform createVoiceRecorderPlatform() =>
    const UnsupportedVoiceRecorderPlatform();
