import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';

/// 紫夜薄包装层（design-system §8 组件清单的 M3 底子 + token 换皮）：
/// 毛玻璃面板与自绘**键盘**焦点环。侧边栏、抽屉、composer、发送钮共用同一
/// 份实现，保证「材质同源」，页面不得再各自抄一遍 Blur + ColoredBox。

/// 毛玻璃容器：玻璃基色 [QiyuColors.glass]（`rgba(19,18,23,0.72)`）+
/// `BackdropFilter`（design-system §2）。
///
/// **身下必须有东西**：`BackdropFilter` 糊的是它之下已经画好的像素，所以本容器
/// 只能作为半透明层叠在全幅页面背景之上（见 `QiyuShell` 的 Stack 分层）。把它
/// 平铺在一层同色 `ColoredBox` 上，糊出来的就是平涂，玻璃材质名存实亡。
/// 圆角与发丝描边由调用方给，模糊半径默认取面板档。
class QiyuGlassPanel extends StatelessWidget {
  const QiyuGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = QiyuRadii.pillBorder,
    this.blurSigma = QiyuGlass.panelBlur,
    this.borderColor = QiyuColors.line,
    this.border,
    this.padding,
    this.duration = QiyuMotion.base,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final Color borderColor;

  /// 需要单侧发丝线时由调用方给（侧边栏与抽屉只画右缘一条）；为空则整圈
  /// [borderColor] 1px。
  final BoxBorder? border;
  final EdgeInsetsGeometry? padding;

  /// 底色/描边变化的过渡时长（§9「动效一律 150–250ms 轻缓动」）。composer
  /// 的聚焦描边就从这里走：`line` ↔ `composerFocusLine` 是 200ms 过渡，不是
  /// 瞬时换色；reduced-motion 下由 [qiyuMotion] 压成 0。
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: AnimatedContainer(
          duration: qiyuMotion(context, duration),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: QiyuColors.glass,
            // 自定义边线（如侧边栏的单侧发丝线）不是均匀边，BoxDecoration
            // 此时不接受圆角；圆角已经由外层 ClipRRect 裁出，视觉一致。
            borderRadius: border == null ? borderRadius : null,
            border: border ??
                Border.all(width: QiyuLine.hairline, color: borderColor),
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

/// 自绘**键盘**焦点环（design-system §9）：Material 3 的 `focusColor` 只能贴在
/// 控件表面，画不出「2px `accentBright` + offset 3px」的外环。
///
/// 表意分流（2026-08-29 裁定）：这一圈实紫**只服务键盘焦点**。判据取框架自带的
/// 高亮模式语义，与 `InkResponse.updateFocusHighlights` 同一条规则——
/// `FocusHighlightMode.touch` 一律不画，`traditional` 且节点持焦才画；环另外监听
/// `FocusManager.addHighlightModeListener`，模式切换当帧重绘。触摸/手写输入下
/// 点击不会留下紫环；输入框文本编辑态的 0.13 淡紫描边是 §8 组件 5 的另一件事，
/// 由 composer 自己的 `QiyuGlassPanel.borderColor` 给出，不走本组件。
///
/// 用法一（控件已有节点）：把调用方持有的 [focusNode] 同时交给环和它包住的
/// `InkWell`，Enter/Space 仍由 InkResponse 激活。
/// 用法二（`IconButton` 这类内部自建节点的控件）：用 [QiyuFocusRing.own]，环自己
/// 持有节点并交给 [builder]，由子控件挂到树上；子控件不挂就永远不显环（宁可少显，
/// 也不画出与焦点无关的环）。
///
/// 环的留白常驻（未聚焦时透明），因此出现与消失都不会引起布局跳动。
class QiyuFocusRing extends StatefulWidget {
  const QiyuFocusRing({
    super.key,
    required this.focusNode,
    required this.child,
    this.borderRadius = QiyuRadii.smallBorder,
  }) : builder = null;

  /// 环自持焦点节点：[builder] 拿到的节点必须由子控件挂进焦点树。
  const QiyuFocusRing.own({
    super.key,
    required this.builder,
    this.borderRadius = QiyuRadii.smallBorder,
  }) : focusNode = null,
       child = null;

  /// 调用方持有的节点（与内层 `InkWell` 共用）。
  final FocusNode? focusNode;
  final BorderRadius borderRadius;
  final Widget? child;
  final Widget Function(BuildContext context, FocusNode focusNode)? builder;

  @override
  State<QiyuFocusRing> createState() => _QiyuFocusRingState();
}

class _QiyuFocusRingState extends State<QiyuFocusRing> {
  /// 仅 [QiyuFocusRing.own] 用：节点由环创建并负责释放。
  FocusNode? _ownedNode;

  FocusNode get _node => widget.focusNode ?? (_ownedNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    if (widget.builder != null) {
      _ownedNode = FocusNode();
    }
    // 高亮模式换了（键盘遍历 ↔ 触摸）就得重画：只监听 focusNode 收不到这个变化。
    _focusManager.addHighlightModeListener(_onHighlightModeChanged);
  }

  @override
  void didUpdateWidget(QiyuFocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      setState(() {});
    }
  }

  FocusManager get _focusManager => FocusManager.instance;

  void _onHighlightModeChanged(FocusHighlightMode mode) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focusManager.removeHighlightModeListener(_onHighlightModeChanged);
    _ownedNode?.dispose();
    super.dispose();
  }

  /// 框架自己怎么说「现在该不该画焦点高亮」——与 Material `InkWell` 同一判据：
  /// 触摸模式不画，传统模式看节点是否持焦。
  bool get _showRing {
    final highlightMode = _focusManager.highlightMode;
    return switch (highlightMode) {
      FocusHighlightMode.touch => false,
      FocusHighlightMode.traditional => _node.hasFocus,
    };
  }

  @override
  Widget build(BuildContext context) {
    final builder = widget.builder;
    final child = builder != null
        ? Builder(builder: (context) => builder(context, _node))
        : widget.child!;
    return ListenableBuilder(
      listenable: _node,
      builder: (context, child) => Padding(
        padding: const EdgeInsets.all(QiyuLayout.focusRingOffset),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: Border.all(
              width: QiyuLayout.focusRingWidth,
              color: _showRing
                  ? QiyuColors.accentBright
                  : Colors.transparent,
            ),
          ),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
