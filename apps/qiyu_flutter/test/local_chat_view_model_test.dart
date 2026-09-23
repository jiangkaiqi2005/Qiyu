import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/baseline/background_status_client.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'support/shared_fakes.dart';

void main() {
  test('空白、发送占用及 Host 不可用的拒绝没有创建新请求', () async {
    final gateway = _ScriptedGateway();
    var counter = 0;
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [false]),
      requestIdFactory: () => 'request-${counter += 1}',
      autoStart: false,
    );
    addTearDown(viewModel.dispose);

    final blank = await viewModel.send('  \n  ');
    expect(blank.status, ChatSendStatus.notAccepted);
    expect(blank.requestId, isNull);
    final sending = viewModel.send('已有发送');
    final busy = await viewModel.send('不能并发');
    expect(busy.status, ChatSendStatus.notAccepted);
    expect(busy.requestId, isNull);
    gateway.closeStream('request-1');
    await sending;
    await viewModel.checkHostNow();
    final unavailable = await viewModel.send('Host 已停止');
    expect(unavailable.status, ChatSendStatus.notAccepted);
    expect(unavailable.requestId, isNull);
    expect(counter, 1);
    expect(viewModel.messages, isEmpty);
  });

  for (final kind in [LocalChatEventKind.error, LocalChatEventKind.cancelled]) {
    test('受理前 $kind 返回未接管与本轮 requestId', () async {
      final gateway = _ScriptedGateway();
      final viewModel = LocalChatViewModel(
        gateway,
        requestIdFactory: () => 'unaccepted-request',
        autoStart: false,
      );
      addTearDown(viewModel.dispose);

      final sending = viewModel.send('尚未接管的内容');
      gateway.emit(
        'unaccepted-request',
        kind == LocalChatEventKind.error
            ? const LocalChatDeliveryEvent.error(
                requestId: 'unaccepted-request',
                code: 'chat_failed',
                text: '连接中断',
                retryable: true,
              )
            : const LocalChatDeliveryEvent.cancelled(
                requestId: 'unaccepted-request',
              ),
      );
      final result = await sending;
      expect(result.status, ChatSendStatus.notAccepted);
      expect(result.requestId, 'unaccepted-request');
      expect(viewModel.messages, isEmpty);
    });
  }

  test('第一段完成后取消第二段仍返回已完成，已交付气泡保持', () async {
    final gateway = _ScriptedGateway();
    final viewModel = LocalChatViewModel(
      gateway,
      requestIdFactory: () => 'two-bubbles',
      autoStart: false,
    );
    addTearDown(viewModel.dispose);
    final sending = viewModel.send('那次爬山');
    gateway
      ..emitAccepted('two-bubbles')
      ..emitMessage('two-bubbles', const ['一时没想起。'])
      ..emitState('two-bubbles')
      ..emitDone('two-bubbles')
      ..emitWaiting('two-bubbles')
      ..emitDelta('two-bubbles', '对了，你');
    await Future<void>.delayed(Duration.zero);
    await viewModel.stop();
    gateway.emitCancelled('two-bubbles');

    final result = await sending;
    expect(result.status, ChatSendStatus.completed);
    expect(result.requestId, 'two-bubbles');
    expect(gateway.cancelCalls, ['two-bubbles']);
    expect(viewModel.messages.map((message) => message.text), [
      '那次爬山',
      '一时没想起。',
    ]);
    expect(viewModel.streamingText, isEmpty);
    expect(viewModel.sending, isFalse);
  });

  for (final failure in ['error', 'EOF']) {
    test('第一段完成后第二段 $failure 保留首段，半句不提交', () async {
      final gateway = _ScriptedGateway();
      final viewModel = LocalChatViewModel(
        gateway,
        requestIdFactory: () => 'two-bubbles',
        autoStart: false,
      );
      addTearDown(viewModel.dispose);
      final sending = viewModel.send('那次爬山');
      gateway
        ..emitAccepted('two-bubbles')
        ..emitMessage('two-bubbles', const ['一时没想起。'])
        ..emitState('two-bubbles')
        ..emitDone('two-bubbles')
        ..emitWaiting('two-bubbles')
        ..emitDelta('two-bubbles', '对了，你');
      if (failure == 'error') {
        gateway.emit(
          'two-bubbles',
          const LocalChatDeliveryEvent.error(
            requestId: 'two-bubbles',
            code: 'chat_failed',
            text: '连接中断',
            retryable: true,
          ),
        );
      } else {
        gateway.closeStream('two-bubbles');
      }
      await sending;
      expect(viewModel.messages.map((message) => message.text), [
        '那次爬山',
        '一时没想起。',
      ]);
      expect(viewModel.streamingText, isEmpty);
      expect(viewModel.sending, isFalse);
    });
  }

  test('丢弃会话后排队的转写失效，不发送到新会话', () async {
    final gateway = _ScriptedGateway();
    var counter = 0;
    final viewModel = LocalChatViewModel(
      gateway,
      requestIdFactory: () => 'queue-${counter += 1}',
      autoStart: false,
    );
    addTearDown(viewModel.dispose);

    final first = viewModel.send('原会话消息');
    gateway.emitAccepted('queue-1');
    await Future<void>.delayed(Duration.zero);
    final queued = viewModel.sendWhenIdle('原会话转写');
    await viewModel.discardSession('session-1');
    await Future<void>.delayed(Duration.zero);
    gateway
      ..closeStream('queue-1')
      ..closeStream('queue-2');

    final stale = await queued;
    expect(stale.status, ChatSendStatus.staleSession);
    expect(stale.requestId, isNull);
    expect((await first).status, ChatSendStatus.staleSession);
    expect(viewModel.messages, isEmpty);
    expect(counter, 1);
  });

  test('已接管消息重试在受理前失败仍保留原请求归属', () async {
    final gateway = _ScriptedGateway();
    var counter = 0;
    final viewModel = LocalChatViewModel(
      gateway,
      requestIdFactory: () => 'retry-${counter += 1}',
      autoStart: false,
    );
    addTearDown(viewModel.dispose);

    final first = viewModel.send('这句话已接管');
    gateway
      ..emitAccepted('retry-1')
      ..emit(
        'retry-1',
        const LocalChatDeliveryEvent.error(
          requestId: 'retry-1',
          code: 'chat_failed',
          text: '连接中断',
          retryable: true,
        ),
      );
    final failed = await first;
    expect(failed.status, ChatSendStatus.acceptedIncomplete);
    expect(failed.requestId, 'retry-1');

    final retry = viewModel.send('这句话已接管');
    gateway.closeStream('retry-1');
    final interruptedRetry = await retry;
    expect(interruptedRetry.status, ChatSendStatus.acceptedIncomplete);
    expect(interruptedRetry.requestId, 'retry-1');
    expect(viewModel.messages.map((message) => message.requestId), ['retry-1']);

    final finalRetry = viewModel.send('这句话已接管');
    gateway
      ..emitAccepted('retry-1')
      ..emitMessage('retry-1', const ['听见了。'])
      ..emitState('retry-1')
      ..emitDone('retry-1')
      ..closeStream('retry-1');
    final completed = await finalRetry;
    expect(completed.status, ChatSendStatus.completed);
    expect(completed.requestId, 'retry-1');
    expect(viewModel.messages.map((message) => message.text), ['这句话已接管', '听见了。']);
    expect(counter, 1);
  });

  test(
    'a submitted user message is visible before the host accepts it',
    () async {
      final gateway = _GatedGateway();
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: FakeHostConnectionProbe(const [true]),
        requestIdFactory: () => 'pending-request',
        autoStart: false,
      );
      addTearDown(() {
        gateway.release();
        viewModel.dispose();
      });

      final send = viewModel.send('这条先显示');
      await Future<void>.delayed(Duration.zero);

      expect(viewModel.messages, hasLength(1));
      expect(viewModel.messages.single.speaker, LocalChatSpeaker.user);
      expect(viewModel.messages.single.text, '这条先显示');

      gateway.release();
      expect((await send).status, ChatSendStatus.completed);
    },
  );

  test(
    'a recall bubble 2 on the same stream is committed as a second message',
    () async {
      final gateway = _TwoBubbleGateway();
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: FakeHostConnectionProbe(const [true]),
        requestIdFactory: () => 'request-1',
        autoStart: false,
      );

      final sent = await viewModel.send('我上次说爬山的事');

      expect(sent.status, ChatSendStatus.completed);
      final qiyuMessages = viewModel.messages
          .where((message) => message.speaker == LocalChatSpeaker.qiyu)
          .toList();
      expect(qiyuMessages, hasLength(2));
      expect(qiyuMessages.first.text, '一时没想起。');
      expect(qiyuMessages.last.text, '对了，你周末是要去爬山来着。');
      // 两段都属于同一用户轮。
      expect(qiyuMessages.map((message) => message.requestId), [
        'request-1',
        'request-1',
      ]);
      expect(viewModel.streamingText, isEmpty);
      viewModel.dispose();
    },
  );

  test('协议失败留下的半句照常提交，消息带未完成标记', () async {
    final gateway = _ScriptedGateway();
    final viewModel = LocalChatViewModel(
      gateway,
      requestIdFactory: () => 'half-1',
      autoStart: false,
    );
    addTearDown(viewModel.dispose);

    final sending = viewModel.send('在吗');
    await Future<void>.delayed(Duration.zero);
    gateway
      ..emitAccepted('half-1')
      ..emitDelta('half-1', '在。刚')
      ..emitMessage('half-1', const ['在。刚'], incomplete: true)
      ..emitState('half-1')
      ..emitDone('half-1')
      ..closeStream('half-1');

    expect((await sending).status, ChatSendStatus.completed);
    final qiyu = viewModel.messages.last;
    expect(qiyu.speaker, LocalChatSpeaker.qiyu);
    expect(qiyu.text, '在。刚');
    expect(qiyu.incomplete, isTrue);
    // 半句不是本地兜底：没有错误提示、没有回退原因。
    expect(viewModel.errorMessage, isNull);
    expect(viewModel.latestFallbackReason, isNull);
  });

  test('a single-bubble stream still commits exactly one message', () async {
    final gateway = _TwoBubbleGateway(withBubble2: false);
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-2',
      autoStart: false,
    );

    final sent = await viewModel.send('在吗');

    expect(sent.status, ChatSendStatus.completed);
    final qiyuMessages = viewModel.messages
        .where((message) => message.speaker == LocalChatSpeaker.qiyu)
        .toList();
    expect(qiyuMessages, hasLength(1));
    expect(qiyuMessages.single.text, '在。');
    viewModel.dispose();
  });

  test('sendWhenIdle 等正在回复的一轮结束后再发出语音转写内容', () async {
    final gateway = _GatedGateway();
    var counter = 0;
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'voice-${counter += 1}',
      autoStart: false,
    );
    addTearDown(() {
      gateway.release();
      viewModel.dispose();
    });

    final first = viewModel.send('第一条');
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.sending, isTrue);

    var secondSettled = false;
    final second = viewModel
        .sendWhenIdle('语音转写的内容')
        .whenComplete(() => secondSettled = true);
    await Future<void>.delayed(Duration.zero);
    // 第一轮还在流式回复：排队中的语音消息不并发发出。
    expect(secondSettled, isFalse);
    expect(
      viewModel.messages
          .where((message) => message.speaker == LocalChatSpeaker.user)
          .map((message) => message.text),
      ['第一条'],
    );

    gateway.release();
    expect((await first).status, ChatSendStatus.completed);
    expect((await second).status, ChatSendStatus.completed);
    expect(
      viewModel.messages
          .where((message) => message.speaker == LocalChatSpeaker.user)
          .map((message) => message.text),
      ['第一条', '语音转写的内容'],
    );
  });

  test('双 bubble 交付段按序进入朗读队列；开关关着不触发', () async {
    final speakGateway = _RecordingSpeakGateway();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: _SequentialPlayerPlatform(),
    );
    final viewModel = LocalChatViewModel(
      _TwoBubbleGateway(),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-voice',
      ttsSettingsGateway: _FixedTtsSettingsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    expect((await viewModel.send('我上次说爬山的事')).status, ChatSendStatus.completed);
    // 等朗读队列消化完两段。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(speakGateway.calls, [
      (requestId: 'request-voice', deliveryIndex: 0),
      (requestId: 'request-voice', deliveryIndex: 1),
    ]);
    viewModel.dispose();
    controller.dispose();
  });

  test('发送消息先取得浏览器播放许可，异步回复可直接自动朗读', () async {
    final player = _GestureLockedSequentialPlayer();
    final speakGateway = _RecordingSpeakGateway();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      _TwoBubbleGateway(withBubble2: false),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-auto-unlock',
      ttsSettingsGateway: _FixedTtsSettingsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();

    player.gestureActive = true;
    final sending = viewModel.send('在吗');
    player.gestureActive = false;
    expect((await sending).status, ChatSendStatus.completed);
    await Future<void>.delayed(Duration.zero);

    expect(player.started, isTrue);
    expect(controller.failureNotice, isNull);
    viewModel.dispose();
    controller.dispose();
  });

  test('语音块搭车：流式播过即不再整段重合成，停播通知 Host 停止合成', () async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _StreamingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final gateway = _ScriptedGateway();
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-voice-stream',
      ttsSettingsGateway: _FixedTtsSettingsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();

    final sending = viewModel.send('在吗');
    void emit(LocalChatDeliveryEvent event) =>
        gateway.emit('request-voice-stream', event);
    emit(
      const LocalChatDeliveryEvent.accepted(
        requestId: 'request-voice-stream',
        sessionId: 'session-1',
      ),
    );
    emit(
      const LocalChatDeliveryEvent.delta(
        requestId: 'request-voice-stream',
        sessionId: 'session-1',
        text: '在。刚忙完。',
      ),
    );
    // 两个语音块搭车文字事件流到达（首句、第二句各一块）。
    for (var index = 0; index < 2; index += 1) {
      emit(
        LocalChatDeliveryEvent.voiceChunk(
          requestId: 'request-voice-stream',
          sessionId: 'session-1',
          deliveryIndex: 0,
          chunkIndex: index,
          sampleRate: 24000,
          data: base64Encode([index + 1]),
        ),
      );
    }
    // 语音块还在播：等视图模型消费完事件再停播——停播要通知 Host
    // 作废在途合成。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    controller.stopAll();
    expect(gateway.stopVoiceCalls, ['request-voice-stream']);
    expect(player.streams.single.stopped, isTrue);
    expect(controller.phase, VoiceOutputPhase.idle);

    // 之后照常终局：整段重合成不再发生（同一段话不响两遍）。
    emit(
      const LocalChatDeliveryEvent.message(
        requestId: 'request-voice-stream',
        sessionId: 'session-1',
        messages: ['在。刚忙完。'],
      ),
    );
    emit(
      const LocalChatDeliveryEvent.state(
        requestId: 'request-voice-stream',
        sessionId: 'session-1',
        source: ReplySource.llm,
        mode: 'llm',
      ),
    );
    emit(
      const LocalChatDeliveryEvent.done(
        requestId: 'request-voice-stream',
        sessionId: 'session-1',
      ),
    );
    gateway.closeStream('request-voice-stream');
    expect((await sending).status, ChatSendStatus.completed);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 块按序进了播放器；流式播过即不再整段重合成。
    expect(speakGateway.calls, isEmpty);
    expect(player.streams.single.appended, [1, 2]);
    viewModel.dispose();
    controller.dispose();
  });

  test('首句合成失败：done 不整段重读（D1 后续不出声）', () async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _StreamingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final gateway = _ScriptedGateway();
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-voice-fail',
      ttsSettingsGateway: _FixedTtsSettingsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();

    final sending = viewModel.send('在吗');
    void emit(LocalChatDeliveryEvent event) =>
        gateway.emit('request-voice-fail', event);
    emit(
      const LocalChatDeliveryEvent.accepted(
        requestId: 'request-voice-fail',
        sessionId: 'session-1',
      ),
    );
    emit(
      const LocalChatDeliveryEvent.delta(
        requestId: 'request-voice-fail',
        sessionId: 'session-1',
        text: '在。刚忙完。',
      ),
    );
    // 一个块都没到，先来失败信号（首句就失败）。
    emit(
      const LocalChatDeliveryEvent.voiceError(
        requestId: 'request-voice-fail',
        sessionId: 'session-1',
        deliveryIndex: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.failureNotice, isNotNull);
    controller.consumeFailureNotice();
    emit(
      const LocalChatDeliveryEvent.message(
        requestId: 'request-voice-fail',
        sessionId: 'session-1',
        messages: ['在。刚忙完。'],
      ),
    );
    emit(
      const LocalChatDeliveryEvent.state(
        requestId: 'request-voice-fail',
        sessionId: 'session-1',
        source: ReplySource.llm,
        mode: 'llm',
      ),
    );
    emit(
      const LocalChatDeliveryEvent.done(
        requestId: 'request-voice-fail',
        sessionId: 'session-1',
      ),
    );
    gateway.closeStream('request-voice-fail');
    expect((await sending).status, ChatSendStatus.completed);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 失败段不再整段重读：用户刚听完「后面的先不读了」。
    expect(speakGateway.calls, isEmpty);
    // 文字照常完整交付。
    expect(
      viewModel.messages
          .where((message) => message.speaker == LocalChatSpeaker.qiyu)
          .map((message) => message.text),
      ['在。刚忙完。'],
    );
    viewModel.dispose();
    controller.dispose();
  });

  test('直播块未被受理时 done 仍走整段入队（不失声）', () async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _StreamingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final gateway = _ScriptedGateway();
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-voice-busy',
      ttsSettingsGateway: _FixedTtsSettingsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();

    final sending = viewModel.send('在吗');
    void emit(LocalChatDeliveryEvent event) =>
        gateway.emit('request-voice-busy', event);
    emit(
      const LocalChatDeliveryEvent.accepted(
        requestId: 'request-voice-busy',
        sessionId: 'session-1',
      ),
    );
    emit(
      const LocalChatDeliveryEvent.delta(
        requestId: 'request-voice-busy',
        sessionId: 'session-1',
        text: '在。刚忙完。',
      ),
    );
    // 先让整段路径占住播放器（手动重听旧 bubble）。
    controller.playNow(
      const VoiceOutputRequest(requestId: 'old', deliveryIndex: 0),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, VoiceOutputPhase.playing);
    emit(
      LocalChatDeliveryEvent.voiceChunk(
        requestId: 'request-voice-busy',
        sessionId: 'session-1',
        deliveryIndex: 0,
        chunkIndex: 0,
        sampleRate: 24000,
        data: base64Encode([1]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    // 块被丢弃（不抢占），账本不记。
    expect(player.streams, isEmpty);
    emit(
      const LocalChatDeliveryEvent.message(
        requestId: 'request-voice-busy',
        sessionId: 'session-1',
        messages: ['在。刚忙完。'],
      ),
    );
    emit(
      const LocalChatDeliveryEvent.state(
        requestId: 'request-voice-busy',
        sessionId: 'session-1',
        source: ReplySource.llm,
        mode: 'llm',
      ),
    );
    emit(
      const LocalChatDeliveryEvent.done(
        requestId: 'request-voice-busy',
        sessionId: 'session-1',
      ),
    );
    gateway.closeStream('request-voice-busy');
    expect((await sending).status, ChatSendStatus.completed);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 没播过的交付段 done 时仍整段入队：旧段播完后接着读。先让旧段
    // 播完（直播块被丢弃时它还在播），队列才排到新交付段。
    player.wholePlaybacks.first.finish();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      speakGateway.calls.map((call) => call.requestId),
      ['old', 'request-voice-busy'],
    );
    viewModel.dispose();
    controller.dispose();
  });

  test('取消后同 requestId 重发：直播块照常受理，done 不整段重读', () async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _StreamingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final gateway = _ScriptedGateway();
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-retry-voice',
      ttsSettingsGateway: _FixedTtsSettingsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();

    // 第一轮：直播块受理后轮交付取消（停播记账写下这个 requestId）。
    final sending = viewModel.send('在吗');
    gateway.emitAccepted('request-retry-voice');
    gateway.emitDelta('request-retry-voice', '在。刚忙完。');
    gateway.emit(
      'request-retry-voice',
      LocalChatDeliveryEvent.voiceChunk(
        requestId: 'request-retry-voice',
        sessionId: 'session-1',
        deliveryIndex: 0,
        chunkIndex: 0,
        sampleRate: 24000,
        data: base64Encode([1]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    gateway.emitCancelled('request-retry-voice');
    gateway.closeStream('request-retry-voice');
    expect((await sending).status, ChatSendStatus.acceptedIncomplete);
    await Future<void>.delayed(Duration.zero);

    // 重发同一文本：幂等复用同一 requestId，停播记账随新轮翻篇。
    final retrying = viewModel.send('在吗');
    gateway.emitAccepted('request-retry-voice');
    gateway.emitDelta('request-retry-voice', '在。刚忙完。');
    gateway.emit(
      'request-retry-voice',
      LocalChatDeliveryEvent.voiceChunk(
        requestId: 'request-retry-voice',
        sessionId: 'session-1',
        deliveryIndex: 0,
        chunkIndex: 0,
        sampleRate: 24000,
        data: base64Encode([2]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    // 新轮的直播块被受理：另开一路流（不被旧轮残块记账挡住）。
    expect(player.streams, hasLength(2));

    gateway.emitMessage('request-retry-voice', ['在。刚忙完。']);
    gateway.emitState('request-retry-voice');
    gateway.emitDone('request-retry-voice');
    gateway.closeStream('request-retry-voice');
    expect((await retrying).status, ChatSendStatus.completed);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 播过即不整段重读：同一段话不响两遍，不多烧一次合成。
    expect(speakGateway.calls, isEmpty);
    viewModel.dispose();
    controller.dispose();
  });

  test('取消后同 requestId 重发：新轮直播块未被受理时 done 仍整段入队', () async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _StreamingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final gateway = _ScriptedGateway();
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-retry-quiet',
      ttsSettingsGateway: _FixedTtsSettingsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();

    // 第一轮：直播块受理（「播过」账本记下 requestId#0）后轮交付取消。
    final sending = viewModel.send('在吗');
    gateway.emitAccepted('request-retry-quiet');
    gateway.emitDelta('request-retry-quiet', '在。刚忙完。');
    gateway.emit(
      'request-retry-quiet',
      LocalChatDeliveryEvent.voiceChunk(
        requestId: 'request-retry-quiet',
        sessionId: 'session-1',
        deliveryIndex: 0,
        chunkIndex: 0,
        sampleRate: 24000,
        data: base64Encode([1]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(player.streams, hasLength(1));
    gateway.emitCancelled('request-retry-quiet');
    gateway.closeStream('request-retry-quiet');
    expect((await sending).status, ChatSendStatus.acceptedIncomplete);
    await Future<void>.delayed(Duration.zero);

    // 重发同一文本前先让手动重听占住播放器：新轮直播块到不了口。
    controller.playNow(
      const VoiceOutputRequest(requestId: 'old', deliveryIndex: 0),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, VoiceOutputPhase.playing);

    final retrying = viewModel.send('在吗');
    gateway.emitAccepted('request-retry-quiet');
    gateway.emitDelta('request-retry-quiet', '在。刚忙完。');
    gateway.emit(
      'request-retry-quiet',
      LocalChatDeliveryEvent.voiceChunk(
        requestId: 'request-retry-quiet',
        sessionId: 'session-1',
        deliveryIndex: 0,
        chunkIndex: 0,
        sampleRate: 24000,
        data: base64Encode([2]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    // 直播块被丢弃（不抢占），账本不记——新轮没有「播过」记录。
    expect(player.streams, hasLength(1));

    gateway.emitMessage('request-retry-quiet', ['在。刚忙完。']);
    gateway.emitState('request-retry-quiet');
    gateway.emitDone('request-retry-quiet');
    gateway.closeStream('request-retry-quiet');
    expect((await retrying).status, ChatSendStatus.completed);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 旧账本条目已随新轮翻篇：done 整段入队，旧段播完后接着读——不
    // 因命中上一轮的记录彻底不出声。
    player.wholePlaybacks.first.finish();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      speakGateway.calls.map((call) => call.requestId),
      ['old', 'request-retry-quiet'],
    );
    viewModel.dispose();
    controller.dispose();
  });

  test('autoSpeak 关或未配置时交付不朗读', () async {
    for (final ttsGateway in [
      _FixedTtsSettingsGateway(configured: true, autoSpeak: false),
      _FixedTtsSettingsGateway(configured: false),
    ]) {
      final speakGateway = _RecordingSpeakGateway();
      final controller = VoiceOutputController(
        speakGateway,
        playerPlatform: _SequentialPlayerPlatform(),
      );
      final viewModel = LocalChatViewModel(
        _TwoBubbleGateway(withBubble2: false),
        hostConnectionProbe: FakeHostConnectionProbe(const [true]),
        requestIdFactory: () => 'request-quiet',
        ttsSettingsGateway: ttsGateway,
        voiceOutput: controller,
        autoStart: false,
      );
      await viewModel.refreshVoiceOutputStatus();
      expect((await viewModel.send('在吗')).status, ChatSendStatus.completed);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(speakGateway.calls, isEmpty);
      viewModel.dispose();
      controller.dispose();
    }
  });

  test('toggleVoiceOutput：写 Host autoSpeak 并刷新可用状态', () async {
    final gateway = _MutableTtsSettingsGateway(autoSpeak: true);
    final viewModel = LocalChatViewModel(
      _TwoBubbleGateway(withBubble2: false),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-toggle',
      ttsSettingsGateway: gateway,
      voiceOutput: VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: _SequentialPlayerPlatform(),
      ),
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    expect(viewModel.voiceOutputConfigured, isTrue);
    expect(viewModel.voiceOutputEnabled, isTrue);

    await viewModel.toggleVoiceOutput();
    expect(gateway.autoSpeakWrites, [false]);
    expect(viewModel.voiceOutputEnabled, isFalse);

    await viewModel.toggleVoiceOutput();
    expect(gateway.autoSpeakWrites, [false, true]);
    expect(viewModel.voiceOutputEnabled, isTrue);
    viewModel.dispose();
  });

  test('会话切换后旧流的迟到事件不影响新一代：等待、气泡与通知都干净', () async {
    final gateway = _ScriptedGateway();
    var counter = 0;
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-${counter += 1}',
      autoStart: false,
    );
    addTearDown(viewModel.dispose);

    final first = viewModel.send('旧一轮的话');
    await Future<void>.delayed(Duration.zero);
    gateway
      ..emitAccepted('request-1')
      ..emitWaiting('request-1')
      ..emitDelta('request-1', '旧流的半句');
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.streamingText, '旧流的半句');

    // 切换会话：恢复进入新一代；旧流尚未结束，发送锁随旧事务失效。
    await viewModel.discardSession('session-1');
    expect(viewModel.streamingText, isEmpty);
    expect(viewModel.waiting, isFalse);
    expect(viewModel.sending, isFalse);

    // 新流已经开始并出了增量之后，旧流仍在发 delta / done。
    final second = viewModel.send('新一轮的话');
    await Future<void>.delayed(Duration.zero);
    gateway
      ..emitAccepted('request-2')
      ..emitDelta('request-2', '新一轮的回复');
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.streamingText, '新一轮的回复');

    var lateNotifications = 0;
    void countLateNotifications() => lateNotifications += 1;
    viewModel.addListener(countLateNotifications);
    gateway
      ..emitDelta('request-1', '迟到的内容')
      ..emitMessage('request-1', const ['迟到的气泡'])
      ..emitState('request-1')
      ..emitDone('request-1');
    await Future<void>.delayed(Duration.zero);
    viewModel.removeListener(countLateNotifications);

    // 迟到事件整体丢弃：不写入、不通知，新一代的流式文本不被惊动。
    expect(lateNotifications, 0);
    expect(viewModel.streamingText, '新一轮的回复');
    expect(viewModel.waiting, isFalse);

    gateway
      ..emitMessage('request-2', const ['新一轮的回复'])
      ..emitState('request-2')
      ..emitDone('request-2')
      ..closeStream('request-2');
    expect((await second).status, ChatSendStatus.completed);
    expect((await first).status, ChatSendStatus.staleSession);

    final qiyuMessages = viewModel.messages
        .where((message) => message.speaker == LocalChatSpeaker.qiyu)
        .toList();
    expect(qiyuMessages, hasLength(1));
    expect(qiyuMessages.single.text, '新一轮的回复');
    // 旧流迟到的 done 没有占用交付计数。
    expect(qiyuMessages.single.deliveryIndex, 0);
    expect(viewModel.streamingText, isEmpty);
    expect(viewModel.waiting, isFalse);
  });

  test('停止生成后迟到的交付整体丢弃：界面无残影，重发计数不漂', () async {
    final gateway = _ScriptedGateway();
    var counter = 0;
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-${counter += 1}',
      autoStart: false,
    );
    addTearDown(viewModel.dispose);

    final first = viewModel.send('先说一半');
    await Future<void>.delayed(Duration.zero);
    gateway
      ..emitAccepted('request-1')
      ..emitWaiting('request-1')
      ..emitDelta('request-1', '半句');
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.streamingText, '半句');

    await viewModel.stop();
    expect(gateway.cancelCalls, ['request-1']);
    gateway.emitCancelled('request-1');
    expect((await first).status, ChatSendStatus.acceptedIncomplete);
    expect(viewModel.streamingText, isEmpty);
    expect(viewModel.waiting, isFalse);
    expect(viewModel.sending, isFalse);
    // 取消保留可重试的用户 turn。
    expect(viewModel.messages.map((message) => message.text), ['先说一半']);

    // Host 取消没跑赢缓冲：迟到的交付段继续到达。
    gateway
      ..emitDelta('request-1', '迟到的内容')
      ..emitMessage('request-1', const ['迟到的气泡'])
      ..emitState('request-1')
      ..emitDone('request-1');
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.streamingText, isEmpty);
    expect(
      viewModel.messages.where(
        (message) => message.speaker == LocalChatSpeaker.qiyu,
      ),
      isEmpty,
    );

    // 重发同一句复用原 requestId，交付计数不被迟到事件挤占。
    final retry = viewModel.send('先说一半');
    await Future<void>.delayed(Duration.zero);
    gateway
      ..emitAccepted('request-1')
      ..emitDelta('request-1', '重新说完的回复')
      ..emitMessage('request-1', const ['重新说完的回复'])
      ..emitState('request-1')
      ..emitDone('request-1')
      ..closeStream('request-1');
    expect((await retry).status, ChatSendStatus.completed);
    final qiyuMessages = viewModel.messages
        .where((message) => message.speaker == LocalChatSpeaker.qiyu)
        .toList();
    expect(qiyuMessages, hasLength(1));
    expect(qiyuMessages.single.text, '重新说完的回复');
    expect(qiyuMessages.single.requestId, 'request-1');
    expect(qiyuMessages.single.deliveryIndex, 0);
  });

  test('提前 EOF 撞上取消：半句清空无残影，重发照常', () async {
    final gateway = _ScriptedGateway();
    var counter = 0;
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-${counter += 1}',
      autoStart: false,
    );
    addTearDown(viewModel.dispose);

    final first = viewModel.send('半句的话');
    await Future<void>.delayed(Duration.zero);
    gateway
      ..emitAccepted('request-1')
      ..emitWaiting('request-1')
      ..emitDelta('request-1', '半句');
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.streamingText, '半句');

    // 取消刚发出，传输就断了：没有 cancelled、也没有 done。
    await viewModel.stop();
    expect(gateway.cancelCalls, ['request-1']);
    gateway.closeStream('request-1');
    expect((await first).status, ChatSendStatus.acceptedIncomplete);
    expect(viewModel.streamingText, isEmpty);
    expect(viewModel.waiting, isFalse);
    expect(viewModel.messages.map((message) => message.text), ['半句的话']);

    // 重发同一句照常走完。
    final retry = viewModel.send('半句的话');
    await Future<void>.delayed(Duration.zero);
    gateway
      ..emitAccepted('request-1')
      ..emitDelta('request-1', '补完的回复')
      ..emitMessage('request-1', const ['补完的回复'])
      ..emitState('request-1')
      ..emitDone('request-1')
      ..closeStream('request-1');
    expect((await retry).status, ChatSendStatus.completed);
    final qiyuMessages = viewModel.messages
        .where((message) => message.speaker == LocalChatSpeaker.qiyu)
        .toList();
    expect(qiyuMessages, hasLength(1));
    expect(qiyuMessages.single.text, '补完的回复');
    expect(viewModel.streamingText, isEmpty);
    expect(viewModel.waiting, isFalse);
  });

  test(
    'hasLocalFallback is suppressed while sending and only shows when the latest turn is local fallback',
    () async {
      final gateway = _ScriptedGateway();
      var counter = 0;
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: FakeHostConnectionProbe(const [true]),
        requestIdFactory: () => 'req-${counter += 1}',
        autoStart: false,
      );
      addTearDown(viewModel.dispose);

      // 第一轮走本地降级
      final first = viewModel.send('第一句');
      await Future<void>.delayed(Duration.zero);
      gateway
        ..emitAccepted('req-1')
        ..emitMessage('req-1', const ['本地回复'])
        ..emitState('req-1', source: ReplySource.local)
        ..emitDone('req-1')
        ..closeStream('req-1');
      expect((await first).status, ChatSendStatus.completed);
      expect(viewModel.hasLocalFallback, isTrue);

      // 第二轮开始发送与等待期间，不展示过期的 fallback 标签
      final second = viewModel.send('第二句');
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.sending, isTrue);
      expect(viewModel.hasLocalFallback, isFalse);

      gateway
        ..emitAccepted('req-2')
        ..emitWaiting('req-2');
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.hasLocalFallback, isFalse);

      gateway.emitDelta('req-2', '流式中');
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.hasLocalFallback, isFalse);

      gateway
        ..emitMessage('req-2', const ['流式中完成了'])
        ..emitState('req-2')
        ..emitDone('req-2')
        ..closeStream('req-2');
      expect((await second).status, ChatSendStatus.completed);
      expect(viewModel.hasLocalFallback, isFalse);
    },
  );

  testWidgets('自动启动后按默认 2 秒周期轮询连接探测，只有这一条周期计时', (
    tester,
  ) async {
    final probe = _CountingProbe();
    final viewModel = LocalChatViewModel(
      _TwoBubbleGateway(),
      hostConnectionProbe: probe,
      backgroundStatusGateway: _EmptyBackgroundGateway(),
    );

    await tester.pump();
    await tester.pump();
    final afterInit = probe.calls;
    expect(afterInit, 1, reason: '初始化先探测一次连接');

    await tester.pump(const Duration(milliseconds: 1900));
    expect(probe.calls, afterInit, reason: '默认周期未到不再探测');

    await tester.pump(const Duration(milliseconds: 100));
    expect(probe.calls, afterInit + 1, reason: '默认 2 秒到点再探测');

    viewModel.dispose();
  });

  testWidgets('释放后周期探测停止：计时器随 dispose 取消', (tester) async {
    final probe = _CountingProbe();
    final viewModel = LocalChatViewModel(
      _TwoBubbleGateway(),
      hostConnectionProbe: probe,
    );
    await tester.pump();
    await tester.pump();
    final afterInit = probe.calls;

    viewModel.dispose();
    await tester.pump(const Duration(seconds: 5));

    expect(probe.calls, afterInit, reason: 'dispose 后不再周期探测');
  });

  test('聊天恢复发生在初始化连接探测完成之后', () async {
    final probe = _GatedProbe();
    final gateway = _RestoreCountingGateway();
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: probe,
      autoStart: false,
    );
    addTearDown(viewModel.dispose);

    final initializing = viewModel.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(probe.calls, 1);
    expect(
      gateway.restoreCalls,
      0,
      reason: '探测未完成不得开始恢复会话',
    );

    probe.gate.complete(true);
    await initializing;
    expect(gateway.restoreCalls, 1);
  });
}

/// 计数连接探针：立即返回可用。
final class _CountingProbe implements HostConnectionProbe {
  int calls = 0;

  @override
  Future<bool> isHostAvailable() async {
    calls += 1;
    return true;
  }
}

/// 可挂起的计数连接探针：用于锁定初始化顺序。
final class _GatedProbe implements HostConnectionProbe {
  final gate = Completer<bool>();
  int calls = 0;

  @override
  Future<bool> isHostAvailable() async {
    calls += 1;
    return gate.future;
  }
}

/// 立即返回无失败的后台状态网关。
final class _EmptyBackgroundGateway implements BackgroundStatusGateway {
  @override
  Future<BackgroundFailureStatus?> read() async => null;
}

/// 记录会话恢复调用的聊天网关。
final class _RestoreCountingGateway implements StreamingLocalChatGateway {
  int restoreCalls = 0;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async {
    restoreCalls += 1;
    return const LocalChatSnapshot(sessionId: 'session-1', messages: []);
  }

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<bool> stopVoice(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {}
}

final class _TwoBubbleGateway implements StreamingLocalChatGateway {
  _TwoBubbleGateway({this.withBubble2 = true});

  final bool withBubble2;

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<bool> stopVoice(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    yield LocalChatDeliveryEvent.accepted(
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent.waiting(
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent.delta(
      requestId: requestId,
      sessionId: 'session-1',
      text: withBubble2 ? '一时没想起。' : '在。',
    );
    yield LocalChatDeliveryEvent.message(
      requestId: requestId,
      sessionId: 'session-1',
      messages: [withBubble2 ? '一时没想起。' : '在。'],
    );
    yield LocalChatDeliveryEvent.state(
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    );
    yield LocalChatDeliveryEvent.done(
      requestId: requestId,
      sessionId: 'session-1',
    );
    if (!withBubble2) {
      return;
    }
    // 轮内召回命中：同一 requestId 的第二段交付。
    yield LocalChatDeliveryEvent.delta(
      requestId: requestId,
      sessionId: 'session-1',
      text: '对了，你周末是要去爬山来着。',
    );
    yield LocalChatDeliveryEvent.message(
      requestId: requestId,
      sessionId: 'session-1',
      messages: ['对了，你周末是要去爬山来着。'],
    );
    yield LocalChatDeliveryEvent.state(
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    );
    yield LocalChatDeliveryEvent.done(
      requestId: requestId,
      sessionId: 'session-1',
    );
  }

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);
}

final class _GatedGateway implements StreamingLocalChatGateway {
  final _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<bool> stopVoice(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    await _gate.future;
    yield LocalChatDeliveryEvent.accepted(
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent.message(
      requestId: requestId,
      sessionId: 'session-1',
      messages: const ['看见了。'],
    );
    yield LocalChatDeliveryEvent.state(
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    );
    yield LocalChatDeliveryEvent.done(
      requestId: requestId,
      sessionId: 'session-1',
    );
  }

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);
}

final class _FixedTtsSettingsGateway implements TtsSettingsGateway {
  _FixedTtsSettingsGateway({required this.configured, this.autoSpeak = true});

  final bool configured;
  final bool autoSpeak;

  @override
  Future<TtsSettings> read() async => TtsSettings(
    configured: configured,
    keySet: configured,
    autoSpeak: autoSpeak,
  );

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> forgetApiKey() async => throw UnimplementedError();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      throw UnimplementedError();
}

final class _RecordingSpeakGateway implements ChatSpeechGateway {
  final List<({String requestId, int deliveryIndex})> calls = [];

  @override
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  }) async {
    calls.add((requestId: requestId, deliveryIndex: deliveryIndex));
    return Uint8List.fromList([1]);
  }
}

/// 可编程事件流网关：每次 [deliver] 都为该 requestId 新开一条流，测试侧
/// 可以按任意时序推事件、关流，用来模拟迟到事件、取消与提前 EOF 的竞态。
final class _ScriptedGateway implements StreamingLocalChatGateway {
  final cancelCalls = <String>[];
  final stopVoiceCalls = <String>[];
  final _controllers = <String, StreamController<LocalChatDeliveryEvent>>{};

  StreamController<LocalChatDeliveryEvent> _controllerFor(String requestId) {
    final existing = _controllers[requestId];
    if (existing != null && !existing.isClosed) {
      return existing;
    }
    final controller = StreamController<LocalChatDeliveryEvent>();
    _controllers[requestId] = controller;
    return controller;
  }

  void emit(String requestId, LocalChatDeliveryEvent event) {
    _controllerFor(requestId).add(event);
  }

  void emitAccepted(String requestId) => emit(
    requestId,
    LocalChatDeliveryEvent.accepted(
      requestId: requestId,
      sessionId: 'session-1',
    ),
  );

  void emitWaiting(String requestId) => emit(
    requestId,
    LocalChatDeliveryEvent.waiting(
      requestId: requestId,
      sessionId: 'session-1',
    ),
  );

  void emitDelta(String requestId, String text) => emit(
    requestId,
    LocalChatDeliveryEvent.delta(
      requestId: requestId,
      sessionId: 'session-1',
      text: text,
    ),
  );

  void emitMessage(
    String requestId,
    List<String> messages, {
    bool incomplete = false,
  }) => emit(
    requestId,
    LocalChatDeliveryEvent.message(
      requestId: requestId,
      sessionId: 'session-1',
      messages: messages,
      incomplete: incomplete,
    ),
  );

  void emitState(String requestId, {ReplySource source = ReplySource.llm}) =>
      emit(
        requestId,
        LocalChatDeliveryEvent.state(
          requestId: requestId,
          sessionId: 'session-1',
          source: source,
        ),
      );

  void emitDone(String requestId) => emit(
    requestId,
    LocalChatDeliveryEvent.done(requestId: requestId, sessionId: 'session-1'),
  );

  void emitCancelled(String requestId) => emit(
    requestId,
    LocalChatDeliveryEvent.cancelled(
      requestId: requestId,
      sessionId: 'session-1',
    ),
  );

  void closeStream(String requestId) {
    _controllers[requestId]?.close();
  }

  @override
  Future<bool> cancel(String requestId) async {
    cancelCalls.add(requestId);
    return true;
  }
  @override
  Future<bool> stopVoice(String requestId) async {
    stopVoiceCalls.add(requestId);
    return true;
  }


  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) {
    // 新的一次交付取代同一 requestId 的旧流（重发即新连接）。
    _controllers[requestId]?.close();
    _controllers.remove(requestId);
    return _controllerFor(requestId).stream;
  }

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);
}

final class _SequentialPlayerPlatform implements VoicePlayerPlatform {
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
  }) async => _AutoFinishPlayback();
}

/// 立即播完的整段播放（按序队列用例用：不等测试手动收尾）。
final class _AutoFinishPlayback implements VoicePlayback {
  final Completer<void> _done = Completer<void>()..complete();

  @override
  Future<void> get done => _done.future;

  @override
  void setVolume(double volume) {}

  @override
  void stop() {}
}

/// 带流式能力的播放平台假件：记录每路流的块序列与结束态。
final class _StreamingPlayerPlatform
    implements VoicePlayerPlatform, StreamingVoicePlayerPlatform {
  final List<_RecordingStreamPlayback> streams = [];
  final List<_InstantPlayback> wholePlaybacks = [];

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
    final playback = _InstantPlayback();
    wholePlaybacks.add(playback);
    return playback;
  }

  @override
  Future<VoiceStreamPlayback?> startStream({
    required int sampleRate,
    double volume = 1.0,
  }) async {
    final playback = _RecordingStreamPlayback(sampleRate: sampleRate);
    streams.add(playback);
    return playback;
  }
}

final class _RecordingStreamPlayback implements VoiceStreamPlayback {
  _RecordingStreamPlayback({required this.sampleRate});

  final int sampleRate;
  final List<int> appended = [];
  final Completer<void> _done = Completer<void>();
  bool ended = false;
  bool stopped = false;

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
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;

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

final class _GestureLockedSequentialPlayer
    implements VoicePlayerPlatform, UserGestureVoicePlayerPlatform {
  bool gestureActive = false;
  bool _prepared = false;
  bool started = false;

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
    started = true;
    return _InstantPlayback();
  }
}

/// 整段播放假件：done 由测试手动收尾（[finish]）——「在播中」的用例
/// 要靠它把播放器占住。
final class _InstantPlayback implements VoicePlayback {
  final Completer<void> _done = Completer<void>();

  void finish() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;

  @override
  void setVolume(double volume) {}

  @override
  void stop() => finish();
}

/// 可翻转的 TTS 设置 fake：记录 autoSpeak 写入，供 toggle 测试。
final class _MutableTtsSettingsGateway implements TtsSettingsGateway {
  _MutableTtsSettingsGateway({this.autoSpeak = true});

  bool autoSpeak;
  final autoSpeakWrites = <bool>[];

  @override
  Future<TtsSettings> read() async =>
      TtsSettings(configured: true, keySet: true, autoSpeak: autoSpeak);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async {
    autoSpeakWrites.add(enabled);
    autoSpeak = enabled;
    return TtsSettings(configured: true, keySet: true, autoSpeak: autoSpeak);
  }

  @override
  Future<TtsSettings> forgetApiKey() async => throw UnimplementedError();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      throw UnimplementedError();
}
