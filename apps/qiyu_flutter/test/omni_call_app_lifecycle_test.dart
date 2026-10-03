import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/omni_call_controller.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';

import 'support/omni_call_fakes.dart';
import 'support/shared_fakes.dart';

void main() {
  testWidgets('生产 app 首挂载自动；push/pop/go 同一通，挂断后路由和前后台不重开', (tester) async {
    final gateway = FakeOmniProviderGateway(
      callStartupMode: CallStartupMode.autoOnChatEntry,
    );
    final chat = LocalChatViewModel(
      FakeLocalChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe([true]),
      autoStart: false,
    );
    await chat.initialize();
    final onboarding = OnboardingViewModel(
      FakeOnboardingGateway(completed: true),
      const FixedProviderSettingsGateway(),
      autoStart: false,
    );
    await onboarding.initialize();
    final socket = FakeOmniSocket();
    final capture = FakeOmniCapture();
    final call = OmniCallController(
      surface: chat,
      providerSettings: gateway,
      capture: capture,
      player: FakeOmniStreamingPlayer(),
      connector: (_) => socket,
      autoStartAllowed: () async => true,
    );
    await tester.pumpWidget(
      QiyuApp(
        viewModel: chat,
        onboardingViewModel: onboarding,
        providerSettingsViewModel: ProviderSettingsViewModel(
          gateway,
          autoStart: false,
        ),
        omniCallController: call,
      ),
    );
    await tester.pumpAndSettle();
    expect(socket.decodedFrames.single['type'], 'start');
    socket.emit({'type': 'state', 'phase': 'active'});
    await tester.pumpAndSettle();
    final router = GoRouter.of(
      tester.element(find.byKey(const Key('chat-input'))),
    );
    router.push('/settings');
    await tester.pumpAndSettle();
    expect(call.phase, OmniCallPhase.active);
    router.pop();
    await tester.pumpAndSettle();
    router.go('/settings');
    await tester.pumpAndSettle();
    router.go('/chat');
    await tester.pumpAndSettle();
    expect(socket.decodedFrames, hasLength(1));
    expect(capture.lastSession?.stopped, isFalse);
    await tester.tap(find.byKey(const Key('omni-strip-end')));
    await socket.closeStream();
    await tester.pumpAndSettle();
    expect(call.autoStartSuppressed, isTrue);
    router.go('/settings');
    await tester.pumpAndSettle();
    router.go('/chat');
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      socket.decodedFrames.where((f) => f['type'] == 'start'),
      hasLength(1),
    );
    expect(find.byKey(const Key('omni-call-start')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    call.dispose();
    chat.dispose();
    onboarding.dispose();
  });

  testWidgets('自动启动失败在聊天页提示，电话手动入口与打字仍可用', (tester) async {
    final gateway = FakeOmniProviderGateway(
      callStartupMode: CallStartupMode.autoOnChatEntry,
    );
    final chat = LocalChatViewModel(
      FakeLocalChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe([true]),
      autoStart: false,
    );
    final onboarding = OnboardingViewModel(
      FakeOnboardingGateway(completed: true),
      const FixedProviderSettingsGateway(),
      autoStart: false,
    );
    await onboarding.initialize();
    final call = OmniCallController(
      surface: chat,
      providerSettings: gateway,
      capture: FakeOmniCapture(),
      autoStartAllowed: () async => false,
    );
    await tester.pumpWidget(
      QiyuApp(
        viewModel: chat,
        onboardingViewModel: onboarding,
        omniCallController: call,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('麦克风没有就绪，这次没有开始通话，仍可以打字。'), findsOneWidget);
    expect(find.byKey(const Key('omni-call-start')), findsOneWidget);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    call.dispose();
    chat.dispose();
    onboarding.dispose();
  });
}
