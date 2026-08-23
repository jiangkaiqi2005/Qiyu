import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'voice_player_platform.dart';

/// Flutter Web 的内存音频播放器。
///
/// 用户点击试听或重听时先同步恢复一个 [web.AudioContext]，这样云端合成
/// 跨过异步边界后仍可在同一上下文解码、播放。音频字节和解码缓冲都只在
/// 内存中，播放结束或停止后由浏览器回收，不创建文件或持久化缓存。
final class WebVoicePlayerPlatform
    implements VoicePlayerPlatform, UserGestureVoicePlayerPlatform {
  web.AudioContext? _context;
  Future<bool>? _resumeAttempt;

  @override
  bool get supported => true;

  @override
  void prepareForPlayback() {
    final context = _ensureContext();
    // resume() 必须在用户点击回调的同步调用栈里发起；异步结果由 play 等待。
    _resumeAttempt = _resume(context);
  }

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
  }) async {
    final context = _ensureContext();
    try {
      if (!await _waitUntilRunning(context)) {
        return null;
      }
      // Uint8List 可能只是更大 buffer 的视图；只把本次音频的确切字节交给
      // decodeAudioData，避免 offset/尾部字节污染解码。
      final copy =
          bytes.offsetInBytes == 0 &&
              bytes.lengthInBytes == bytes.buffer.lengthInBytes
          ? bytes
          : Uint8List.fromList(bytes);
      final decoded = await context
          .decodeAudioData(copy.buffer.toJS)
          .toDart
          .timeout(const Duration(seconds: 5));
      final source = context.createBufferSource()..buffer = decoded;
      source.connect(context.destination);
      final stopped = Completer<void>();
      source.onended = ((web.Event _) {
        if (!stopped.isCompleted) {
          stopped.complete();
        }
      }).toJS;
      source.start();
      return _WebVoicePlayback(source, stopped);
    } on Object {
      return null;
    }
  }

  web.AudioContext _ensureContext() => _context ??= web.AudioContext();

  Future<bool> _waitUntilRunning(web.AudioContext context) async {
    if (context.state == 'running') {
      return true;
    }
    final attempt = _resumeAttempt ??= _resume(context);
    final resumed = await attempt.timeout(
      const Duration(seconds: 1),
      onTimeout: () => false,
    );
    return resumed && context.state == 'running';
  }

  Future<bool> _resume(web.AudioContext context) async {
    try {
      await context.resume().toDart;
      return context.state == 'running';
    } on Object {
      return false;
    }
  }
}

final class _WebVoicePlayback implements VoicePlayback {
  _WebVoicePlayback(this._source, this._stopped);

  final web.AudioBufferSourceNode _source;
  final Completer<void> _stopped;
  bool _released = false;

  @override
  Future<void> get done => _stopped.future;

  @override
  void stop() {
    if (_released) {
      return;
    }
    _released = true;
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
