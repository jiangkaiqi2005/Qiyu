import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

void main() {
  test(
    'a submitted user message is visible before the host accepts it',
    () async {
      final gateway = _GatedGateway();
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: _AvailableProbe(),
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
        hostConnectionProbe: _AvailableProbe(),
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
      hostConnectionProbe: _AvailableProbe(),
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
      hostConnectionProbe: _AvailableProbe(),
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
      hostConnectionProbe: _AvailableProbe(),
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
        hostConnectionProbe: _AvailableProbe(),
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
      hostConnectionProbe: _AvailableProbe(),
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

final class _AvailableProbe implements HostConnectionProbe {
  @override
  Future<bool> isHostAvailable() async => true;
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

final class _SequentialPlayerPlatform implements VoicePlayerPlatform {
  @override
  bool get supported => true;

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
  }) async => _InstantPlayback();
}

final class _InstantPlayback implements VoicePlayback {
  final Completer<void> _done = (Completer<void>()..complete());

  @override
  Future<void> get done => _done.future;

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
