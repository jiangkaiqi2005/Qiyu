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
    expect(controller.failureNotice, '无法播放语音，点小喇叭再听一次。');
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

  test('整段失败后手动重听成功，清掉过期失败提示', () async {
    final player = _FlakyWholePlayerPlatform();
    final controller = VoiceOutputController(
      _RecordingSpeakGateway(),
      playerPlatform: player,
    );

    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, '无法播放语音，点小喇叭再听一次。');

    controller.playNow(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(player.plays, 2);
    expect(controller.failureNotice, isNull);
    expect(controller.phase, VoiceOutputPhase.playing);
    player.finishCurrent();
    controller.dispose();
  });

  test('队列前一项失败后下一项成功，不误清前一项失败提示', () async {
    final player = _FlakyWholePlayerPlatform();
    final controller = VoiceOutputController(
      _RecordingSpeakGateway(),
      playerPlatform: player,
    );

    controller.offer(
      const VoiceOutputRequest(requestId: 'a', deliveryIndex: 0),
      enabled: true,
    );
    controller.offer(
      const VoiceOutputRequest(requestId: 'b', deliveryIndex: 0),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(player.plays, 2);
    expect(controller.failureNotice, '无法播放语音，点小喇叭再听一次。');
    expect(controller.phase, VoiceOutputPhase.playing);

    // B 成功只清 B 的账；A 的提示要留给用户，直到重听 A 成功。
    player.finishCurrent();
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, '无法播放语音，点小喇叭再听一次。');
    controller.dispose();
  });

  test('交付段 1 的 D1 提示不会被交付段 0 的成功播放清掉', () async {
    final player = _FakeVoicePlayerPlatform();
    final controller = VoiceOutputController(
      _RecordingSpeakGateway(),
      playerPlatform: player,
    );

    // 交付段 0 已在整段回退播放中；交付段 1 的 D1 随后到达。
    controller.offer(
      const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    controller.notifyStreamFailure(requestId: 'r1', deliveryIndex: 1);
    expect(controller.failureNotice, '有句话没合成出来，后面的先不读了。');

    // 交付段 0 播完并继续队列：它不能把交付段 1 的 D1 提示当过期清掉。
    player.finishCurrent();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, '有句话没合成出来，后面的先不读了。');
    controller.dispose();
  });

  // 语音流式（票二）：块搭车聊天事件流，首块开流、后续块追加、end 后
  // 播完缓冲即 idle；失败按 D1（已播留着、提示一次）；停播通知 Host。
  group('语音流式播放', () {
    VoiceStreamChunk chunkOf(
      String requestId,
      List<int> bytes, {
      int deliveryIndex = 0,
      int chunkIndex = 0,
      int sampleRate = 24000,
      String? mimeType,
    }) => VoiceStreamChunk(
      requestId: requestId,
      deliveryIndex: deliveryIndex,
      chunkIndex: chunkIndex,
      sampleRate: sampleRate,
      mimeType: mimeType,
      data: Uint8List.fromList(bytes),
    );

    test('首块开流、后续块按序追加，end 后播完即 idle', () async {
      final player = _FakeVoicePlayerPlatform();
      final controller = VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: player,
      );

      controller.offerStreamChunk(chunkOf('r1', [1, 2]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, VoiceOutputPhase.playing);
      expect(controller.nowReading?.requestId, 'r1');
      // 播放端按协商采样率初始化，不猜。
      expect(player.lastStreamSampleRate, 24000);
      final stream = player.streams.single;
      expect(stream.appended, [1, 2]);

      controller.offerStreamChunk(chunkOf('r1', [3]), enabled: true);
      expect(stream.appended, [1, 2, 3]);

      controller.endStream(requestId: 'r1');
      expect(stream.ended, isTrue);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, VoiceOutputPhase.idle);
      expect(controller.nowReading, isNull);
    });

    test('流式期间入队的整段项在流播完后按序继播', () async {
      final player = _FakeVoicePlayerPlatform();
      final gateway = _RecordingSpeakGateway();
      final controller = VoiceOutputController(
        gateway,
        playerPlatform: player,
      );

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      // 流式播放期间来一条整段请求（轮内召回 bubble 2）：排队等着。
      controller.offer(
        const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 1),
        enabled: true,
      );
      expect(gateway.calls, isEmpty);

      controller.endStream(requestId: 'r1');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // 流收尾时把队列排空：不必等下一次 offer 才播。
      expect(gateway.calls, hasLength(1));
      expect(controller.nowReading?.deliveryIndex, 1);
    });

    test('一句合成失败：已播句子留着、提示一次、之后静默', () async {
      final player = _FakeVoicePlayerPlatform();
      final controller = VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: player,
      );

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      final stream = player.streams.single;

      controller.notifyStreamFailure(requestId: 'r1', deliveryIndex: 0);
      expect(controller.failureNotice, '有句话没合成出来，后面的先不读了。');
      // 已到的块照常播完（已播句子 standing），后续块丢弃。
      expect(stream.ended, isTrue);
      controller.offerStreamChunk(chunkOf('r1', [2]), enabled: true);
      expect(stream.appended, [1]);
      controller.consumeFailureNotice();

      // 同会话第二次失败不再提示。
      controller.offerStreamChunk(chunkOf('r2', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      controller.notifyStreamFailure(requestId: 'r2', deliveryIndex: 0);
      expect(controller.failureNotice, isNull);
    });

    test('停播立即停止并通知 Host 作废在途合成；停后迟到块丢弃', () async {
      final player = _FakeVoicePlayerPlatform();
      final controller = VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: player,
      );
      final stopped = <String>[];
      controller.onVoiceStopRequested = stopped.add;

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      final stream = player.streams.single;

      controller.stopAll();
      expect(controller.phase, VoiceOutputPhase.idle);
      expect(stream.stopped, isTrue);
      expect(stopped, ['r1']);

      // 停止信号到达 Host 之前产出的块还在途：同一 requestId 的迟到
      // 块直接丢弃，不重开一路（用户按了停播，声音就不该再起来）。
      controller.offerStreamChunk(chunkOf('r1', [2]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      expect(player.streams, hasLength(1));
      // 新的 requestId 不受影响。
      controller.offerStreamChunk(chunkOf('r2', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      expect(player.streams, hasLength(2));
    });

    test('取消只停流式播放，不清整段队列、不通知 Host 停止', () async {
      final player = _FakeVoicePlayerPlatform();
      final gateway = _RecordingSpeakGateway();
      final controller = VoiceOutputController(
        gateway,
        playerPlatform: player,
      );
      final stopped = <String>[];
      controller.onVoiceStopRequested = stopped.add;

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      final stream = player.streams.single;
      // 取消前入队的一条整段项：轮交付取消不清它。
      controller.offer(
        const VoiceOutputRequest(requestId: 'r1', deliveryIndex: 0),
        enabled: true,
      );

      controller.stopStream(requestId: 'r1');
      expect(stream.stopped, isTrue);
      expect(stopped, isEmpty);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // 流式音频停了，整段队列照常排空（取消针对的是这一路搭车音频）。
      expect(gateway.calls, hasLength(1));
      expect(controller.phase, VoiceOutputPhase.playing);
      expect(controller.nowReading?.requestId, 'r1');
    });

    test('停播记账只挡旧轮残块：同 requestId 重发后直播块照常受理', () async {
      final player = _FakeVoicePlayerPlatform();
      final controller = VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: player,
      );

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      expect(player.streams, hasLength(1));

      // 取消后旧轮残块到达即被记账丢弃（按了停播声音就不该再起来）。
      controller.stopStream(requestId: 'r1');
      expect(controller.offerStreamChunk(chunkOf('r1', [2]), enabled: true), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(player.streams, hasLength(1));

      // 幂等重发复用同一 requestId 开新轮：记账翻篇，新轮直播块受理，
      // 重新开一路流（首音提前特性不失效）。
      controller.forgetStreamStop('r1');
      expect(controller.offerStreamChunk(chunkOf('r1', [3]), enabled: true), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(player.streams, hasLength(2));
      expect(player.streams.last.appended, [3]);
    });

    test('朗读关着与麦克风占用即丢弃，不出声', () async {
      final player = _FakeVoicePlayerPlatform();
      final controller = VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: player,
      );

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: false);
      await Future<void>.delayed(Duration.zero);
      expect(player.streams, isEmpty);

      controller.isMicrophoneInUse = () => true;
      controller.offerStreamChunk(chunkOf('r2', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      expect(player.streams, isEmpty);
      expect(controller.phase, VoiceOutputPhase.idle);
    });

    test('平台没有流式播放能力：done 后回退失败才提示，不冒充服务断线', () async {
      final player = _NonStreamingPlayerPlatform();
      final controller = VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: player,
      );

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.failureNotice, isNull);
      expect(controller.phase, VoiceOutputPhase.idle);

      // 只有终局才允许走整段路径；该平台的整段播放也失败才显示提示。
      controller.endStream(requestId: 'r1');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.failureNotice, '无法播放语音，点小喇叭再听一次。');
      expect(controller.phase, VoiceOutputPhase.idle);
    });

    test('开流失败后 voiceError 仍按 D1 收声，不整段回退', () async {
      final player = _NonStreamingPlayerPlatform();
      final gateway = _RecordingSpeakGateway();
      final controller = VoiceOutputController(gateway, playerPlatform: player);

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      controller.notifyStreamFailure(requestId: 'r1', deliveryIndex: 0);
      expect(controller.failureNotice, '有句话没合成出来，后面的先不读了。');

      controller.endStream(requestId: 'r1');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(gateway.calls, isEmpty);
      expect(controller.phase, VoiceOutputPhase.idle);

      // 旧轮占位已释放，下一轮仍可重新开流（即使当前平台随后仍失败）。
      expect(
        controller.offerStreamChunk(chunkOf('r2', [2]), enabled: true),
        isTrue,
      );
      controller.dispose();
    });

    test('D1 不清已排队到的整段块：失败段不回退，排队音频照常播', () async {
      final player = _StreamStartFailsWholeWorksPlayerPlatform();
      final gateway = _RecordingSpeakGateway();
      final controller = VoiceOutputController(gateway, playerPlatform: player);

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(player.streamStarts, 1);

      // 失败段等待 done 期间，下一句的完整容器块已排队。
      expect(
        controller.offerStreamChunk(
          chunkOf('r1', [9], deliveryIndex: 1, mimeType: 'audio/wav'),
          enabled: true,
        ),
        isTrue,
      );

      controller.notifyStreamFailure(requestId: 'r1', deliveryIndex: 0);
      controller.endStream(requestId: 'r1');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // D1 不给失败段 /speak 回退；已排队到的音频按 standing 语义播放。
      expect(gateway.calls, isEmpty);
      expect(player.wholeBlobs.single.bytes, [9]);
      expect(player.wholeBlobs.single.mimeType, 'audio/wav');
      expect(controller.phase, VoiceOutputPhase.playing);

      player.finishCurrent();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, VoiceOutputPhase.idle);
      controller.dispose();
    });

    test('整段在读时不抢占：直播语音丢弃，整段照常播完', () async {
      final player = _FakeVoicePlayerPlatform();
      final controller = VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: player,
      );

      controller.offer(
        const VoiceOutputRequest(requestId: 'old', deliveryIndex: 0),
        enabled: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, VoiceOutputPhase.playing);

      controller.offerStreamChunk(chunkOf('new', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      expect(player.streams, isEmpty);
      expect(controller.nowReading?.requestId, 'old');

      player.finishCurrent();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, VoiceOutputPhase.idle);
    });

    test('离页无条件停播：流式播放立即停声并通知 Host（ADR 0002 语义延续）', () async {
      final player = _FakeVoicePlayerPlatform();
      final controller = VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: player,
      );
      final stopped = <String>[];
      controller.onVoiceStopRequested = stopped.add;

      controller.offerStreamChunk(chunkOf('r1', [1]), enabled: true);
      await Future<void>.delayed(Duration.zero);
      final stream = player.streams.single;

      controller.stopAllForLeavingPage();
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, VoiceOutputPhase.idle);
      expect(stream.stopped, isTrue);
      expect(stopped, ['r1']);
    });

    // E1（票二）：拿不到音频块的档位按句子级顺序播——每句一个完整
    // 容器块，走既有整段播放器按序播，不抢占、不清队语义不变。
    group('E1 句子级整段块', () {
      test('整段块按序入队播放，播完才播下一句', () async {
        final player = _FakeVoicePlayerPlatform();
        final gateway = _RecordingSpeakGateway();
        final controller = VoiceOutputController(
          gateway,
          playerPlatform: player,
        );

        expect(
          controller.offerStreamChunk(
            chunkOf('r1', [1], chunkIndex: 0, mimeType: 'audio/wav'),
            enabled: true,
          ),
          isTrue,
        );
        expect(
          controller.offerStreamChunk(
            chunkOf('r1', [2], chunkIndex: 1, mimeType: 'audio/wav'),
            enabled: true,
          ),
          isTrue,
        );
        await Future<void>.delayed(Duration.zero);
        // 第一句在播：走既有整段播放器（字节原样，不猜容器）。
        expect(controller.phase, VoiceOutputPhase.playing);
        expect(controller.nowReading?.requestId, 'r1');
        expect(player.wholeBlobs.single.bytes, [1]);
        expect(player.wholeBlobs.single.mimeType, 'audio/wav');
        // 整段合成路径一次都没走（句子音频已在手）。
        expect(gateway.calls, isEmpty);

        player.finishCurrent();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(controller.phase, VoiceOutputPhase.playing);
        expect(player.wholeBlobs.last.bytes, [2]);

        player.finishCurrent();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(controller.phase, VoiceOutputPhase.idle);
      });

      test('整段块在整段读着时排队，不抢占', () async {
        final player = _FakeVoicePlayerPlatform();
        final controller = VoiceOutputController(
          _RecordingSpeakGateway(),
          playerPlatform: player,
        );

        controller.offer(
          const VoiceOutputRequest(requestId: 'old', deliveryIndex: 0),
          enabled: true,
        );
        await Future<void>.delayed(Duration.zero);

        controller.offerStreamChunk(
          chunkOf('new', [1], mimeType: 'audio/wav'),
          enabled: true,
        );
        await Future<void>.delayed(Duration.zero);
        // 旧段在播：新块只是入队，没有抢播（整段只播过旧段那一条）。
        expect(player.wholeBlobs, hasLength(1));
        expect(controller.nowReading?.requestId, 'old');
        expect(player.streams, isEmpty);
      });
    });
  });

  test('音量调节：初始读取、调节并通知监听者、持久化保存与实时生效', () async {
    final player = _FakeVoicePlayerPlatform(savedVolume: 0.8);
    final gateway = _RecordingSpeakGateway();
    final controller = VoiceOutputController(gateway, playerPlatform: player);

    expect(controller.volume, 0.8);

    var notifyCount = 0;
    controller.addListener(() => notifyCount += 1);

    controller.setVolume(0.5);
    expect(controller.volume, 0.5);
    expect(player.persistedVolume, 0.5);
    expect(notifyCount, 1);

    // 播放时传入当前音量
    controller.offer(
      const VoiceOutputRequest(requestId: 'req-1', deliveryIndex: 0),
      enabled: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.lastPlayedVolume, 0.5);

    // 播放中调节音量，实时同步给活动 playback
    controller.setVolume(0.3);
    expect(player._active.single.currentVolume, 0.3);

    player.finishCurrent();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
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

/// 播放平台假件：整段与流式两条路共用同一个完成分发口（原生侧同一语义）。
final class _FakeVoicePlayerPlatform
    implements VoicePlayerPlatform, StreamingVoicePlayerPlatform {
  _FakeVoicePlayerPlatform({double? savedVolume})
    : persistedVolume = savedVolume ?? 1.0;

  final List<_FakeVoicePlayback> _active = [];
  final List<_FakeVoiceStreamPlayback> streams = [];
  final List<({List<int> bytes, String mimeType})> wholeBlobs = [];
  int stoppedCount = 0;
  double persistedVolume;
  double? lastPlayedVolume;
  int? lastStreamSampleRate;

  @override
  bool get supported => true;

  @override
  double getInitialVolume() => persistedVolume;

  @override
  void saveVolume(double volume) {
    persistedVolume = volume;
  }

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async {
    lastPlayedVolume = volume;
    wholeBlobs.add((bytes: bytes.toList(), mimeType: mimeType));
    final playback = _FakeVoicePlayback(this, initialVolume: volume);
    _active.add(playback);
    return playback;
  }

  @override
  Future<VoiceStreamPlayback?> startStream({
    required int sampleRate,
    double volume = 1.0,
  }) async {
    lastStreamSampleRate = sampleRate;
    final playback = _FakeVoiceStreamPlayback(this, initialVolume: volume);
    streams.add(playback);
    return playback;
  }

  void finishCurrent() {
    // 模拟自然播完；没有在播的（已被 stopAll 清掉）忽略。
    if (_active.isNotEmpty) {
      _active.removeLast().finish();
    }
  }

  /// 模拟流式播放把缓冲播完（排空后 done）。
  void drainCurrentStream() {
    if (streams.isNotEmpty) {
      streams.removeLast().drain();
    }
  }
}

final class _FakeVoicePlayback implements VoicePlayback {
  _FakeVoicePlayback(this._platform, {double initialVolume = 1.0})
    : currentVolume = initialVolume;

  final _FakeVoicePlayerPlatform _platform;
  final Completer<void> _done = Completer<void>();
  double currentVolume;

  void finish() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;

  @override
  void setVolume(double volume) {
    currentVolume = volume;
  }

  @override
  void stop() {
    _platform.stoppedCount += 1;
    _platform._active.remove(this);
    finish();
  }
}

/// 流式播放假件：块按到达序记录，end 之后 drain 才播完（done）。
final class _FakeVoiceStreamPlayback implements VoiceStreamPlayback {
  _FakeVoiceStreamPlayback(this._platform, {double initialVolume = 1.0})
    : currentVolume = initialVolume;

  final _FakeVoicePlayerPlatform _platform;
  final Completer<void> _done = Completer<void>();
  final List<int> appended = [];
  double currentVolume;
  bool ended = false;
  bool stopped = false;

  void drain() {
    if (ended && !_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  void append(Uint8List pcm) {
    if (stopped || ended) {
      return;
    }
    appended.addAll(pcm);
  }

  @override
  void end() {
    ended = true;
    drain();
  }

  @override
  Future<void> get done => _done.future;

  @override
  void setVolume(double volume) {
    currentVolume = volume;
  }

  @override
  void stop() {
    stopped = true;
    _platform.stoppedCount += 1;
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

/// 没有流式播放能力的平台（旧浏览器/桌面宿主）：整段可播，流式如实
/// 返回 null。
final class _NonStreamingPlayerPlatform implements VoicePlayerPlatform {
  const _NonStreamingPlayerPlatform();

  @override
  bool get supported => true;

  @override
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async => null;
}

final class _RefusingVoicePlayerPlatform implements VoicePlayerPlatform {
  const _RefusingVoicePlayerPlatform();

  @override
  bool get supported => true;

  @override
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
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
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

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
    double volume = 1.0,
  }) async {
    if (!_prepared) {
      return null;
    }
    return _playback = _FakeVoicePlayback(_FakeVoicePlayerPlatform());
  }

  void finish() => _playback?.finish();
}

final class _FlakyWholePlayerPlatform implements VoicePlayerPlatform {
  int plays = 0;
  _ManualPlayback? _current;

  @override
  bool get supported => true;

  @override
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async {
    plays += 1;
    if (plays == 1) {
      return null;
    }
    return _current = _ManualPlayback();
  }

  void finishCurrent() {
    _current?.finish();
    _current = null;
  }
}

/// 流式开不了但整段可播的平台：锁定开流失败后的终局回退与队列行为。
final class _StreamStartFailsWholeWorksPlayerPlatform
    implements VoicePlayerPlatform, StreamingVoicePlayerPlatform {
  int streamStarts = 0;
  final List<({List<int> bytes, String mimeType})> wholeBlobs = [];
  _ManualPlayback? _current;

  @override
  bool get supported => true;

  @override
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async {
    wholeBlobs.add((bytes: bytes.toList(), mimeType: mimeType));
    return _current = _ManualPlayback();
  }

  @override
  Future<VoiceStreamPlayback?> startStream({
    required int sampleRate,
    double volume = 1.0,
  }) async {
    streamStarts += 1;
    return null;
  }

  void finishCurrent() {
    _current?.finish();
    _current = null;
  }
}

final class _ManualPlayback implements VoicePlayback {
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  void setVolume(double volume) {}

  @override
  void stop() => finish();

  void finish() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}
