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

GoRouter _createRouter() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const RootView()),
    GoRoute(path: '/chat', builder: (context, state) => const LocalChatView()),
    GoRoute(
      path: '/history',
      builder: (context, state) => const HistoryView(),
    ),
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
    GoRoute(
      path: '/privacy',
      builder: (context, state) => const PrivacyView(),
    ),
  ],
);

class QiyuApp extends StatefulWidget {
  const QiyuApp({
    super.key,
    this.viewModel,
    this.providerSettingsViewModel,
    this.historyViewModel,
    this.onboardingViewModel,
    this.memoryViewModel,
    this.settingsViewModel,
  });

  final LocalChatViewModel? viewModel;
  final ProviderSettingsViewModel? providerSettingsViewModel;
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

  @override
  Widget build(BuildContext context) {
    final injectedChatViewModel = widget.viewModel;
    final injectedSettingsViewModel = widget.providerSettingsViewModel;
    final injectedHistoryViewModel = widget.historyViewModel;
    final injectedOnboardingViewModel = widget.onboardingViewModel;
    final injectedMemoryViewModel = widget.memoryViewModel;
    final injectedAppSettingsViewModel = widget.settingsViewModel;
    return MultiProvider(
      providers: [
        if (injectedChatViewModel != null)
          ChangeNotifierProvider.value(value: injectedChatViewModel)
        else
          ChangeNotifierProvider(
            create: (_) => LocalChatViewModel(HttpLocalChatGateway()),
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
      theme: ThemeData(
        fontFamily: 'Noto Sans SC',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8C86B8),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF15131A),
        useMaterial3: true,
        // 键盘焦点高亮在深色底上必须清晰可见，对比度留足余量（ticket 24）。
        focusColor: const Color(0x80CFC8F5),
      ),
    );
  }
}
