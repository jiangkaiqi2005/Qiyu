import 'package:flutter/material.dart';

import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import 'qiyu_markdown.dart';

/// 会话气泡：聊天页与历史回看页共用。按 design-system §7 的**单侧气泡**
/// 形态——用户消息右对齐水滴气泡（圆角 20/20/6/20、无描边、面色
/// `bubble-user`），栖语的话**没有气泡**，书页式宋体靠左、行高 1.9。
/// 语义标签带上说话人，屏幕阅读器分得清谁在说（ticket 24）。
class QiyuChatBubble extends StatelessWidget {
  const QiyuChatBubble({
    super.key,
    required this.text,
    required this.fromUser,
    this.isSpeaking = false,
    this.onReplay,
    this.deliveryIndex,
  });

  final String text;
  final bool fromUser;

  /// 这段话正在被朗读（ADR 0002 的「正在朗读」轻量指示）：气泡尾部
  /// 多一行小字与音量图标，读完即消失。
  final bool isSpeaking;

  /// 栖语气泡的重听入口（小喇叭）：点一下立即重读这句（重听=重新
  /// 合成，文字都在）。null（用户气泡、历史回看页）不显示。
  final VoidCallback? onReplay;

  /// 朗读定位序号（同 requestId 内第 N 次交付段）：作重听按钮的可
  /// 访问 key 标识，widget 测试可精确定位。
  final int? deliveryIndex;

  @override
  Widget build(BuildContext context) {
    final content = MergeSemantics(
      child: Semantics(
        label: fromUser ? '你说' : '栖语说',
        child: fromUser
            ? Text(
                text,
                style: QiyuTypography.body.copyWith(color: QiyuColors.ink),
              )
            : QiyuMarkdown(text: text),
      ),
    );
    final body = isSpeaking || onReplay != null
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              content,
              const SizedBox(height: 6),
              if (isSpeaking)
                // 正在读：动效位交给「正在读」文本，此时不叠重听键。
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.volume_up_outlined, size: 16),
                    SizedBox(width: 4),
                    Text('正在读', style: TextStyle(fontSize: 12)),
                  ],
                )
              else if (onReplay != null)
                _ReplayButton(
                  key: Key('chat-replay-$deliveryIndex'),
                  onReplay: onReplay!,
                ),
            ],
          )
        : content;

    if (!fromUser) {
      // 栖语的话：完全没有气泡，靠左，行高 1.9 由 QiyuMarkdown 的字阶给出。
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: QiyuSpacing.sm),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: QiyuLayout.messageMaxWidth,
            ),
            child: body,
          ),
        ),
      );
    }

    // 用户消息：右对齐水滴气泡，靠面色与背景拉开层次，平时不给描边。
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: QiyuSpacing.sm),
        padding: const EdgeInsets.symmetric(
          horizontal: QiyuSpacing.md,
          vertical: QiyuSpacing.sm,
        ),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: QiyuColors.bubbleUser,
          borderRadius: QiyuRadii.bubbleBorder,
          // 高对比模式下面色不再可靠，才补一条可见边（ticket 24）。
          border: Border.fromBorderSide(highContrastSide(context)),
        ),
        child: body,
      ),
    );
  }
}

/// 气泡尾部的重听小喇叭：语义按钮（tooltip 即无障碍名）。
class _ReplayButton extends StatelessWidget {
  const _ReplayButton({super.key, required this.onReplay});

  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      tooltip: '再听一遍这句',
      onPressed: onReplay,
      icon: const Icon(Icons.volume_up_outlined, size: 16),
    );
  }
}
