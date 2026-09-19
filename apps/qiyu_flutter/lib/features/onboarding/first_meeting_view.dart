import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../accessibility.dart';
import 'onboarding_view_model.dart';

/// 首见页（称呼定稿 2026-09-03）：在「嗨。我是栖语。」那一页里加一个
/// 可跳过的称呼输入框——只收称呼一项，用栖语的口吻问一句，不做注册
/// 表单。空着点开始就是跳过，之后也可以在记忆中心补设。
class FirstMeetingView extends StatefulWidget {
  const FirstMeetingView({super.key});

  @override
  State<FirstMeetingView> createState() => _FirstMeetingViewState();
}

class _FirstMeetingViewState extends State<FirstMeetingView> {
  final _appellationController = TextEditingController();

  @override
  void dispose() {
    _appellationController.dispose();
    super.dispose();
  }

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
              TextField(
                key: const Key('first-meeting-appellation-input'),
                controller: _appellationController,
                enabled: !viewModel.completing,
                maxLength: 20,
                decoration: const InputDecoration(
                  hintText: '怎么称呼你？',
                  counterText: '',
                ),
                onSubmitted: (_) =>
                    unawaited(_enter(context, viewModel, '/chat')),
              ),
              const SizedBox(height: 8),
              Text(
                '名字、昵称、代号都行；不想说就先跳过。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              if (viewModel.providerConfigured)
                FilledButton(
                  key: const Key('first-meeting-start-chat'),
                  onPressed: viewModel.completing
                      ? null
                      : () => unawaited(_enter(context, viewModel, '/chat')),
                  child: const Text('开始聊天'),
                )
              else ...[
                // 引导优先（ADR 0011）：未配置模型时主按钮导向模型连接，
                // 试聊退为次按钮并如实标注体验差异。
                FilledButton(
                  key: const Key('first-meeting-go-settings'),
                  onPressed: viewModel.completing
                      ? null
                      : () => unawaited(
                          _enter(context, viewModel, '/settings', push: true),
                        ),
                  child: const Text('先去连上模型'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('first-meeting-start-local'),
                  onPressed: viewModel.completing
                      ? null
                      : () => unawaited(_enter(context, viewModel, '/chat')),
                  child: const Text('先聊聊'),
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

  /// 完成引导后跳转：聊天入口走 [context.go]，设置入口走
  /// [context.push]（返回键回首见页）——跳转语义由 [push] 位区分。
  Future<void> _enter(
    BuildContext context,
    OnboardingViewModel viewModel,
    String location, {
    bool push = false,
  }) async {
    final completed = await viewModel.complete(
      appellation: _appellationController.text,
    );
    if (completed && context.mounted) {
      if (push) {
        context.push(location);
      } else {
        context.go(location);
      }
    }
  }
}
