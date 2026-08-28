import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/qiyu_tokens.dart';

/// 紫夜薄包装层（design-system §8 组件清单的 M3 底子 + token 换皮）：
/// 毛玻璃面板与自绘键盘焦点环。侧边栏、抽屉、composer、发送钮共用同一
/// 份实现，保证「材质同源」，页面不得再各自抄一遍 Blur + ColoredBox。

/// 毛玻璃容器：`panel` 高透明度 + `BackdropFilter`（design-system §2）。
/// 圆角与发丝描边由调用方给，模糊半径默认取面板档。
class QiyuGlassPanel extends StatelessWidget {
  const QiyuGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = QiyuRadii.pillBorder,
    this.blurSigma = QiyuGlass.panelBlur,
    this.borderColor = QiyuColors.line,
    this.border,
    this.tint = QiyuColors.glass,
    this.padding,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final Color borderColor;

  /// 需要单侧发丝线时由调用方给（侧边栏与抽屉只画右缘一条）；为空则整圈
  /// [borderColor] 1px。
  final BoxBorder? border;
  final Color tint;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            // 自定义边线（如侧边栏的单侧发丝线）不是均匀边，BoxDecoration
            // 此时不接受圆角；圆角已经由外层 ClipRRect 裁出，视觉一致。
            borderRadius: border == null ? borderRadius : null,
            border: border ?? Border.all(width: 1, color: borderColor),
          ),
          child: Padding(
            padding: padding ?? EdgeInsets.zero,
            // 面板自带一层透明 Material 作为 ink 载体：导航壳在子页面
            // Scaffold 的**兄弟**位置，不能指望外层给 InkWell 提供 Material。
            child: Material(
              type: MaterialType.canvas,
              color: Colors.transparent,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘键盘焦点环（design-system §9）：Material 3 的 `focusColor` 只能贴在
/// 控件表面，画不出「2px `accentBright` + offset 3px」的外环。
///
/// 用法：把调用方持有的 [FocusNode] 交给环，同时交给它包住的 `InkWell`，
/// 键盘 Tab 落焦即出现外环，Enter/Space 仍由 InkResponse 激活。环的留白
/// 常驻（未聚焦时透明），因此出现与消失都不会引起布局跳动。
class QiyuFocusRing extends StatelessWidget {
  const QiyuFocusRing({
    super.key,
    required this.focusNode,
    required this.child,
    this.borderRadius = QiyuRadii.smallBorder,
  });

  final FocusNode focusNode;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, child) {
        // 本版本 Flutter 的 FocusNode 没有区分指针/键盘获焦的 API
        // （无 `NodeFocusDisposition`），因此获焦即画环：指针点击也会显环，
        // 但规范 §9 的硬要求是「键盘焦点必须可见」，宁可多显不可漏显。
        final showRing = focusNode.hasFocus;
        return Padding(
          padding: const EdgeInsets.all(QiyuFocus.ringOffset),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(
                width: QiyuFocus.ringWidth,
                color: showRing
                    ? QiyuColors.accentBright
                    : Colors.transparent,
              ),
            ),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
