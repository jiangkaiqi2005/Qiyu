import 'dart:typed_data';

export 'voice_player_platform_stub.dart'
    if (dart.library.js_interop) 'voice_player_platform_web.dart';

/// 一次播放会话：done 在自然播完、被 stop 或播放出错时完成（不抛）。
abstract interface class VoicePlayback {
  Future<void> get done;

  /// 立即停止播放（幂等，停完 done 也会完成）。
  void stop();
}

/// 语音输出的浏览器能力接缝（与录音平台接缝同构）：Web 构建走真实
/// HTMLAudioElement + blob URL（播完即 revoke，字节只存在于内存）；
/// 其余平台（含 widget 测试环境）按「不支持」如实呈现，调用方按
/// 「读不出来」降级，不抛异常。
abstract interface class VoicePlayerPlatform {
  bool get supported;

  /// 播放一段完整音频字节。浏览器不支持解码、自动播放被拒或设备
  /// 不可用时返回 null，由调用方决定降级（试听提示、朗读静默跳过）。
  Future<VoicePlayback?> play(Uint8List bytes, {required String mimeType});
}

/// 需要浏览器用户手势才能启用有声播放的平台能力。
///
/// 调用方必须在点击回调的同步阶段调用 [prepareForPlayback]，不能先等待
/// 合成或其他异步工作；不需要这项能力的平台只实现 [VoicePlayerPlatform]。
abstract interface class UserGestureVoicePlayerPlatform {
  void prepareForPlayback();
}

extension VoicePlayerUserGesture on VoicePlayerPlatform {
  /// 在当前用户点击/按键的同步调用栈中预备后续异步音频播放。
  void prepareForUserGesturePlayback() {
    if (this case final UserGestureVoicePlayerPlatform player) {
      player.prepareForPlayback();
    }
  }
}
