import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'features/baseline/migration_baseline_view.dart';
import 'features/baseline/migration_baseline_view_model.dart';

final _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const MigrationBaselineView(),
    ),
  ],
);

class QiyuApp extends StatelessWidget {
  const QiyuApp({super.key, this.viewModel});

  final MigrationBaselineViewModel? viewModel;

  @override
  Widget build(BuildContext context) {
    final injectedViewModel = viewModel;
    if (injectedViewModel != null) {
      return ChangeNotifierProvider.value(
        value: injectedViewModel,
        child: _buildMaterialApp(),
      );
    }
    return ChangeNotifierProvider(
      create: (_) => MigrationBaselineViewModel(),
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
