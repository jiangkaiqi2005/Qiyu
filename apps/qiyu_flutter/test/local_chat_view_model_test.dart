import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'support/shared_fakes.dart';

void main() {
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
      expect(await send, isTrue);
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

      expect(sent, isTrue);
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

  test('a single-bubble stream still commits exactly one message', () async {
    final gateway = _TwoBubbleGateway(withBubble2: false);
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      requestIdFactory: () => 'request-2',
      autoStart: false,
    );

    final sent = await viewModel.send('在吗');

    expect(sent, isTrue);
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
    expect(await first, isTrue);
    expect(await second, isTrue);
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
    expect(await viewModel.send('我上次说爬山的事'), isTrue);
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
    expect(await sending, isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(player.started, isTrue);
    expect(controller.failureNotice, isNull);
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
      expect(await viewModel.send('在吗'), isTrue);
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
    expect(await second, isTrue);
    expect(await first, isFalse);

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
    expect(await first, isFalse);
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
    expect(await retry, isTrue);
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
    expect(await first, isFalse);
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
    expect(await retry, isTrue);
    final qiyuMessages = viewModel.messages
        .where((message) => message.speaker == LocalChatSpeaker.qiyu)
        .toList();
    expect(qiyuMessages, hasLength(1));
    expect(qiyuMessages.single.text, '补完的回复');
    expect(viewModel.streamingText, isEmpty);
    expect(viewModel.waiting, isFalse);
  });
}

final class _TwoBubbleGateway implements StreamingLocalChatGateway {
  _TwoBubbleGateway({this.withBubble2 = true});

  final bool withBubble2;

  @override
  Future<bool> cancel(String requestId) async => true;

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
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      sessionId: 'session-1',
      text: withBubble2 ? '一时没想起。' : '在。',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      sessionId: 'session-1',
      messages: [withBubble2 ? '一时没想起。' : '在。'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
      sessionId: 'session-1',
    );
    if (!withBubble2) {
      return;
    }
    // 轮内召回命中：同一 requestId 的第二段交付。
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      sessionId: 'session-1',
      text: '对了，你周末是要去爬山来着。',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      sessionId: 'session-1',
      messages: ['对了，你周末是要去爬山来着。'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
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
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      sessionId: 'session-1',
      messages: const ['看见了。'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
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
    LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: 'session-1',
    ),
  );

  void emitWaiting(String requestId) => emit(
    requestId,
    LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: requestId,
      sessionId: 'session-1',
    ),
  );

  void emitDelta(String requestId, String text) => emit(
    requestId,
    LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      sessionId: 'session-1',
      text: text,
    ),
  );

  void emitMessage(String requestId, List<String> messages) => emit(
    requestId,
    LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      sessionId: 'session-1',
      messages: messages,
    ),
  );

  void emitState(String requestId) => emit(
    requestId,
    LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    ),
  );

  void emitDone(String requestId) => emit(
    requestId,
    LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
      sessionId: 'session-1',
    ),
  );

  void emitCancelled(String requestId) => emit(
    requestId,
    LocalChatDeliveryEvent(
      kind: LocalChatEventKind.cancelled,
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
  }) async => _InstantPlayback();
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

final class _InstantPlayback implements VoicePlayback {
  final Completer<void> _done = (Completer<void>()..complete());

  @override
  Future<void> get done => _done.future;

  @override
  void setVolume(double volume) {}

  @override
  void stop() {}
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
