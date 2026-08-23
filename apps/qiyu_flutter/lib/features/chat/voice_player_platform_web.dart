import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'voice_player_platform.dart';

/// Flutter Web 构建的真实浏览器实现：音频字节经内存 blob URL 交给
/// HTMLAudioElement 播放，播完/停止立即 revoke URL——磁盘上永远不出现
/// 声音文件（ADR 0002）。自动播放被浏览器策略拒绝时返回 null，调用方
/// 按「读不出来」降级。
final class WebVoicePlayerPlatform implements VoicePlayerPlatform {
  const WebVoicePlayerPlatform();

  @override
  bool get supported => true;

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
  }) async {
    String? url;
    web.HTMLAudioElement? audio;
    try {
      final blob = web.Blob(
        <web.BlobPart>[bytes.toJS].toJS,
        web.BlobPropertyBag(type: mimeType),
      );
      url = web.URL.createObjectURL(blob);
      audio = web.HTMLAudioElement()..src = url;
      final stopped = Completer<void>();
      audio.onended = ((web.Event _) {
        if (!stopped.isCompleted) {
          stopped.complete();
        }
      }).toJS;
      audio.onerror = ((web.Event _) {
        if (!stopped.isCompleted) {
          stopped.complete();
        }
      }).toJS;
      // 自动播放策略拒绝（NotAllowedError）或解码失败都在这里变 null。
      await audio.play().toDart;
      return _WebVoicePlayback(audio, url, stopped);
    } on Object {
      audio?.pause();
      audio?.removeAttribute('src');
      if (url != null) {
        web.URL.revokeObjectURL(url);
      }
      return null;
    }
  }
}

final class _WebVoicePlayback implements VoicePlayback {
  _WebVoicePlayback(this._audio, this._url, this._stopped);

  final web.HTMLAudioElement _audio;
  final String _url;
  final Completer<void> _stopped;
  bool _released = false;

  @override
  Future<void> get done async {
    await _stopped.future;
    _release();
  }

  @override
  void stop() {
    _audio.pause();
    if (!_stopped.isCompleted) {
      _stopped.complete();
    }
    _release();
  }

  void _release() {
    if (_released) {
      return;
    }
    _released = true;
    _audio.removeAttribute('src');
    web.URL.revokeObjectURL(_url);
  }
}

VoicePlayerPlatform createVoicePlayerPlatform() =>
    const WebVoicePlayerPlatform();
