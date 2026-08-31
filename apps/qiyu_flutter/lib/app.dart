import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'features/chat/local_chat_client.dart';
import 'features/chat/local_chat_view.dart';
import 'features/chat/local_chat_view_model.dart';
import 'features/history/history_client.dart';
import 'features/history/history_view.dart';
import 'features/history/history_view_model.dart';
import 'features/memory/memory_client.dart';
import 'features/memory/memory_view.dart';
import 'features/memory/memory_view_model.dart';
import 'features/onboarding/onboarding_client.dart';
import 'features/onboarding/onboarding_view_model.dart';
import 'features/onboarding/root_view.dart';
import 'features/settings/diagnostics_view.dart';
import 'features/settings/privacy_view.dart';
import 'features/settings/provider_settings_client.dart';
import 'features/settings/provider_settings_view.dart';
import 'features/settings/provider_settings_view_model.dart';
import 'features/settings/settings_client.dart';
import 'features/settings/settings_view_model.dart';
import 'features/settings/stt_settings_client.dart';
import 'features/settings/tts_settings_client.dart';
import 'features/settings/stt_settings_view_model.dart';
import 'features/settings/tts_settings_view_model.dart';
import 'features/settings/web_search_settings_client.dart';
import 'features/settings/web_search_settings_view_model.dart';
import 'features/shell/qiyu_shell.dart';
import 'features/accessibility.dart';
import 'theme/qiyu_theme.dart';

/// 生产路由表（9 条路径）：路径集合是行为不变量（Spec Implementation
/// Decisions 第 18 条），一条都没动。
///
/// 本表**公开**是为了测试能对着真实配置断言（路径集合、壳挂在哪些路由上），
/// 而不是在测试里另抄一份然后验自己抄的那份。
///
/// 四条挂壳路由（/chat、/history、/memory、/settings）收在同一个 [ShellRoute]
/// 下：[QiyuShell] 挂在这一层，不再由每条路由各自新建——四项顶层页因此始终
/// 挂着同一只壳（User Story 5：桌面端始终看得到侧边栏，导航选中态也才真的
/// 成立），侧边栏 `go` 在四页之间切换时只换壳下的内容页，壳的 State 跨导航
/// 存活，侧边栏、品牌图标与背景不随路由替换重放进场动画；壳页自身与壳下内容
/// 页都走 [NoTransitionPage]，切换不带整页过渡（壳页之间的过渡是「整页跳闪」
/// 的另一半病灶）。导航语义一项不动：侧边栏与抽屉仍是 `go`，聊天页工具条仍是
/// `push`（推进来的页面仍留在壳里），页内详情沿用既有 `openInFront`。
///
/// 页内详情（某一天、某条记忆、诊断、隐私）仍是自己的页面：不挂壳、自带
/// 页内返回，也保留各自的默认路由过渡（不在壳页之列）。
///
/// 紫夜改造后的「合一页」不落在新路由上：`/` 与 `/chat` 渲染**同一个**由
/// [QiyuShell] 包住的对话视图——`/` 前头仍压着 [RootView] 的初见门禁（门禁
/// 放行后由它自己挂壳），`/chat` 直接进对话态。
List<RouteBase> qiyuRoutes() => [
  GoRoute(path: '/', builder: (context, state) => const RootView()),
  ShellRoute(
    pageBuilder: (context, state, navigationShell) => NoTransitionPage<void>(
      key: state.pageKey,
      child: QiyuShell(
        showHomeBackdrop: state.matchedLocation == '/chat',
        child: navigationShell,
      ),
    ),
    routes: [
      GoRoute(
        path: '/chat',
        pageBuilder: (context, state) => NoTransitionPage<void>(
          key: state.pageKey,
          child: const LocalChatView(),
        ),
      ),
      GoRoute(
        path: '/history',
        pageBuilder: (context, state) => NoTransitionPage<void>(
          key: state.pageKey,
          child: const HistoryView(),
        ),
      ),
      GoRoute(
        path: '/memory',
        pageBuilder: (context, state) => NoTransitionPage<void>(
          key: state.pageKey,
          child: const MemoryView(),
        ),
      ),
      GoRoute(
        path: '/settings',
        pageBuilder: (context, state) => NoTransitionPage<void>(
          key: state.pageKey,
          child: const ProviderSettingsView(),
        ),
      ),
    ],
  ),
  GoRoute(
    path: '/history/:sessionId',
    builder: (context, state) =>
        HistorySessionView(sessionId: state.pathParameters['sessionId']!),
  ),
  GoRoute(
    path: '/memory/item/:itemId',
    builder: (context, state) =>
        MemoryItemView(itemId: state.pathParameters['itemId']!),
  ),
  GoRoute(
    path: '/settings/diagnostics',
    builder: (context, state) => const DiagnosticsView(),
  ),
  GoRoute(path: '/privacy', builder: (context, state) => const PrivacyView()),
];

class QiyuApp extends StatefulWidget {
  const QiyuApp({
    super.key,
    this.viewModel,
    this.providerSettingsViewModel,
    this.sttSettingsViewModel,
    this.sttSettingsGateway,
    this.ttsSettingsViewModel,
    this.ttsSettingsGateway,
    this.webSearchSettingsViewModel,
    this.historyViewModel,
    this.onboardingViewModel,
    this.memoryViewModel,
    this.settingsViewModel,
  });

  final LocalChatViewModel? viewModel;
  final ProviderSettingsViewModel? providerSettingsViewModel;
  final SttSettingsViewModel? sttSettingsViewModel;

  /// 语音服务设置网关：缺省由 [_QiyuAppState] 持有单例，聊天页与设置
  /// 页共享同一实例（bootstrap 的 CSRF 只换一次）；测试注入桩。
  final SttSettingsGateway? sttSettingsGateway;
  final TtsSettingsViewModel? ttsSettingsViewModel;

  /// 语音朗读设置网关：同上，缺省共享单例；测试注入桩。
  final TtsSettingsGateway? ttsSettingsGateway;
  final WebSearchSettingsViewModel? webSearchSettingsViewModel;
  final HistoryViewModel? historyViewModel;
  final OnboardingViewModel? onboardingViewModel;
  final MemoryCenterViewModel? memoryViewModel;
  final SettingsViewModel? settingsViewModel;

  @override
  State<QiyuApp> createState() => _QiyuAppState();
}

class _QiyuAppState extends State<QiyuApp> {
  /// 每个应用实例持有独立路由：返回键依赖真实导航栈，测试之间不得
  /// 共享栈状态。路由表读 [qiyuRoutes]，不再有第二份副本。
  late final GoRouter _router = GoRouter(routes: qiyuRoutes());

  /// 未注入时的共享 STT 设置网关：聊天页的 configured 探测与设置页的
  /// 读写共用同一实例，CSRF 不重复换取。
  late final SttSettingsGateway _defaultSttGateway = HttpSttSettingsGateway();

  SttSettingsGateway get _effectiveSttGateway =>
      widget.sttSettingsGateway ?? _defaultSttGateway;

  /// 未注入时的共享 TTS 设置网关：同 STT。
  late final TtsSettingsGateway _defaultTtsGateway = HttpTtsSettingsGateway();

  TtsSettingsGateway get _effectiveTtsGateway =>
      widget.ttsSettingsGateway ?? _defaultTtsGateway;

  @override
  Widget build(BuildContext context) {
    final injectedChatViewModel = widget.viewModel;
    final injectedSettingsViewModel = widget.providerSettingsViewModel;
    final injectedSttSettingsViewModel = widget.sttSettingsViewModel;
    final injectedTtsSettingsViewModel = widget.ttsSettingsViewModel;
    final injectedWebSearchSettingsViewModel =
        widget.webSearchSettingsViewModel;
    final injectedHistoryViewModel = widget.historyViewModel;
    final injectedOnboardingViewModel = widget.onboardingViewModel;
    final injectedMemoryViewModel = widget.memoryViewModel;
    final injectedAppSettingsViewModel = widget.settingsViewModel;
    return MultiProvider(
      providers: [
        Provider<SttSettingsGateway>.value(value: _effectiveSttGateway),
        Provider<TtsSettingsGateway>.value(value: _effectiveTtsGateway),
        if (injectedChatViewModel != null)
          ChangeNotifierProvider.value(value: injectedChatViewModel)
        else
          ChangeNotifierProvider(
            create: (context) => LocalChatViewModel(
              HttpLocalChatGateway(),
              ttsSettingsGateway: context.read<TtsSettingsGateway>(),
            ),
          ),
        if (injectedSettingsViewModel != null)
          ChangeNotifierProvider.value(value: injectedSettingsViewModel)
        else
          ChangeNotifierProvider(
            create: (_) => ProviderSettingsViewModel(
              HttpProviderSettingsGateway(),
              autoStart: false,
            ),
          ),
        if (injectedSttSettingsViewModel != null)
          ChangeNotifierProvider.value(value: injectedSttSettingsViewModel)
        else
          ChangeNotifierProvider(
            create: (context) => SttSettingsViewModel(
              context.read<SttSettingsGateway>(),
              autoStart: false,
            ),
          ),
        if (injectedTtsSettingsViewModel != null)
          ChangeNotifierProvider.value(value: injectedTtsSettingsViewModel)
        else
          ChangeNotifierProvider(
            create: (context) => TtsSettingsViewModel(
              context.read<TtsSettingsGateway>(),
              autoStart: false,
            ),
          ),
        if (injectedWebSearchSettingsViewModel != null)
          ChangeNotifierProvider.value(
            value: injectedWebSearchSettingsViewModel,
          )
        else
          ChangeNotifierProvider(
            create: (_) => WebSearchSettingsViewModel(
              HttpWebSearchSettingsGateway(),
              autoStart: false,
            ),
          ),
        if (injectedHistoryViewModel != null)
          ChangeNotifierProvider.value(value: injectedHistoryViewModel)
        else
          ChangeNotifierProvider(
            create: (context) => HistoryViewModel(
              HttpHistoryGateway(),
              onSessionDeleted: (sessionId) => unawaited(
                context.read<LocalChatViewModel>().discardSession(sessionId),
              ),
            ),
          ),
        if (injectedOnboardingViewModel != null)
          ChangeNotifierProvider.value(value: injectedOnboardingViewModel)
        else
          ChangeNotifierProvider(
            create: (_) => OnboardingViewModel(
              HttpOnboardingGateway(),
              HttpProviderSettingsGateway(),
            ),
          ),
        if (injectedMemoryViewModel != null)
          ChangeNotifierProvider.value(value: injectedMemoryViewModel)
        else
          ChangeNotifierProvider(
            create: (_) => MemoryCenterViewModel(HttpMemoryGateway()),
          ),
        if (injectedAppSettingsViewModel != null)
          ChangeNotifierProvider.value(value: injectedAppSettingsViewModel)
        else
          ChangeNotifierProvider(
            create: (_) => SettingsViewModel(HttpSettingsGateway()),
          ),
      ],
      child: _buildMaterialApp(),
    );
  }

  MaterialApp _buildMaterialApp() {
    return MaterialApp.router(
      title: '栖语',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      // 紫夜主题：色板、字族、几何与组件主题全部来自 token 层
      // （lib/theme/qiyu_tokens.dart），这里不再写任何视觉值。
      //
      // **全应用只有 builder 这一份生效主题**：reduced-motion 要盖住全部过渡
      // （design-system §9），而路由过渡与 ink ripple 都长在 ThemeData 上、
      // 主题层拿不到 MediaQuery，所以只能在 MediaQuery 已可用的这一层读系统
      // 读数，按它建一份主题往下发。`MaterialApp.theme` 因此留空——在那儿
      // 再写一份 `qiyuDarkTheme()` 会在 builder 的 Theme 处被整个覆盖，
      // 只是白建一份永远不生效的 ThemeData。
      builder: (context, child) => Theme(
        data: qiyuDarkTheme(reduceMotion: qiyuReducedMotion(context)),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
