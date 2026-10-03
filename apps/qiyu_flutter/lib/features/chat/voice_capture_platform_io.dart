// 连续 PCM 采集的 io 平台实现（T05）：Android 真实现，经原生通话桥
// （OmniCallBridge.kt，通道 dev.qiyu.app/omni_call）完成同时录放。
//
// Windows App 客户端与 Flutter Web 同构建（浏览器承载），io 分支在
// 生产里只有安卓壳一个宿主：非 Android 的 io 宿主（测试跑在桌面、
// Windows 开发调试）如实报告不可用，通话入口维持不可用引导。
// 接口契约见 [VoiceCapturePlatform]；测试注入 fake 通道并显式指定
// [supported]。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'omni_call_native_channel.dart';
import 'voice_capture_platform.dart';

/// 安卓壳的 Omni 连续采集实现（T05）：AudioRecord 用标准通信音源
/// （VOICE_COMMUNICATION）加设备可用的回声消除（AcousticEchoCanceler），
/// 同时录放（消除原单轮录放互斥），microphone 前台服务随之起停——
/// 全在原生桥内；Dart 侧只看到块与中断。
///
/// 权限：先查后请（系统弹窗只由用户点「拨通」的动作触发，拒绝即返回
/// null，调用方按「可继续打字」如实呈现，不偷偷重试）；通知权限只在
/// 33+ 一并尽力请求且不影响开始（原生桥内处理）。
final class AndroidVoiceCapturePlatform
    implements VoiceCapturePlatform, AutoStartVoiceCapturePlatform,
        InterruptibleVoiceCapturePlatform {
  AndroidVoiceCapturePlatform({
    OmniCallNativeChannel? channel,
    bool? supported,
  }) : _channel = channel ?? MethodOmniCallChannel.instance,
       _supportedOverride = supported;

  final OmniCallNativeChannel _channel;
  final bool? _supportedOverride;
  static int _nextRequestId = 1;
  int? _pendingRequestId;

  @override
  void cancelPendingStart() {
    final id = _pendingRequestId;
    if (id == null) return;
    _pendingRequestId = null;
    unawaited(_channel.cancelPendingCaptureStart(id));
  }

  @override
  bool get supported => _supportedOverride ?? Platform.isAndroid;

  @override
  Future<bool> canAutoStart() async =>
      supported && await _channel.canAutoStartCapture();

  @override
  Future<VoiceCaptureSession?> start({
    bool automatic = false,
    required void Function(Uint8List pcm) onChunk,
    required void Function(String reason) onUnavailable,
  }) async {
    if (!supported) {
      return null;
    }
    cancelPendingStart();
    final id = _nextRequestId++;
    _pendingRequestId = id;
    void Function()? unsubscribeChunk;
    void Function()? unsubscribeUnavailable;
    var delivered = false;
    try {
      final granted = await _channel.hasMicrophonePermission();
      if (_pendingRequestId != id) return null;
      if (!granted) {
        if (automatic) return null;
        final accepted = await _channel.requestMicrophonePermission();
        if (_pendingRequestId != id || !accepted) return null;
      }
      // 先订阅后起采；取消后的块和中断不得进入旧通话。
      unsubscribeChunk = _channel.onCaptureChunk((pcm) {
        if (delivered || _pendingRequestId == id) onChunk(pcm);
      });
      unsubscribeUnavailable = _channel.onCaptureUnavailable((reason) {
        if (delivered || _pendingRequestId == id) onUnavailable(reason);
      });
      final started = await _channel.startCapture(requestId: id);
      if (_pendingRequestId != id) {
        // 原生成功与取消交错也只收本次资源，不能误停新通话。
        if (started) await _channel.stopCapture(requestId: id);
        return null;
      }
      if (!started) return null;
      delivered = true;
      return _AndroidVoiceCaptureSession(
        _channel, id, unsubscribeChunk, unsubscribeUnavailable,
      );
    } finally {
      if (!delivered) {
        unsubscribeChunk?.call();
        unsubscribeUnavailable?.call();
      }
      if (_pendingRequestId == id) _pendingRequestId = null;
    }
  }
}

/// 一次安卓连续采集会话：块经通道从原生内存直进控制器，stop 摘订阅并
/// 请原生收口整通（含前台服务），幂等；闭麦转发原生（照读不外发）。
final class _AndroidVoiceCaptureSession implements VoiceCaptureSession {
  _AndroidVoiceCaptureSession(
    this._channel,
    this._requestId,
    this._unsubscribeChunk,
    this._unsubscribeUnavailable,
  );

  final OmniCallNativeChannel _channel;
  final int _requestId;
  final void Function() _unsubscribeChunk;
  final void Function() _unsubscribeUnavailable;
  bool _stopped = false;

  @override
  void setMuted(bool muted) {
    if (_stopped) {
      return;
    }
    _channel.setMuted(muted).catchError((Object _) {
      // 静音以「动作意图已生效」收尾，失败不打断通话。
    });
  }

  @override
  void stop() {
    if (_stopped) {
      return;
    }
    _stopped = true;
    // 先摘订阅再停原生：stop 后即便原生还有残余通知也不再外泄。
    _unsubscribeChunk();
    _unsubscribeUnavailable();
    _channel.stopCapture(requestId: _requestId).catchError((Object _) {
      // 收尾以「不再收音」为准；原生可能已收尾。
    });
  }
}

VoiceCapturePlatform createVoiceCapturePlatform() =>
    AndroidVoiceCapturePlatform();
