import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'voice_recorder_platform.dart';

/// Flutter Web 构建的真实浏览器实现（ADR 0001）：getUserMedia 取麦克
/// 风，MediaRecorder 容器优先 audio/webm，Safari 回退 audio/mp4；字节
/// 只在内存 Blob 里累积，stop/discard 后连同媒体轨道一并释放。豆包
/// 协议需要 16kHz/16-bit 单声道 WAV，转换（decodeAudioData 解码 +
/// OfflineAudioContext 重采样 + Int16 量化 + RIFF 头）全部在浏览器内
/// 完成，本机 Host 不做音频解码。
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

  @override
  Future<RecordedAudio> toWav16kMono(RecordedAudio audio) async {
    // 解码或重采样失败（损坏字节、不支持的编码等）交给调用方按
    // 「录音无法转换」的可重试失败呈现。
    final wav = await _decodeResampleAndPack(audio.bytes);
    return RecordedAudio(bytes: wav, mimeType: 'audio/wav');
  }
}

/// 契约采样率的本地别名：值来自缝文件的共享常量（不留第二份字面值），
/// 下面的重采样目标与 RIFF 头里的采样率因此必然同源。
const _wavTargetSampleRate = wav16kMonoTargetSampleRate;

/// webm/mp4 → AudioBuffer → 16kHz 单声道 → Int16 LE + 44 字节 RIFF 头。
/// interop 调用全部经 lambda 显式调用（dart2js 禁止 tear-off）。
Future<Uint8List> _decodeResampleAndPack(Uint8List bytes) async {
  // 用一次性 OfflineAudioContext 只做解码，避免动到真实音频设备。
  final decodeContext = web.OfflineAudioContext(1.toJS, 1, 48000);
  // Uint8List 可能是某个更大 buffer 的视图：拷到独立拷贝再交出 JSArrayBuffer，
  // 避免 offset 不为 0 时 decodeAudioData 读到错字节。dart2js 上 JSUint8Array
  // 没有 .buffer 成员，必须走 ByteBuffer.toJS。
  final copy =
      bytes.offsetInBytes == 0 &&
          bytes.lengthInBytes == bytes.buffer.lengthInBytes
      ? bytes
      : Uint8List.fromList(bytes);
  final decoded = await decodeContext.decodeAudioData(copy.buffer.toJS).toDart;
  final frameCount =
      (decoded.length * _wavTargetSampleRate / decoded.sampleRate).ceil();
  final renderContext = web.OfflineAudioContext(
    1.toJS,
    frameCount,
    _wavTargetSampleRate,
  );
  final source = renderContext.createBufferSource();
  source.buffer = decoded;
  source.connect(renderContext.destination);
  source.start();
  final rendered = await renderContext.startRendering().toDart;
  return _packWav(rendered.getChannelData(0).toDart);
}

/// Float32 声道 → 契约 PCM 字节（Int16 小端）；RIFF/WAV 头由两端共用的
/// [packWav16kMonoPcm] 补齐，web 侧只负责自己那步量化。
Uint8List _packWav(Float32List samples) {
  final pcm = Uint8List(samples.length * 2);
  final view = ByteData.view(pcm.buffer);
  var offset = 0;
  for (final sample in samples) {
    // 浮点采样可能略越界：clamp 到 [-1, 1] 再放大成 Int16。
    view.setInt16(
      offset,
      (sample.clamp(-1.0, 1.0) * 32767).round(),
      Endian.little,
    );
    offset += 2;
  }
  return packWav16kMonoPcm(pcm);
}

final class _WebVoiceRecordingSession implements VoiceRecordingSession {
  _WebVoiceRecordingSession._(this._stream, this._recorder, this._mimeType);

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
      recorder.ondataavailable = ((web.BlobEvent event) {
        if (!session._discarded) {
          session._chunks.add(event.data);
        }
      }).toJS;
      recorder.onstop = ((web.Event _) {
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
