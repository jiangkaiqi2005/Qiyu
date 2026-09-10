import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'voice_player_platform.dart';

/// Flutter Web 的内存音频播放器。
///
/// 用户点击试听或重听时先同步恢复一个 [web.AudioContext]，这样云端合成
/// 跨过异步边界后仍可在同一上下文解码、播放。音频字节和解码缓冲都只在
/// 内存中，播放结束或停止后由浏览器回收，不创建文件或持久化缓存（ADR 0002）。
///
/// 当底层 Windows WASAPI 音频通道因待机唤醒、蓝牙断连或切换设备而失效时，
/// 播放器支持透明自愈重建 [web.AudioContext]，并为每次播放提供时长兜底保护，
/// 防止播放状态机因底层缺失 `onended` 事件而挂起。
final class WebVoicePlayerPlatform
    implements VoicePlayerPlatform, UserGestureVoicePlayerPlatform {
  web.AudioContext? _context;
  Future<bool>? _resumeAttempt;

  @override
  bool get supported => true;

  @override
  void prepareForPlayback() {
    _resumeAttempt = null;
    try {
      final context = _ensureContext();
      // resume() 必须在用户点击回调的同步调用栈里发起；异步结果由 play 等待。
      _resumeAttempt = _resume(context);
    } on Object {
      _resumeAttempt = null;
    }
  }

  @override
  double getInitialVolume() {
    try {
      final parsed = parseVoiceVolumePreference(
        web.window.localStorage.getItem(voiceOutputVolumeStorageKey),
      );
      if (parsed != null) {
        return parsed;
      }
    } on Object {
      // 忽略 localStorage 读取异常
    }
    return 1.0;
  }

  @override
  void saveVolume(double volume) {
    try {
      web.window.localStorage.setItem(
        voiceOutputVolumeStorageKey,
        encodeVoiceVolumePreference(volume),
      );
    } on Object {
      // 忽略 localStorage 写入异常
    }
  }

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async {
    try {
      final context = _ensureContext();
      if (!await _waitUntilRunning(context)) {
        return null;
      }
      final activeContext = _ensureContext();
      // Uint8List 可能只是更大 buffer 的视图；只把本次音频的确切字节交给
      // decodeAudioData，避免 offset/尾部字节污染解码。
      final copy =
          bytes.offsetInBytes == 0 &&
              bytes.lengthInBytes == bytes.buffer.lengthInBytes
          ? bytes
          : Uint8List.fromList(bytes);
      final decoded = await activeContext
          .decodeAudioData(copy.buffer.toJS)
          .toDart
          .timeout(const Duration(seconds: 5));
      final source = activeContext.createBufferSource()..buffer = decoded;
      final gainNode = activeContext.createGain();
      gainNode.gain.value = volume.clamp(0.0, 1.0);
      source.connect(gainNode);
      gainNode.connect(activeContext.destination);

      final stopped = Completer<void>();
      final durationSeconds = decoded.duration;
      final fallbackDurationMs = durationSeconds.isFinite && durationSeconds > 0
          ? (durationSeconds * 1000).ceil() + 2000
          : 2000;
      final fallbackTimer = Timer(
        Duration(milliseconds: fallbackDurationMs),
        () {
          if (!stopped.isCompleted) {
            stopped.complete();
          }
        },
      );

      source.onended = ((web.Event _) {
        fallbackTimer.cancel();
        if (!stopped.isCompleted) {
          stopped.complete();
        }
      }).toJS;

      source.start();
      return _WebVoicePlayback(source, gainNode, stopped, fallbackTimer);
    } on Object {
      return null;
    }
  }

  bool _isContextUnhealthy(web.AudioContext context) {
    try {
      final state = context.state;
      return state == 'closed' || state == 'interrupted';
    } on Object {
      return true;
    }
  }

  void _disposeOldContext() {
    final old = _context;
    _context = null;
    _resumeAttempt = null;
    if (old != null) {
      try {
        if (old.state != 'closed') {
          old.close();
        }
      } on Object {
        // 忽略关闭旧 context 时的异常
      }
    }
  }

  web.AudioContext _ensureContext() {
    final existing = _context;
    if (existing != null && _isContextUnhealthy(existing)) {
      _disposeOldContext();
    }
    return _context ??= web.AudioContext();
  }

  Future<bool> _waitUntilRunning(web.AudioContext context) async {
    if (await _waitForRunning(context, _resumeAttempt ??= _resume(context))) {
      return true;
    }
    // 自愈尝试：主动销毁当前可能失效的 context，重建全新 context 并再次尝试唤醒
    _disposeOldContext();
    try {
      final healedContext = _ensureContext();
      final healedAttempt = _resume(healedContext);
      _resumeAttempt = healedAttempt;
      return await _waitForRunning(healedContext, healedAttempt);
    } on Object {
      return false;
    }
  }

  Future<bool> _waitForRunning(
    web.AudioContext context,
    Future<bool> attempt,
  ) async {
    try {
      if (context.state == 'running') {
        return true;
      }
      final resumed = await attempt.timeout(
        const Duration(seconds: 1),
        onTimeout: () => false,
      );
      return resumed && context.state == 'running';
    } on Object {
      return false;
    }
  }

  Future<bool> _resume(web.AudioContext context) async {
    try {
      await context.resume().toDart;
      return context.state == 'running';
    } on Object {
      return false;
    }
  }

  /// 供测试检查内部 AudioContext 状态。
  web.AudioContext? get debugAudioContext => _context;

  /// 供测试显式关闭 AudioContext 模拟脱钩失效场景。
  void debugCloseContext() {
    final ctx = _context;
    if (ctx != null) {
      try {
        ctx.close();
      } on Object {
        // 忽略测试环境关闭异常
      }
    }
  }
}

final class _WebVoicePlayback implements VoicePlayback {
  _WebVoicePlayback(
    this._source,
    this._gainNode,
    this._stopped,
    this._fallbackTimer,
  );

  final web.AudioBufferSourceNode _source;
  final web.GainNode _gainNode;
  final Completer<void> _stopped;
  final Timer _fallbackTimer;
  bool _released = false;

  @override
  Future<void> get done => _stopped.future;

  @override
  void setVolume(double volume) {
    if (_released) {
      return;
    }
    try {
      _gainNode.gain.value = volume.clamp(0.0, 1.0);
    } on Object {
      // 忽略音量调节异常
    }
  }

  @override
  void stop() {
    if (_released) {
      return;
    }
    _released = true;
    _fallbackTimer.cancel();
    try {
      _source.stop();
    } on Object {
      // 已自然结束的 source 再 stop 会因浏览器实现不同而可能抛错；幂等吞掉。
    }
    if (!_stopped.isCompleted) {
      _stopped.complete();
    }
  }
}

VoicePlayerPlatform createVoicePlayerPlatform() => WebVoicePlayerPlatform();
