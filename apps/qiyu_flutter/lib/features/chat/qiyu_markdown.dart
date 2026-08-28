import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../theme/qiyu_tokens.dart';

/// 渲染栖语回复的 Markdown。
///
/// 模型内容可能包含图片语法；本机应用不得因回复内容发起外网请求，
/// 因此图片一律渲染为空占位。用户输入不应使用本组件，应按纯文本展示。
///
/// 字族与行高取紫夜 token：栖语的话是书页式宋体正文，行高 1.9
/// （design-system §3、§7），不跟 UI 常规文字共用同一档行高。
class QiyuMarkdown extends StatelessWidget {
  const QiyuMarkdown({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    return GptMarkdown(
      text,
      style: body?.copyWith(
        fontFamily: QiyuType.fontFamily,
        height: QiyuType.qiyuBodyLineHeight,
      ),
      imageBuilder: (context, url, width, height) => const SizedBox.shrink(),
    );
  }
}
