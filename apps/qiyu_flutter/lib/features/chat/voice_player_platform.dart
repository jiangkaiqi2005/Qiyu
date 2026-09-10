import 'dart:typed_data';

export 'voice_player_platform_stub.dart'
    if (dart.library.js_interop) 'voice_player_platform_web.dart'
    if (dart.library.io) 'voice_player_platform_io.dart';

/// 播放音量偏好的**唯一存储键名**（值是 "0.00" ~ "1.00" 的小数串）：
/// web 落 localStorage，安卓落应用私有目录同名文件，语义逐条同构。
/// 键名单一是为了不留下第二份可以各自漂移的音量偏好（与
/// `settingsCollapsedSectionsKey` 同一先例）；文本怎么读、怎么写由下面的
/// [parseVoiceVolumePreference] 与 [encodeVoiceVolumePreference] 单一定义，
/// 两端只各自负责存取动作与异常处理。
const String voiceOutputVolumeStorageKey = 'qiyu_voice_output_volume';

/// 存储文本 → 音量（两端唯一的**解析**规则，纯函数、不碰存储）。
///
/// 只接受可解析、有限且落在 0.0~1.0 闭区间内的值；其余（从没存过、空串、
/// 不可解析文本、越界数字、NaN、±Infinity）一律返回 null，由调用方退回
/// 缺省 1.0。**读取不做 clamp**——把越界值收进区间是写入侧的事，读回一条
/// 被人为写坏的记录时退回缺省比采纳更安全。
double? parseVoiceVolumePreference(String? stored) {
  if (stored == null) {
    return null;
  }
  final parsed = double.tryParse(stored);
  if (parsed != null && parsed.isFinite && parsed >= 0.0 && parsed <= 1.0) {
    return parsed;
  }
  return null;
}

/// 音量 → 存储文本（两端唯一的**编码**规则，纯函数、不碰存储）。
///
/// 沿用既有表达式：先把值限制到 0.0~1.0，再固定两位小数。非有限值与负零
/// 的结果就是这个表达式在各平台上的实际结果（NaN 与 +Infinity 归上界、
/// -Infinity 归下界、负零写成 "0.00"），不在此新增拒绝策略。
String encodeVoiceVolumePreference(double volume) =>
    volume.clamp(0.0, 1.0).toStringAsFixed(2);

/// 一次播放会话：done 在自然播完、被 stop 或播放出错时完成（不抛）。
abstract interface class VoicePlayback {
  Future<void> get done;

  /// 立即停止播放（幂等，停完 done 也会完成）。
  void stop();

  /// 实时调节当前正在播放的音量（0.0 ~ 1.0）。
  void setVolume(double volume);
}

/// 语音输出的浏览器能力接缝（与录音平台接缝同构）：Web 构建走真实
/// Web Audio API GainNode（播完即释放，字节只存在于内存）；
/// 其余平台（含 widget 测试环境）按「不支持」如实呈现，调用方按
/// 「读不出来」降级，不抛异常。
abstract interface class VoicePlayerPlatform {
  bool get supported;

  /// 播放一段完整音频字节。浏览器不支持解码、自动播放被拒或设备
  /// 不可用时返回 null，由调用方决定降级（试听提示、朗读静默跳过）。
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  });

  /// 读取持久化的播放音量偏好（0.0 ~ 1.0），缺省 1.0。
  double getInitialVolume() => 1.0;

  /// 持久化保存播放音量偏好。
  void saveVolume(double volume) {}
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
