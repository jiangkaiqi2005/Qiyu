import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'host_stopped_gate.dart';
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
                      Text(hostStoppedGateSituation),
                      SizedBox(height: 8),
                      Text(hostStoppedGateGuidance),
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
