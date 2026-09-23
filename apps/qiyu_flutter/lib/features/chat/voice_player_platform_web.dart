import 'dart:async';
import 'dart:js_interop';
// 浏览器侧链路不引 Flutter：dart2js 编不了 dart:ui（交付门禁的
// dart_test.browser.yaml 是 plain dart test）。Uint8List 原先经
// flutter/foundation 的转出泄漏进来，删包后显式 import。
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
///
/// 流式 PCM 播放（票二）：另实现 [StreamingVoicePlayerPlatform]——主线程
/// 收块经 MessagePort 转交 AudioWorklet 处理器，环形缓冲里按 128 帧
/// 节奏输出（MDN 标准形态），替代整段 decodeAudioData。块边界任意：
/// PCM 无帧对齐问题，16-bit 样本完整、有序连续即可。
final class WebVoicePlayerPlatform
    implements
        VoicePlayerPlatform,
        UserGestureVoicePlayerPlatform,
        StreamingVoicePlayerPlatform {
  web.AudioContext? _context;
  Future<bool>? _resumeAttempt;

  /// AudioWorklet 模块的 Blob URL（进程内建一次）：处理器源码是字符串，
  /// 包成 Blob 免去为它单开一个静态资源路由。
  static String? _workletModuleUrl;

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

  // ---- 流式 PCM 播放（票二） ----

  @override
  Future<VoiceStreamPlayback?> startStream({
    required int sampleRate,
    double volume = 1.0,
  }) async {
    try {
      // 播放端按协商采样率建上下文：PCM 块的采样率由 Host 随块带上，
      // 不猜、不让浏览器重采样（重采样会变调）。
      final context = web.AudioContext(
        web.AudioContextOptions(sampleRate: sampleRate),
      );
      if (!await _waitStreamContextRunning(context)) {
        _closeQuietly(context);
        return null;
      }
      final moduleUrl = _ensureWorkletModule();
      if (moduleUrl == null) {
        _closeQuietly(context);
        return null;
      }
      await context.audioWorklet.addModule(moduleUrl).toDart;
      final node = web.AudioWorkletNode(context, _pcmWorkletProcessorName);
      final gain = context.createGain();
      gain.gain.value = volume.clamp(0.0, 1.0);
      node.connect(gain);
      gain.connect(context.destination);
      final playback = _WebVoiceStreamPlayback(
        context,
        node,
        gain,
        sampleRate,
      );
      node.port.onmessage = ((web.MessageEvent event) {
        // 处理器只在缓冲排空后发这一个信令；字符串信令与二进制块用
        // 类型区分，不引入第二套消息协议。
        if (event.data case final JSString text) {
          if (text.toDart == 'drained') {
            playback._completeDrained();
          }
        }
      }).toJS;
      return playback;
    } on Object {
      return null;
    }
  }

  /// 流式上下文的唤醒：用户发送消息时的手势 resume 已激活页面，这里
  /// 只负责把新上下文推到 running；推不动就如实播不了。
  Future<bool> _waitStreamContextRunning(web.AudioContext context) async {
    try {
      if (context.state == 'running') {
        return true;
      }
      final resumed = await _resume(
        context,
      ).timeout(const Duration(seconds: 1), onTimeout: () => false);
      return resumed && context.state == 'running';
    } on Object {
      return false;
    }
  }

  static String? _ensureWorkletModule() {
    final existing = _workletModuleUrl;
    if (existing != null) {
      return existing;
    }
    try {
      final parts = <web.BlobPart>[_pcmWorkletSource.toJS];
      final blob = web.Blob(parts.toJS);
      final url = web.URL.createObjectURL(blob);
      _workletModuleUrl = url;
      return url;
    } on Object {
      return null;
    }
  }

  static void _closeQuietly(web.AudioContext context) {
    try {
      if (context.state != 'closed') {
        context.close();
      }
    } on Object {
      // 关不掉就没有可补救动作。
    }
  }
}

/// AudioWorklet 处理器名（Dart 侧建节点与 JS 侧注册同名）。
const _pcmWorkletProcessorName = 'qiyu-pcm-ring';

/// AudioWorklet 处理器源码（票二）：主线程把 PCM16 小端块经
/// MessagePort 转交这里，环形缓冲按 128 帧节奏输出。块边界任意——
/// 只要 16-bit 样本完整、有序连续。收满时丢最旧样本保延迟有界
/// （陪伴场景宁可少一声也不让声音越播越滞后）。
const _pcmWorkletSource = '''
class QiyuPcmRingProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.capacity = Math.max(sampleRate * 4, 4096);
    this.ring = new Float32Array(this.capacity);
    this.head = 0;
    this.count = 0;
    this.ended = false;
    this.started = false;
    this.drained = false;
    this.prebuffer = Math.floor(sampleRate * 0.12);
    this.port.onmessage = (event) => {
      const data = event.data;
      if (typeof data === 'string') {
        if (data === 'end') this.ended = true;
        return;
      }
      if (data instanceof ArrayBuffer) {
        const pcm = new Int16Array(data);
        for (let i = 0; i < pcm.length; i++) {
          if (this.count >= this.capacity) {
            this.head = (this.head + 1) % this.capacity;
            this.count -= 1;
          }
          this.ring[(this.head + this.count) % this.capacity] = pcm[i] / 32768;
          this.count += 1;
        }
      }
    };
  }
  process(inputs, outputs) {
    const out = outputs[0][0];
    if (!this.started) {
      // 起播前垫 120ms：块边到达边播，避免首块太薄立刻欠载。
      if (this.count >= this.prebuffer || (this.ended && this.count > 0)) {
        this.started = true;
      } else {
        out.fill(0);
        this._maybeDrained();
        return true;
      }
    }
    let written = 0;
    while (written < out.length && this.count > 0) {
      out[written++] = this.ring[this.head];
      this.head = (this.head + 1) % this.capacity;
      this.count -= 1;
    }
    if (written < out.length) out.fill(0, written);
    this._maybeDrained();
    return true;
  }
  _maybeDrained() {
    if (this.ended && this.count === 0 && !this.drained) {
      this.drained = true;
      this.port.postMessage('drained');
    }
  }
}
registerProcessor('$_pcmWorkletProcessorName', QiyuPcmRingProcessor);
''';

/// 一路流式 PCM 播放会话（票二）：块经 MessagePort 进 worklet 环形
/// 缓冲，`end` 之后缓冲排空即 done。上下文随会话创建、随会话关闭
/// （采样率由该路音频协商决定），音频只在内存。
///
/// 时长兜底：`done` 只在 worklet 回报 `drained` 时完成，AudioContext
/// 被系统挂起或 worklet 静默异常时它可能永不到达——`end` 之后按已
/// 写入的音频时长估算一个上限定时器，超按播完收尾并记诊断（与整段
/// 路径的 fallbackTimer 同构）。
final class _WebVoiceStreamPlayback implements VoiceStreamPlayback {
  _WebVoiceStreamPlayback(
    this._context,
    this._node,
    this._gain,
    this._sampleRate,
  );

  final web.AudioContext _context;
  final web.AudioWorkletNode _node;
  final web.GainNode _gain;
  final Completer<void> _done = Completer<void>();
  bool _released = false;
  bool _ended = false;

  /// 已写入的 PCM 字节数（16-bit 单声道）：时长兜底按它估算。
  int _appendedBytes = 0;

  /// 该路音频的采样率（Hz）：兜底定时器把字节数换算成秒。
  final int _sampleRate;
  Timer? _fallbackTimer;

  @override
  void append(Uint8List pcm) {
    if (_released || _ended || pcm.isEmpty) {
      return;
    }
    try {
      // 只把本块的准确字节交出去：视图的 offset/尾部字节不进 worklet。
      final exact =
          pcm.offsetInBytes == 0 &&
              pcm.lengthInBytes == pcm.buffer.lengthInBytes
          ? pcm
          : Uint8List.fromList(pcm);
      _node.port.postMessage(exact.buffer.toJS);
      _appendedBytes += exact.lengthInBytes;
    } on Object {
      // 单块投递失败不打断播放：后续块仍可到达（最坏是欠载静音）。
    }
  }

  @override
  void end() {
    if (_released || _ended) {
      return;
    }
    _ended = true;
    try {
      _node.port.postMessage('end'.toJS);
    } on Object {
      _release();
      return;
    }
    // 兜底：drained 不到达时按已写入时长 + 5s 余量强制收尾。已写入
    // 时长是上界（起播只垫了 120ms），宁可晚到也不卡死播放状态机。
    final bufferedSeconds = _appendedBytes / 2 / _sampleRate;
    if (!bufferedSeconds.isFinite || bufferedSeconds <= 0) {
      return;
    }
    _fallbackTimer = Timer(
      Duration(milliseconds: (bufferedSeconds * 1000).ceil() + 5000),
      () {
        if (!_released) {
          // 浏览器控制台：本文件不引 Flutter（见文件头 import 注释）。
          web.console.log('qiyu voice stream: drained 信令超时，按播完收尾。'.toJS);
          _release();
        }
      },
    );
  }

  /// 处理器回报缓冲排空：自然播完的唯一信号。
  void _completeDrained() => _release();

  @override
  Future<void> get done => _done.future;

  @override
  void setVolume(double volume) {
    if (_released) {
      return;
    }
    try {
      _gain.gain.value = volume.clamp(0.0, 1.0);
    } on Object {
      // 调节失败不影响播放继续。
    }
  }

  @override
  void stop() => _release();

  void _release() {
    if (_released) {
      return;
    }
    _released = true;
    _fallbackTimer?.cancel();
    try {
      _node.disconnect();
    } on Object {
      // 已断开的节点再断会抛，幂等吞掉。
    }
    try {
      _gain.disconnect();
    } on Object {
      // 同上。
    }
    try {
      if (_context.state != 'closed') {
        _context.close();
      }
    } on Object {
      // 关闭失败没有可补救动作。
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

/// 一路整段播放会话（浏览器 decodeAudioData + AudioBufferSourceNode）：
/// done 在自然播完、被 stop 或底层缺失 onended 时的兜底定时器到点完成
/// （不抛）。播完即释放，字节只存在于内存。
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
