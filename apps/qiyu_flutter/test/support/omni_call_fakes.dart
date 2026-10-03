import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:qiyu_flutter/features/chat/omni_call_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_capture_platform.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';

/// Omni 通话测试替身（omni_call_controller_test 与 omni_call_ui_test 共用）。

final class FakeOmniSocket implements OmniCallSocket {
  FakeOmniSocket();

  final frames = <String>[];
  bool readyFails = false;
  bool _closed = false;
  final _controller = StreamController<String>.broadcast(sync: true);

  List<Map<String, Object?>> get decodedFrames =>
      frames.map((f) => jsonDecode(f) as Map<String, Object?>).toList();

  void emit(Map<String, Object?> event) => _controller.add(jsonEncode(event));

  void emitRaw(String raw) => _controller.add(raw);

  Future<void> closeStream() async {
    _closed = true;
    await _controller.close();
  }

  @override
  Future<void> get ready async {
    if (readyFails) {
      throw const FakeOmniConnectError();
    }
  }

  @override
  Stream<String> get stream => _controller.stream;

  @override
  void send(String frame) {
    if (_closed) {
      throw StateError('socket closed');
    }
    frames.add(frame);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

final class FakeOmniConnectError implements Exception {
  const FakeOmniConnectError();
}

final class FakeOmniCaptureSession implements VoiceCaptureSession {
  bool stopped = false;
  bool muted = false;

  @override
  void setMuted(bool value) => muted = value;

  @override
  void stop() => stopped = true;
}

final class FakeOmniCapture implements VoiceCapturePlatform {
  bool denied = false;
  FakeOmniCaptureSession? lastSession;
  void Function(Uint8List pcm)? _onChunk;
  void Function(String reason)? _onUnavailable;

  void emitChunk(Uint8List pcm) => _onChunk?.call(pcm);

  /// 设备失效/轨道被夺走（spec:23）：采集中断回调。
  void loseDevice() => _onUnavailable?.call('microphone track ended');

  @override
  bool get supported => true;

  @override
  Future<VoiceCaptureSession?> start({
    required void Function(Uint8List pcm) onChunk,
    required void Function(String reason) onUnavailable,
  }) async {
    if (denied) {
      return null;
    }
    _onChunk = onChunk;
    _onUnavailable = onUnavailable;
    return lastSession = FakeOmniCaptureSession();
  }
}

final class FakeOmniStreamPlayback implements VoiceStreamPlayback {
  final appended = <Uint8List>[];
  bool ended = false;
  bool stopped = false;
  final _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  void append(Uint8List pcm) => appended.add(pcm);

  @override
  void end() => ended = true;

  @override
  void stop() {
    stopped = true;
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  void setVolume(double volume) {}
}

final class FakeOmniStreamingPlayer implements StreamingVoicePlayerPlatform {
  final sampleRates = <int>[];
  final playbacks = <FakeOmniStreamPlayback>[];

  /// 开流返回 null（能力缺失/自动播放被拒）的注入位。
  bool returnNull = false;

  @override
  Future<VoiceStreamPlayback?> startStream({
    required int sampleRate,
    double volume = 1.0,
  }) async {
    sampleRates.add(sampleRate);
    if (returnNull) {
      return null;
    }
    final playback = FakeOmniStreamPlayback();
    playbacks.add(playback);
    return playback;
  }
}

final class RecordingCallSurface implements OmniCallChatSurface {
  int resets = 0;
  final userTurns = <({String requestId, String text})>[];
  final deltas = <String>[];
  final dones = <bool>[];
  int resyncs = 0;

  @override
  void callSessionReset() => resets += 1;

  @override
  void callUserTurn({required String requestId, required String text}) {
    userTurns.add((requestId: requestId, text: text));
  }

  @override
  void callReplyDelta(String text) => deltas.add(text);

  @override
  void callReplyDone({required bool incomplete}) => dones.add(incomplete);

  @override
  Future<void> resyncAfterCall() async => resyncs += 1;
}

final class FakeOmniProviderGateway implements ProviderSettingsGateway {
  FakeOmniProviderGateway({this.kind = ProviderKind.qwenOmniRealtime});

  final ProviderKind? kind;

  @override
  Future<ProviderSettings> read() async =>
      ProviderSettings(configured: true, keySet: true, provider: kind);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
}

Uint8List omniTestPcm({int frames = 160, int fill = 1}) {
  final bytes = Uint8List(frames * 2);
  final view = ByteData.view(bytes.buffer);
  for (var i = 0; i < frames; i++) {
    view.setInt16(i * 2, fill * 1000, Endian.little);
  }
  return bytes;
}

Future<void> omniDrain() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
