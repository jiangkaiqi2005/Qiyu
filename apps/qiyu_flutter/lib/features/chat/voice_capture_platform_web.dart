import 'dart:async';
import 'dart:js_interop';
// 浏览器侧链路不引 Flutter（与 voice_player_platform_web.dart 同一纪律）：
// dart2js 编不了 dart:ui；Uint8List 用显式 import。
import 'dart:typed_data';
import 'package:web/web.dart' as web;

import 'voice_capture_platform.dart';

/// Flutter Web 构建的真实浏览器连续采集实现（T04）。
///
/// getUserMedia 打开麦克风时启用浏览器标准音频处理（回声消除、噪声抑制、
/// 自动增益）——通话要同时收发，回声处理必须由平台做，不做自制 DSP
/// （spec:82）。采集链是 MediaStream → AudioWorklet：处理器在音频线程
/// 按 100ms（1600 帧 @16 kHz）攒块，线性插值重采样到 16 kHz 并量化成
/// Int16 小端，经 MessagePort 交主线程出块；块边界整齐，双工上行直接
/// 可用。字节只在内存流转，stop 后随轨道与上下文一并释放。
final class WebVoiceCapturePlatform
    implements VoiceCapturePlatform, AutoStartVoiceCapturePlatform {
  const WebVoiceCapturePlatform();

  @override
  bool get supported => true;

  @override
  Future<bool> canAutoStart() async {
    try {
      if (!web.window.isSecureContext ||
          web.document.visibilityState != 'visible') {
        return false;
      }
      final permission = await web.window.navigator.permissions
          .query({'name': 'microphone'}.jsify()! as JSObject)
          .toDart
          .timeout(const Duration(seconds: 1));
      if (permission.state != 'granted') return false;
      final devices = await web.window.navigator.mediaDevices
          .enumerateDevices()
          .toDart
          .timeout(const Duration(seconds: 1));
      return web.document.visibilityState == 'visible' &&
          permission.state == 'granted' &&
          devices.toDart.any((device) => device.kind == 'audioinput');
    } on Object {
      // 不支持无弹窗权限查询时退回手动，不拿 getUserMedia 试探权限。
      return false;
    }
  }

  @override
  Future<VoiceCaptureSession?> start({
    required void Function(Uint8List pcm) onChunk,
    required void Function(String reason) onUnavailable,
  }) async {
    final web.MediaStream stream;
    try {
      stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(audio: _audioConstraints().jsify()!),
          )
          .toDart;
    } on Object {
      // 授权被拒、设备不存在或采集不可用：按「没有开始」处理。
      return null;
    }
    final session = await _WebVoiceCaptureSession.tryCreate(
      stream,
      onChunk,
      onUnavailable,
    );
    if (session == null) {
      _releaseStream(stream);
    }
    return session;
  }

  /// 标准回声处理三件套：通信场景必须开，浏览器按设备能力生效。
  static Map<String, JSAny?> _audioConstraints() => {
    'echoCancellation': true.toJS,
    'noiseSuppression': true.toJS,
    'autoGainControl': true.toJS,
  };
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

/// AudioWorklet 模块的 Blob URL（进程内建一次）：与播放侧同一手法，
/// 处理器源码是字符串，包成 Blob 免单开静态资源路由。
String? _workletModuleUrl;

String? _ensureWorkletModule() {
  final existing = _workletModuleUrl;
  if (existing != null) {
    return existing;
  }
  try {
    final parts = <web.BlobPart>[_captureWorkletSource.toJS];
    final blob = web.Blob(
      parts.toJS,
      web.BlobPropertyBag(type: 'text/javascript'),
    );
    final url = web.URL.createObjectURL(blob);
    _workletModuleUrl = url;
    return url;
  } on Object {
    return null;
  }
}

/// 采集处理器（音频线程）：Float32 输入按线性插值重采样到 16 kHz、
/// 量化 Int16，攒满 100ms（1600 帧）经 MessagePort 交出一份拷贝。
/// 重采样状态跨 process 调用延续，块与块之间不丢样本。
const _captureWorkletSource = '''
class QiyuCaptureResampler extends AudioWorkletProcessor {
  constructor() {
    super();
    this.step = sampleRate / 16000;
    this.pos = 0;
    this.time = -1;
    this.prev = 0;
    this.out = new Int16Array(1600);
    this.outLen = 0;
  }
  process(inputs) {
    const input = inputs[0][0];
    if (!input) return true;
    for (let i = 0; i < input.length; i++) {
      const s = input[i];
      this.time += 1;
      while (this.pos <= this.time) {
        let t = this.pos - (this.time - 1);
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        const v = this.prev + (s - this.prev) * t;
        let q = Math.round(v * 32767);
        if (q > 32767) q = 32767;
        if (q < -32768) q = -32768;
        this.out[this.outLen++] = q;
        this.pos += this.step;
        if (this.outLen === this.out.length) {
          this.port.postMessage(this.out.buffer.slice(0));
          this.outLen = 0;
        }
      }
      this.prev = s;
    }
    return true;
  }
}
registerProcessor('qiyu-capture-16k', QiyuCaptureResampler);
''';

final class _WebVoiceCaptureSession implements VoiceCaptureSession {
  _WebVoiceCaptureSession._(
    this._stream,
    this._context,
    this._node,
    this._source,
  );

  final web.MediaStream _stream;
  final web.AudioContext _context;
  final web.AudioWorkletNode _node;
  final web.MediaStreamAudioSourceNode _source;
  bool _stopped = false;
  bool _muted = false;

  static Future<_WebVoiceCaptureSession?> tryCreate(
    web.MediaStream stream,
    void Function(Uint8List pcm) onChunk,
    void Function(String reason) onUnavailable,
  ) async {
    web.AudioContext? context;
    _WebVoiceCaptureSession? session;
    try {
      if (!stream.getAudioTracks().toDart.any(
        (track) => track.readyState == 'live' && !track.muted,
      )) {
        return null;
      }
      context = web.AudioContext();
      final moduleUrl = _ensureWorkletModule();
      if (moduleUrl == null) {
        await _closeContext(context);
        return null;
      }
      await context.audioWorklet
          .addModule(moduleUrl)
          .toDart
          .timeout(const Duration(seconds: 2));
      await context.resume().toDart.timeout(const Duration(seconds: 1));
      if (context.state != 'running') {
        await _closeContext(context);
        return null;
      }
      final source = context.createMediaStreamSource(stream);
      final node = web.AudioWorkletNode(context, 'qiyu-capture-16k');
      source.connect(node);
      // 处理器不上输出目的地：采集链到 worklet 为止，绝不回灌扬声器。
      node.connect(_silentDestination(context));
      final active = session = _WebVoiceCaptureSession._(
        stream,
        context,
        node,
        source,
      );
      final firstChunk = Completer<bool>();
      node.port.onmessage = ((web.MessageEvent event) {
        if (active._stopped) return;
        if (event.data case final JSArrayBuffer buffer) {
          onChunk(buffer.toDart.asUint8List());
          if (!firstChunk.isCompleted) firstChunk.complete(true);
        }
      }).toJS;
      // 设备失效／系统夺走轨道：如实上报，不偷偷重开（spec:23、T04:17）。
      for (final track in stream.getTracks().toDart) {
        track.onended = ((web.Event _) {
          if (active._stopped) return;
          if (!firstChunk.isCompleted) {
            firstChunk.complete(false);
          } else {
            onUnavailable('microphone track ended');
          }
        }).toJS;
      }
      final ready = await firstChunk.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
      if (!ready ||
          context.state != 'running' ||
          stream.getAudioTracks().toDart.every(
            (track) => track.readyState != 'live' || track.muted,
          )) {
        active.stop();
        return null;
      }
      context = null; // 所有权移交会话。
      return active;
    } on Object {
      if (session != null) {
        session.stop();
      } else if (context != null) {
        await _closeContext(context);
      }
      return null;
    }
  }

  /// worklet 节点必须连到图里的某个消费端才会被拉动：连一个静音增益，
  /// 不出声。
  static web.AudioNode _silentDestination(web.AudioContext context) {
    final gain = context.createGain();
    gain.gain.value = 0;
    gain.connect(context.destination);
    return gain;
  }

  static Future<void> _closeContext(web.AudioContext context) async {
    try {
      if (context.state != 'closed') {
        await context.close().toDart.timeout(const Duration(seconds: 1));
      }
    } on Object {
      // 关不掉没有可补救动作。
    }
  }

  @override
  void setMuted(bool muted) {
    if (_stopped || _muted == muted) {
      return;
    }
    _muted = muted;
    for (final track in _stream.getAudioTracks().toDart) {
      try {
        track.enabled = !muted;
      } on Object {
        // 单轨道置静音失败不影响其余轨道。
      }
    }
  }

  @override
  void stop() {
    if (_stopped) {
      return;
    }
    _stopped = true;
    try {
      _node.disconnect();
    } on Object {
      // 幂等吞掉。
    }
    try {
      _source.disconnect();
    } on Object {
      // 同上。
    }
    _releaseStream(_stream);
    unawaited(_closeContext(_context));
  }
}

VoiceCapturePlatform createVoiceCapturePlatform() =>
    const WebVoiceCapturePlatform();
