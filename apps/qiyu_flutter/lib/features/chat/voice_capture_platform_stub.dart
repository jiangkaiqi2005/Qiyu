// 连续 PCM 采集的缺省实现（T04 阶段）：所有平台都按「不支持」如实降级。
//
// Web 构建由条件导出换成 [VoiceCapturePlatform] 的浏览器实现；安卓的
// 同时录放采集是 T05 的范围，在那之前安卓也走这里——通话入口按不可用
// 引导，不假装能采集。
import 'dart:typed_data';

import 'voice_capture_platform.dart';

final class StubVoiceCapturePlatform implements VoiceCapturePlatform {
  const StubVoiceCapturePlatform();

  @override
  bool get supported => false;

  @override
  Future<VoiceCaptureSession?> start({
    required void Function(Uint8List pcm) onChunk,
    required void Function(String reason) onUnavailable,
  }) async => null;
}

VoiceCapturePlatform createVoiceCapturePlatform() =>
    const StubVoiceCapturePlatform();
