import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/history/history_client.dart';
import 'package:qiyu_flutter/features/history/history_view.dart';
import 'package:qiyu_flutter/features/history/history_view_model.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';
import 'package:qiyu_flutter/features/memory/memory_view.dart';
import 'package:qiyu_flutter/features/memory/memory_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/diagnostics_view.dart';
import 'package:qiyu_flutter/features/settings/privacy_view.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_client.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_view_model.dart';
import 'package:qiyu_flutter/features/shell/qiyu_shell.dart';

/// 侧边栏切换页面不再整页跳闪（修复的回归守卫）。
///
/// 修复前的病灶：四条挂壳路由（/chat、/history、/memory、/settings）各自在
/// builder 里新建 [QiyuShell]，侧边栏 `go` 一换路由，整个壳的 State 被销毁
/// 重建，壳上的动画随之重放；GoRouter 默认的 MaterialPage 过渡再叠一层整页
/// 淡入滑入。修复把四条挂壳路由收进同一个 ShellRoute：壳 State 跨导航存活，
/// 壳页之间不再有路由过渡。本文件锁住这个结果，并复验导航语义与壳的挂载
/// 范围一项没动。侧边栏页的页内返回键兜底同样不越过壳：落回壳内的
/// `/chat`（与 `/` 渲染同一个合一页），壳不销毁重建。

void main() {
  group('壳页切换的稳定（修复：整页动画跳闪）', () {
    testWidgets('壳的 State 跨壳页导航存活：四条挂壳路由来回切换不销毁重建', (tester) async {
      await _pumpDesktop(tester);

      // 先经侧边栏进第一张挂壳路由，以这只壳的 State 作基线。
      await tester.tap(find.byKey(const Key('home-go-history')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/history');
      final shellState = tester.state<State<QiyuShell>>(find.byType(QiyuShell));

      await tester.tap(find.byKey(const Key('home-go-memory')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/memory');
      expect(find.byType(QiyuShell), findsOneWidget);
      expect(
        tester.state<State<QiyuShell>>(find.byType(QiyuShell)),
        same(shellState),
        reason: '切换到记忆中心不得销毁重建壳',
      );

      await tester.tap(find.byKey(const Key('home-go-settings')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/settings');
      expect(
        tester.state<State<QiyuShell>>(find.byType(QiyuShell)),
        same(shellState),
        reason: '切换到设置不得销毁重建壳',
      );

      // 桌面没有「回合一页」入口，回程这一跳直接走路由。
      GoRouter.of(tester.element(find.byType(QiyuShell))).go('/chat');
      await tester.pumpAndSettle();
      expect(_location(tester), '/chat');
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
      expect(
        tester.state<State<QiyuShell>>(find.byType(QiyuShell)),
        same(shellState),
        reason: '回到对话页不得销毁重建壳',
      );
    });

    testWidgets('侧边栏页的返回键兜底落回壳内合一页：壳 State 不销毁重建', (tester) async {
      await _pumpDesktop(tester);

      // 经侧边栏 go 进记忆中心，栈里没有上一层；记下这只壳的 State 作基线。
      await tester.tap(find.byKey(const Key('home-go-memory')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/memory');
      final shellState = tester.state<State<QiyuShell>>(find.byType(QiyuShell));

      // 兜底走 `/` 会把整只壳销毁重建、再重放一次默认整页过渡（侧边栏页
      // 返回闪白的病根）；落点改为壳内的 `/chat`——与 `/` 渲染同一个合一页。
      await tester.tap(find.byKey(const Key('memory-back')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/chat');
      expect(find.byType(LocalChatView), findsOneWidget);
      expect(
        tester.state<State<QiyuShell>>(find.byType(QiyuShell)),
        same(shellState),
        reason: '返回落回壳内不得销毁重建壳',
      );
    });

    testWidgets('切换时壳层无可观察动画重放：品牌图标与侧边栏矩形逐帧不动', (tester) async {
      await _pumpDesktop(tester);
      await tester.tap(find.byKey(const Key('home-go-history')));
      await tester.pumpAndSettle();

      final brand = find.byKey(const Key('nav-brand'));
      final sidebar = find.byKey(const Key('nav-sidebar-size'));
      final brandRect = tester.getRect(brand);
      final sidebarRect = tester.getRect(sidebar);

      await tester.tap(find.byKey(const Key('home-go-memory')));
      // 切换后的第一帧：树上只有一只壳（不存在淡出淡入的两张整页），
      // 品牌图标与侧边栏停在原位。
      await tester.pump();
      expect(find.byType(QiyuShell), findsOneWidget);
      expect(brand, findsOneWidget, reason: '任何时刻树上只有一只品牌图标');
      expect(tester.getRect(brand), brandRect);
      expect(tester.getRect(sidebar), sidebarRect);

      // 若还有整页过渡，这一帧正处在它的途中：旧页未出、新页带位移进场。
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(QiyuShell), findsOneWidget);
      expect(tester.getRect(brand), brandRect, reason: '切换途中品牌图标不得漂移、重影或重放');
      expect(tester.getRect(sidebar), sidebarRect);

      await tester.pumpAndSettle();
      expect(_location(tester), '/memory');
      expect(tester.getRect(brand), brandRect, reason: '切换落定后仍在原处');
      expect(tester.getRect(sidebar), sidebarRect);
    });

    testWidgets('工具条入口仍是叠栈：推进去的页面仍在壳里，侧边栏全程可见', (tester) async {
      await _pumpDesktop(tester);
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/chat');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('open-history')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/history');
      // 叠栈推进来的历史页不脱离壳：桌面侧边栏（User Story 5）不掉。
      expect(find.byType(QiyuShell), findsOneWidget);
      expect(find.byKey(const Key('nav-history')), findsOneWidget);

      await tester.tap(find.byKey(const Key('history-back')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/chat', reason: '弹出的是刚压上去的那一层');
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
    });

    testWidgets('壳仍只挂四条顶层页，详情子页不挂壳、自带页内返回', (tester) async {
      await _pumpDesktop(tester);
      final router = GoRouter.of(tester.element(find.byType(Scaffold).first));

      for (final destination in const [
        '/chat',
        '/history',
        '/memory',
        '/settings',
      ]) {
        router.go(destination);
        await tester.pumpAndSettle();
        expect(find.byType(QiyuShell), findsOneWidget, reason: destination);
      }

      router.go('/history/session-1');
      await tester.pumpAndSettle();
      expect(find.byType(QiyuShell), findsNothing, reason: '会话详情不挂壳');
      expect(find.byKey(const Key('history-session-back')), findsOneWidget);

      router.go('/memory/item/item-1');
      await tester.pumpAndSettle();
      expect(find.byType(QiyuShell), findsNothing, reason: '记忆详情不挂壳');

      router.go('/settings/diagnostics');
      await tester.pumpAndSettle();
      expect(find.byType(QiyuShell), findsNothing, reason: '诊断页不挂壳');

      router.go('/privacy');
      await tester.pumpAndSettle();
      expect(find.byType(QiyuShell), findsNothing, reason: '隐私页不挂壳');
      expect(find.byKey(const Key('privacy-back')), findsOneWidget);
    });
  });

  group('页内详情进出的稳定（修复：整页动画跳闪）', () {
    // 四条不挂壳的页内详情：(location, 返回键, 视图类型)。
    const detailRoutes = <(String, String, Type)>[
      ('/history/session-1', 'history-session-back', HistorySessionView),
      ('/memory/item/item-1', 'memory-item-back', MemoryItemView),
      ('/settings/diagnostics', 'diagnostics-back', DiagnosticsView),
      ('/privacy', 'privacy-back', PrivacyView),
    ];

    testWidgets('四条详情路由的过渡时长全为零：默认整页过渡无处重放', (tester) async {
      await _pumpDesktop(tester);
      final router = GoRouter.of(tester.element(find.byType(QiyuShell)));

      for (final (location, backKey, _) in detailRoutes) {
        router.push(location);
        await tester.pumpAndSettle();
        final route = ModalRoute.of(tester.element(find.byKey(Key(backKey))));
        expect(route, isNotNull, reason: location);
        expect(
          route!.transitionDuration,
          Duration.zero,
          reason: '$location 进场不得有整页过渡',
        );
        expect(
          route.reverseTransitionDuration,
          Duration.zero,
          reason: '$location 退场不得有整页过渡',
        );

        await tester.tap(find.byKey(Key(backKey)));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('进入详情第一帧即满幅落定：不得处于缩放/淡入途中', (tester) async {
      await _pumpDesktop(tester);
      final router = GoRouter.of(tester.element(find.byType(QiyuShell)));
      final brand = find.byKey(const Key('nav-brand'));
      final brandRect = tester.getRect(brand);

      // push（openInFront 目标不在栈时的生产路径）推进诊断页：过渡的
      // 第一帧就必须是落定态。默认 MaterialPage 过渡第一帧还在缩放淡入
      // 途中，这里判红。
      router.push('/settings/diagnostics');
      await tester.pump();
      final firstFrame = tester.getRect(find.byType(DiagnosticsView));
      await tester.pump(const Duration(milliseconds: 100));
      final midFrame = tester.getRect(find.byType(DiagnosticsView));
      await tester.pumpAndSettle();
      final settled = tester.getRect(find.byType(DiagnosticsView));
      expect(firstFrame, settled, reason: '第一帧必须已落定，不得处于整页过渡途中');
      expect(midFrame, settled, reason: '过渡途中不得有整页位移或缩放');

      await tester.tap(find.byKey(const Key('diagnostics-back')));
      await tester.pumpAndSettle();
      expect(tester.getRect(brand), brandRect, reason: '返回后侧边栏原位');
    });

    testWidgets('点返回键一帧即回壳页：详情页无退场残留，壳层矩形原位', (tester) async {
      await _pumpDesktop(tester);
      final router = GoRouter.of(tester.element(find.byType(QiyuShell)));
      final brand = find.byKey(const Key('nav-brand'));
      final brandRect = tester.getRect(brand);
      final home = _location(tester);

      for (final (location, backKey, viewType) in detailRoutes) {
        router.push(location);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(Key(backKey)));
        await tester.pump();
        expect(
          find.byType(viewType),
          findsNothing,
          reason: '$location 返回第一帧即消失，不得有退场动画残留',
        );
        await tester.pumpAndSettle();
        expect(_location(tester), home, reason: '$location 弹回的是压上去前的壳页');
        expect(tester.getRect(brand), brandRect, reason: '$location 返回后侧边栏原位');
      }
    });
  });
}

// ---------- 装配 ----------

/// 桌面视口 + 全量注入的 QiyuApp：路由走生产 [qiyuRoutes]，四条挂壳路由
/// 都点得动。初见门禁给已完成态，落在合一页。
Future<void> _pumpDesktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(await _app());
  await tester.pumpAndSettle();
}

Future<Widget> _app() async {
  final chatViewModel = LocalChatViewModel(
    _FakeChatGateway(),
    hostConnectionProbe: _FixedProbe(),
    autoStart: false,
  );
  await chatViewModel.initialize();
  final onboarding = OnboardingViewModel(
    _FakeOnboardingGateway(completed: true),
    _FixedProviderGateway(configured: true),
    autoStart: false,
  );
  await onboarding.initialize();
  final providerViewModel = ProviderSettingsViewModel(
    _FixedProviderGateway(configured: true),
    autoStart: false,
  );
  await providerViewModel.initialize();
  return QiyuApp(
    viewModel: chatViewModel,
    providerSettingsViewModel: providerViewModel,
    sttSettingsViewModel: SttSettingsViewModel(
      const _FixedSttSettingsGateway(),
      autoStart: false,
    ),
    ttsSettingsViewModel: TtsSettingsViewModel(
      const _FixedTtsSettingsGateway(),
      autoStart: false,
    ),
    webSearchSettingsViewModel: WebSearchSettingsViewModel(
      const _FixedWebSearchSettingsGateway(),
      autoStart: false,
    ),
    historyViewModel: HistoryViewModel(
      _EmptyHistoryGateway(),
      onSessionDeleted: (_) {},
      autoStart: false,
    ),
    onboardingViewModel: onboarding,
    memoryViewModel: MemoryCenterViewModel(_FakeMemoryGateway()),
    settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
  );
}

/// 当前路由路径：叠栈时最外层可能是壳匹配，当前位置要取到它最里的叶子。
String _location(WidgetTester tester) {
  final matches = GoRouter.of(
    tester.element(find.byType(QiyuShell).last),
  ).routerDelegate.currentConfiguration.matches;
  var last = matches.last;
  while (last is ShellRouteMatch) {
    last = last.matches.last;
  }
  return last.matchedLocation;
}

// ---------- 假网关 ----------

final class _FakeChatGateway implements StreamingLocalChatGateway {
  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {}
}

final class _FixedProbe implements HostConnectionProbe {
  @override
  Future<bool> isHostAvailable() async => true;
}

final class _FakeOnboardingGateway implements OnboardingGateway {
  _FakeOnboardingGateway({required this.completed});

  bool completed;

  @override
  Future<OnboardingState> read() async => OnboardingState(completed: completed);

  @override
  Future<void> complete() async {
    completed = true;
  }
}

final class _EmptyHistoryGateway implements HistoryGateway {
  @override
  Future<HistoryListing> fetchHistory() async =>
      const HistoryListing(latestSessionId: null, days: [], unavailable: []);

  @override
  Future<void> deleteSession(String sessionId) async {}
}

final class _FakeMemoryGateway implements MemoryGateway {
  @override
  Future<MemoryOverview> fetchOverview() async => MemoryOverview(
    generatedAt: DateTime(2026, 8, 19),
    recent: const MemoryRecentSection(days: []),
    longTerm: const MemoryLongTermSection(
      present: false,
      readable: true,
      organizedAt: null,
      groups: [],
    ),
    persona: const MemoryPersonaSection(branches: []),
    relationship: const MemoryRelationshipSection(
      present: false,
      stage: null,
      since: null,
      confirmed: [],
      probes: [],
      recentChanges: [],
      sharedPast: [],
    ),
    recovery: const MemoryRecoverySection(
      healthy: true,
      quarantinedFiles: 0,
      findings: [],
    ),
  );

  @override
  Future<MemoryItemDetail?> fetchItemDetail(String id) async => null;

  @override
  Future<MemoryActionResult> editItem(String id, String text) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已保存。',
      );

  @override
  Future<MemoryActionResult> freezeItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已暂停使用。',
      );

  @override
  Future<MemoryActionResult> unfreezeItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已恢复使用。',
      );

  @override
  Future<MemoryActionResult> banItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已不再提起。',
      );

  @override
  Future<MemoryActionResult> unbanItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已解除禁提。',
      );

  @override
  Future<MemoryDeleteImpact?> previewDelete(String id) async => null;

  @override
  Future<MemoryActionResult> deleteItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已删除。',
      );

  @override
  Future<MemoryActionResult> revealItem(
    String id, {
    String field = 'content',
  }) async => const MemoryActionResult(
    status: MemoryActionStatus.failed,
    message: '无可展示内容。',
  );
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

final class _FixedProviderGateway implements ProviderSettingsGateway {
  _FixedProviderGateway({required this.configured});
  final bool configured;

  @override
  Future<ProviderSettings> read() async => ProviderSettings(
    configured: configured,
    keySet: configured,
    provider: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.example.com/v1',
    model: 'chat-model',
    temperature: 0.7,
    timeoutSeconds: 60,
  );

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async => read();

  @override
  Future<ProviderSettings> forgetApiKey() async => read();

  @override
  Future<ProviderTestResult> testConnection(
    ProviderSettingsDraft draft,
  ) async => const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功。',
  );
}

final class _FixedSttSettingsGateway implements SttSettingsGateway {
  const _FixedSttSettingsGateway();

  @override
  Future<SttSettings> read() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async => SttSettings(
    configured: true,
    keySet: draft.apiKey != null,
    baseUrl: draft.baseUrl,
    model: draft.model,
  );

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

final class _FixedTtsSettingsGateway implements TtsSettingsGateway {
  const _FixedTtsSettingsGateway();

  @override
  Future<TtsSettings> read() async =>
      const TtsSettings(configured: false, keySet: false);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async => TtsSettings(
    configured: true,
    keySet: draft.apiKey != null,
    baseUrl: draft.baseUrl,
    model: draft.model,
  );

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> forgetApiKey() async =>
      const TtsSettings(configured: false, keySet: false);

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      const TtsConnectionTest(succeeded: false, message: '还没有保存语音合成服务配置。');
}

final class _FixedWebSearchSettingsGateway implements WebSearchSettingsGateway {
  const _FixedWebSearchSettingsGateway();

  @override
  Future<WebSearchSettings> read() async =>
      const WebSearchSettings(configured: false, keySet: false);

  @override
  Future<WebSearchSettings> save(WebSearchSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<WebSearchSettings> forgetApiKey() => throw UnimplementedError();
}
