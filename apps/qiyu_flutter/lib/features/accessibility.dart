import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

/// 平台触摸规则独立于窄屏字阶，只用于指定的安卓输入和导航控件。
bool get qiyuAndroidTouch =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

ButtonStyle? get qiyuAndroidTouchStyle => qiyuAndroidTouch
    ? const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      )
    : null;

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
        // Center 必须在 maxWidth 约束**外面**：滚动视口会把比视口窄的子节点
        // 顶到左缘，只有让 Center 占满视口宽度，≤maxWidth 的内容块才会水平
        // 居中；minHeight 仍由外层 ConstrainedBox 保留「短内容垂直居中」。
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - padding.vertical),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// reduced-motion 判定（design-system §9）：Flutter Web 引擎把浏览器的
/// `prefers-reduced-motion: reduce` 映射到 `AccessibilityFeatures
/// .disableAnimations`，`MediaQuery.disableAnimationsOf` 是唯一可靠读数口。
/// 原生平台该位为 false，等价于「按开关走」，不影响动效。
bool qiyuReducedMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);

/// 动效时长统一出口：系统要求减少动态效果时一律 0（关闭全部过渡与渐显），
/// 否则用 token 层给的 150–250ms 档位。本段新增的过渡都必须走这里。
Duration qiyuMotion(BuildContext context, Duration duration) =>
    qiyuReducedMotion(context) ? Duration.zero : duration;
