import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';

void main() {
  test('bootstraps CSRF, reads onboarding state, and completes with headers', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/onboarding' => _jsonResponse({'completed': false}, 200),
        '/api/onboarding/complete' => _jsonResponse({'completed': true}, 200),
        _ => http.Response('not found', 404),
      };
    });
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
    expect(completeRequest.headers['x-qiyu-csrf'], 'csrf-1');
    expect(
      requests.where((request) => request.url.path == '/api/bootstrap'),
      hasLength(1),
    );
  });

  testWidgets('a fresh user without a Provider chooses local chat first', (
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
    expect(find.byKey(const Key('first-meeting-start-local')), findsOneWidget);
    expect(
      find.byKey(const Key('first-meeting-go-settings')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('first-meeting-start-chat')), findsNothing);
    expect(find.text('不连模型也能聊，只是回复会简单一些。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('first-meeting-start-local')));
    await tester.pumpAndSettle();

    expect(onboardingGateway.completeCalls, 1);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);

    await tester.tap(find.byKey(const Key('go-home')));
    await tester.pumpAndSettle();
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
      expect(
        find.byKey(const Key('first-meeting-start-local')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('first-meeting-go-settings')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('first-meeting-start-chat')));
      await tester.pumpAndSettle();

      expect(onboardingGateway.completeCalls, 1);
      expect(find.byKey(const Key('chat-input')), findsOneWidget);

      await tester.tap(find.byKey(const Key('go-home')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a returning user skips the first meeting and sees home entries', (
    tester,
  ) async {
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
    expect(find.text('回来了。'), findsOneWidget);
    expect(find.byKey(const Key('home-go-chat')), findsOneWidget);
    expect(find.byKey(const Key('home-go-history')), findsOneWidget);
    expect(find.byKey(const Key('home-go-settings')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-go-chat')));
    await tester.pumpAndSettle();

    expect(onboardingGateway.completeCalls, 0);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);

    await tester.tap(find.byKey(const Key('go-home')));
    await tester.pumpAndSettle();
  });

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
    expect(find.text('回来了。'), findsOneWidget);

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
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('first-meeting-go-settings')));
    await tester.pumpAndSettle();

    expect(onboardingGateway.completeCalls, 1);
    expect(find.text('模型连接'), findsOneWidget);
    expect(find.byKey(const Key('provider-base-url')), findsOneWidget);

    await tester.tap(find.byTooltip('返回聊天'));
    await tester.pumpAndSettle();
    expect(find.text('回来了。'), findsOneWidget);
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
    _FixedProviderSettingsGateway(configured: configured),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}

LocalChatViewModel _chatViewModel() => LocalChatViewModel(
  _UnusedChatGateway(),
  hostConnectionProbe: _FakeHostConnectionProbe([true]),
  autoStart: false,
);

http.Response _jsonResponse(Map<String, Object?> body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

final class _FakeOnboardingGateway implements OnboardingGateway {
  _FakeOnboardingGateway({required this.completed, this.failComplete = false});

  bool completed;
  bool failComplete;
  var completeCalls = 0;

  @override
  Future<OnboardingState> read() async =>
      OnboardingState(completed: completed);

  @override
  Future<void> complete() async {
    completeCalls += 1;
    if (failComplete) {
      throw const OnboardingGatewayException('首次见面状态无法保存。');
    }
    completed = true;
  }
}

final class _FixedProviderSettingsGateway implements ProviderSettingsGateway {
  _FixedProviderSettingsGateway({required this.configured});

  final bool configured;

  @override
  Future<ProviderSettings> read() async =>
      ProviderSettings(configured: configured, keySet: configured);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
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
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: true,
        status: ProviderTestStatus.success,
        message: '连接成功，栖语可以使用这个模型。',
      );
}

final class _UnusedChatGateway implements StreamingLocalChatGateway {
  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {}

  @override
  Future<bool> cancel(String requestId) async => true;
}

final class _FakeHostConnectionProbe implements HostConnectionProbe {
  _FakeHostConnectionProbe(this._results);

  final List<bool> _results;
  var _index = 0;

  @override
  Future<bool> isHostAvailable() async {
    final result = _results[_index];
    if (_index < _results.length - 1) {
      _index += 1;
    }
    return result;
  }
}

final class _FakeSettingsGateway implements SettingsGateway {
  @override
  Future<ExperiencePreferences> readPreferences() async =>
      const ExperiencePreferences(developerMode: false);

  @override
  Future<ExperiencePreferences> savePreferences({
    required bool developerMode,
  }) async => ExperiencePreferences(developerMode: developerMode);

  @override
  Future<MemoryControlsOverview> readMemoryControls() async =>
      const MemoryControlsOverview(
        readable: true,
        frozen: [],
        banned: [],
        deletedCount: 0,
      );

  @override
  Future<ClearPreview> readClearPreview() async => const ClearPreview(
    memoryDirectory: 'C:/qiyu-test/memories',
    sessionCount: 0,
    episodeDayCount: 0,
    frozenCount: 0,
    bannedCount: 0,
    deletedCount: 0,
    snapshotCount: 0,
    providerConfigured: false,
    keySet: false,
  );

  @override
  Future<void> clearData() async {}

  @override
  Future<DiagnosticsSnapshot> readDiagnostics() async => DiagnosticsSnapshot(
    generatedAt: DateTime(2026, 8, 19),
    memoryDirectory: 'C:/qiyu-test/memories',
    recentRequests: const [],
    finalization: null,
    dream: null,
    fileHealth: const {},
  );
}
