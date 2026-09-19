import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'migration_baseline_view_model.dart';

class MigrationBaselineView extends StatelessWidget {
  const MigrationBaselineView({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<MigrationBaselineViewModel>();

    return Scaffold(
      body: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('栖语', style: Theme.of(context).textTheme.displaySmall),
                    const SizedBox(height: 20),
                    Text(
                      '迁移基线已就绪',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      viewModel.checkBehaviorCore()
                          ? '纯 Dart 行为核心已连接'
                          : '行为核心启动前检查失败',
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (viewModel.hostStopped)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('栖语本机程序未在运行或已更新。'),
                      SizedBox(height: 8),
                      Text('请在电脑上重新启动栖语，然后刷新这个页面。'),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
