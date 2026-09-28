import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../chat/local_chat_view_model.dart';
import 'qiyu_widgets.dart';
import 'qiyu_ui_locale.dart';

/// 后台记忆整理提示位（ticket 21）：连接状态同区的安静位——同款 6px
/// 小圆点 + 一行 13px 次要字。仅「有失败且未恢复」期间出现，失败着
/// danger（同连接状态失败态）；该任务重试成功时短暂展示「已恢复」再
/// 隐去（停留窗口由视图模型计时），回 muted。不做弹窗、不加导航项，
/// 数据随视图模型既有的连接探测轮询取用，本组件自身零网络调用。
class QiyuBackgroundNotice extends StatelessWidget {
  const QiyuBackgroundNotice({super.key});

  /// 失败未恢复文案（定稿原文，逐字使用，不透内部细节）。
  static const String failureLabel = '今晚的记忆整理没完成，下次会自动补';

  /// 已恢复文案（定稿原文，逐字使用）。
  static const String recoveredLabel = '记忆整理已恢复';

  @override
  Widget build(BuildContext context) {
    // 缺 LocalChatViewModel 时（本页被单独 pump）等同于无失败：安静位
    // 整块不出现。兜底的 try/catch 与导航壳共用 [maybeProvider] 那一处。
    final viewModel = maybeProvider(() => context.watch<LocalChatViewModel>());
    final failure = viewModel?.backgroundFailure;
    final recovered = viewModel?.backgroundRecoveredNotice ?? false;
    if (failure == null && !recovered) {
      return const SizedBox.shrink(key: Key('background-notice-gone'));
    }
    final strings = qiyuStrings(context);
    final label = failure != null
        ? strings.backgroundFailure
        : strings.backgroundRecovered;
    final color = failure != null ? QiyuColors.danger : QiyuColors.muted;
    return Semantics(
      key: const Key('background-notice'),
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: QiyuLayout.navItemPaddingHorizontal,
          vertical: QiyuSpacing.xs,
        ),
        child: Row(
          children: [
            Container(
              width: QiyuLayout.connectionDotSize,
              height: QiyuLayout.connectionDotSize,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: QiyuSpacing.xs),
            Expanded(
              child: Text(
                label,
                key: const Key('background-notice-text'),
                overflow: TextOverflow.ellipsis,
                style: QiyuTypography.of(
                  context,
                ).secondary.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
