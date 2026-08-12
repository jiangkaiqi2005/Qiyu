import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// 渲染栖语回复的 Markdown。
///
/// 模型内容可能包含图片语法；本机应用不得因回复内容发起外网请求，
/// 因此图片一律渲染为空占位。用户输入不应使用本组件，应按纯文本展示。
class QiyuMarkdown extends StatelessWidget {
  const QiyuMarkdown({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      text,
      style: Theme.of(context).textTheme.bodyMedium,
      imageBuilder: (context, url, width, height) => const SizedBox.shrink(),
    );
  }
}
