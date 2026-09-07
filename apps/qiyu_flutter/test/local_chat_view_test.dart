import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart'
    show ProviderTestResult;
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';

import 'support/shared_fakes.dart';

void main() {
  group('LocalChatView 接口限流与 40x 异常提示弹窗', () {
    testWidgets('429 限流：流式完成后弹出模态弹窗，双按钮直达设置', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelRateLimited],
      );
      await _pumpChatView(tester, gateway: gateway);

      // 发送消息
      await tester.enterText(find.byKey(const Key('chat-input')), '你好');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 流式落定后弹出模态对话框
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('服务请求受限'), findsOneWidget);
      expect(find.textContaining('模型服务返回请求过于频繁（429）'), findsOneWidget);

      // 验证双按钮
      final dismissBtn = find.byKey(const Key('api-error-dialog-dismiss'));
      final settingsBtn = find.byKey(const Key('api-error-dialog-settings'));
      expect(dismissBtn, findsOneWidget);
      expect(settingsBtn, findsOneWidget);

      // 点击【前往设置】直接平滑跳转 /settings
      await tester.tap(settingsBtn);
      await tester.pumpAndSettle();

      expect(find.text('设置页'), findsOneWidget);
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
    });

    testWidgets('点击【知道了】：关闭弹窗且返还焦点到输入框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelRateLimited],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '你好');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);

      // 点击【知道了】
      await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
      expect(input.focusNode?.hasFocus, isTrue);
    });

    testWidgets('会话级频控去重：同会话第 2 次不再弹窗，状态行展示轻提示与去设置链接', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [
          FallbackReason.modelRateLimited,
          FallbackReason.modelRateLimited,
        ],
      );
      await _pumpChatView(tester, gateway: gateway);

      // 第 1 次发消息，触发 429
      await tester.enterText(find.byKey(const Key('chat-input')), '第一句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 第 1 次弹窗出现，用户点知道了关闭
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);

      // 第 2 次发消息，再次触发 429
      await tester.enterText(find.byKey(const Key('chat-input')), '第二句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 验证不再弹出模态全屏遮罩
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);

      // 状态行展示轻提示与链接
      expect(
        find.textContaining('⚠️ 接口频繁受限 (429)'),
        findsOneWidget,
      );
      final settingsLink = find.text('去设置检查');
      expect(settingsLink, findsOneWidget);

      // 点击状态行里的【去设置检查】
      await tester.tap(settingsLink);
      await tester.pumpAndSettle();

      expect(find.text('设置页'), findsOneWidget);
    });

    testWidgets('401 鉴权失败：弹出「API Key 鉴权失败」对话框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelAuthentication],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '测试鉴权');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('API Key 鉴权失败'), findsOneWidget);
      expect(find.textContaining('服务商未通过验证（401/403）'), findsOneWidget);
    });

    testWidgets('404 模型未找到：弹出「模型名称不存在」对话框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelNotFound],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '测试模型');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('模型名称不存在'), findsOneWidget);
      expect(find.textContaining('服务商未找到当前配置的模型（404）'), findsOneWidget);
    });

    testWidgets('边界排除：safety 与 noLlmConfig 绝对不弹窗', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [
          FallbackReason.safety,
          FallbackReason.noLlmConfig,
        ],
      );
      await _pumpChatView(tester, gateway: gateway);

      // 第 1 轮：safety 拦截
      await tester.enterText(find.byKey(const Key('chat-input')), '敏感输入');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.byKey(const Key('api-error-notice-text')), findsNothing);

      // 第 2 轮：noLlmConfig 设计内无模型
      await tester.enterText(find.byKey(const Key('chat-input')), '随便聊聊');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.byKey(const Key('api-error-notice-text')), findsNothing);
    });

    testWidgets('边界排除：modelTimeout 仅状态行轻提示，不弹出模态对话框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelTimeout],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '网络慢');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 绝不弹出模态对话框（避免误导用户改 Key）
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);

      // 仅在状态行展示就地轻提示
      expect(
        find.textContaining('网络连接超时'),
        findsOneWidget,
      );
      // 不引导去改配置
      expect(find.text('去设置检查'), findsNothing);
    });

    testWidgets('语音链路联动：STT 429 触发「语音服务受限」弹窗', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.noLlmConfig],
      );
      gateway.transcribeError = const LocalChatGatewayException(
        '语音服务请求过于频繁。',
        code: 'stt_service_error',
      );
      final recorder = _FakeVoiceRecorder();

      await _pumpChatView(
        tester,
        gateway: gateway,
        recorderPlatform: recorder,
      );

      // 点击麦克风开始录音
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();

      // 再次点击麦克风停止录音并触发转写
      await tester.tap(find.byKey(const Key('voice-mic-stop')));
      await tester.pumpAndSettle();

      // 验证弹出语音服务受限弹窗
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('语音服务受限'), findsOneWidget);
      expect(find.textContaining('语音服务请求受限或配置异常'), findsOneWidget);
    });

    testWidgets('语音链路联动：TTS 429 触发「语音朗读受限」弹窗', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.noLlmConfig],
      );
      gateway.speakError = const LocalChatGatewayException(
        '语音合成服务请求过于频繁，请稍后再试。',
        code: 'tts_rate_limited',
      );

      await _pumpChatView(
        tester,
        gateway: gateway,
        autoSpeak: true,
      );

      // 发送消息，回复落盘后触发自动朗读
      await tester.enterText(find.byKey(const Key('chat-input')), '朗读测试');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 验证弹出语音朗读受限弹窗
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('语音朗读受限'), findsOneWidget);
      expect(find.textContaining('语音朗读合成请求受限或配置异常'), findsOneWidget);
    });
  });
}

Future<void> _pumpChatView(
  WidgetTester tester, {
  required _ConfigurableChatGateway gateway,
  VoiceRecorderPlatform? recorderPlatform,
  bool autoSpeak = false,
}) async {
  final ttsGateway = _FixedTtsGateway(configured: autoSpeak, autoSpeak: autoSpeak);
  final voiceOutput = VoiceOutputController(
    gateway,
    playerPlatform: _FakeVoicePlayer(),
  );
  final viewModel = LocalChatViewModel(
    gateway,
    hostConnectionProbe: FakeHostConnectionProbe(const [true]),
    ttsSettingsGateway: ttsGateway,
    voiceOutput: voiceOutput,
    autoStart: false,
  );
  await viewModel.refreshVoiceOutputStatus();

  final router = GoRouter(
    initialLocation: '/chat',
    routes: [
      GoRoute(
        path: '/chat',
        builder: (context, state) => LocalChatView(
          voiceRecorderPlatform: recorderPlatform ?? _FakeVoiceRecorder(),
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
      child: MaterialApp.router(
        theme: qiyuDarkTheme(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _ConfigurableChatGateway
    implements StreamingLocalChatGateway, ChatSpeechGateway {
  _ConfigurableChatGateway({
    required this.fallbackReasons,
  });

  final List<FallbackReason?> fallbackReasons;
  String sessionId = 'test-session-1';
  int deliverCallCount = 0;
  Object? transcribeError;
  Object? speakError;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      LocalChatSnapshot(sessionId: this.sessionId, messages: const []);

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async {
    if (transcribeError != null) {
      throw transcribeError!;
    }
    return '测试转写文本';
  }

  @override
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  }) async {
    if (speakError != null) {
      throw speakError!;
    }
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    final reason = deliverCallCount < fallbackReasons.length
        ? fallbackReasons[deliverCallCount]
        : (fallbackReasons.isNotEmpty ? fallbackReasons.last : null);
    deliverCallCount += 1;

    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: this.sessionId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: requestId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      text: '本地基础回复',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      messages: const ['本地基础回复'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      source: ReplySource.local,
      fallbackReason: reason,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
      sessionId: this.sessionId,
      messages: const ['本地基础回复'],
      source: ReplySource.local,
      fallbackReason: reason,
    );
  }
}

final class _FixedSttGateway implements SttSettingsGateway {
  _FixedSttGateway({this.configured = false});

  final bool configured;

  @override
  Future<SttSettings> read() async => SttSettings(
    configured: configured,
    keySet: configured,
    provider: SttServiceKind.openaiCompatible,
    baseUrl: 'https://api.example.com/v1',
    model: 'whisper-1',
  );

  @override
  Future<SttSettings> save(SttSettingsDraft draft) => throw UnimplementedError();

  @override
  Future<SttSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) =>
      throw UnimplementedError();
}

final class _FixedTtsGateway implements TtsSettingsGateway {
  _FixedTtsGateway({this.configured = false, this.autoSpeak = false});

  final bool configured;
  final bool autoSpeak;

  @override
  Future<TtsSettings> read() async => TtsSettings(
    configured: configured,
    keySet: configured,
    autoSpeak: autoSpeak,
  );

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) => throw UnimplementedError();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async => read();

  @override
  Future<TtsSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) =>
      throw UnimplementedError();
}

final class _FakeVoicePlayer implements VoicePlayerPlatform {
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

final class _FakeVoiceRecorder implements VoiceRecorderPlatform {
  @override
  bool get supported => true;

  @override
  Future<VoiceRecordingSession?> start() async => _FakeSession();

  @override
  Future<RecordedAudio> toWav16kMono(RecordedAudio source) async => source;
}

final class _FakeSession implements VoiceRecordingSession {
  @override
  String get mimeType => 'audio/webm';

  @override
  Future<Uint8List> stop() async => Uint8List.fromList([1, 2, 3]);

  @override
  void discard() {}
}
