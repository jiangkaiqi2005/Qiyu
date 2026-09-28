import 'package:flutter/material.dart';

import '../../theme/qiyu_tokens.dart';
import '../navigation.dart';
import '../shell/qiyu_shell.dart';
import '../shell/qiyu_ui_locale.dart';
import 'privacy_strings.dart';

/// 隐私说明页（ticket 23）：数据只在本机、何时调用用户选择的模型
/// 服务、哪些敏感信息永不提升为记忆、日志与诊断统一脱敏。文案与
/// Windows Host 主链路实际行为一一对应。
class PrivacyView extends StatelessWidget {
  const PrivacyView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = PrivacyStrings.of(qiyuIsEn(context));
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: QiyuLayout.pageReadingMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                24,
                QiyuLayout.pageHeaderTopPaddingNoRing,
                24,
                48,
              ),
              children: [
                Row(
                  children: [
                    // 返回箭头何时让位给三条杠由壳判定（窄屏且被壳包住时
                    // 整块不出现），见 [QiyuPageHeaderBackButton]。
                    const QiyuPageHeaderBackButton(
                      buttonKey: Key('privacy-back'),
                    ),
                    Text(strings.title, style: theme.textTheme.headlineSmall),
                  ],
                ),
                const SizedBox(height: 30),
                Text(
                  strings.heading,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  strings.intro,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: 28),
                _PrivacySection(
                  tag: strings.localTag,
                  title: strings.localTitle,
                  body: strings.localBody,
                ),
                _PrivacySection(
                  tag: strings.modelTag,
                  title: strings.modelTitle,
                  body: strings.modelBody,
                ),
                _PrivacySection(
                  tag: strings.memoryTag,
                  title: strings.memoryTitle,
                  body: strings.memoryBody,
                ),
                _PrivacySection(
                  tag: strings.diagnosticsTag,
                  title: strings.diagnosticsTitle,
                  body: strings.diagnosticsBody,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('privacy-back-to-settings'),
                    onPressed: () => backToPrevious(context),
                    child: Text(strings.backToSettings),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PrivacySection extends StatelessWidget {
  const _PrivacySection({
    required this.tag,
    required this.title,
    required this.body,
  });

  final String tag;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  tag,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
