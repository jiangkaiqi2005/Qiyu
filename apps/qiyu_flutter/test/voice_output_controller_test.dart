import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';

void main() {
  test('按序全播：offer 两条，第一条播完才播第二条（不抢占）', () async {
    final player = _FakeVoicePlayerPlatform();
    final gateway = _RecordingSpeakGateway();
    final controller = VoiceOutputController(gateway, playerPlatform: player);

    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
      enabled: true,
    );
    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 1),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);

    // 第一段在播：第二段已入队但没有出网合成。
    expect(controller.phase, VoiceOutputPhase.playing);
    expect(controller.nowReading?.deliveryIndex, 0);
    expect(gateway.calls, hasLength(1));

    // 播完第一段，第二段才开始。
    player.finishCurrent();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, VoiceOutputPhase.playing);
    expect(controller.nowReading?.deliveryIndex, 1);
    expect(gateway.calls, hasLength(2));

    player.finishCurrent();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, VoiceOutputPhase.idle);
    expect(controller.nowReading, isNull);
  });

  test('stopAll 立即停止并清空队列；在途结果作废', () async {
    final player = _FakeVoicePlayerPlatform();
    final gateway = _RecordingSpeakGateway();
    final controller = VoiceOutputController(gateway, playerPlatform: player);

    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
      enabled: true,
    );
    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 1),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, VoiceOutputPhase.playing);

    controller.stopAll();
    expect(controller.phase, VoiceOutputPhase.idle);
    expect(controller.nowReading, isNull);
    expect(player.stoppedCount, 1);

    // 已停止：队列里的第二段不再播，之后的完成回调不会复活状态。
    player.finishCurrent();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, VoiceOutputPhase.idle);
    expect(gateway.calls, hasLength(1));
  });

  test('合成失败：首次提示一次，后续静默跳过，队列继续', () async {
    final player = _FakeVoicePlayerPlatform();
    final gateway = _RecordingSpeakGateway(failing: true);
    final controller = VoiceOutputController(gateway, playerPlatform: player);

    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, '语音服务连不上，这条读不出来。');
    expect(controller.phase, VoiceOutputPhase.idle);

    controller.consumeFailureNotice();
    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 1),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, isNull);
    expect(controller.phase, VoiceOutputPhase.idle);
  });

  test('合成失败提示按会话重置：同会话只提示一次，新会话可再次提示', () async {
    final gateway = _RecordingSpeakGateway(failing: true);
    final controller = VoiceOutputController(
      gateway,
      playerPlatform: _FakeVoicePlayerPlatform(),
    );

    controller.offer(
      const VoiceOutputRequest(
        requestId: 'r1',
        deliveryIndex: 0,
        sessionId: 'session-1',
      ),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, isNotNull);

    controller.consumeFailureNotice();
    controller.offer(
      const VoiceOutputRequest(
        requestId: 'r2',
        deliveryIndex: 0,
        sessionId: 'session-1',
      ),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, isNull);

    controller.offer(
      const VoiceOutputRequest(
        requestId: 'r3',
        deliveryIndex: 0,
        sessionId: 'session-2',
      ),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, isNotNull);
  });

  test('自动播放被拒时提示点气泡重听，不误报成语音服务断线', () async {
    final gateway = _RecordingSpeakGateway();
    final controller = VoiceOutputController(
      gateway,
      playerPlatform: const _RefusingVoicePlayerPlatform(),
    );

    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, '浏览器没能播放，点小喇叭再听一次。');
    expect(controller.phase, VoiceOutputPhase.idle);
  });

  test('enabled=false 直接丢弃，不出网不排队', () async {
    final player = _FakeVoicePlayerPlatform();
    final gateway = _RecordingSpeakGateway();
    final controller = VoiceOutputController(gateway, playerPlatform: player);

    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
      enabled: false,
    );
    await Future<void>.delayed(Duration.zero);
    expect(gateway.calls, isEmpty);
    expect(controller.phase, VoiceOutputPhase.idle);
  });

  test('playNow 立即顶播：清空自动队列，顶掉正在播的', () async {
    final player = _FakeVoicePlayerPlatform();
    final gateway = _RecordingSpeakGateway();
    final controller = VoiceOutputController(gateway, playerPlatform: player);

    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
      enabled: true,
    );
    controller.offer(
      const VoiceOutputRequest(requestId: 'r2', deliveryIndex: 0),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.nowReading?.requestId, 'r1');

    controller.playNow(
      const VoiceOutputRequest(requestId: 'r3', deliveryIndex: 0),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.nowReading?.requestId, 'r3');
    expect(
      controller.phase == VoiceOutputPhase.synthesizing ||
          controller.phase == VoiceOutputPhase.playing,
      isTrue,
    );

    // r3 播完后队列是空的（r2 被清掉），回到 idle。
    player.finishCurrent();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, VoiceOutputPhase.idle);
    expect(gateway.calls.map((call) => call.requestId), ['r1', 'r3']);
  });

  test('气泡重听先取得浏览器播放许可，异步合成后仍能开始播放', () async {
    final gateway = _PendingSpeakGateway();
    final player = _GestureLockedPlayerPlatform();
    final controller = VoiceOutputController(gateway, playerPlatform: player);

    player.gestureActive = true;
    controller.playNow(
      const VoiceOutputRequest(requestId: 'manual', deliveryIndex: 0),
    );
    player.gestureActive = false;
    gateway.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.phase, VoiceOutputPhase.playing);
    expect(controller.failureNotice, isNull);
    player.finish();
  });
}

final class _PendingSpeakGateway implements ChatSpeechGateway {
  final Completer<Uint8List> _audio = Completer<Uint8List>();

  void complete() => _audio.complete(Uint8List.fromList([1, 2, 3]));

  @override
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  }) => _audio.future;
}

final class _RecordingSpeakGateway implements ChatSpeechGateway {
  _RecordingSpeakGateway({this.failing = false});

  final bool failing;
  final List<({String requestId, int deliveryIndex, String? sessionId})> calls =
      [];

  @override
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  }) async {
    calls.add((
      requestId: requestId,
      deliveryIndex: deliveryIndex,
      sessionId: sessionId,
    ));
    if (failing) {
      throw LocalChatGatewayException('语音服务连不上。');
    }
    return Uint8List.fromList([1, 2, 3]);
  }
}

final class _FakeVoicePlayerPlatform implements VoicePlayerPlatform {
  _FakeVoicePlayerPlatform();

  final List<_FakeVoicePlayback> _active = [];
  int stoppedCount = 0;

  @override
  bool get supported => true;

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
  }) async {
    final playback = _FakeVoicePlayback(this);
    _active.add(playback);
    return playback;
  }

  void finishCurrent() {
    // 模拟自然播完；没有在播的（已被 stopAll 清掉）忽略。
    if (_active.isNotEmpty) {
      _active.removeLast().finish();
    }
  }
}

final class _FakeVoicePlayback implements VoicePlayback {
  _FakeVoicePlayback(this._platform);

  final _FakeVoicePlayerPlatform _platform;
  final Completer<void> _done = Completer<void>();

  void finish() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;

  @override
  void stop() {
    _platform.stoppedCount += 1;
    _platform._active.remove(this);
    finish();
  }
}

final class _RefusingVoicePlayerPlatform implements VoicePlayerPlatform {
  const _RefusingVoicePlayerPlatform();

  @override
  bool get supported => true;

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
  }) async => null;
}

final class _GestureLockedPlayerPlatform
    implements VoicePlayerPlatform, UserGestureVoicePlayerPlatform {
  bool gestureActive = false;
  bool _prepared = false;
  _FakeVoicePlayback? _playback;

  @override
  bool get supported => true;

  @override
  void prepareForPlayback() {
    if (gestureActive) {
      _prepared = true;
    }
  }

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
  }) async {
    if (!_prepared) {
      return null;
    }
    return _playback = _FakeVoicePlayback(_FakeVoicePlayerPlatform());
  }

  void finish() => _playback?.finish();
}
