import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../accessibility.dart';

class HomeView extends StatelessWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // 小窗与字号放大时整体可滚动（ticket 24），绝不溢出。
        child: QiyuCenteredScrollable(
          maxWidth: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '回来了。',
                key: const Key('home-greeting'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 32),
              _HomeEntry(
                key: const Key('home-go-chat'),
                icon: Icons.chat_bubble_outline,
                title: '聊天',
                subtitle: '接着上次说',
                onTap: () => context.go('/chat'),
              ),
              _HomeEntry(
                key: const Key('home-go-history'),
                icon: Icons.history,
                title: '历史',
                subtitle: '看看之前说过的',
                onTap: () => context.go('/history'),
              ),
              _HomeEntry(
                key: const Key('home-go-memory'),
                icon: Icons.auto_stories_outlined,
                title: '记忆',
                subtitle: '看看我记得的',
                onTap: () => context.go('/memory'),
              ),
              _HomeEntry(
                key: const Key('home-go-settings'),
                icon: Icons.tune,
                title: '设置',
                subtitle: '模型连接',
                onTap: () => context.go('/settings'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeEntry extends StatelessWidget {
  const _HomeEntry({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: highContrastSide(context),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}
