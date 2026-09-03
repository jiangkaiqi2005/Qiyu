import 'dart:async';

import 'package:flutter/material.dart';

/// 列表层「滚动期间悬停不显现消息时刻」的门控：包住消息列表（聊天页与
/// 历史回看页共用），`QiyuChatBubble` 经 [QiyuScrollHoverGate.hoverSuppressedOf]
/// 读抑制位，决定 `onEnter`/`onHover` 是否放行显现。
///
/// 状态为什么必须在列表层：滚轮滚动让内容滑到静止光标下时，每帧绘制后
/// MouseTracker 会按最后已知位置重算命中，向新压到光标下的 [MouseRegion]
/// 派发 `onEnter`——鼠标一动不动也触发。这个抑制位若放进气泡，气泡里的
/// `NotificationListener<ScrollNotification>` 收不到祖先 ListView 的滚动
/// 通知——通知从 Scrollable 的 context 向上冒泡只经过祖先，列表项是后代。
/// 所以监听与状态都放列表，气泡经 InheritedWidget 读值。
///
/// 时间线：`ScrollStartNotification` 立即置抑制位，并让依赖它的气泡把已
/// 显现的悬停态复位（气泡在 `didChangeDependencies` 里感知 inherited 值
/// 变化，「滚动开始即隐藏已显现的行」）；`ScrollUpdateNotification` 维持
/// 抑制，并撤掉待触发的复位 Timer——滚轮逐格滚动每格都成对派发
/// Start/End，没有这一步，下一格压到光标下的内容会在上一格的缓冲窗内
/// 显现；`ScrollEndNotification` 启动 [revealDelay] 缓冲窗，到期才撤抑制
/// （惯性滚动与停下后的余动都落在这扇窗里）。撤销抑制**不主动显现**：
/// 指针不动就收不到事件，要恢复显现需缓冲窗过期后轻移鼠标——气泡侧的
/// `onHover` 放行覆盖这一步（enter 只在进出边界时派发，指针已在块内时
/// 轻移只走 hover）。
class QiyuScrollHoverGate extends StatefulWidget {
  const QiyuScrollHoverGate({super.key, required this.child});

  final Widget child;

  /// 当前是否处于「滚动期间或滚动结束缓冲窗内」。气泡在
  /// `didChangeDependencies` 里调用（注册依赖，值变化会再收到通知）；
  /// 列表之外独立使用气泡（单气泡场景、既有测试）查不到 scope，返回
  /// false——默认不抑制。
  static bool hoverSuppressedOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_QiyuScrollHoverScope>();
    return scope?.suppressed ?? false;
  }

  /// 缓冲窗时长：滚动结束后悬停仍被抑制的时间。
  static const Duration revealDelay = Duration(milliseconds: 250);

  @override
  State<QiyuScrollHoverGate> createState() => _QiyuScrollHoverGateState();
}

class _QiyuScrollHoverGateState extends State<QiyuScrollHoverGate> {
  bool _suppressed = false;
  Timer? _revealTimer;

  bool _handleNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _revealTimer?.cancel();
      _revealTimer = null;
      if (!_suppressed) {
        setState(() => _suppressed = true);
      }
    } else if (notification is ScrollUpdateNotification) {
      // 维持抑制（Start 已置位），关键是撤掉上一格 ScrollEnd 留下的
      // 缓冲 Timer：连续滚动期间不出现「窗口已过期」的缝隙。
      _revealTimer?.cancel();
      _revealTimer = null;
    } else if (notification is ScrollEndNotification) {
      _revealTimer?.cancel();
      _revealTimer = Timer(QiyuScrollHoverGate.revealDelay, () {
        if (mounted) {
          setState(() => _suppressed = false);
        }
      });
    }
    // 不拦截：别的祖先（如滚动条）同样需要这些通知。
    return false;
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // NotificationListener 在外：要接住 child 里 Scrollable 向上冒泡的
    // 滚动通知；InheritedWidget 在内：气泡是它的后代才读得到抑制位。
    return NotificationListener<ScrollNotification>(
      onNotification: _handleNotification,
      child: _QiyuScrollHoverScope(
        suppressed: _suppressed,
        child: widget.child,
      ),
    );
  }
}

class _QiyuScrollHoverScope extends InheritedWidget {
  const _QiyuScrollHoverScope({required this.suppressed, required super.child});

  final bool suppressed;

  @override
  bool updateShouldNotify(_QiyuScrollHoverScope oldWidget) {
    return suppressed != oldWidget.suppressed;
  }
}
