import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/omni_call_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_capture_platform.dart';
import 'package:qiyu_flutter/features/chat/omni_call_usage_state.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';

import 'support/omni_call_fakes.dart';

void main() {
  test('旧进页的非 Omni 读取迟到不结束后一次 Omni 自动通话', () async {
    final gateway = DeferredProviderGateway();
    final capture = FakeOmniCapture();
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: gateway,
      capture: capture,
      player: FakeOmniStreamingPlayer(),
      connector: (_) => FakeOmniSocket(),
      autoStartAllowed: () async => true,
    );
    call.updateLocation(onChat: true, visible: true);
    call.updateLocation(onChat: false, visible: true);
    call.updateLocation(onChat: true, visible: true);
    gateway.requests.last.complete(autoOmniSettings);
    await omniDrain();
    expect(call.phase, OmniCallPhase.connecting);
    gateway.requests.first.complete(nonOmniSettings);
    await omniDrain();
    expect(call.phase, OmniCallPhase.connecting);
    expect(call.omniReady, isTrue);
    expect(capture.lastSession?.stopped, isFalse);
    call.dispose();
  });

  test('旧 refresh 可用结果不能覆盖新进页非 Omni，下一次启动仍受当前配置限制', () async {
    final gateway = DeferredProviderGateway();
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: gateway,
      capture: DeferredCapture(),
      autoStartAllowed: () async => true,
    );
    final refresh = call.refreshAvailability();
    call.updateLocation(onChat: true, visible: true);
    gateway.requests.last.complete(nonOmniSettings);
    await omniDrain();
    gateway.requests.first.complete(autoOmniSettings);
    await refresh;
    expect(call.omniReady, isFalse);
    expect(await call.startCall(), isFalse);
    expect(call.startupFailure, OmniCallStartupFailure.notReady);
    call.dispose();
  });

  test('进页与 refresh 并发读取时，以最新结果自动启动且旧结果不结束通话', () async {
    final gateway = DeferredProviderGateway();
    final capture = FakeOmniCapture();
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: gateway,
      capture: capture,
      player: FakeOmniStreamingPlayer(),
      connector: (_) => FakeOmniSocket(),
      autoStartAllowed: () async => true,
    );
    call.updateLocation(onChat: true, visible: true);
    final refresh = call.refreshAvailability();
    gateway.requests.last.complete(autoOmniSettings);
    await refresh;
    gateway.requests.first.complete(nonOmniSettings);
    await omniDrain();
    expect(call.phase, OmniCallPhase.connecting);
    expect(call.omniReady, isTrue);
    expect(capture.lastSession?.stopped, isFalse);
    call.dispose();
  });

  test('Provider 切换使未完成自动采集失效，迟到结果只释放不接通', () async {
    final gateway = FakeOmniProviderGateway(
      callStartupMode: CallStartupMode.autoOnChatEntry,
    );
    final capture = DeferredCapture();
    final socket = FakeOmniSocket();
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: gateway,
      capture: capture,
      player: FakeOmniStreamingPlayer(),
      connector: (_) => socket,
      autoStartAllowed: () async => true,
    );
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    gateway.kind = ProviderKind.openAiCompatible;
    await call.refreshAvailability();
    final session = FakeOmniCaptureSession();
    capture.requests.single.complete(session);
    await omniDrain();
    expect(session.stopped, isTrue);
    expect(call.callInProgress, isFalse);
    expect(call.omniReady, isFalse);
    expect(socket.frames, isEmpty);
    call.dispose();
  });

  test('旧首帧失败的异步关闭不能把已重开的通话置空闲', () async {
    final oldSocket = DelayedRejectingSocket();
    final newSocket = FakeOmniSocket();
    var first = true;
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: FakeOmniProviderGateway(),
      capture: FakeOmniCapture(),
      connector: (_) {
        if (first) {
          first = false;
          return oldSocket;
        }
        return newSocket;
      },
    );
    await call.refreshAvailability();
    final oldStart = call.startCall();
    await omniDrain();
    await call.end();
    expect(await call.startCall(), isTrue);
    newSocket.emit({'type': 'state', 'phase': 'active'});
    await omniDrain();
    oldSocket.closeResult.complete();
    expect(await oldStart, isFalse);
    expect(call.phase, OmniCallPhase.active);
    call.dispose();
  });
  test('首帧发送失败时停采集关 socket，失败不冒充接通', () async {
    final capture = FakeOmniCapture();
    final socket = RejectingSocket();
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: FakeOmniProviderGateway(),
      capture: capture,
      connector: (_) => socket,
    );
    await call.refreshAvailability();
    expect(await call.startCall(), isFalse);
    expect(call.startupFailure, OmniCallStartupFailure.connectFailed);
    expect(capture.lastSession?.stopped, isTrue);
    expect(socket.closed, isTrue);
    call.dispose();
  });
  test('挂断抑制先于未完成平台许可；回页/前台不复活，手动仍可重开', () async {
    final permitted = Completer<bool>();
    final socket = FakeOmniSocket();
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: FakeOmniProviderGateway(
        callStartupMode: CallStartupMode.autoOnChatEntry,
      ),
      capture: FakeOmniCapture(),
      player: FakeOmniStreamingPlayer(),
      connector: (_) => socket,
      autoStartAllowed: () => permitted.future,
    );
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    await call.end();
    expect(call.autoStartSuppressed, isTrue);
    permitted.complete(true);
    call.updateLocation(onChat: false, visible: true);
    call.updateLocation(onChat: true, visible: true);
    call.updateLocation(onChat: true, visible: false);
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    expect(socket.frames, isEmpty);
    expect(await call.startCall(), isTrue);
    call.dispose();
  });

  test('设置中改为自动不当场拨通，下一次进页才读取新偏好', () async {
    final gateway = FakeOmniProviderGateway();
    final socket = FakeOmniSocket();
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: gateway,
      capture: FakeOmniCapture(),
      player: FakeOmniStreamingPlayer(),
      connector: (_) => socket,
      autoStartAllowed: () async => true,
    );
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    gateway.callStartupMode = CallStartupMode.autoOnChatEntry;
    await call.refreshAvailability();
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    expect(socket.frames, isEmpty);
    call.updateLocation(onChat: false, visible: true);
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    expect(socket.decodedFrames.single['type'], 'start');
    call.dispose();
  });

  test('输出不就绪：停止采集，反馈失败且本次不重试，手动可继续', () async {
    final capture = FakeOmniCapture();
    final socket = FakeOmniSocket();
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: FakeOmniProviderGateway(
        callStartupMode: CallStartupMode.autoOnChatEntry,
      ),
      capture: capture,
      player: FakeOmniStreamingPlayer()..autoPlaybackReady = false,
      connector: (_) => socket,
      autoStartAllowed: () async => true,
    );
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    expect(call.automaticStartFailed, isTrue);
    expect(call.startupFailure, OmniCallStartupFailure.playbackUnavailable);
    expect(capture.lastSession?.stopped, isTrue);
    call.updateLocation(onChat: false, visible: true);
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    expect(socket.frames, isEmpty);
    expect(await call.startCall(), isTrue);
    call.dispose();
  });

  test('同一次使用的刷新保留抑制，新的进程/页面使用可再自动', () async {
    final usage = OmniCallUsageState();
    OmniCallController create(
      OmniCallUsageState state,
      FakeOmniSocket socket,
    ) => OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: FakeOmniProviderGateway(
        callStartupMode: CallStartupMode.autoOnChatEntry,
      ),
      capture: FakeOmniCapture(),
      player: FakeOmniStreamingPlayer(),
      connector: (_) => socket,
      usageState: state,
      autoStartAllowed: () async => true,
    );
    final first = create(usage, FakeOmniSocket());
    await first.end();
    first.dispose();
    final refreshedSocket = FakeOmniSocket();
    final refreshed = create(usage, refreshedSocket);
    refreshed.updateLocation(onChat: true, visible: true);
    await omniDrain();
    expect(refreshedSocket.frames, isEmpty);
    refreshed.dispose();
    final reopenedSocket = FakeOmniSocket();
    final reopened = create(OmniCallUsageState(), reopenedSocket);
    reopened.updateLocation(onChat: true, visible: true);
    await omniDrain();
    expect(reopenedSocket.decodedFrames.single['type'], 'start');
    reopened.dispose();
  });

  for (final leave in [false, true]) {
    test('${leave ? '离页' : '隐藏'}使未完成自动采集过时；回前台不重开', () async {
      final capture = DeferredCapture();
      final socket = FakeOmniSocket();
      final call = OmniCallController(
        surface: RecordingCallSurface(),
        providerSettings: FakeOmniProviderGateway(
          callStartupMode: CallStartupMode.autoOnChatEntry,
        ),
        capture: capture,
        player: FakeOmniStreamingPlayer(),
        connector: (_) => socket,
        autoStartAllowed: () async => true,
      );
      call.updateLocation(onChat: true, visible: true);
      await omniDrain();
      call.updateLocation(onChat: !leave, visible: leave);
      final session = FakeOmniCaptureSession();
      capture.requests.single.complete(session);
      await omniDrain();
      expect(session.stopped, isTrue);
      expect(call.callInProgress, isFalse);
      call.updateLocation(onChat: true, visible: true);
      await omniDrain();
      expect(socket.frames, isEmpty);
      expect(capture.requests, hasLength(1));
      call.dispose();
    });
  }

  test('非 Omni 与隐藏进页均不开麦，不以回前台补拨', () async {
    final capture = DeferredCapture();
    final gateway = FakeOmniProviderGateway(
      kind: ProviderKind.openAiCompatible,
      callStartupMode: CallStartupMode.autoOnChatEntry,
    );
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: gateway,
      capture: capture,
      autoStartAllowed: () async => true,
    );
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    gateway.kind = ProviderKind.qwenOmniRealtime;
    call.updateLocation(onChat: false, visible: false);
    call.updateLocation(onChat: true, visible: false);
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    expect(capture.requests, isEmpty);
    call.dispose();
  });

  test('旧 socket 失败与挂断对账不能关闭已重开的手动通话', () async {
    final capture = FakeOmniCapture();
    final oldSocket = DeferredSocket();
    final newSocket = FakeOmniSocket();
    final surface = RecordingCallSurface();
    var first = true;
    final call = OmniCallController(
      surface: surface,
      providerSettings: FakeOmniProviderGateway(),
      capture: capture,
      connector: (_) {
        if (first) {
          first = false;
          return oldSocket;
        }
        return newSocket;
      },
    );
    await call.refreshAvailability();
    final oldStart = call.startCall();
    await omniDrain();
    await call.end();
    final resyncs = surface.resyncs;
    expect(await call.startCall(), isTrue);
    newSocket.emit({'type': 'state', 'phase': 'active'});
    oldSocket.readyResult.completeError(const FakeOmniConnectError());
    expect(await oldStart, isFalse);
    await omniDrain();
    expect(call.phase, OmniCallPhase.active);
    expect(capture.lastSession?.stopped, isFalse);
    expect(newSocket.decodedFrames.single['type'], 'start');
    expect(surface.resyncs, resyncs);
    call.dispose();
  });

  test('自动偏好仅进聊天页生效；跨页已有通话与后台回来不另拨', () async {
    final socket = FakeOmniSocket();
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: FakeOmniProviderGateway(
        callStartupMode: CallStartupMode.autoOnChatEntry,
      ),
      capture: FakeOmniCapture(),
      player: FakeOmniStreamingPlayer(),
      connector: (_) => socket,
      autoStartAllowed: () async => true,
    );
    call.updateLocation(onChat: false, visible: true);
    await omniDrain();
    expect(call.callInProgress, isFalse);
    call.updateLocation(onChat: true, visible: true, sessionId: 'session-1');
    await omniDrain();
    expect(socket.decodedFrames.single, {
      'type': 'start',
      'sessionId': 'session-1',
    });
    socket.emit({'type': 'state', 'phase': 'active'});
    await omniDrain();
    call.updateLocation(onChat: false, visible: true);
    call.updateLocation(onChat: true, visible: true);
    call.updateLocation(onChat: true, visible: false);
    call.updateLocation(onChat: true, visible: true);
    await omniDrain();
    expect(call.phase, OmniCallPhase.active);
    expect(socket.decodedFrames, hasLength(1));
    call.dispose();
  });

  test('挂断后手动重开：旧采集结果不能接管新通话或关掉新采集', () async {
    final capture = DeferredCapture();
    final sockets = <FakeOmniSocket>[];
    final call = OmniCallController(
      surface: RecordingCallSurface(),
      providerSettings: FakeOmniProviderGateway(),
      capture: capture,
      connector: (_) {
        final socket = FakeOmniSocket();
        sockets.add(socket);
        return socket;
      },
    );
    await call.refreshAvailability();
    final oldStart = call.startCall();
    await call.end();
    final newStart = call.startCall();
    final oldSession = FakeOmniCaptureSession();
    capture.requests.first.complete(oldSession);
    expect(await oldStart, isFalse);
    expect(oldSession.stopped, isTrue);
    final newSession = FakeOmniCaptureSession();
    capture.requests.last.complete(newSession);
    expect(await newStart, isTrue);
    expect(newSession.stopped, isFalse);
    expect(sockets.single.decodedFrames.single['type'], 'start');
    call.dispose();
  });
}

const autoOmniSettings = ProviderSettings(
  configured: true,
  keySet: true,
  provider: ProviderKind.qwenOmniRealtime,
  callStartupMode: CallStartupMode.autoOnChatEntry,
);
const nonOmniSettings = ProviderSettings(
  configured: true,
  keySet: true,
  provider: ProviderKind.openAiCompatible,
  callStartupMode: CallStartupMode.autoOnChatEntry,
);

class DeferredProviderGateway implements ProviderSettingsGateway {
  final requests = <Completer<ProviderSettings>>[];
  @override
  Future<ProviderSettings> read() {
    final request = Completer<ProviderSettings>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();
  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
}

class DeferredCapture implements VoiceCapturePlatform {
  final requests = <Completer<VoiceCaptureSession?>>[];

  @override
  bool get supported => true;

  @override
  Future<VoiceCaptureSession?> start({
    required void Function(Uint8List pcm) onChunk,
    required void Function(String reason) onUnavailable,
  }) {
    final request = Completer<VoiceCaptureSession?>();
    requests.add(request);
    return request.future;
  }
}

class DeferredSocket implements OmniCallSocket {
  final readyResult = Completer<void>();
  final socket = FakeOmniSocket();
  bool closed = false;
  @override
  Future<void> get ready => readyResult.future;
  @override
  Stream<String> get stream => socket.stream;
  @override
  void send(String frame) => socket.send(frame);
  @override
  Future<void> close() async {
    closed = true;
    await socket.close();
  }
}

class RejectingSocket extends DeferredSocket {
  RejectingSocket() {
    readyResult.complete();
  }
  @override
  void send(String frame) => throw const FakeOmniConnectError();
}

class DelayedRejectingSocket extends RejectingSocket {
  final closeResult = Completer<void>();
  @override
  Future<void> close() async {
    await closeResult.future;
    await super.close();
  }
}
