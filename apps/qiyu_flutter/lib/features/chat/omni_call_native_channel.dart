// Omni 双工通话的原生通道抽缝（T05）：Android 原生侧 OmniCallBridge.kt
// 注册同名处理器。
//
// **本文件只能从 io 分支文件导入**（voice_capture_platform_io.dart 与
// omni_call_player_platform_io.dart）——它走 flutter/services 的平台通道，
// web 构建里没有这层；web 的采集/播放各有自己的浏览器实现。
import 'dart:async';

import 'package:flutter/services.dart';

/// Android 原生通话通道名（原生侧 OmniCallBridge.kt 注册同名处理器）。
const androidOmniCallChannelName = 'dev.qiyu.app/omni_call';

/// 原生通话通道的抽缝：生产实现走 [MethodChannel]，dart 测试注入 fake
/// （平台通道行为本身归真机冒烟，不在 dart 测试里 mock 平台业务）。
///
/// 采集与播放共用一条原生桥：双工通话是同一通原生资源（前台服务、通话
/// 级焦点、AudioRecord/AudioTrack）的两半，分开注册只会让生命周期收口
/// 各管一段。音频只在内存流转，块经通道直进直出，永不落盘。
abstract interface class OmniCallNativeChannel {
  // ---- 上行采集 ----

  Future<bool> hasMicrophonePermission();

  /// 仅预检 Activity 可见、既有授权和输入设备，不弹权限、不起服务。
  Future<bool> canAutoStartCapture();

  /// 请求麦克风权限（系统弹窗；33+ 上随同一枚系统弹窗尽力请求通知权限，
  /// 结果只看麦克风）。返回 true 表示已授权；拒绝或通道不可用返回 false。
  Future<bool> requestMicrophonePermission();

  /// 请求原生开始连续采集（VOICE_COMMUNICATION 音源 + 可用回声消除 +
  /// microphone 前台服务 + 通话级焦点）。返回 false 表示权限缺失、设备
  /// 不可用或链路起不来；成功后块经 [onCaptureChunk] 持续到达。
  Future<bool> startCapture({int? requestId});

  /// 只取消该次尚未交付的起采；旧请求不能停掉后来开始的通话。
  Future<void> cancelPendingCaptureStart(int requestId);

  /// 结束整通通话的原生资源：停采集、清播放流、摘焦点与前台服务（幂等）。
  Future<void> stopCapture({int? requestId});

  /// 闭麦／恢复：闭麦后原生照读不外发（恢复时无旧数据残留）。
  Future<void> setMuted(bool muted);

  /// 订阅上行 PCM 块（PCM16 LE 单声道 16 kHz，约 100ms 一块）；返回退订。
  void Function() onCaptureChunk(void Function(Uint8List pcm) handler);

  /// 订阅采集中断（设备失效、录音被系统静音、前台服务被系统停止、永久
  /// 焦点丢失等）；reason 是面向诊断的简述。返回退订。
  void Function() onCaptureUnavailable(void Function(String reason) handler);

  // ---- 通话播放（同桥承载，焦点已由整通持有） ----

  /// 真实采集后核验通话焦点、AudioTrack 起播与 PCM 写入；不外发准备音频。
  Future<bool> prepareForAutoPlayback();

  /// 开一路流式 PCM 播放（AudioTrack MODE_STREAM 按协商采样率起播），
  /// 返回流句柄；无法开始返回 null。
  Future<int?> startStream({required int sampleRate, required double volume});

  /// 往流句柄写一块 PCM16 小端字节（只在内存，不落盘）。
  Future<void> appendStreamChunk(int streamId, Uint8List pcm);

  /// 声明流块收完：写完的缓冲播完即自然结束。
  Future<void> endStream(int streamId);

  /// 实时调节指定流的播放音量（0.0 ~ 1.0）。
  Future<void> setStreamVolume(int streamId, double volume);

  /// 显式停止并释放指定流（幂等；不产生 onPlaybackFinished）。
  Future<void> stopStream(int streamId);

  /// 订阅播放流收口回调（自然播完、被打断或底层出错都会到达，显式
  /// 停止不产生）；返回退订函数。
  void Function() onPlaybackFinished(void Function(int streamId) handler);
}

/// [OmniCallNativeChannel] 的 MethodChannel 真实现：进程级单例——上行
/// 块（约每 100ms 一块）与播放收口共用一条底层通道，回调在此统一分发
/// 给全部订阅者（多实例各自注册会互相顶掉底层 handler）。
///
/// 底层 handler 的注册是惰性的（首次订阅回调或首次起采时才发生）：不碰
/// 通话的平台路径不触碰 platform services。
final class MethodOmniCallChannel implements OmniCallNativeChannel {
  MethodOmniCallChannel._();

  static final MethodOmniCallChannel instance = MethodOmniCallChannel._();

  static const MethodChannel _channel = MethodChannel(androidOmniCallChannelName);

  bool _registered = false;
  final List<void Function(Uint8List)> _chunkHandlers = [];
  final List<void Function(String)> _unavailableHandlers = [];
  final List<void Function(int)> _finishedHandlers = [];

  @override
  Future<bool> canAutoStartCapture() async {
    try {
      return await _channel.invokeMethod<bool>('canAutoStartCapture') ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> hasMicrophonePermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasMicrophonePermission') ??
          false;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> requestMicrophonePermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestMicrophonePermission') ??
          false;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> startCapture({int? requestId}) async {
    try {
      return await _channel.invokeMethod<bool>(
            'startCapture',
            requestId == null ? null : {'requestId': requestId},
          ) ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> cancelPendingCaptureStart(int requestId) async {
    try {
      await _channel.invokeMethod<void>('cancelPendingCaptureStart', {
        'requestId': requestId,
      });
    } on Object {
      // 取消后迟到结果由 Dart 所有权和原生请求 ID 双重隔离。
    }
  }

  @override
  Future<void> stopCapture({int? requestId}) async {
    try {
      await _channel.invokeMethod<void>(
        'stopCapture',
        requestId == null ? null : {'requestId': requestId},
      );
    } on Object {
      // 收尾以「不再收音」为准；原生可能已收尾，异常吞掉。
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    try {
      await _channel.invokeMethod<void>('setMuted', muted);
    } on Object {
      // 静音以「不再外发」为准；失败只影响即刻生效，不影响通话。
    }
  }

  @override
  void Function() onCaptureChunk(void Function(Uint8List pcm) handler) {
    _ensureRegistered();
    _chunkHandlers.add(handler);
    return () => _chunkHandlers.remove(handler);
  }

  @override
  void Function() onCaptureUnavailable(void Function(String reason) handler) {
    _ensureRegistered();
    _unavailableHandlers.add(handler);
    return () => _unavailableHandlers.remove(handler);
  }

  @override
  Future<bool> prepareForAutoPlayback() async {
    try {
      return await _channel.invokeMethod<bool>('prepareForAutoPlayback') ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<int?> startStream({
    required int sampleRate,
    required double volume,
  }) async {
    _ensureRegistered();
    try {
      return await _channel.invokeMethod<int>('startStream', {
        'sampleRate': sampleRate,
        'volume': volume.clamp(0.0, 1.0),
      });
    } on Object {
      return null;
    }
  }

  @override
  Future<void> appendStreamChunk(int streamId, Uint8List pcm) async {
    try {
      await _channel.invokeMethod<void>('appendStreamChunk', {
        'id': streamId,
        'bytes': pcm,
      });
    } on Object {
      // 单块写失败由原生侧按出错收口（onPlaybackFinished 到达），这里
      // 不重复处理。
    }
  }

  @override
  Future<void> endStream(int streamId) async {
    try {
      await _channel.invokeMethod<void>('endStream', {'id': streamId});
    } on Object {
      // 原生可能已收尾；结束语义以「不再出声」为准。
    }
  }

  @override
  Future<void> setStreamVolume(int streamId, double volume) async {
    try {
      await _channel.invokeMethod<void>('setStreamVolume', {
        'id': streamId,
        'volume': volume.clamp(0.0, 1.0),
      });
    } on Object {
      // 与 web 侧 setVolume 同语义：调节失败不影响播放继续。
    }
  }

  @override
  Future<void> stopStream(int streamId) async {
    try {
      await _channel.invokeMethod<void>('stopStream', {'id': streamId});
    } on Object {
      // 停止以「不再出声」为准；句柄可能已被原生侧释放，异常吞掉。
    }
  }

  @override
  void Function() onPlaybackFinished(void Function(int streamId) handler) {
    _ensureRegistered();
    _finishedHandlers.add(handler);
    return () => _finishedHandlers.remove(handler);
  }

  void _ensureRegistered() {
    if (_registered) {
      return;
    }
    _registered = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onCaptureChunk':
        final pcm = call.arguments;
        if (pcm is Uint8List) {
          for (final handler in List.of(_chunkHandlers)) {
            handler(pcm);
          }
        }
      case 'onCaptureUnavailable':
        final reason = (call.arguments as Map<Object?, Object?>?)?['reason'];
        if (reason is String) {
          for (final handler in List.of(_unavailableHandlers)) {
            handler(reason);
          }
        }
      case 'onPlaybackFinished':
        final id = (call.arguments as Map<Object?, Object?>?)?['id'];
        if (id is int) {
          for (final handler in List.of(_finishedHandlers)) {
            handler(id);
          }
        }
    }
  }
}
