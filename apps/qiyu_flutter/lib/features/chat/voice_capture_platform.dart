import 'dart:typed_data';

export 'voice_capture_platform_stub.dart'
    if (dart.library.js_interop) 'voice_capture_platform_web.dart'
    if (dart.library.io) 'voice_capture_platform_io.dart';

/// Omni 双工通话的上行采集契约（T04，spec:70）：
/// PCM16、16 kHz、单声道，约 100 ms 一块，平台原生回声消除与同时收发。
///
/// 旧「停止后返回全量字节」的录音接口（[VoiceRecorderPlatform] 一族）不能
/// 充当双工采集——那是一条「录完才交」的整段通道，spec:82 明确排除。本接缝
/// 是连续流式采集，块到手即交，双方音频同时收发；安卓（T05）复用同一接缝
/// 换平台实现，平台代码不渗入 Host 与通话控制器。
///
/// 采样率常量只描述上行块的字节契约；播放侧采样率由协商结果（下行事件）
/// 决定，两者互不推断。
const int omniCaptureSampleRate = 16000;

/// 一路上行采集会话：持续 [start] 时交给它的回调出块，直到 [stop]。
abstract interface class VoiceCaptureSession {
  /// 闭麦／恢复收音（同一通话内复用，spec 前端摆放）：闭麦后平台停发
  /// 有效音频，恢复沿用同一会话，不重新走授权。
  void setMuted(bool muted);

  /// 结束采集并释放麦克风与相关资源（幂等）。
  void stop();
}

/// 连续 PCM 采集的平台能力接缝（与录音/播放平台接缝同构）：
/// Web 构建走 getUserMedia + AudioWorklet（标准回声处理），安卓（T05）
/// 将走 AudioRecord 通信音源，测试宿主按「不支持」如实降级。
abstract interface class VoiceCapturePlatform {
  /// 当前平台是否具备连续采集能力。不具备时入口置灰或按不可用引导，
  /// 不抛异常。
  bool get supported;

  /// 开始一路连续采集：
  /// - [onChunk] 持续收到 PCM16 LE 单声道 [omniCaptureSampleRate] 块
  ///   （约 100 ms 一块），块内样本完整有序；音频只在内存流转。
  /// - [onUnavailable] 在设备失效、轨道被系统夺走等**采集中断**时回调
  ///   （start 成功后才可能发生）；reason 是面向诊断的简述，不是面向
  ///   用户的文案。
  ///
  /// 返回 null 表示没有开始（授权被拒、设备不可用、采集链路起不来），
  /// 调用方按「可继续打字」如实呈现，不偷偷重试。
  Future<VoiceCaptureSession?> start({
    required void Function(Uint8List pcm) onChunk,
    required void Function(String reason) onUnavailable,
  });
}
