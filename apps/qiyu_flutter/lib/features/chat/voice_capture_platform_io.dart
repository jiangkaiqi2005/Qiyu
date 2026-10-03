// 连续 PCM 采集的 io 平台实现（T04 阶段）：按「不支持」如实降级。
//
// Windows App 客户端与 Flutter Web 同构建（浏览器承载），真正的原生
// 采集只有安卓（T05：AudioRecord 通信音源 + 同时录放 + 前台服务）。
// T05 落地时替换本文件，接口契约见 [VoiceCapturePlatform]。
import 'dart:typed_data';

import 'voice_capture_platform.dart';

final class IoVoiceCapturePlatform implements VoiceCapturePlatform {
  const IoVoiceCapturePlatform();

  @override
  bool get supported => false;

  @override
  Future<VoiceCaptureSession?> start({
    required void Function(Uint8List pcm) onChunk,
    required void Function(String reason) onUnavailable,
  }) async => null;
}

VoiceCapturePlatform createVoiceCapturePlatform() =>
    const IoVoiceCapturePlatform();
