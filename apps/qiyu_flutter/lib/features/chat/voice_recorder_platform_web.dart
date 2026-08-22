import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'voice_recorder_platform.dart';

/// Flutter Web 构建的真实浏览器实现（ADR 0001）：getUserMedia 取麦克
/// 风，MediaRecorder 容器优先 audio/webm，Safari 回退 audio/mp4；字节
/// 只在内存 Blob 里累积，stop/discard 后连同媒体轨道一并释放。
final class WebVoiceRecorderPlatform implements VoiceRecorderPlatform {
  const WebVoiceRecorderPlatform();

  /// 候选编码按优先级排列：绝大多数桌面浏览器拿到 webm/opus，
  /// Safari 只有 mp4。
  static const _candidateMimeTypes = [
    'audio/webm;codecs=opus',
    'audio/webm',
    'audio/mp4',
  ];

  @override
  bool get supported {
    try {
      // 老浏览器缺 MediaRecorder 时这里会抛，按不支持处理。dart2js 禁止
      // interop 成员 tear-off，必须经 lambda 显式调用。
      return _candidateMimeTypes.any(
        (mimeType) => web.MediaRecorder.isTypeSupported(mimeType),
      );
    } on Object {
      return false;
    }
  }

  @override
  Future<VoiceRecordingSession?> start() async {
    try {
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
          .toDart;
      final session = _WebVoiceRecordingSession.tryCreate(stream);
      if (session == null) {
        _releaseStream(stream);
      }
      return session;
    } on Object {
      // 授权被拒、设备不可用或编码不支持都按「无法开始」处理。
      return null;
    }
  }
}

final class _WebVoiceRecordingSession implements VoiceRecordingSession {
  _WebVoiceRecordingSession._(
    this._stream,
    this._recorder,
    this._mimeType,
  );

  final web.MediaStream _stream;
  final web.MediaRecorder _recorder;
  final String _mimeType;
  final List<web.Blob> _chunks = [];
  final Completer<void> _stopped = Completer<void>();
  bool _discarded = false;

  static _WebVoiceRecordingSession? tryCreate(web.MediaStream stream) {
    for (final mimeType in WebVoiceRecorderPlatform._candidateMimeTypes) {
      if (!web.MediaRecorder.isTypeSupported(mimeType)) {
        continue;
      }
      final recorder = web.MediaRecorder(
        stream,
        web.MediaRecorderOptions(mimeType: mimeType),
      );
      final session = _WebVoiceRecordingSession._(
        stream,
        recorder,
        // 容器类型去掉编解码参数再上送：转写服务只认容器。
        mimeType.split(';').first.trim(),
      );
      recorder.ondataavailable =
          ((web.BlobEvent event) {
            if (!session._discarded) {
              session._chunks.add(event.data);
            }
          }).toJS;
      recorder.onstop =
          ((web.Event _) {
            if (!session._stopped.isCompleted) {
              session._stopped.complete();
            }
          }).toJS;
      recorder.start();
      return session;
    }
    return null;
  }

  @override
  String get mimeType => _mimeType;

  @override
  Future<Uint8List> stop() async {
    if (_recorder.state != 'inactive') {
      _recorder.stop();
    }
    await _stopped.future;
    _releaseStream(_stream);
    final merged = web.Blob(_chunks.toJS);
    final buffer = await merged.arrayBuffer().toDart;
    _chunks.clear();
    return buffer.toDart.asUint8List();
  }

  @override
  void discard() {
    _discarded = true;
    if (_recorder.state != 'inactive') {
      _recorder.stop();
    }
    _releaseStream(_stream);
    _chunks.clear();
  }
}

void _releaseStream(web.MediaStream stream) {
  for (final track in stream.getTracks().toDart) {
    try {
      track.stop();
    } on Object {
      // 单个轨道停止失败不影响其余轨道的释放。
    }
  }
}

VoiceRecorderPlatform createVoiceRecorderPlatform() =>
    const WebVoiceRecorderPlatform();
