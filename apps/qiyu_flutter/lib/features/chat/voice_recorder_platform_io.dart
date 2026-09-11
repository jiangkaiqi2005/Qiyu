import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'voice_recorder_platform.dart';

/// Android 原生录音通道名（原生侧 VoiceBridge.kt 注册同名处理器）。
const androidVoiceRecorderChannelName = 'dev.qiyu.app/voice_recorder';

/// 原生录音通道的抽缝：生产实现走 [MethodChannel]，dart 测试注入
/// fake（平台通道行为本身归真机冒烟，不在 dart 测试里 mock 平台业务）。
abstract interface class VoiceRecorderNativeChannel {
  Stream<void> get interruptions;
  Future<void> prepareRecording();

  /// 请求麦克风权限（系统弹窗）。返回 true 表示已授权；拒绝或通道
  /// 不可用返回 false。
  Future<bool> requestMicrophonePermission();

  Future<bool> hasMicrophonePermission();

  /// 请求原生开始录音（AudioRecord → 内存 PCM 缓冲）。返回 false 表示
  /// 权限缺失、设备不可用或录音器初始化失败。
  Future<bool> startRecording();

  /// 停止录音并取回完整原始 PCM 字节（16kHz、16-bit、单声道、小端）。
  /// 字节只存在于内存，从不落盘。取不到字节时分两条路：通道异常才抛出
  /// 交由调用方收尾（吞成空字节会把「拿不到音频」伪装成「用户没说话」）；
  /// 原生正常回包但字节为空则按空字节继续，打包成空 WAV 照常上送，
  /// 由本机 Host 把空转写判为「没有识别到语音」（`stt_settings_service`）。
  Future<Uint8List> stopRecording();

  /// 丢弃录音：停止采集并放弃已缓冲字节，不产生任何数据。
  Future<void> discardRecording();
}

/// MethodChannel 真实现：与原生 VoiceBridge.kt 的四方法一一对应。
///
/// 通道错误与「无原生处理器」统一按操作失败处理（返回 false / 抛出），
/// 绝不携带敏感信息——录音通道只有会话内的音频字节与权限布尔。
final class MethodVoiceRecorderChannel implements VoiceRecorderNativeChannel {
  const MethodVoiceRecorderChannel();

  static const MethodChannel _channel = MethodChannel(
    androidVoiceRecorderChannelName,
  );

  static final StreamController<void> _interruptions =
      StreamController<void>.broadcast(
        sync: true,
        onListen: () => _channel.setMethodCallHandler((call) async {
          if (call.method == 'onRecordingInterrupted') _interruptions.add(null);
        }),
        onCancel: () => _channel.setMethodCallHandler(null),
      );

  @override
  Stream<void> get interruptions => _interruptions.stream;

  @override
  Future<void> prepareRecording() =>
      _channel.invokeMethod<void>('prepareRecording');

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
  Future<bool> startRecording() async {
    try {
      return await _channel.invokeMethod<bool>('startRecording') ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<Uint8List> stopRecording() async {
    // 与同类另三个方法相反，这条故意不把通道异常吞成降级值：调用方
    // VoiceInputController.stopAndTranscribe 已把它收尾成「录音结束失败，
    // 请重新说一次」并回到待录状态；吞成空字节会得到一个只有 44 字节头
    // 的空 WAV 并照常上送转写，把「拿不到音频」伪装成「用户没说话」。
    final bytes = await _channel.invokeMethod<Uint8List>('stopRecording');
    return bytes ?? Uint8List(0);
  }

  @override
  Future<void> discardRecording() async {
    try {
      await _channel.invokeMethod<void>('discardRecording');
    } on Object {
      // 丢弃本来就以「不产生任何数据」收尾；通道异常同样按已丢弃处理。
    }
  }
}

/// io 平台（安卓壳）的录音接缝实现：原生 AudioRecord 直接按契约采样
/// （16kHz、16-bit、单声道）采集 PCM，Dart 侧打包 RIFF/WAV 头——
/// 与 web 侧 `toWav16kMono` 的产物逐字节同构（见 [packWav16kMonoPcm]）。
///
/// 麦克风权限走系统弹窗（[VoiceRecorderNativeChannel.requestMicrophonePermission]），
/// 拒绝即返回 null，调用方按「无法使用麦克风」如实呈现；文字输入与
/// 朗读链路不受影响。
///
/// widget 测试跑在桌面宿主上，[supported] 如实报告不可用（与 stub 同
/// 语义）；接缝行为测试用构造参数注入 fake 通道并显式指定 [supported]。
final class IoVoiceRecorderPlatform
    implements
        VoiceRecorderPlatform,
        PermissionAwareVoiceRecorderPlatform,
        InterruptibleVoiceRecorderPlatform {
  IoVoiceRecorderPlatform({
    VoiceRecorderNativeChannel? channel,
    bool? supported,
  }) : _channel = channel ?? const MethodVoiceRecorderChannel(),
       _supportedOverride = supported;

  final VoiceRecorderNativeChannel _channel;
  final bool? _supportedOverride;

  @override
  bool get supported => _supportedOverride ?? Platform.isAndroid;

  @override
  Stream<void> get interruptions => _channel.interruptions;

  @override
  Future<void> prepareInput() => _channel.prepareRecording();

  @override
  void cancelPreparation() => unawaited(_channel.discardRecording());

  @override
  Future<VoicePermissionResult> preparePermission() async {
    if (await _channel.hasMicrophonePermission()) {
      return VoicePermissionResult.ready;
    }
    return await _channel.requestMicrophonePermission()
        ? VoicePermissionResult.grantedNow
        : VoicePermissionResult.denied;
  }

  @override
  Future<VoiceRecordingSession?> start() async {
    if (!supported) {
      return null;
    }
    // 授权由 preparePermission 独立完成；起录只复查，不打开系统弹窗。
    if (!await _channel.hasMicrophonePermission()) {
      return null;
    }
    if (!await _channel.startRecording()) {
      return null;
    }
    return _AndroidVoiceRecordingSession(_channel);
  }

  @override
  Future<RecordedAudio> toWav16kMono(RecordedAudio audio) async {
    // 安卓录音本身就是契约格式（16kHz/16-bit/单声道 WAV），转换是
    // 恒等映射；豆包契约与 web 侧转换产物逐项对齐，Host 上送契约不变。
    return audio;
  }
}

/// 一次安卓录音会话：PCM 只在原生内存缓冲与通道返回值里流转，
/// stop 打包 WAV 后交还调用方（随转写完成或取消即丢弃），永不落盘。
final class _AndroidVoiceRecordingSession implements VoiceRecordingSession {
  _AndroidVoiceRecordingSession(this._channel);

  final VoiceRecorderNativeChannel _channel;
  bool _stopped = false;

  /// 容器类型即 MIME：本实现产出的就是完整 WAV 字节，不带编解码参数。
  @override
  String get mimeType => 'audio/wav';

  @override
  Future<Uint8List> stop() async {
    if (_stopped) {
      throw StateError('录音会话只应停止一次。');
    }
    _stopped = true;
    final pcm = await _channel.stopRecording();
    return packWav16kMonoPcm(pcm);
  }

  @override
  void discard() {
    _stopped = true;
    unawaited(_channel.discardRecording());
  }
}

VoiceRecorderPlatform createVoiceRecorderPlatform() =>
    IoVoiceRecorderPlatform();
