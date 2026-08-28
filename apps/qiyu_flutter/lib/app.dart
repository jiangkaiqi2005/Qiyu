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
import 'theme/qiyu_theme.dart';

GoRouter _createRouter() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const RootView()),
    GoRoute(path: '/chat', builder: (context, state) => const LocalChatView()),
    GoRoute(path: '/history', builder: (context, state) => const HistoryView()),
    GoRoute(
      path: '/history/:sessionId',
      builder: (context, state) =>
          HistorySessionView(sessionId: state.pathParameters['sessionId']!),
    ),
    GoRoute(path: '/memory', builder: (context, state) => const MemoryView()),
    GoRoute(
      path: '/memory/item/:itemId',
      builder: (context, state) =>
          MemoryItemView(itemId: state.pathParameters['itemId']!),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const ProviderSettingsView(),
    ),
    GoRoute(
      path: '/settings/diagnostics',
      builder: (context, state) => const DiagnosticsView(),
    ),
    GoRoute(path: '/privacy', builder: (context, state) => const PrivacyView()),
  ],
);

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
  /// 共享栈状态。
  late final GoRouter _router = _createRouter();

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
      theme: qiyuDarkTheme(),
    );
  }
}
