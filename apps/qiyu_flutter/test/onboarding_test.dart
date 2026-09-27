import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';

import 'support/host_transport.dart';
import 'support/shared_fakes.dart';

void main() {
  test(
    'bootstraps CSRF, reads onboarding state, and completes with headers',
    () async {
      final requests = <http.Request>[];
      final client = hostTransportClient(
        (request) => switch (request.url.path) {
          '/api/onboarding' => hostJsonResponse({'completed': false}, 200),
          '/api/onboarding/complete' => hostJsonResponse({
            'completed': true,
          }, 200),
          _ => http.Response('not found', 404),
        },
        requests: requests,
      );
      final gateway = HttpOnboardingGateway(
        client: client,
        baseUri: Uri.parse('http://127.0.0.1:5173/'),
      );

      final state = await gateway.read();
      expect(state.completed, isFalse);

      await gateway.complete();

      final completeRequest = requests.last;
      expect(completeRequest.method, 'POST');
      expect(completeRequest.url.path, '/api/onboarding/complete');
      expectCsrfHeader(completeRequest);
      expectBootstrapRequestedOnce(requests);

      // 带称呼完成：请求体携带称呼字段；跳过时不携带。
      await gateway.complete(appellation: '凯奇');
      expect(jsonDecode(requests.last.body), {'appellation': '凯奇'});
      await gateway.complete();
      expect(jsonDecode(requests.last.body), <String, Object?>{});
    },
  );

  testWidgets('首见页输入称呼后完成，完成请求带上称呼', (tester) async {
    final onboardingGateway = _FakeOnboardingGateway(completed: false);
    final onboardingViewModel = await _onboardingViewModel(
      onboardingGateway,
      configured: false,
    );
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        onboardingViewModel: onboardingViewModel,
      ),
    );
    await tester.pumpAndSettle();

    // 栖语口吻的一问：不是注册表单。
    expect(find.text('嗨。我是栖语。'), findsOneWidget);
    expect(
      find.byKey(const Key('first-meeting-appellation-input')),
      findsOneWidget,
    );
    expect(find.text('怎么称呼你？'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('first-meeting-appellation-input')),
      '凯奇',
    );
    await tester.tap(find.byKey(const Key('first-meeting-start-local')));
    await tester.pumpAndSettle();

    expect(onboardingGateway.completeCalls, 1);
    expect(onboardingGateway.lastAppellation, '凯奇');
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
  });

  testWidgets('首见页跳过称呼直接完成，完成请求不带称呼', (tester) async {
    final onboardingGateway = _FakeOnboardingGateway(completed: false);
    final onboardingViewModel = await _onboardingViewModel(
      onboardingGateway,
      configured: true,
    );
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        onboardingViewModel: onboardingViewModel,
      ),
    );
    await tester.pumpAndSettle();

    // 不输入任何内容直接开始：与跳过等价。
    await tester.tap(find.byKey(const Key('first-meeting-start-chat')));
    await tester.pumpAndSettle();

    expect(onboardingGateway.completeCalls, 1);
    expect(onboardingGateway.lastAppellation, isNull);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
  });

  testWidgets(
    'a fresh user without a Provider is guided to connect a model first', (
    tester,
  ) async {
    final onboardingGateway = _FakeOnboardingGateway(completed: false);
    final onboardingViewModel = await _onboardingViewModel(
      onboardingGateway,
      configured: false,
    );
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        onboardingViewModel: onboardingViewModel,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('嗨。我是栖语。'), findsOneWidget);
    expect(find.textContaining('鸟归巢'), findsOneWidget);
    expect(find.byKey(const Key('first-meeting-start-chat')), findsNothing);

    // 主按钮导向模型连接，次按钮保留试聊；主次顺序与两处文案都被锁定。
    final goSettings = find.byKey(const Key('first-meeting-go-settings'));
    final startLocal = find.byKey(const Key('first-meeting-start-local'));
    expect(goSettings, findsOneWidget);
    expect(startLocal, findsOneWidget);
    expect(tester.widget(goSettings), isA<FilledButton>());
    expect(tester.widget(startLocal), isA<TextButton>());
    expect(
      tester.getTopLeft(goSettings).dy,
      lessThan(tester.getTopLeft(startLocal).dy),
    );
    expect(find.text('先去连上模型'), findsOneWidget);
    expect(find.text('先聊聊'), findsOneWidget);
    expect(find.text('不连模型也能聊，只是回复会简单一些。'), findsOneWidget);
    // 标注跟着试聊按钮走：只在次按钮下方如实说明体验差异。
    expect(
      tester
          .getTopLeft(find.text('不连模型也能聊，只是回复会简单一些。'))
          .dy,
      greaterThan(tester.getTopLeft(startLocal).dy),
    );

    await tester.tap(find.byKey(const Key('first-meeting-start-local')));
    await tester.pumpAndSettle();

    expect(onboardingGateway.completeCalls, 1);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);

    await _returnToHomeViaDrawer(tester);
  });

  testWidgets(
    'a fresh user with a saved Provider goes straight to chat without config questions',
    (tester) async {
      final onboardingGateway = _FakeOnboardingGateway(completed: false);
      final onboardingViewModel = await _onboardingViewModel(
        onboardingGateway,
        configured: true,
      );
      await tester.pumpWidget(
        QiyuApp(
          viewModel: _chatViewModel(),
          onboardingViewModel: onboardingViewModel,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('嗨。我是栖语。'), findsOneWidget);
      expect(find.byKey(const Key('first-meeting-start-chat')), findsOneWidget);
      expect(find.byKey(const Key('first-meeting-start-local')), findsNothing);
      expect(find.byKey(const Key('first-meeting-go-settings')), findsNothing);

      await tester.tap(find.byKey(const Key('first-meeting-start-chat')));
      await tester.pumpAndSettle();

      expect(onboardingGateway.completeCalls, 1);
      expect(find.byKey(const Key('chat-input')), findsOneWidget);

      await _returnToHomeViaDrawer(tester);
    },
  );

  testWidgets(
    'a returning user skips the first meeting and sees home entries',
    (tester) async {
      final onboardingGateway = _FakeOnboardingGateway(completed: true);
      final onboardingViewModel = await _onboardingViewModel(
        onboardingGateway,
        configured: false,
      );
      await tester.pumpWidget(
        QiyuApp(
          viewModel: _chatViewModel(),
          onboardingViewModel: onboardingViewModel,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('嗨。我是栖语。'), findsNothing);
      // 问候位改由时段问候渲染（首页四张入口卡随合一页退场），断言
      // 强度不变：仍在原位、仍然只有一个。
      expect(find.byKey(const Key('home-greeting')), findsOneWidget);
      expect(find.byKey(const Key('home-go-chat')), findsOneWidget);
      expect(find.byKey(const Key('home-go-history')), findsOneWidget);
      expect(find.byKey(const Key('home-go-settings')), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-go-chat')));
      await tester.pumpAndSettle();

      expect(onboardingGateway.completeCalls, 0);
      expect(find.byKey(const Key('chat-input')), findsOneWidget);

      await _returnToHomeViaDrawer(tester);
    },
  );

  testWidgets('merged home stays in the empty state before today first chat', (
    tester,
  ) async {
    final onboardingGateway = _FakeOnboardingGateway(completed: true);
    final onboardingViewModel = await _onboardingViewModel(
      onboardingGateway,
      configured: false,
    );
    final chatViewModel = LocalChatViewModel(
      _RestoringChatGateway(
        const LocalChatSnapshot(sessionId: 'session-today', messages: []),
      ),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      autoStart: false,
    );
    await chatViewModel.initialize();

    await tester.pumpWidget(
      QiyuApp(
        viewModel: chatViewModel,
        onboardingViewModel: onboardingViewModel,
      ),
    );
    await tester.pumpAndSettle();

    // 今天还没聊过：合一页停在空状态首页（问候 + 夜景背景），不开消息流。
    expect(find.byKey(const Key('home-greeting')), findsOneWidget);
    expect(find.byKey(const Key('home-backdrop')), findsOneWidget);
    expect(find.byKey(const Key('chat-message-0')), findsNothing);
  });

  testWidgets(
    'merged page resumes straight into the chat once today has messages',
    (tester) async {
      final onboardingGateway = _FakeOnboardingGateway(completed: true);
      final onboardingViewModel = await _onboardingViewModel(
        onboardingGateway,
        configured: false,
      );
      final chatViewModel = LocalChatViewModel(
        _RestoringChatGateway(
          const LocalChatSnapshot(
            sessionId: 'session-today',
            messages: [
              LocalChatMessage(
                requestId: 'today-1',
                speaker: LocalChatSpeaker.user,
                text: '今天有点累',
              ),
            ],
          ),
        ),
        hostConnectionProbe: FakeHostConnectionProbe(const [true]),
        autoStart: false,
      );
      await chatViewModel.initialize();

      await tester.pumpWidget(
        QiyuApp(
          viewModel: chatViewModel,
          onboardingViewModel: onboardingViewModel,
        ),
      );
      await tester.pumpAndSettle();

      // 当天已有会话：直接是「已有消息」状态，问候与背景图退场。
      expect(find.text('今天有点累'), findsOneWidget);
      expect(find.byKey(const Key('chat-message-0')), findsOneWidget);
      expect(find.byKey(const Key('home-greeting')), findsNothing);
      expect(find.byKey(const Key('home-backdrop')), findsNothing);
    },
  );

  testWidgets('clearing local product data reopens the first meeting', (
    tester,
  ) async {
    final onboardingGateway = _FakeOnboardingGateway(completed: true);
    final firstRun = await _onboardingViewModel(
      onboardingGateway,
      configured: false,
    );
    await tester.pumpWidget(
      QiyuApp(viewModel: _chatViewModel(), onboardingViewModel: firstRun),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-greeting')), findsOneWidget);

    onboardingGateway.completed = false;
    final afterClear = await _onboardingViewModel(
      onboardingGateway,
      configured: false,
    );
    await tester.pumpWidget(
      QiyuApp(viewModel: _chatViewModel(), onboardingViewModel: afterClear),
    );
    await tester.pumpAndSettle();

    expect(find.text('嗨。我是栖语。'), findsOneWidget);
  });

  testWidgets('choosing the settings path completes the first meeting', (
    tester,
  ) async {
    final onboardingGateway = _FakeOnboardingGateway(completed: false);
    final onboardingViewModel = await _onboardingViewModel(
      onboardingGateway,
      configured: false,
    );
    final settingsViewModel = ProviderSettingsViewModel(
      _FakeProviderSettingsGateway(),
      autoStart: false,
    );
    await settingsViewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        providerSettingsViewModel: settingsViewModel,
        onboardingViewModel: onboardingViewModel,
        settingsViewModel: SettingsViewModel(FakeSettingsGateway()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('first-meeting-go-settings')));
    await tester.pumpAndSettle();

    expect(onboardingGateway.completeCalls, 1);
    expect(find.text('模型连接'), findsOneWidget);
    expect(find.byKey(const Key('provider-preset')), findsOneWidget);
    expect(find.text('官方 API · OpenAI 兼容'), findsOneWidget);

    await tester.tap(find.byTooltip('返回上一页'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-greeting')), findsOneWidget);
  });

  testWidgets(
    'a failed completion keeps the user on the first meeting and shows the error',
    (tester) async {
      final onboardingGateway = _FakeOnboardingGateway(
        completed: false,
        failComplete: true,
      );
      final onboardingViewModel = await _onboardingViewModel(
        onboardingGateway,
        configured: false,
      );
      await tester.pumpWidget(
        QiyuApp(
          viewModel: _chatViewModel(),
          onboardingViewModel: onboardingViewModel,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('first-meeting-start-local')));
      await tester.pumpAndSettle();

      expect(onboardingGateway.completeCalls, 1);
      expect(find.byKey(const Key('chat-input')), findsNothing);
      expect(find.text('嗨。我是栖语。'), findsOneWidget);
      expect(find.byKey(const Key('first-meeting-error')), findsOneWidget);
      expect(find.text('首次见面状态无法保存。'), findsOneWidget);
    },
  );
}

Future<OnboardingViewModel> _onboardingViewModel(
  _FakeOnboardingGateway gateway, {
  required bool configured,
}) async {
  final viewModel = OnboardingViewModel(
    gateway,
    FixedProviderSettingsGateway(configured: configured),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}

LocalChatViewModel _chatViewModel() => LocalChatViewModel(
  FakeLocalChatGateway.silent(),
  hostConnectionProbe: FakeHostConnectionProbe(const [true]),
  autoStart: false,
);

/// 回合一页改走窄屏抽屉：桌面已不设任何「回合一页」入口（2026-08-31 二次
/// 裁定），`go-home` 键只保留在抽屉品牌槽上。切到窄视口开抽屉点品牌槽，
/// 停播 + `go('/')` 的语义不变；抽屉收回后合一页仍可聊。
Future<void> _returnToHomeViaDrawer(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pump();
  await tester.tap(find.byKey(const Key('nav-menu-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('go-home')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('nav-history')), findsNothing, reason: '抽屉收回');
  expect(find.byKey(const Key('chat-input')), findsOneWidget);
}

final class _FakeOnboardingGateway implements OnboardingGateway {
  _FakeOnboardingGateway({required this.completed, this.failComplete = false});

  bool completed;
  bool failComplete;
  var completeCalls = 0;

  /// 最近一次完成请求携带的称呼；null 表示未带（跳过输入）。
  String? lastAppellation;

  @override
  Future<OnboardingState> read() async => OnboardingState(completed: completed);

  @override
  Future<void> complete({String? appellation}) async {
    completeCalls += 1;
    lastAppellation = appellation;
    if (failComplete) {
      throw const OnboardingGatewayException('首次见面状态无法保存。');
    }
    completed = true;
  }
}

final class _FakeProviderSettingsGateway implements ProviderSettingsGateway {
  ProviderSettings current = const ProviderSettings(
    configured: false,
    keySet: false,
  );

  @override
  Future<ProviderSettings> read() async => current;

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async => current;

  @override
  Future<ProviderSettings> forgetApiKey() async => current;

  @override
  Future<ProviderTestResult> testConnection(
    ProviderSettingsDraft draft,
  ) async => const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功，栖语可以使用这个模型。',
  );
}

final class _RestoringChatGateway implements StreamingLocalChatGateway {
  _RestoringChatGateway(this.snapshot);

  final LocalChatSnapshot snapshot;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async => snapshot;

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {}

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<bool> stopVoice(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';
}
