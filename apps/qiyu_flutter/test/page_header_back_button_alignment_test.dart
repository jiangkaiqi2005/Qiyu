import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/history/history_client.dart';
import 'package:qiyu_flutter/features/history/history_view_model.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';
import 'package:qiyu_flutter/features/memory/memory_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_client.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_view_model.dart';

/// 宽视口下历史、记忆中心、设置、隐私四页页头的返回键必须同位。
///
/// 返回键本体四页共用同一个 `QiyuPageHeaderBackButton`；位置由外层页头
/// 决定：挂壳三页（历史/记忆/设置，桌面左侧 240px 侧边栏）必须用同一档
/// 阅读列宽（窄窗口下列宽贴边看不出差异，列居中的宽窗口才会暴露），页头
/// 顶留白与页头 Row 的高度也必须一致——记忆/历史页 Row 右侧按钮带焦点环
/// 常驻占位，Row 被撑高后返回键随居中下移；设置页头无环，差额补进顶留白。
/// 隐私页不挂壳（页内详情自带页内返回），内容列全视口居中，与挂壳页恒差
/// 侧边栏占位 120，是锁定的结构性残差而非缺陷。top 断言四页两两钉死；
/// left 分两层：挂壳三页两两同位，隐私页单独钉残差。列宽或页头几何再出现
/// 漂移，本测试即红。窄视口下 ConstrainedBox 不生效，本就同位，不必断言。
void main() {
  testWidgets('宽视口下四页页头返回键同位（隐私页锁侧边栏残差）', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final memoryViewModel = MemoryCenterViewModel(
      _FixedMemoryGateway(),
      autoStart: false,
    );
    await memoryViewModel.refresh();
    final chatViewModel = LocalChatViewModel(
      _IdleChatGateway(),
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStart: false,
    );
    await chatViewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: chatViewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
        historyViewModel: HistoryViewModel(
          _FixedHistoryGateway(),
          onSessionDeleted: (_) {},
          autoStart: false,
        ),
        memoryViewModel: memoryViewModel,
        providerSettingsViewModel: ProviderSettingsViewModel(
          const _FixedProviderSettingsGateway(),
          autoStart: false,
        ),
        sttSettingsGateway: const _FixedSttSettingsGateway(),
        ttsSettingsGateway: const _FixedTtsSettingsGateway(),
        webSearchSettingsViewModel: WebSearchSettingsViewModel(
          const _FixedWebSearchSettingsGateway(),
          autoStart: false,
        ),
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
      ),
    );
    await tester.pumpAndSettle();

    // 依次经侧边栏导航三页（NoTransitionPage 无过渡，一帧即稳），各自
    // 当场量返回键几何——三页互斥挂载，离开后旧页的键不在树上。隐私页
    // 不在侧边栏导航里（页内详情），直接 go 过去量。
    final backRects = <String, Rect>{};
    for (final page in const ['history', 'memory', 'settings']) {
      await tester.tap(find.byKey(Key('home-go-$page')));
      await tester.pumpAndSettle();
      backRects[page] = tester.getRect(find.byKey(Key('$page-back')));
    }
    GoRouter.of(
      tester.element(find.byKey(const Key('home-go-settings'))),
    ).go('/privacy');
    await tester.pumpAndSettle();
    backRects['privacy'] = tester.getRect(find.byKey(const Key('privacy-back')));

    final historyBack = backRects['history']!;
    final memoryBack = backRects['memory']!;
    final settingsBack = backRects['settings']!;
    final privacyBack = backRects['privacy']!;

    // top：四页两两同位（同一纵向基线）。
    expect(
      settingsBack.top,
      closeTo(historyBack.top, 0.5),
      reason: '设置页返回键上缘应与历史页一致（同一页头几何）',
    );
    expect(
      settingsBack.top,
      closeTo(memoryBack.top, 0.5),
      reason: '设置页返回键上缘应与记忆中心一致（同一页头几何）',
    );
    expect(
      privacyBack.top,
      closeTo(historyBack.top, 0.5),
      reason: '隐私页返回键上缘应与历史页一致（同一页头几何）',
    );
    expect(
      privacyBack.top,
      closeTo(memoryBack.top, 0.5),
      reason: '隐私页返回键上缘应与记忆中心一致（同一页头几何）',
    );
    expect(
      privacyBack.top,
      closeTo(settingsBack.top, 0.5),
      reason: '隐私页返回键上缘应与设置页一致（同一页头几何）',
    );
    expect(
      historyBack.top,
      closeTo(memoryBack.top, 0.5),
      reason: '历史页与记忆中心返回键上缘应一致（同一页头几何）',
    );

    // left：挂壳三页两两同位（同一阅读列宽 + 同一页头左内缩）。
    expect(
      settingsBack.left,
      closeTo(historyBack.left, 0.5),
      reason: '设置页返回键左缘应与历史页一致（同一阅读列宽）',
    );
    expect(
      settingsBack.left,
      closeTo(memoryBack.left, 0.5),
      reason: '设置页返回键左缘应与记忆中心一致（同一阅读列宽）',
    );
    expect(
      historyBack.left,
      closeTo(memoryBack.left, 0.5),
      reason: '历史页与记忆中心返回键左缘应一致（同一阅读列宽）',
    );
    // 隐私页不挂壳、列全视口居中，与挂壳页恒差侧边栏占位 120（240 侧边栏
    // 减去居中分摊），锁此残差防列宽漂移。
    expect(
      privacyBack.left,
      closeTo(settingsBack.left - 120, 0.5),
      reason: '隐私页返回键左缘应与挂壳页恒差侧边栏占位 120',
    );
  });
}

Future<OnboardingViewModel> _completedOnboardingViewModel() async {
  final viewModel = OnboardingViewModel(
    _FakeOnboardingGateway(),
    const _FixedProviderSettingsGateway(),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}

final class _FakeOnboardingGateway implements OnboardingGateway {
  @override
  Future<OnboardingState> read() async =>
      const OnboardingState(completed: true);

  @override
  Future<void> complete() async {}
}

final class _FakeHostConnectionProbe implements HostConnectionProbe {
  _FakeHostConnectionProbe(this._results);

  final List<bool> _results;

  @override
  Future<bool> isHostAvailable() async => _results.first;
}

final class _IdleChatGateway implements StreamingLocalChatGateway {
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

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';
}

final class _FixedHistoryGateway implements HistoryGateway {
  @override
  Future<HistoryListing> fetchHistory() async =>
      const HistoryListing(latestSessionId: null, days: [], unavailable: []);

  @override
  Future<void> deleteSession(String sessionId) async {}
}

final class _FixedMemoryGateway implements MemoryGateway {
  static final MemoryOverview _emptyOverview = MemoryOverview(
    generatedAt: DateTime(2026, 9, 3),
    recent: const MemoryRecentSection(days: []),
    longTerm: const MemoryLongTermSection(
      present: false,
      readable: false,
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
  );

  @override
  Future<MemoryOverview> fetchOverview() async => _emptyOverview;

  @override
  Future<MemoryItemDetail?> fetchItemDetail(String id) =>
      throw UnimplementedError();

  @override
  Future<MemoryActionResult> editItem(String id, String text) =>
      throw UnimplementedError();

  @override
  Future<MemoryActionResult> freezeItem(String id) =>
      throw UnimplementedError();

  @override
  Future<MemoryActionResult> unfreezeItem(String id) =>
      throw UnimplementedError();

  @override
  Future<MemoryActionResult> banItem(String id) => throw UnimplementedError();

  @override
  Future<MemoryActionResult> unbanItem(String id) => throw UnimplementedError();

  @override
  Future<MemoryDeleteImpact?> previewDelete(String id) =>
      throw UnimplementedError();

  @override
  Future<MemoryActionResult> deleteItem(String id) =>
      throw UnimplementedError();

  @override
  Future<MemoryActionResult> revealItem(
    String id, {
    String field = 'content',
  }) => throw UnimplementedError();
}

final class _FixedProviderSettingsGateway implements ProviderSettingsGateway {
  const _FixedProviderSettingsGateway();

  @override
  Future<ProviderSettings> read() async =>
      const ProviderSettings(configured: false, keySet: false);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
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
      const TtsSettings(configured: false, keySet: false, autoSpeak: false);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) => read();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) => read();

  @override
  Future<TtsSettings> forgetApiKey() => read();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      const TtsConnectionTest(succeeded: true, message: '连接成功。');
}

final class _FixedWebSearchSettingsGateway implements WebSearchSettingsGateway {
  const _FixedWebSearchSettingsGateway();

  @override
  Future<WebSearchSettings> read() async =>
      const WebSearchSettings(configured: false, keySet: false);

  @override
  Future<WebSearchSettings> save(WebSearchSettingsDraft draft) async =>
      const WebSearchSettings(configured: false, keySet: false);

  @override
  Future<WebSearchSettings> forgetApiKey() async =>
      const WebSearchSettings(configured: false, keySet: false);
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
    generatedAt: DateTime(2026, 9, 3),
    memoryDirectory: 'C:/qiyu-test/memories',
    recentRequests: const [],
    finalization: const FinalizationHealth(
      today: '2026-09-03',
      todayFinalized: false,
      pendingDays: 0,
      unreadableDays: 0,
    ),
    dream: const DreamHealth(),
    fileHealth: const {},
  );
}
