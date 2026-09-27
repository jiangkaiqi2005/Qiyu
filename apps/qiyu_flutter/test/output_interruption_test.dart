import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform_io.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(androidVoicePlayerChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  Completer<Object?>? prepare;
  Completer<Object?>? start;
  var allowed = true;
  setUp(() {
    calls = [];
    prepare = null;
    start = null;
    allowed = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'prepareOutput' => prepare != null ? await prepare!.future : allowed,
        'startPlayback' => start != null ? await start!.future : 7,
        _ => null,
      };
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  Future<void> interrupt({int? sessionId}) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      androidVoicePlayerChannelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onOutputInterrupted', {
          'sessionId':
              sessionId ??
              (calls.lastWhere((c) => c.method == 'prepareOutput').arguments
                  as Map)['sessionId'],
        }),
      ),
      (_) => done.complete(),
    );
    await done.future;
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> pump() => Future<void>.delayed(Duration.zero);
  for (final stage in ['准备焦点', '合成', '准备播放器', '播放']) {
    test('生产播放通道在$stage中断清队，迟到回包不复活，主动重听可用', () async {
      final gateway = _Speech();
      final controller = VoiceOutputController(
        gateway,
        playerPlatform: IoVoicePlayerPlatform(supported: true),
      );
      addTearDown(controller.dispose);
      if (stage == '准备焦点') prepare = Completer<Object?>();
      if (stage == '合成') gateway.pending = Completer<Uint8List>();
      if (stage == '准备播放器') start = Completer<Object?>();
      const request = VoiceOutputRequest(requestId: 'r', deliveryIndex: 0);
      controller.offer(request, enabled: true);
      controller.offer(
        const VoiceOutputRequest(requestId: 'queued', deliveryIndex: 0),
        enabled: true,
      );
      await pump();
      expect(calls.first.method, 'prepareOutput');
      final oldSession = (calls.first.arguments as Map)['sessionId'] as int;
      await interrupt();
      await interrupt();
      prepare?.complete(true);
      start?.complete(8);
      gateway.pending?.complete(Uint8List.fromList([1]));
      await pump();
      expect(controller.isReading, false);
      expect(gateway.requests, isNot(contains('queued')));
      controller.offer(
        const VoiceOutputRequest(requestId: 'late-text', deliveryIndex: 0),
        enabled: true,
      );
      await pump();
      expect(gateway.requests, isNot(contains('late-text')));
      if (stage == '准备播放器') {
        expect(
          calls
              .where((c) => c.method == 'stopPlayback')
              .any((c) => (c.arguments as Map)['id'] == 8),
          true,
        );
      }
      prepare = null;
      start = null;
      gateway.pending = null;
      controller.playNow(request);
      await pump();
      expect(controller.phase, VoiceOutputPhase.playing);
      await interrupt(sessionId: oldSession);
      expect(controller.phase, VoiceOutputPhase.playing);
      controller.stopAll();
      await pump();
      expect(calls.where((c) => c.method == 'endOutput'), isNotEmpty);
    });
  }
  test('焦点拒绝不合成不播放，队列失效，主动重听重新请求焦点', () async {
    allowed = false;
    final gateway = _Speech();
    final controller = VoiceOutputController(
      gateway,
      playerPlatform: IoVoicePlayerPlatform(supported: true),
    );
    addTearDown(controller.dispose);
    const request = VoiceOutputRequest(requestId: 'r', deliveryIndex: 0);
    controller.offer(request, enabled: true);
    controller.offer(request, enabled: true);
    await pump();
    expect(gateway.requests, isEmpty);
    expect(calls.where((c) => c.method == 'startPlayback'), isEmpty);
    allowed = true;
    controller.playNow(request);
    await pump();
    expect(controller.phase, VoiceOutputPhase.playing);
  });
  for (final stage in ['准备焦点', '合成', '准备播放器', '播放']) {
    test('生产通道设置试听$stage中断后安静且主动试听可用', () async {
      final gateway = _Preview();
      if (stage == '准备焦点') prepare = Completer<Object?>();
      if (stage == '合成') gateway.pending = Completer<TtsConnectionTest>();
      if (stage == '准备播放器') start = Completer<Object?>();
      final model = TtsSettingsViewModel(
        gateway,
        autoStart: false,
        playerPlatform: IoVoicePlayerPlatform(supported: true),
      );
      addTearDown(model.dispose);
      const draft = TtsSettingsDraft(
        baseUrl: 'https://example.com',
        model: 'tts',
      );
      final testing = model.testConnection(draft);
      await pump();
      expect(calls.first.method, 'prepareOutput');
      await interrupt();
      final starts = calls.where((c) => c.method == 'startPlayback').length;
      gateway.pending?.complete(_Preview.audio);
      prepare?.complete(true);
      start?.complete(8);
      await testing;
      expect(calls.where((c) => c.method == 'startPlayback').length, starts);
      gateway.pending = null;
      prepare = null;
      start = null;
      await model.testConnection(draft);
      expect(
        calls.where((c) => c.method == 'startPlayback').length,
        starts + 1,
      );
      model.stopPreview();
    });
  }
  test('设置试听焦点请求失败不启动合成或播放，主动测试可以重来', () async {
    allowed = false;
    final gateway = _Preview();
    final model = TtsSettingsViewModel(
      gateway,
      autoStart: false,
      playerPlatform: IoVoicePlayerPlatform(supported: true),
    );
    addTearDown(model.dispose);
    const draft = TtsSettingsDraft(
      baseUrl: 'https://example.com',
      model: 'tts',
    );
    await model.testConnection(draft);
    expect(gateway.calls, 0);
    expect(calls.where((c) => c.method == 'startPlayback'), isEmpty);
    allowed = true;
    await model.testConnection(draft);
    expect(gateway.calls, 1);
    expect(calls.where((c) => c.method == 'startPlayback'), hasLength(1));
  });
}

final class _Speech implements ChatSpeechGateway {
  Completer<Uint8List>? pending;
  final requests = <String>[];
  @override
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  }) async {
    requests.add(requestId);
    return pending != null ? await pending!.future : Uint8List.fromList([1]);
  }
}

final class _Preview implements TtsSettingsGateway {
  int calls = 0;
  Completer<TtsConnectionTest>? pending;
  static TtsConnectionTest get audio => TtsConnectionTest(
    succeeded: true,
    message: '连接成功',
    audio: Uint8List.fromList([1]),
  );
  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async {
    calls++;
    return pending != null ? await pending!.future : audio;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
