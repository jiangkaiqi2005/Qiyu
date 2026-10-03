import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'voice_recorder_platform.dart';

/// 浏览器授权独立于录音：临时流不接播放器、处理器或上传入口，
/// 包括过时的授权结果，返回调用方前都释放全部轨道。
final class WebMicrophonePermissionPlatform
    implements PermissionAwareVoiceRecorderPlatform {
  const WebMicrophonePermissionPlatform();

  @override
  Future<VoicePermissionResult> preparePermission() async {
    web.MediaStream? stream;
    try {
      stream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
          .toDart;
      return stream.getAudioTracks().toDart.any(
            (track) => track.readyState == 'live',
          )
          ? VoicePermissionResult.ready
          : VoicePermissionResult.denied;
    } on Object {
      return VoicePermissionResult.denied;
    } finally {
      if (stream != null) {
        for (final track in stream.getTracks().toDart) {
          track.stop();
        }
      }
    }
  }
}

PermissionAwareVoiceRecorderPlatform createMicrophonePermissionPlatform() =>
    const WebMicrophonePermissionPlatform();
