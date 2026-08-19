import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 无障碍共享工具（ticket 24）：高对比模式可见边界与「小窗/字号
/// 放大绝不溢出」的居中可滚动布局。

/// 高对比模式（Windows 强制颜色等）下背景色不再可靠，依赖底色区分
/// 的块级容器需要可见边框；普通模式返回 [BorderSide.none]。
BorderSide highContrastSide(BuildContext context) {
  if (!MediaQuery.highContrastOf(context)) {
    return BorderSide.none;
  }
  return BorderSide(color: Theme.of(context).colorScheme.outline);
}

/// 居中可滚动容器：窗口足够时内容居中，窗口变小或字号放大时整体可
/// 滚动，绝不产生 RenderFlex 溢出。首页与初见页这类非列表页使用。
class QiyuCenteredScrollable extends StatelessWidget {
  const QiyuCenteredScrollable({
    super.key,
    required this.maxWidth,
    required this.child,
    this.padding = const EdgeInsets.all(32),
  });

  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              minHeight: math.max(0, constraints.maxHeight - padding.vertical),
            ),
            child: Center(child: child),
          ),
        );
      },
    );
  }
}
