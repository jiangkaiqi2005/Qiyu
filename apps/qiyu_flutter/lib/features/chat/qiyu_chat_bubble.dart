import 'package:flutter/material.dart';

import '../accessibility.dart';
import 'qiyu_markdown.dart';

/// 会话气泡：聊天页与历史回看页共用。用户输入按纯文本靠右展示；
/// 栖语回复来自模型，按 Markdown 靠左渲染。语义标签带上说话人，
/// 屏幕阅读器分得清谁在说（ticket 24）。
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

  /// 栖语气泡的重听入口（小喇叭）：点击立即重读这句话（重听=重新
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
        child: fromUser ? Text(text) : QiyuMarkdown(text: text),
      ),
    );
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: fromUser
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
          border: Border.fromBorderSide(highContrastSide(context)),
        ),
        child: isSpeaking || onReplay != null
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
            : content,
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
