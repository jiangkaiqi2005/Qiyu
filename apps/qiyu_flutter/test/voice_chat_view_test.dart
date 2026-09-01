import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';

void main() {
  testWidgets('模型回复完整交付后自动朗读：指示与停止按钮', (tester) async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _HoldingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      _VoiceChatGateway(),
      hostConnectionProbe: _FixedHostConnectionProbe(),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );

    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    // 完整交付后自动朗读一次（且仅一次）：状态行、气泡指示、停止按钮。
    expect(speakGateway.calls, hasLength(1));
    expect(find.byKey(const Key('voice-output-status')), findsOneWidget);
    expect(find.byKey(const Key('voice-output-stop')), findsOneWidget);
    expect(find.text('正在读'), findsOneWidget);

    // 停止按钮：立即停播收起状态。
    await tester.tap(find.byKey(const Key('voice-output-stop')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsNothing);
    expect(find.text('正在读'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  });

  testWidgets('点麦克风与 Esc 都让栖语立即闭嘴（防自我循环）', (tester) async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _HoldingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      _VoiceChatGateway(),
      hostConnectionProbe: _FixedHostConnectionProbe(),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );

    // 一轮回复后自动朗读中。
    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsOneWidget);

    // 点麦克风：立即停播清队列（否则她的声音会被录进转写自我循环）。
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsNothing);

    // 再触发一轮朗读，Esc 同样停播。
    await tester.enterText(find.byKey(const Key('chat-input')), '还在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  });

  testWidgets('离开聊天页立即停止朗读并清空队列', (tester) async {
    final player = _HoldingPlayerPlatform();
    final controller = VoiceOutputController(
      _RecordingSpeakGateway(),
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      _VoiceChatGateway(),
      hostConnectionProbe: _FixedHostConnectionProbe(),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    final router = GoRouter(
      initialLocation: '/chat',
      routes: [
        GoRoute(
          path: '/chat',
          builder: (context, state) => LocalChatView(
            voiceRecorderPlatform: _FakeRecorderPlatform(),
            sttSettingsGateway: _FixedSttGateway(configured: true),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(body: Text('设置页')),
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: viewModel,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(controller.phase, VoiceOutputPhase.playing);
    expect(player.activeCount, 1);

    await tester.tap(find.byKey(const Key('open-provider-settings')));
    await tester.pumpAndSettle();
    expect(find.text('设置页'), findsOneWidget);
    expect(controller.phase, VoiceOutputPhase.idle);
    expect(player.activeCount, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    viewModel.dispose();
    controller.dispose();
  });

  testWidgets('气泡小喇叭重听：播完后点喇叭立即再读一次', (tester) async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _HoldingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      _VoiceChatGateway(),
      hostConnectionProbe: _FixedHostConnectionProbe(),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );

    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    // 自动朗读一次；播完后气泡出现重听小喇叭。
    expect(speakGateway.calls, hasLength(1));
    player.finishAll();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-replay-0')), findsOneWidget);

    // 点小喇叭：重听 = 重新合成再播一次。
    await tester.tap(find.byKey(const Key('chat-replay-0')));
    await tester.pumpAndSettle();
    expect(speakGateway.calls, hasLength(2));
    expect(speakGateway.calls.last.deliveryIndex, 0);
    expect(speakGateway.calls.map((call) => call.sessionId), [
      'session-voice',
      'session-voice',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  });

  testWidgets('朗读开关：配了才显示，点按切 autoSpeak 并停播', (tester) async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _HoldingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final mutableTts = _MutableTtsGateway(configured: true, autoSpeak: true);
    final viewModel = LocalChatViewModel(
      _VoiceChatGateway(),
      hostConnectionProbe: _FixedHostConnectionProbe(),
      ttsSettingsGateway: mutableTts,
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );

    // 配了 TTS：顶部出现朗读小喇叭（开着）。
    expect(find.byKey(const Key('voice-output-toggle-on')), findsOneWidget);

    // 点小喇叭弹出音量与静音卡片。
    await tester.tap(find.byKey(const Key('voice-output-toggle-on')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('voice-output-volume-slider')), findsOneWidget);
    expect(
      find.byKey(const Key('voice-output-popover-mute-button')),
      findsOneWidget,
    );

    // 点弹窗里的静音按钮关掉朗读：写 Host autoSpeak=false，图标切换。
    await tester.tap(find.byKey(const Key('voice-output-popover-mute-button')));
    await tester.pumpAndSettle();
    expect(mutableTts.autoSpeakWrites, [false]);
    expect(find.byKey(const Key('voice-output-toggle-off')), findsOneWidget);

    // 弹窗开着时全屏遮罩盖住 composer：先点遮罩收起弹窗，发送才点得到。
    await tester.tapAt(const Offset(10, 590));
    await tester.pumpAndSettle();

    // 关了之后自动朗读不触发（纯文字）。
    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    // 发送真实触发：回复落屏；只是不朗读。
    expect(find.text('咋了'), findsOneWidget);
    expect(speakGateway.calls, isEmpty);
    expect(find.byKey(const Key('voice-output-status')), findsNothing);

    // 再点开小喇叭弹窗，点静音按钮解除静音：恢复自动朗读。
    await tester.tap(find.byKey(const Key('voice-output-toggle-off')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-output-popover-mute-button')));
    await tester.pumpAndSettle();
    expect(mutableTts.autoSpeakWrites, [false, true]);
    expect(find.byKey(const Key('voice-output-toggle-on')), findsOneWidget);

    // 调节滑块
    await tester.drag(
      find.byKey(const Key('voice-output-volume-slider')),
      const Offset(0, -30),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  });

  testWidgets('未配语音合成：不显示朗读开关', (tester) async {
    final viewModel = LocalChatViewModel(
      _VoiceChatGateway(),
      hostConnectionProbe: _FixedHostConnectionProbe(),
      ttsSettingsGateway: _FixedTtsGateway(configured: false),
      voiceOutput: VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: _HoldingPlayerPlatform(),
      ),
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-toggle-on')), findsNothing);
    expect(find.byKey(const Key('voice-output-toggle-off')), findsNothing);
    viewModel.dispose();
  });

  testWidgets('未配置语音服务：置灰点按引导去设置页', (tester) async {
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(),
        platform: _FakeRecorderPlatform(),
        sttConfigured: false,
      ),
    );
    await tester.pump();

    final mic = find.byKey(const Key('voice-mic'));
    expect(mic, findsOneWidget);
    await tester.tap(mic);
    await tester.pump();

    expect(find.textContaining('还没有配置语音服务'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    // SnackBar 到期退出，避免挂起计时器。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('浏览器不支持录音：明确提示而不是无声失败', (tester) async {
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(),
        platform: _FakeRecorderPlatform(supported: false),
        sttConfigured: false,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();

    expect(find.textContaining('不支持语音输入'), findsOneWidget);
    expect(find.text('去设置'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('配置完成后置灰麦克风直接开始录音（无需刷新页面）', (tester) async {
    final sttGateway = _MutableSttGateway()..configured = false;
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(),
        platform: _FakeRecorderPlatform(),
        sttGateway: sttGateway,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('voice-mic')), findsOneWidget);

    // 用户在设置页配好语音服务后回到聊天页再点麦克风。
    sttGateway.configured = true;
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();

    // 重查成功：不弹引导，直接进入录音。
    expect(find.textContaining('还没有配置语音服务'), findsNothing);
    expect(find.byKey(const Key('voice-mic-stop')), findsOneWidget);
  });

  testWidgets('录音 → 转写 → 成功只发一条用户消息', (tester) async {
    // 先挂起转写以观察「正在转文字」中间态，再放行到成功。
    final gateway = _VoiceChatGateway()..hangTranscribe = true;
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(gateway),
        platform: _FakeRecorderPlatform(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-stop')), findsOneWidget);
    expect(find.textContaining('正在录音'), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice-mic-stop')));
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-busy')), findsOneWidget);
    expect(find.textContaining('正在转文字'), findsOneWidget);
    expect(gateway.sentTexts, isEmpty);

    gateway.completeHungTranscribe('今天有点累');
    await tester.pumpAndSettle();

    // 转写文本经既有发送链路变成唯一一条用户消息与栖语回复。
    expect(gateway.sentTexts, ['今天有点累']);
    expect(find.text('今天有点累'), findsOneWidget);
    expect(find.text('咋了'), findsOneWidget);
    expect(find.byKey(const Key('voice-mic')), findsOneWidget);
  });

  testWidgets('说完按停止先取得播放许可，异步转写和回复后仍自动朗读', (tester) async {
    final gateway = _VoiceChatGateway()..hangTranscribe = true;
    final player = _GestureLockedPlayerPlatform();
    final controller = VoiceOutputController(
      _RecordingSpeakGateway(),
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _FixedHostConnectionProbe(),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    player.gestureActive = true;
    await tester.tap(find.byKey(const Key('voice-mic-stop')));
    player.gestureActive = false;
    await tester.pump();

    gateway.completeHungTranscribe('今天有点累');
    await tester.pumpAndSettle();

    expect(player.started, isTrue);
    expect(controller.failureNotice, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  });

  testWidgets('60 秒自动收尾仍沿用开始录音的许可自动朗读', (tester) async {
    final gateway = _VoiceChatGateway()..hangTranscribe = true;
    final player = _GestureLockedPlayerPlatform();
    final controller = VoiceOutputController(
      _RecordingSpeakGateway(),
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _FixedHostConnectionProbe(),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );
    await tester.pump();

    player.gestureActive = true;
    await tester.tap(find.byKey(const Key('voice-mic')));
    player.gestureActive = false;
    await tester.pump(const Duration(seconds: 60));
    expect(find.byKey(const Key('voice-mic-busy')), findsOneWidget);

    gateway.completeHungTranscribe('今天有点累');
    await tester.pumpAndSettle();

    expect(player.started, isTrue);
    expect(controller.failureNotice, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  });

  testWidgets('转写失败进重试态，点麦克风重传后照常发送', (tester) async {
    final gateway = _VoiceChatGateway()
      ..transcribeFailuresRemaining = 1
      ..transcribeError = const LocalChatGatewayException('没有识别到语音，可以再说一次。');
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(gateway),
        platform: _FakeRecorderPlatform(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-mic-stop')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('voice-mic-retry')), findsOneWidget);
    expect(find.textContaining('没有识别到语音'), findsOneWidget);
    expect(gateway.sentTexts, isEmpty);
    expect(gateway.transcribeCalls, 1);

    // 重试：不重录、同一段音频再传一次。
    await tester.tap(find.byKey(const Key('voice-mic-retry')));
    await tester.pumpAndSettle();

    expect(gateway.transcribeCalls, 2);
    expect(
      gateway.transcribeAudioCalls.first,
      gateway.transcribeAudioCalls.last,
    );
    expect(gateway.sentTexts, ['今天有点累']);
    expect(find.text('今天有点累'), findsOneWidget);
  });

  testWidgets('录音中按 Esc 丢弃：不转写也不发送', (tester) async {
    final platform = _FakeRecorderPlatform();
    final gateway = _VoiceChatGateway();
    await tester.pumpWidget(
      _harness(viewModel: _chatViewModel(gateway), platform: platform),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-stop')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.byKey(const Key('voice-mic')), findsOneWidget);
    expect(find.textContaining('正在录音'), findsNothing);
    expect(gateway.transcribeCalls, 0);
    expect(platform.session!.discardCalls, 1);
    expect(gateway.sentTexts, isEmpty);
  });

  testWidgets('转写中按 Esc 中止：回重试态且迟到结果不发送', (tester) async {
    final gateway = _VoiceChatGateway()..hangTranscribe = true;
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(gateway),
        platform: _FakeRecorderPlatform(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-mic-stop')));
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-busy')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-retry')), findsOneWidget);

    // 迟到的转写结果到达：不触发发送，重试态保持。
    gateway.completeHungTranscribe('迟到的话');
    await tester.pumpAndSettle();
    expect(gateway.sentTexts, isEmpty);
    expect(find.byKey(const Key('voice-mic-retry')), findsOneWidget);
  });
}

Widget _harness({
  required LocalChatViewModel viewModel,
  required VoiceRecorderPlatform platform,
  bool sttConfigured = true,
  SttSettingsGateway? sttGateway,
}) {
  return MultiProvider(
    providers: [ChangeNotifierProvider.value(value: viewModel)],
    child: MaterialApp(
      home: LocalChatView(
        voiceRecorderPlatform: platform,
        sttSettingsGateway:
            sttGateway ?? _FixedSttGateway(configured: sttConfigured),
      ),
    ),
  );
}

LocalChatViewModel _chatViewModel([StreamingLocalChatGateway? gateway]) =>
    LocalChatViewModel(
      gateway ?? _VoiceChatGateway(),
      hostConnectionProbe: _FixedHostConnectionProbe(),
      autoStart: false,
    );

final class _FixedHostConnectionProbe implements HostConnectionProbe {
  @override
  Future<bool> isHostAvailable() async => true;
}

/// configured 可翻转的 STT 设置网关：模拟设置页保存前后的状态。
final class _MutableSttGateway implements SttSettingsGateway {
  var configured = false;

  @override
  Future<SttSettings> read() async =>
      SttSettings(configured: configured, keySet: configured);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async =>
      const SttSettings(configured: true, keySet: true);

  @override
  Future<SttSettings> forgetApiKey() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: true,
        status: ProviderTestStatus.success,
        message: '连接成功，语音输入可以使用。',
      );
}

final class _FixedSttGateway implements SttSettingsGateway {
  const _FixedSttGateway({required this.configured});

  final bool configured;

  @override
  Future<SttSettings> read() async =>
      SttSettings(configured: configured, keySet: configured);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async =>
      const SttSettings(configured: true, keySet: true);

  @override
  Future<SttSettings> forgetApiKey() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: true,
        status: ProviderTestStatus.success,
        message: '连接成功，语音输入可以使用。',
      );
}

/// 聊天 + 转写双通道 fake：转写行为可编程（失败次数、挂起等待）。
final class _VoiceChatGateway implements StreamingLocalChatGateway {
  final sentTexts = <String>[];
  final transcribeAudioCalls = <List<int>>[];
  int transcribeCalls = 0;
  int transcribeFailuresRemaining = 0;
  LocalChatGatewayException? transcribeError;
  bool hangTranscribe = false;
  final _hungCompleters = <Completer<String>>[];

  void completeHungTranscribe(String text) {
    for (final completer in _hungCompleters) {
      if (!completer.isCompleted) {
        completer.complete(text);
      }
    }
  }

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-voice', messages: []);

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async {
    transcribeCalls += 1;
    transcribeAudioCalls.add(audio.toList());
    if (hangTranscribe) {
      final completer = Completer<String>();
      _hungCompleters.add(completer);
      return completer.future;
    }
    if (transcribeFailuresRemaining > 0) {
      transcribeFailuresRemaining -= 1;
      throw transcribeError ?? const LocalChatGatewayException('转写失败。');
    }
    return '今天有点累';
  }

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    sentTexts.add(text);
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: 'session-voice',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      messages: ['咋了'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      source: ReplySource.local,
      fallbackReason: FallbackReason.noLlmConfig,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
    );
  }
}

final class _FakeRecorderPlatform implements VoiceRecorderPlatform {
  _FakeRecorderPlatform({this.supported = true});

  @override
  final bool supported;
  _FakeRecordingSession? session;

  @override
  Future<VoiceRecordingSession?> start() async =>
      supported ? (session = _FakeRecordingSession()) : null;

  @override
  Future<RecordedAudio> toWav16kMono(RecordedAudio audio) async =>
      RecordedAudio(bytes: audio.bytes, mimeType: 'audio/wav');
}

final class _FakeRecordingSession implements VoiceRecordingSession {
  int discardCalls = 0;

  @override
  String get mimeType => 'audio/webm';

  @override
  Future<Uint8List> stop() async => Uint8List.fromList([1, 2, 3]);

  @override
  void discard() {
    discardCalls += 1;
  }
}

/// TTS 设置 fake：朗读可用性可编程。
final class _FixedTtsGateway implements TtsSettingsGateway {
  _FixedTtsGateway({required this.configured});

  final bool configured;

  @override
  Future<TtsSettings> read() async =>
      TtsSettings(configured: configured, keySet: configured);

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

/// 朗读 fake：记录调用，播放挂起直到测试放行。
final class _RecordingSpeakGateway implements ChatSpeechGateway {
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
    return Uint8List.fromList([1]);
  }
}

/// 播放挂起型 fake：正在读的状态保持到 finish 被调用。
final class _HoldingPlayerPlatform implements VoicePlayerPlatform {
  final _playbacks = <Completer<void>>[];

  int get activeCount => _playbacks.length;

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
    final playback = _HoldingPlayback(this);
    _playbacks.add(playback._done);
    return playback;
  }

  void finishAll() {
    for (final done in _playbacks) {
      if (!done.isCompleted) {
        done.complete();
      }
    }
    _playbacks.clear();
  }
}

final class _HoldingPlayback implements VoicePlayback {
  _HoldingPlayback(this._platform);

  final _HoldingPlayerPlatform _platform;
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  void setVolume(double volume) {}

  @override
  void stop() {
    _platform._playbacks.remove(_done);
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

final class _GestureLockedPlayerPlatform
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
    return const _CompletedPlayback();
  }
}

final class _CompletedPlayback implements VoicePlayback {
  const _CompletedPlayback();

  @override
  Future<void> get done => Future<void>.value();

  @override
  void setVolume(double volume) {}

  @override
  void stop() {}
}

/// 可翻转的 TTS 设置 fake：记录 autoSpeak 写入。
final class _MutableTtsGateway implements TtsSettingsGateway {
  _MutableTtsGateway({required this.configured, this.autoSpeak = true});

  bool configured;
  bool autoSpeak;
  final autoSpeakWrites = <bool>[];

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
  Future<TtsSettings> setAutoSpeak(bool enabled) async {
    autoSpeakWrites.add(enabled);
    autoSpeak = enabled;
    return TtsSettings(
      configured: configured,
      keySet: configured,
      autoSpeak: autoSpeak,
    );
  }

  @override
  Future<TtsSettings> forgetApiKey() async => throw UnimplementedError();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      throw UnimplementedError();
}
