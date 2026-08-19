import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../accessibility.dart';
import 'onboarding_view_model.dart';

class FirstMeetingView extends StatelessWidget {
  const FirstMeetingView({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<OnboardingViewModel>();
    return Scaffold(
      body: SafeArea(
        // 小窗与字号放大时整体可滚动（ticket 24），绝不溢出。
        child: QiyuCenteredScrollable(
          maxWidth: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '嗨。我是栖语。',
                key: const Key('first-meeting-greeting'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              Text(
                '栖，是鸟归巢的栖。\n睡不着的时候，可以跟我说说话。',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 40),
              if (viewModel.providerConfigured)
                FilledButton(
                  key: const Key('first-meeting-start-chat'),
                  onPressed: viewModel.completing
                      ? null
                      : () => unawaited(_enter(context, viewModel, '/chat')),
                  child: const Text('开始聊天'),
                )
              else ...[
                FilledButton(
                  key: const Key('first-meeting-start-local'),
                  onPressed: viewModel.completing
                      ? null
                      : () => unawaited(_enter(context, viewModel, '/chat')),
                  child: const Text('先聊聊'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('first-meeting-go-settings'),
                  onPressed: viewModel.completing
                      ? null
                      : () => unawaited(
                          _enterSettings(context, viewModel),
                        ),
                  child: const Text('先去连上模型'),
                ),
                const SizedBox(height: 8),
                Text(
                  '不连模型也能聊，只是回复会简单一些。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (viewModel.completeError case final message?) ...[
                const SizedBox(height: 16),
                Text(
                  message,
                  key: const Key('first-meeting-error'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _enter(
    BuildContext context,
    OnboardingViewModel viewModel,
    String location,
  ) async {
    final completed = await viewModel.complete();
    if (completed && context.mounted) {
      context.go(location);
    }
  }

  Future<void> _enterSettings(
    BuildContext context,
    OnboardingViewModel viewModel,
  ) async {
    final completed = await viewModel.complete();
    if (completed && context.mounted) {
      context.push('/settings');
    }
  }
}
