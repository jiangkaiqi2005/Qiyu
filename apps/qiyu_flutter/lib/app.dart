import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'features/chat/local_chat_client.dart';
import 'features/chat/local_chat_view.dart';
import 'features/chat/local_chat_view_model.dart';
import 'features/settings/provider_settings_client.dart';
import 'features/settings/provider_settings_view.dart';
import 'features/settings/provider_settings_view_model.dart';

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const LocalChatView()),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const ProviderSettingsView(),
    ),
  ],
);

class QiyuApp extends StatelessWidget {
  const QiyuApp({super.key, this.viewModel, this.providerSettingsViewModel});

  final LocalChatViewModel? viewModel;
  final ProviderSettingsViewModel? providerSettingsViewModel;

  @override
  Widget build(BuildContext context) {
    final injectedChatViewModel = viewModel;
    final injectedSettingsViewModel = providerSettingsViewModel;
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
