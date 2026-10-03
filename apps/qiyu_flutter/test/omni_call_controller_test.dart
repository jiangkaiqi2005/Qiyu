import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/omni_call_controller.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';

import 'support/omni_call_fakes.dart';

void main() {
  group('OmniCallController 线协议与状态机（T04）', () {
    test('startCall 发 start 首帧带 sessionId；建连窗口内的上行块在 active 后补发', () async {
      final capture = FakeOmniCapture();
      final socket = FakeOmniSocket();
      final surface = RecordingCallSurface();
      final call = _buildController(
        surface: surface,
        capture: capture,
        socket: socket,
      );
      await call.refreshAvailability();
      expect(await call.startCall(sessionId: 'session-1'), isTrue);
      expect(
        socket.frames.single,
        jsonEncode({'type': 'start', 'sessionId': 'session-1'}),
      );
      expect(call.phase, OmniCallPhase.connecting);

      // 建连窗口内的开口：不丢，攒着等 active。
      capture.emitChunk(omniTestPcm(frames: 160));
      expect(socket.frames.length, 1);

      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();
      expect(call.phase, OmniCallPhase.active);
      final sent = socket.decodedFrames;
      expect(sent.length, 2, reason: '补发的开口紧跟 state 后出网');
      expect(sent[1]['type'], 'audio');
      expect(sent[1]['pcm'], base64Encode(omniTestPcm(frames: 160)));

      // active 后的采集块直出。
      capture.emitChunk(omniTestPcm(frames: 320, fill: 2));
      expect(socket.frames.length, 3);
      call.dispose();
    });

    test('麦克风不可用：回到空闲并置 micUnavailable，可继续打字（不建 socket）', () async {
      final capture = FakeOmniCapture()..denied = true;
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: RecordingCallSurface(),
        capture: capture,
        socket: socket,
      );
      await call.refreshAvailability();
      expect(await call.startCall(), isFalse);
      expect(call.phase, OmniCallPhase.idle);
      expect(call.startupFailure, OmniCallStartupFailure.micUnavailable);
      expect(call.callInProgress, isFalse);
      expect(socket.frames, isEmpty);
      call.dispose();
    });

    test('连接失败：置 connectFailed，采集已停，可继续打字', () async {
      final capture = FakeOmniCapture();
      final socket = FakeOmniSocket()..readyFails = true;
      final call = _buildController(
        surface: RecordingCallSurface(),
        capture: capture,
        socket: socket,
      );
      await call.refreshAvailability();
      expect(await call.startCall(), isFalse);
      expect(call.startupFailure, OmniCallStartupFailure.connectFailed);
      expect(call.phase, OmniCallPhase.idle);
      expect(capture.lastSession?.stopped, isTrue);
      call.dispose();
    });

    test('未配置 Omni：startCall 直接 notReady；availability 识别非 Omni 档', () async {
      final call = _buildController(
        surface: RecordingCallSurface(),
        capture: FakeOmniCapture(),
        socket: FakeOmniSocket(),
        providerKind: null,
      );
      await call.refreshAvailability();
      expect(call.omniReady, isFalse);
      expect(await call.startCall(), isFalse);
      expect(call.startupFailure, OmniCallStartupFailure.notReady);
      call.dispose();
    });

    test('输入转录进入聊天流；回复增量与终态按序落显示（完成轮不标记）', () async {
      final surface = RecordingCallSurface();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: surface,
        capture: FakeOmniCapture(),
        socket: socket,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();

      socket.emit({
        'type': 'inputTranscript',
        'turnId': 'voice-1',
        'text': '今晚有点睡不着。',
      });
      await omniDrain();
      expect(surface.userTurns.single.requestId, 'voice-1');
      expect(surface.userTurns.single.text, '今晚有点睡不着。');

      socket.emit({'type': 'replyDelta', 'turnId': 'voice-1', 'text': '嗯，'});
      socket.emit({'type': 'replyDelta', 'turnId': 'voice-1', 'text': '我在。'});
      socket.emit({
        'type': 'replyDone',
        'turnId': 'voice-1',
        'status': 'completed',
        'incomplete': false,
      });
      await omniDrain();
      expect(surface.deltas.join(), '嗯，我在。');
      expect(surface.dones.single, isFalse);
      call.dispose();
    });

    test('下行音频按 24k 开流播放；同轮续答在收口后重开一路继续播', () async {
      final player = FakeOmniStreamingPlayer();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: RecordingCallSurface(),
        capture: FakeOmniCapture(),
        socket: socket,
        player: player,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();

      socket.emit({
        'type': 'audio',
        'turnId': 'voice-1',
        'pcm': base64Encode(omniTestPcm(frames: 10)),
      });
      await omniDrain();
      await omniDrain();
      expect(player.sampleRates, [OmniCallController.playbackSampleRate]);
      expect(player.playbacks.first.appended, hasLength(1));
      expect(call.qiyuSpeaking, isTrue);

      // 主回复完成：缓冲播完即止（end），同轮续答的音频重开一路。
      socket.emit({
        'type': 'replyDone',
        'turnId': 'voice-1',
        'status': 'completed',
        'incomplete': false,
      });
      socket.emit({
        'type': 'audio',
        'turnId': 'voice-1',
        'pcm': base64Encode(omniTestPcm(frames: 11)),
      });
      await omniDrain();
      await omniDrain();
      expect(player.playbacks.first.ended, isTrue);
      expect(player.sampleRates.length, 2, reason: '静默工具轮后的续答重开一路');
      expect(player.playbacks.last.appended, hasLength(1));
      call.dispose();
    });

    test('真正插话：立即停播清队列，旧轮后到音频与文字按死轮隔离，前缀标记未完成', () async {
      final player = FakeOmniStreamingPlayer();
      final surface = RecordingCallSurface();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: surface,
        capture: FakeOmniCapture(),
        socket: socket,
        player: player,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();

      socket.emit({
        'type': 'audio',
        'turnId': 'voice-1',
        'pcm': base64Encode(omniTestPcm(frames: 10)),
      });
      await omniDrain();
      await omniDrain();

      socket.emit({'type': 'speechStarted'});
      await omniDrain();
      expect(call.userSpeaking, isTrue);
      expect(player.playbacks.first.stopped, isTrue, reason: '打断即时停播清队列');

      // 被取消轮的后到事件：一律丢弃（T04:15）。
      socket.emit({
        'type': 'audio',
        'turnId': 'voice-1',
        'pcm': base64Encode(omniTestPcm(frames: 12)),
      });
      socket.emit({'type': 'replyDelta', 'turnId': 'voice-1', 'text': '迟到的话'});
      socket.emit({
        'type': 'replyDone',
        'turnId': 'voice-1',
        'status': 'cancelled',
        'incomplete': true,
      });
      await omniDrain();
      await omniDrain();
      expect(player.sampleRates.length, 1, reason: '旧轮迟到音频不再开新播放');
      expect(surface.deltas, isEmpty, reason: '旧轮迟到文字不追加');
      expect(surface.dones.single, isTrue, reason: '已显示前缀如实标记未完成');

      // 新一轮照常。
      socket.emit({
        'type': 'audio',
        'turnId': 'voice-2',
        'pcm': base64Encode(omniTestPcm(frames: 13)),
      });
      await omniDrain();
      await omniDrain();
      expect(player.sampleRates.length, 2);
      call.dispose();
    });

    test('replyDone incomplete 的轮直接进入死轮：后到音频不复活', () async {
      final player = FakeOmniStreamingPlayer();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: RecordingCallSurface(),
        capture: FakeOmniCapture(),
        socket: socket,
        player: player,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();

      socket.emit({
        'type': 'replyDone',
        'turnId': 'voice-3',
        'status': 'failed',
        'incomplete': true,
      });
      socket.emit({
        'type': 'audio',
        'turnId': 'voice-3',
        'pcm': base64Encode(omniTestPcm(frames: 10)),
      });
      await omniDrain();
      await omniDrain();
      expect(player.sampleRates, isEmpty);
      call.dispose();
    });

    test('闭麦/恢复：平台会话与 Host 帧同步，静音期间采集块不上送', () async {
      final capture = FakeOmniCapture();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: RecordingCallSurface(),
        capture: capture,
        socket: socket,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();

      call.toggleMute();
      expect(call.muted, isTrue);
      expect(capture.lastSession?.muted, isTrue);
      expect(
        socket.frames.last,
        jsonEncode({'type': 'mute', 'muted': true}),
      );

      capture.emitChunk(omniTestPcm(frames: 100));
      final mutedFrameCount = socket.frames.length;
      expect(mutedFrameCount, 2, reason: '静音期间不上送音频');

      call.toggleMute();
      expect(call.muted, isFalse);
      expect(capture.lastSession?.muted, isFalse);
      capture.emitChunk(omniTestPcm(frames: 100, fill: 3));
      expect(socket.frames.length, greaterThan(mutedFrameCount));
      call.dispose();
    });

    test('通话中打字：text 帧带 requestId 且乐观入列；非活动通话不受理', () async {
      final surface = RecordingCallSurface();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: surface,
        capture: FakeOmniCapture(),
        socket: socket,
        requestIdFactory: () => 'omni-fixed',
      );
      await call.refreshAvailability();
      expect(call.sendTypedText('早'), isFalse, reason: '未接通不接受通话打字');

      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();
      expect(call.sendTypedText('早'), isTrue);
      final sent = socket.decodedFrames;
      expect(sent.last['type'], 'text');
      expect(sent.last['requestId'], 'omni-fixed');
      expect(sent.last['text'], '早');
      expect(surface.userTurns.last.text, '早');
      call.dispose();
    });

    test('挂断：立即停麦停播、发 end 帧、置 ended；socket 收口后对账一次', () async {
      final player = FakeOmniStreamingPlayer();
      final capture = FakeOmniCapture();
      final surface = RecordingCallSurface();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: surface,
        capture: capture,
        socket: socket,
        player: player,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();
      socket.emit({
        'type': 'audio',
        'turnId': 'voice-1',
        'pcm': base64Encode(omniTestPcm(frames: 10)),
      });
      await omniDrain();
      await omniDrain();

      await call.end();
      expect(call.phase, OmniCallPhase.ended);
      expect(call.callInProgress, isFalse);
      expect(socket.frames.last, jsonEncode({'type': 'end'}));
      expect(capture.lastSession?.stopped, isTrue);
      expect(player.playbacks.first.stopped, isTrue);

      // Host 收尾落盘完才关连接：这里关闭 socket，等对账跑完。
      await socket.closeStream();
      await omniDrain();
      await omniDrain();
      expect(surface.resyncs, 1);
      call.dispose();
    });

    test('Host 推送 ended：如实收口并对账', () async {
      final surface = RecordingCallSurface();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: surface,
        capture: FakeOmniCapture(),
        socket: socket,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();
      socket.emit({
        'type': 'state',
        'phase': 'ended',
        'reason': '模型配置已切换，本次通话已结束。',
      });
      await omniDrain();
      expect(call.phase, OmniCallPhase.ended);
      expect(call.phaseReason, '模型配置已切换，本次通话已结束。');
      await socket.closeStream();
      await omniDrain();
      await omniDrain();
      expect(surface.resyncs, 1);
      call.dispose();
    });

    test('socket 断开（非 ended 期）：通话真实结束，不偷偷重开，仍对账', () async {
      final surface = RecordingCallSurface();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: surface,
        capture: FakeOmniCapture(),
        socket: socket,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();

      await socket.closeStream();
      await omniDrain();
      await omniDrain();
      expect(call.phase, OmniCallPhase.ended);
      expect(call.phaseReason, isNotNull);
      expect(surface.resyncs, 1);
      call.dispose();
    });

    test('设备失效：通话真实结束，不偷偷重开', () async {
      final capture = FakeOmniCapture();
      final surface = RecordingCallSurface();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: surface,
        capture: capture,
        socket: socket,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();

      capture.loseDevice();
      await omniDrain();
      expect(call.phase, OmniCallPhase.ended);
      expect(capture.lastSession?.stopped, isTrue);
      expect(socket.frames.last, jsonEncode({'type': 'end'}));
      await socket.closeStream();
      await omniDrain();
      await omniDrain();
      expect(surface.resyncs, 1);
      call.dispose();
    });

    test('播放器播不出来：文字照常交付，声音如实缺席，不崩', () async {
      final player = FakeOmniStreamingPlayer()..returnNull = true;
      final surface = RecordingCallSurface();
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: surface,
        capture: FakeOmniCapture(),
        socket: socket,
        player: player,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();

      socket.emit({
        'type': 'audio',
        'turnId': 'voice-1',
        'pcm': base64Encode(omniTestPcm(frames: 10)),
      });
      socket.emit({
        'type': 'replyDelta',
        'turnId': 'voice-1',
        'text': '我在。',
      });
      socket.emit({
        'type': 'replyDone',
        'turnId': 'voice-1',
        'status': 'completed',
        'incomplete': false,
      });
      await omniDrain();
      await omniDrain();
      expect(call.qiyuSpeaking, isFalse);
      expect(surface.deltas.join(), '我在。');
      expect(surface.dones.single, isFalse);
      call.dispose();
    });

    test('重连中状态透出；未知类型与坏帧静默忽略', () async {
      final socket = FakeOmniSocket();
      final call = _buildController(
        surface: RecordingCallSurface(),
        capture: FakeOmniCapture(),
        socket: socket,
      );
      await call.refreshAvailability();
      await call.startCall();
      socket.emit({'type': 'state', 'phase': 'active'});
      await omniDrain();
      socket.emit({'type': 'state', 'phase': 'reconnecting'});
      await omniDrain();
      expect(call.phase, OmniCallPhase.reconnecting);
      expect(call.callInProgress, isTrue);

      socket.emitRaw('not json');
      socket.emit({'type': 'unknown-future-event'});
      socket.emit({'type': 'replyDelta'});
      await omniDrain();
      expect(call.phase, OmniCallPhase.reconnecting);
      call.dispose();
    });
  });
}

OmniCallController _buildController({
  required OmniCallChatSurface surface,
  required FakeOmniCapture capture,
  required FakeOmniSocket socket,
  FakeOmniStreamingPlayer? player,
  ProviderKind? providerKind = ProviderKind.qwenOmniRealtime,
  String Function()? requestIdFactory,
}) {
  return OmniCallController(
    surface: surface,
    providerSettings: FakeOmniProviderGateway(kind: providerKind),
    capture: capture,
    player: player,
    connector: (_) => socket,
    baseUri: Uri.parse('http://127.0.0.1:8080/'),
    requestIdFactory: requestIdFactory ?? () => 'omni-test-1',
  );
}
