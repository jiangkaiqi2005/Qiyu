import 'dart:typed_data';

export 'voice_recorder_platform_stub.dart'
    if (dart.library.js_interop) 'voice_recorder_platform_web.dart';

/// 一段完整录音（或其转换结果）：字节只存在于内存，随转写完成或
/// 取消即丢弃，永不落盘。
final class RecordedAudio {
  const RecordedAudio({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

/// 语音输入的浏览器能力接缝（与备份平台接缝同构）：Web 构建走真实
/// getUserMedia + MediaRecorder；其余平台（含 widget 测试环境）按
/// 「不支持」如实呈现，界面置灰而不是假装成功。
abstract interface class VoiceRecorderPlatform {
  bool get supported;

  /// 请求麦克风并开始录音；浏览器不支持、无可用编码或用户拒绝授权时
  /// 返回 null，调用方按「无法使用麦克风」提示。
  Future<VoiceRecordingSession?> start();

  /// 把一段录音转换成 16kHz、16-bit 单声道 WAV（豆包流式语音识别只吃
  /// 这个格式，解码与重采样都在浏览器完成，本机 Host 不碰音频）。
  /// 仅当语音服务是豆包协议时才会被调用；失败抛错由调用方按可重试
  /// 失败呈现。
  Future<RecordedAudio> toWav16kMono(RecordedAudio audio);
}

/// 一次录音会话：音频字节只存在于内存缓冲，stop/discard 后即丢弃，
/// 永不落盘、不进会话记录。
abstract interface class VoiceRecordingSession {
  /// MediaRecorder 产出的容器类型（audio/webm 或 audio/mp4，不带编解码
  /// 参数）；随转写请求原样上送本机程序。
  String get mimeType;

  /// 结束录音并取回完整音频字节；会话只应停止一次。
  Future<Uint8List> stop();

  /// 丢弃录音：停止全部轨道并放弃已缓存字节，不产生任何数据。
  void discard();
}
