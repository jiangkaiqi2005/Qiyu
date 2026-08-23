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
  });

  final String text;
  final bool fromUser;

  /// 这段话正在被朗读（ADR 0002 的「正在朗读」轻量指示）：气泡尾部
  /// 多一行小字与音量图标，读完即消失。
  final bool isSpeaking;

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
        child: isSpeaking
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  content,
                  const SizedBox(height: 6),
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.volume_up_outlined, size: 16),
                      SizedBox(width: 4),
                      Text('正在读', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ],
              )
            : content,
      ),
    );
  }
}
