import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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
  testWidgets(
    'developer diagnostics entry only appears after developer mode is on',
    (tester) async {
      final settingsGateway = _FakeSettingsGateway();
      await tester.pumpWidget(
        await _app(
          settingsViewModel: SettingsViewModel(settingsGateway),
          providerGateway: _FixedProviderSettingsGateway(configured: false),
        ),
      );
      await _openSettings(tester);

      // 默认不打扰普通用户：诊断入口不存在。
      expect(find.byKey(const Key('settings-diagnostics')), findsNothing);
      expect(settingsGateway.developerMode, isFalse);

      // 打开开发者模式后入口出现。
      await tester.scrollUntilVisible(
        find.byKey(const Key('developer-mode-switch')),
        200,
        scrollable: _verticalScrollable(),
        maxScrolls: 20,
      );
      await tester.ensureVisible(find.byKey(const Key('developer-mode-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('developer-mode-switch')));
      await tester.pumpAndSettle();

      expect(settingsGateway.developerMode, isTrue);
      expect(find.byKey(const Key('settings-diagnostics')), findsOneWidget);

      // 进入诊断页：最近请求、后台整理、Dream 资格与文件健康逐区呈现。
      await tester.ensureVisible(find.byKey(const Key('settings-diagnostics')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-diagnostics')));
      await tester.pumpAndSettle();
      expect(find.text('开发者诊断'), findsOneWidget);
      expect(find.textContaining('聊天'), findsWidgets);
      expect(find.textContaining('model_timeout'), findsOneWidget);
      expect(find.textContaining('已回退本地'), findsOneWidget);
      expect(find.textContaining('待补归档 2 天'), findsOneWidget);
      expect(find.textContaining('当前具备资格'), findsOneWidget);
      // 数据位置在页面底部：滚到可见再断言。
      await tester.scrollUntilVisible(
        find.textContaining('C:/qiyu/memories'),
        200,
        scrollable: _verticalScrollable(),
        maxScrolls: 20,
      );
      expect(
        find.textContaining('C:/qiyu/memories'),
        findsAtLeastNWidgets(1),
      );
    },
  );

  testWidgets('memory controls overview lists frozen and banned entries', (
    tester,
  ) async {
    final settingsGateway = _FakeSettingsGateway();
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(settingsGateway),
        providerGateway: _FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-memory-controls')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('settings-memory-controls')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-memory-controls')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('memory-controls-dialog')), findsOneWidget);
    expect(find.textContaining('已冻结（1）'), findsOneWidget);
    expect(find.textContaining('一段冻结的记忆'), findsOneWidget);
    expect(find.textContaining('已禁提（1）'), findsOneWidget);
    expect(find.textContaining('一段禁提的往事'), findsOneWidget);
    expect(find.textContaining('已删除范围：3 条'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-controls-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-controls-dialog')), findsNothing);
  });

  testWidgets('clearing product data previews impact and needs confirmation', (
    tester,
  ) async {
    final onboardingGateway = _ClearableOnboardingGateway();
    // 清除落地的同时初见记录也被清除：重读状态后当次会话重走初见引导。
    final settingsGateway = _FakeSettingsGateway(
      onCleared: () => onboardingGateway.completed = false,
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(settingsGateway),
        providerGateway: _FixedProviderSettingsGateway(configured: false),
        onboardingGateway: onboardingGateway,
      ),
    );
    await _openSettings(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-clear-data')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('settings-clear-data')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-clear-data')));
    await tester.pumpAndSettle();

    // 影响逐条列清。
    expect(find.byKey(const Key('clear-data-dialog')), findsOneWidget);
    expect(find.textContaining('4 段会话'), findsOneWidget);
    expect(find.textContaining('9 天的整理记录'), findsOneWidget);
    expect(find.textContaining('冻结 1、禁提 2'), findsOneWidget);
    expect(find.textContaining('备份快照'), findsWidgets);

    // 取消不执行。
    await tester.tap(find.byKey(const Key('clear-data-cancel')));
    await tester.pumpAndSettle();
    expect(settingsGateway.clearCalls, 0);

    // 再次进入并确认后才真正清除，随后重走初见引导。
    await tester.tap(find.byKey(const Key('settings-clear-data')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear-data-confirm')));
    await tester.pumpAndSettle();
    expect(settingsGateway.clearCalls, 1);
    expect(find.byKey(const Key('first-meeting-greeting')), findsOneWidget);
  });

  testWidgets('forgetting the saved API key needs confirmation', (
    tester,
  ) async {
    final providerGateway = _MutableProviderSettingsGateway();
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: providerGateway,
      ),
    );
    await _openSettings(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('forget-api-key')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('forget-api-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-api-key')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('forget-key-dialog')), findsOneWidget);
    expect(find.textContaining('无法调用模型服务'), findsOneWidget);

    await tester.tap(find.byKey(const Key('forget-key-cancel')));
    await tester.pumpAndSettle();
    expect(providerGateway.forgetCalls, 0);

    await tester.tap(find.byKey(const Key('forget-api-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(providerGateway.forgetCalls, 1);
  });

  testWidgets('privacy page states the local-only boundaries', (
    tester,
  ) async {
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: _FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-privacy')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('settings-privacy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-privacy')));
    await tester.pumpAndSettle();

    expect(find.text('隐私与边界'), findsWidgets);
    expect(find.textContaining('数据只保存在你的电脑上'), findsOneWidget);

    // 页面较长逐段滚动断言；危机输入绝不发给模型是必须讲清的边界。
    await tester.scrollUntilVisible(
      find.textContaining('何时调用你选择的模型服务'),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    expect(find.textContaining('何时调用你选择的模型服务'), findsOneWidget);
    expect(find.textContaining('绝不发送给模型'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('永远不会被提升为记忆'),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    expect(find.textContaining('永远不会被提升为记忆'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('日志与诊断统一脱敏'),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    expect(find.textContaining('日志与诊断统一脱敏'), findsOneWidget);
  });
}

Future<Widget> _app({
  required SettingsViewModel settingsViewModel,
  required ProviderSettingsGateway providerGateway,
  OnboardingGateway? onboardingGateway,
}) async {
  final providerViewModel = ProviderSettingsViewModel(
    providerGateway,
    autoStart: false,
  );
  await providerViewModel.initialize();
  final onboardingViewModel = OnboardingViewModel(
    onboardingGateway ?? _CompletedOnboardingGateway(),
    _FixedProviderSettingsGateway(configured: true),
    autoStart: false,
  );
  await onboardingViewModel.initialize();
  return QiyuApp(
    viewModel: LocalChatViewModel(
      _UnusedChatGateway(),
      hostConnectionProbe: _FixedHostConnectionProbe(),
      autoStart: false,
    ),
    providerSettingsViewModel: providerViewModel,
    onboardingViewModel: onboardingViewModel,
    settingsViewModel: settingsViewModel,
  );
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.pumpAndSettle();
  // 全局 GoRouter 跨用例保留栈：先强制回到首页再进入设置。
  final context = tester.element(find.byType(Scaffold).first);
  GoRouter.of(context).go('/');
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('home-go-settings')));
  await tester.pumpAndSettle();
}

Finder _verticalScrollable() => find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down,
);

final class _FakeSettingsGateway implements SettingsGateway {
  _FakeSettingsGateway({this.onCleared});

  bool developerMode = false;
  int clearCalls = 0;

  /// 清除成功时的回调：测试用它同步翻转初见网关状态。
  final void Function()? onCleared;

  @override
  Future<ExperiencePreferences> readPreferences() async =>
      ExperiencePreferences(developerMode: developerMode);

  @override
  Future<ExperiencePreferences> savePreferences({
    required bool developerMode,
  }) async {
    this.developerMode = developerMode;
    return ExperiencePreferences(developerMode: developerMode);
  }

  @override
  Future<MemoryControlsOverview> readMemoryControls() async =>
      const MemoryControlsOverview(
        readable: true,
        frozen: [
          MemoryControlRecord(id: 1, origin: 'chat', summary: '一段冻结的记忆'),
        ],
        banned: [
          MemoryControlRecord(id: 2, origin: 'chat', summary: '一段禁提的往事'),
        ],
        deletedCount: 3,
      );

  @override
  Future<ClearPreview> readClearPreview() async => const ClearPreview(
    memoryDirectory: 'C:/qiyu/memories',
    sessionCount: 4,
    episodeDayCount: 9,
    frozenCount: 1,
    bannedCount: 2,
    deletedCount: 0,
    snapshotCount: 1,
    providerConfigured: false,
    keySet: false,
  );

  @override
  Future<void> clearData() async {
    clearCalls += 1;
    onCleared?.call();
  }

  @override
  Future<DiagnosticsSnapshot> readDiagnostics() async => DiagnosticsSnapshot(
    generatedAt: DateTime.parse('2026-08-19T14:00:00.000Z'),
    memoryDirectory: 'C:/qiyu/memories',
    recentRequests: [
      RecentRequest(
        at: DateTime.parse('2026-08-19T13:59:00.000Z'),
        source: 'chat',
        result: 'fallback',
        replySource: 'local',
        fallbackReason: 'model_timeout',
      ),
    ],
    finalization: const FinalizationHealth(
      today: '2026-08-19',
      todayFinalized: false,
      pendingDays: 2,
      unreadableDays: 0,
    ),
    dream: DreamHealth(
      lastSuccessAt: DateTime.parse('2026-08-11T16:00:00.000Z'),
      daysSinceLastSuccess: 8,
      pending: false,
      minIntervalDays: 7,
      intervalSatisfied: true,
      providerConfigured: true,
      eligible: true,
    ),
    fileHealth: const {
      'sessionsReadable': 4,
      'sessionsUnavailable': 0,
      'episodeDays': 9,
      'episodeUnfinalized': 2,
      'episodeUnreadable': 0,
    },
  );
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

final class _MutableProviderSettingsGateway implements ProviderSettingsGateway {
  var keySet = true;
  int forgetCalls = 0;

  @override
  Future<ProviderSettings> read() async => ProviderSettings(
    configured: true,
    keySet: keySet,
    provider: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.example.com/v1',
    model: 'chat-model',
    temperature: 0.7,
    timeoutSeconds: 60,
  );

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async => read();

  @override
  Future<ProviderSettings> forgetApiKey() async {
    forgetCalls += 1;
    keySet = false;
    return read();
  }

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: true,
        status: ProviderTestStatus.success,
        message: '连接成功，栖语可以使用这个模型。',
      );
}

final class _CompletedOnboardingGateway extends _ClearableOnboardingGateway {}

/// 初见状态可翻转：清除产品数据测试用它模拟初见记录被一并清除。
class _ClearableOnboardingGateway implements OnboardingGateway {
  bool completed = true;

  @override
  Future<OnboardingState> read() async => OnboardingState(completed: completed);

  @override
  Future<void> complete() async {
    completed = true;
  }
}

final class _FixedHostConnectionProbe implements HostConnectionProbe {
  @override
  Future<bool> isHostAvailable() async => true;
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
