import 'dart:typed_data';

export 'voice_recorder_platform_stub.dart'
    if (dart.library.js_interop) 'voice_recorder_platform_web.dart'
    if (dart.library.io) 'voice_recorder_platform_io.dart';

/// 契约目标采样率：豆包流式语音识别只吃 16kHz、16-bit、单声道 WAV。
/// web 与安卓两端共用这一个常量（与 [packWav16kMonoPcm] 写进 RIFF 头
/// 的取值同源），不留两份可以各自漂移的值。
const wav16kMonoTargetSampleRate = 16000;

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

/// 安卓授权先独立完成，本次授权手势不能继续起录。
enum VoicePermissionResult { ready, grantedNow, denied }

abstract interface class PermissionAwareVoiceRecorderPlatform {
  Future<VoicePermissionResult> preparePermission();
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

/// 把 16kHz、16-bit、单声道、小端 PCM 打包成 44 字节 RIFF 头 + data 的
/// 完整 WAV：RIFF 尺寸 = 36 + 数据长，fmt 块 16 字节（PCM=1、单声道、
/// 16000Hz、字节率 32000、块对齐 2、位深 16），data 块紧随其后。
///
/// 这是 web 与安卓**唯一一份**头部实现——平台差异只留在各自喂进来的
/// PCM 上（安卓：原生 AudioRecord 已按契约采样；web：浏览器解码重采样
/// 后的 Float32 → Int16 小端量化），产物字节两端必然同构，改动不必
/// 再两端同步。dart 层契约对齐测试逐字段断言。
Uint8List packWav16kMonoPcm(Uint8List pcmLe) {
  final wav = Uint8List(44 + pcmLe.length);
  final view = ByteData.view(wav.buffer);
  var offset = 0;
  void ascii(String text) {
    for (final code in text.codeUnits) {
      view.setUint8(offset, code);
      offset += 1;
    }
  }

  void u32(int value) {
    view.setUint32(offset, value, Endian.little);
    offset += 4;
  }

  void u16(int value) {
    view.setUint16(offset, value, Endian.little);
    offset += 2;
  }

  ascii('RIFF');
  u32(36 + pcmLe.length);
  ascii('WAVE');
  ascii('fmt ');
  u32(16); // fmt 块长度
  u16(1); // PCM
  u16(1); // 单声道
  u32(wav16kMonoTargetSampleRate);
  u32(wav16kMonoTargetSampleRate * 2); // 字节率 = 采样率 × 块对齐
  u16(2); // 块对齐 = 2 字节
  u16(16); // 位深
  ascii('data');
  u32(pcmLe.length);
  wav.setRange(44, wav.length, pcmLe);
  return wav;
}
