import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/omni_call_controller.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/shell/qiyu_shell.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';

import 'support/omni_call_fakes.dart';
import 'support/shared_fakes.dart';

void main() {
  group('聊天页 Omni 通话入口与状态栏（T04）', () {
    testWidgets('选中 Omni 且平台可采集：输入行尾随按钮换成电话入口', (tester) async {
      final harness = await _pump(tester);
      expect(find.byKey(const Key('omni-call-start')), findsOneWidget);
      expect(find.byKey(const Key('voice-mic')), findsNothing);
      harness.call.dispose();
    });

    testWidgets('非 Omni（或不可用）：原麦克风入口保持现状，无电话入口', (tester) async {
      final harness = await _pump(tester, omniProviderKind: null);
      expect(find.byKey(const Key('voice-mic')), findsOneWidget);
      expect(find.byKey(const Key('omni-call-start')), findsNothing);
      harness.call.dispose();
    });

    testWidgets('拨通：状态栏出现并随 phase 更新；通话中打字走通话线协议', (tester) async {
      final harness = await _pump(tester);
      await tester.tap(find.byKey(const Key('omni-call-start')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('omni-call-strip')), findsOneWidget);
      expect(find.text('正在接通…'), findsOneWidget);
      final startFrame = harness.socket.decodedFrames.single;
      expect(startFrame['type'], 'start');
      expect(startFrame['sessionId'], 'session-1');

      harness.socket.emit({'type': 'state', 'phase': 'active'});
      await tester.pumpAndSettle();
      expect(find.text('正在聆听'), findsOneWidget);
      expect(find.byKey(const Key('omni-call-start')), findsNothing,
          reason: '通话中入口让位给状态栏');

      await tester.enterText(find.byKey(const Key('chat-input')), '早');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      final frame = harness.socket.decodedFrames.last;
      expect(frame['type'], 'text');
      expect(frame['text'], '早');
      expect(harness.gateway.sentTexts, isEmpty, reason: '打字不再走 /api/chat');
      harness.call.dispose();
    });

    testWidgets('转录与回复进入普通聊天流：用户气泡、流式行、终态气泡', (tester) async {
      final harness = await _pump(tester);
      await tester.tap(find.byKey(const Key('omni-call-start')));
      await tester.pumpAndSettle();
      harness.socket.emit({'type': 'state', 'phase': 'active'});
      await tester.pumpAndSettle();

      harness.socket.emit({
        'type': 'inputTranscript',
        'turnId': 'voice-1',
        'text': '今晚有点睡不着。',
      });
      await tester.pumpAndSettle();
      expect(find.text('今晚有点睡不着。'), findsOneWidget);

      harness.socket.emit({
        'type': 'replyDelta',
        'turnId': 'voice-1',
        'text': '嗯，我在。',
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-streaming-reply')), findsOneWidget);

      harness.socket.emit({
        'type': 'replyDone',
        'turnId': 'voice-1',
        'status': 'completed',
        'incomplete': false,
      });
      await tester.pumpAndSettle();
      expect(find.text('嗯，我在。'), findsOneWidget);
      expect(find.byKey(const Key('chat-streaming-reply')), findsNothing);
      harness.call.dispose();
    });

    testWidgets('被打断回复如实标记（可见前缀 + 被打断标识），后到音频不复活', (tester) async {
      final harness = await _pump(tester);
      await tester.tap(find.byKey(const Key('omni-call-start')));
      await tester.pumpAndSettle();
      harness.socket.emit({'type': 'state', 'phase': 'active'});
      await tester.pumpAndSettle();

      harness.socket.emit({
        'type': 'replyDelta',
        'turnId': 'voice-1',
        'text': '我先说到这',
      });
      harness.socket.emit({'type': 'speechStarted'});
      harness.socket.emit({
        'type': 'replyDone',
        'turnId': 'voice-1',
        'status': 'cancelled',
        'incomplete': true,
      });
      harness.socket.emit({
        'type': 'audio',
        'turnId': 'voice-1',
        'pcm': base64Encode(omniTestPcm(frames: 10)),
      });
      await tester.pumpAndSettle();
      expect(find.text('我先说到这'), findsOneWidget);
      // spec:20：打断标记「被打断」，与失败轮的「未完成」是两种标记。
      expect(find.text('被打断'), findsOneWidget,
          reason: '被打断前缀不冒充完整回复，也不与失败标记混用');
      expect(find.text('未完成'), findsNothing);
      expect(
        harness.player.sampleRates,
        isEmpty,
        reason: '取消轮的后到音频不再开播放',
      );
      harness.call.dispose();
    });

    testWidgets('闭麦/恢复同一通话：帧与图标同步，挂断后显示结束态', (tester) async {
      final harness = await _pump(tester);
      await tester.tap(find.byKey(const Key('omni-call-start')));
      await tester.pumpAndSettle();
      harness.socket.emit({'type': 'state', 'phase': 'active'});
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('omni-strip-mute')));
      await tester.pumpAndSettle();
      expect(harness.socket.decodedFrames.last['type'], 'mute');
      expect(harness.socket.decodedFrames.last['muted'], isTrue);
      expect(find.text('已闭麦，仍在听她说'), findsOneWidget);

      await tester.tap(find.byKey(const Key('omni-strip-mute')));
      await tester.pumpAndSettle();
      expect(find.text('正在聆听'), findsOneWidget, reason: '恢复收音沿用同一通话');

      await tester.tap(find.byKey(const Key('omni-strip-end')));
      await tester.pumpAndSettle();
      expect(harness.socket.decodedFrames.last['type'], 'end');
      expect(find.text('通话已结束。'), findsOneWidget);
      expect(find.byKey(const Key('omni-call-start')), findsOneWidget,
          reason: '结束态保留展示，拨通入口回到输入行');
      // Host 收尾完才关连接；对账等待随收口解除。
      await harness.socket.closeStream();
      await tester.pump();
      harness.call.dispose();
    });

    testWidgets('麦克风被拒：不进通话、就近平铺通知，打字走正常聊天', (tester) async {
      final harness = await _pump(tester, captureDenied: true);
      await tester.tap(find.byKey(const Key('omni-call-start')));
      await tester.pumpAndSettle();
      expect(find.text('麦克风没有就绪，这次没有开始通话，仍可以打字。'), findsOneWidget);
      expect(find.byKey(const Key('omni-call-strip')), findsNothing);

      await tester.enterText(find.byKey(const Key('chat-input')), '还在吗');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(harness.gateway.sentTexts, ['还在吗'], reason: '可继续打字走 /api/chat');
      harness.call.dispose();
    });

    testWidgets('通话控件无障碍名：动作名进语义 label，不只落在 tooltip（决策 #17）',
        (tester) async {
      // 语义句柄须在测试体内同步释放（accessibility_test 同一口径）。
      final handle = tester.ensureSemantics();
      try {
        final harness = await _pump(tester);
        // 拨通入口：label = 拨通栖语。
        expect(find.bySemanticsLabel('拨通栖语'), findsOneWidget);

        await tester.tap(find.byKey(const Key('omni-call-start')));
        await tester.pumpAndSettle();
        harness.socket.emit({'type': 'state', 'phase': 'active'});
        await tester.pumpAndSettle();
        // 状态栏两颗：闭麦与挂断的动作名进得了 label。
        expect(find.bySemanticsLabel('闭麦（她还在说，说完继续听）'), findsOneWidget);
        expect(find.bySemanticsLabel('挂断'), findsOneWidget);
        harness.call.dispose();
      } finally {
        handle.dispose();
      }
    });
  });

  group('跨页通话条（T04:13）', () {
    testWidgets('活动通话在功能页底部：状态可点回聊天页，闭麦挂断可用；结束后收起', (tester) async {
      final harness = await _pumpShell(tester);
      harness.socket.emit({'type': 'state', 'phase': 'active'});
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('omni-call-bar')), findsOneWidget);
      expect(find.text('正在聆听'), findsOneWidget);

      await tester.tap(find.byKey(const Key('omni-callbar-mute')));
      await tester.pumpAndSettle();
      expect(harness.socket.decodedFrames.last['type'], 'mute');

      await tester.tap(find.byKey(const Key('omni-callbar-status')));
      await tester.pumpAndSettle();
      expect(find.text('聊天页'), findsOneWidget, reason: '点状态回聊天页');
      expect(find.byKey(const Key('omni-call-bar')), findsNothing,
          reason: '聊天页不叠加全局条');

      // 回设置页从全局条挂断：条随 ended 收起。
      GoRouter.of(tester.element(find.text('聊天页'))).go('/settings');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('omni-callbar-end')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('omni-call-bar')), findsNothing,
          reason: 'ended 不是进行中的通话');
      await harness.socket.closeStream();
      await tester.pump();
      harness.call.dispose();
    });
  });
}

// -----------------------------------------------------------------------------
// 装配替身
// -----------------------------------------------------------------------------

final class _Harness {
  _Harness(this.call, this.socket, this.player, this.gateway);

  final OmniCallController call;
  final FakeOmniSocket socket;
  final FakeOmniStreamingPlayer player;
  final FakeLocalChatGateway gateway;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  ProviderKind? omniProviderKind = ProviderKind.qwenOmniRealtime,
  bool captureDenied = false,
}) async {
  final gateway = FakeLocalChatGateway();
  final viewModel = LocalChatViewModel(
    gateway,
    hostConnectionProbe: FakeHostConnectionProbe(const [true]),
    autoStart: false,
  );
  // 恢复会话：composer 传给 startCall 的 sessionId 来自 VM。
  await viewModel.initialize();
  final socket = FakeOmniSocket();
  final player = FakeOmniStreamingPlayer();
  final capture = FakeOmniCapture()..denied = captureDenied;
  final call = OmniCallController(
    surface: viewModel,
    providerSettings: FakeOmniProviderGateway(kind: omniProviderKind),
    capture: capture,
    player: player,
    connector: (_) => socket,
    baseUri: Uri.parse('http://127.0.0.1:8080/'),
    requestIdFactory: () => 'omni-test-1',
  );
  await call.refreshAvailability();

  final router = GoRouter(
    initialLocation: '/chat',
    routes: [
      GoRoute(
        path: '/chat',
        builder: (context, state) => LocalChatView(
          sttSettingsGateway: _FixedSttGateway(),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const Scaffold(body: Text('设置页')),
      ),
    ],
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LocalChatViewModel>.value(value: viewModel),
        ChangeNotifierProvider<OmniCallController>.value(value: call),
      ],
      child: MaterialApp.router(theme: qiyuDarkTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(call, socket, player, gateway);
}

Future<_Harness> _pumpShell(WidgetTester tester) async {
  final gateway = FakeLocalChatGateway();
  final viewModel = LocalChatViewModel(
    gateway,
    hostConnectionProbe: FakeHostConnectionProbe(const [true]),
    autoStart: false,
  );
  final socket = FakeOmniSocket();
  final call = OmniCallController(
    surface: viewModel,
    providerSettings: FakeOmniProviderGateway(),
    capture: FakeOmniCapture(),
    player: FakeOmniStreamingPlayer(),
    connector: (_) => socket,
    baseUri: Uri.parse('http://127.0.0.1:8080/'),
  );
  await call.refreshAvailability();
  await call.startCall(sessionId: 'session-1');
  await tester.pump();

  final router = GoRouter(
    initialLocation: '/settings',
    routes: [
      GoRoute(
        path: '/settings',
        builder: (context, state) => QiyuShell(
          showOmniCallBar: true,
          child: const Scaffold(body: Text('设置页')),
        ),
      ),
      GoRoute(
        path: '/chat',
        builder: (context, state) => QiyuShell(
          showOmniCallBar: false,
          child: const Scaffold(body: Text('聊天页')),
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LocalChatViewModel>.value(value: viewModel),
        ChangeNotifierProvider<OmniCallController>.value(value: call),
      ],
      child: MaterialApp.router(theme: qiyuDarkTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(call, socket, FakeOmniStreamingPlayer(), gateway);
}

final class _FixedSttGateway implements SttSettingsGateway {
  @override
  Future<SttSettings> read() async => const SttSettings(
    configured: false,
    keySet: false,
  );

  @override
  Future<SttSettings> save(SttSettingsDraft draft) => throw UnimplementedError();

  @override
  Future<SttSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) =>
      throw UnimplementedError();
}
