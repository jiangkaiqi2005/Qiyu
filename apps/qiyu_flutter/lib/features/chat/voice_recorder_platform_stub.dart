import 'voice_recorder_platform.dart';

/// 非 Web 环境（含 widget 测试）的缺省实现：麦克风录音不可用，
/// 调用方必须按 [supported] 如实呈现置灰。
final class UnsupportedVoiceRecorderPlatform implements VoiceRecorderPlatform {
  const UnsupportedVoiceRecorderPlatform();

  @override
  bool get supported => false;

  @override
  Future<VoiceRecordingSession?> start() async => null;

  @override
  Future<RecordedAudio> toWav16kMono(RecordedAudio audio) async {
    // 非浏览器环境没有 Web Audio 解码能力；真实调用只会发生在 Web 构建。
    throw UnsupportedError('当前环境不支持音频转换。');
  }
}

VoiceRecorderPlatform createVoiceRecorderPlatform() =>
    const UnsupportedVoiceRecorderPlatform();
