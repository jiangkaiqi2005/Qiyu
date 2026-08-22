import 'package:flutter/material.dart';

import '../accessibility.dart';
import 'qiyu_markdown.dart';

/// 会话气泡：聊天页与历史回看页共用。用户输入按纯文本靠右展示；
/// 栖语回复来自模型，按 Markdown 靠左渲染。语义标签带上说话人，
/// 屏幕阅读器分得清谁在说（ticket 24）。
class QiyuChatBubble extends StatelessWidget {
  const QiyuChatBubble({super.key, required this.text, required this.fromUser});

  final String text;
  final bool fromUser;

  @override
  Widget build(BuildContext context) {
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
        child: MergeSemantics(
          child: Semantics(
            label: fromUser ? '你说' : '栖语说',
            child: fromUser ? Text(text) : QiyuMarkdown(text: text),
          ),
        ),
      ),
    );
  }
}
