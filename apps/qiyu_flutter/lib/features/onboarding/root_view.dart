import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../chat/local_chat_view.dart';
import '../shell/qiyu_shell.dart';
import 'first_meeting_view.dart';
import 'onboarding_view_model.dart';

/// 应用根：只见面的门禁压在最前，放行后就是**合一页**——导航壳包住的
/// 对话视图，空状态即首页（design-system §5）。旧首页的四张入口卡已
/// 废弃，导航职责交给侧边栏与抽屉。
class RootView extends StatelessWidget {
  const RootView({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<OnboardingViewModel>();
    if (viewModel.loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }
    if (viewModel.errorMessage case final message?) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('retry-root'),
                  onPressed: () => unawaited(viewModel.initialize()),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return viewModel.completed
        ? const QiyuShell(
            // 空状态首页的夜景背景由壳铺成**全幅底层**（不被侧边栏切断），
            // 侧边栏/抽屉的玻璃层才有内容可糊。
            showHomeBackdrop: true,
            child: LocalChatView(),
          )
        : const FirstMeetingView();
  }
}
