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
import 'features/settings/provider_settings_client.dart';
import 'features/settings/provider_settings_view.dart';
import 'features/settings/provider_settings_view_model.dart';

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const LocalChatView()),
    GoRoute(
      path: '/history',
      builder: (context, state) => const HistoryView(),
    ),
    GoRoute(
      path: '/history/:sessionId',
      builder: (context, state) =>
          HistorySessionView(sessionId: state.pathParameters['sessionId']!),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const ProviderSettingsView(),
    ),
  ],
);

class QiyuApp extends StatelessWidget {
  const QiyuApp({
    super.key,
    this.viewModel,
    this.providerSettingsViewModel,
    this.historyViewModel,
  });

  final LocalChatViewModel? viewModel;
  final ProviderSettingsViewModel? providerSettingsViewModel;
  final HistoryViewModel? historyViewModel;

  @override
  Widget build(BuildContext context) {
    final injectedChatViewModel = viewModel;
    final injectedSettingsViewModel = providerSettingsViewModel;
    final injectedHistoryViewModel = historyViewModel;
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
      ),
    );
  }
}
