import 'package:flutter/material.dart';

/// 空态→聊天态时问候的**淡出层**：从完全不透明淡到透明，淡完通知父级把自己
/// 摘掉（Spec User Story 2「发出第一句后背景与问候淡出」）。
///
/// 时长由调用方给（`qiyuMotion(context, QiyuMotion.base)`，reduced-motion 下是
/// [Duration.zero]，第一帧就到位、等于没有动效）。它在父级重建时**必须保持同一个
/// 键**：聊天态的那次 build 每次 notify 都重建，键一变这个 State 就重造、动画
/// 从头再来，淡出永远走不完——所以父级只把它当固定的一层挂在那里，不拿内容
/// 当 key。
class QiyuGreetingFadeOut extends StatefulWidget {
  const QiyuGreetingFadeOut({
    super.key,
    required this.duration,
    required this.onFinished,
    required this.child,
  });

  final Duration duration;
  final VoidCallback onFinished;
  final Widget child;

  @override
  State<QiyuGreetingFadeOut> createState() => _QiyuGreetingFadeOutState();
}

class _QiyuGreetingFadeOutState extends State<QiyuGreetingFadeOut>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1.0,
  );

  @override
  void initState() {
    super.initState();
    // 听 TickerFuture，不听状态监听：以 value 1.0 构造出来的控制器「上次上报的
    // 状态」还是 dismissed，零时长（reduced-motion）下直接跳到 dismissed 不算
    // 状态变化，监听器一次都不会触发，这一层就永远挂在树上。
    _controller.reverse().whenComplete(_notifyFinished);
  }

  void _notifyFinished() {
    // 再等这一帧画完才通知父级：whenComplete 的回调可能落在本帧 build 之后立刻
    // 执行，那时 setState 会撞上「build 期间不得标脏」的限制。
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onFinished());
  }

  @override
  void dispose() {
    // 父级提前摘掉这一层（例如又回到空态）时动画可能还在跑：先 stop，
    // 不留活跃 ticker。
    _controller
      ..stop()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _controller, child: widget.child);
  }
}
