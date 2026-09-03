import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 列表层「行进期间悬停不显现消息时刻」的门控：包住消息列表（聊天页与
/// 历史回看页共用），`QiyuChatBubble` 经 [QiyuHoverGate.hoverSuppressedOf]
/// 读抑制位，决定 `onEnter`/`onHover` 是否放行显现。
///
/// 「行进」有两类，共享同一个对外抑制位（[hoverSuppressedOf] 取两者之
/// 或；气泡只在滚动位由假转真时复位已显现的行，滚动位单独读数见
/// [scrollSuppressedOf]）：
///
/// 1. **滚轮/程序滚动**：`NotificationListener<ScrollNotification>` 监听
///    滚动通知。这个抑制位若放进气泡，气泡里的
///    `NotificationListener<ScrollNotification>` 收不到祖先 ListView 的
///    滚动通知——通知从 Scrollable 的 context 向上冒泡只经过祖先，列表
///    项是后代。所以监听与状态都放列表，气泡经 InheritedWidget 读值。
/// 2. **指针快速移动**：child 外再包一层 `MouseRegion`，`onHover` 对指针
///    事件做速度采样，速度超过阈值即判为行进。用户实测反馈：快速上下
///    扫过消息列时每颗气泡都闪时间——只要鼠标进入气泡就立即显现，而
///    快速移动与滚轮滚动是同一类「我在赶路，不是想看」的意图。
///    `MouseRegion` 包住整个 ListView，列表空白处也产生 hover 事件
///    （Scrollable 的手势检测命中面盖住整块列表，空白处采样不断线），
///    跨气泡移动的连续速度计算才成立。
///
/// 滚动时间线：`ScrollStartNotification` 立即置抑制位，并让依赖它的气泡
/// 把已显现的悬停态复位（气泡在 `didChangeDependencies` 里感知滚动位
/// 变化，「滚动开始即隐藏已显现的行」）；`ScrollUpdateNotification` 维持
/// 抑制，并撤掉待触发的复位 Timer——滚轮逐格滚动每格都成对派发
/// Start/End，没有这一步，下一格压到光标下的内容会在上一格的缓冲窗内
/// 显现；`ScrollEndNotification` 启动 [revealDelay] 缓冲窗，到期才撤抑制
/// （惯性滚动与停下后的余动都落在这扇窗里）。撤销抑制后指针若停在消息
/// 块上，气泡侧在抑制解除时**主动调度显现**（走 80ms 延迟阀，无需任何新
/// 指针事件——指针停稳后 Flutter 不再派发事件，靠「再动一下」恢复会留
/// 死区，用户实测显现拖到约两秒且时好时坏）；指针在列表空白处则仍需
/// 轻移跨进气泡块——跨界派发的是 `onEnter`，由它放行显现；指针已在块
/// 内的轻移只走 `onHover`，主动显现通路落地后这条路径降级为兜底。
///
/// 指针行进时间线：`onHover` 维护判定基线（最近一次参与速度判定的采
/// 样，全局位置 + 事件时间戳；时间戳取事件自带值而非挂钟，测试可用显
/// 式时间戳做确定性驱动）。距基线间隔不足地板值**不判定也不推进基
/// 线**——距离与时间都留在窗里，累计满地板再判一次：高刷新率屏
/// （120/144Hz）逐帧间隔约 8/7ms 全都低于地板，基线若逐事件推进，每对
/// 样本都过不了地板，行进判定会整体失灵；高报告率鼠标的单像素抖动也
/// 被跨样本累计摊薄（乱序/同刻时间戳同理被拦在基线外）。首个采样不算
/// 行进（无从算速度——从列表外快速甩入随即停稳的场景由气泡侧的显现
/// 延迟兜底）。速度超过阈值即置行进抑制位并**重启**
/// [revealDelay] 衰减 Timer——持续快速移动期间每个快速样本都把窗口向后
/// 推，抑制一直保持；慢速样本不续期也不解除，衰减从最后一个快速样本
/// 起算。行进抑制**不复位已显现的行**（只有滚动位才复位）：鼠标在同一个
/// 大气泡内快速晃动，时刻保持已显状态是合理的——人还在气泡上，移出
/// 自然触发气泡的 `onExit` 隐藏。
class QiyuHoverGate extends StatefulWidget {
  const QiyuHoverGate({super.key, required this.child});

  final Widget child;

  /// 当前是否处于「行进期间或行进结束缓冲窗内」（滚动与指针快速移动
  /// 之或）。气泡在 `didChangeDependencies` 里调用（注册依赖，值变化会
  /// 再收到通知）；列表之外独立使用气泡（单气泡场景、既有测试）查不到
  /// scope，返回 false——默认不抑制。
  static bool hoverSuppressedOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_QiyuHoverScope>();
    return scope?.suppressed ?? false;
  }

  /// 滚动抑制位单独读数：气泡用它判定「滚动开始即隐藏已显现的行」的
  /// 复位时机——行进抑制不复位已显现的行，只有滚动位由假转真才复位。
  /// 行进抑制单独压着时合并值不变（InheritedWidget 不通知），滚动位的
  /// 变化必须能独立通知到气泡，否则行进期间开始的滚动收不到复位。
  static bool scrollSuppressedOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_QiyuHoverScope>();
    return scope?.scrollSuppressed ?? false;
  }

  /// 缓冲窗时长：滚动结束/最后一个快速样本之后，悬停仍被抑制的时间。
  /// 2026-09-03 用户裁定从 250ms 加长到 500ms（250ms 里快速扫过仍会
  /// 闪），明确是暂时值，可能再调——改这里即可，测试断言取窗内外余量
  /// 值（400ms/600ms）不贴边。
  static const Duration revealDelay = Duration(milliseconds: 500);

  /// 行进速度阈值（px/ms）：速度超过它即判为「指针在赶路」。0.5 px/ms
  /// = 500 px/s，刻意偏向抑制侧——真实鼠标扫过一屏轻而易举破
  /// 2000 px/s，而有意悬停的挪动远低于它；用户明确说快速移动不该显，
  /// 边界情况宁可压住。真实设备（触控板惯性、高报告率鼠标、高刷新率
  /// 屏）上可能需要再调。
  static const double _travelSpeedThreshold = 0.5;

  /// 采样间隔地板：距判定基线的间隔低于它就不做速度判定，也不推进基
  /// 线——距离与时间累计到下个样本一起算（见类注释「指针行进时间线」，
  /// 高刷新率屏逐帧间隔都低于地板，基线逐事件推进会整体失灵）。累计过
  /// 地板后，单像素抖动的假高速也被摊薄；含乱序/同刻样本。真实设备上
  /// 可能需要再调。
  static const Duration _minSampleInterval = Duration(milliseconds: 16);

  @override
  State<QiyuHoverGate> createState() => _QiyuHoverGateState();
}

class _QiyuHoverGateState extends State<QiyuHoverGate> {
  bool _scrollSuppressed = false;
  bool _travelSuppressed = false;
  Timer? _revealTimer;
  Timer? _travelTimer;

  // 最近一次 hover 采样：全局位置与事件时间戳。
  Offset? _lastSamplePosition;
  Duration? _lastSampleTime;

  bool _handleNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _revealTimer?.cancel();
      _revealTimer = null;
      if (!_scrollSuppressed) {
        setState(() => _scrollSuppressed = true);
      }
    } else if (notification is ScrollUpdateNotification) {
      // 维持抑制（Start 已置位），关键是撤掉上一格 ScrollEnd 留下的
      // 缓冲 Timer：连续滚动期间不出现「窗口已过期」的缝隙。
      _revealTimer?.cancel();
      _revealTimer = null;
    } else if (notification is ScrollEndNotification) {
      _revealTimer?.cancel();
      _revealTimer = Timer(QiyuHoverGate.revealDelay, () {
        if (mounted && _scrollSuppressed) {
          setState(() => _scrollSuppressed = false);
        }
      });
    }
    // 不拦截：别的祖先（如滚动条）同样需要这些通知。
    return false;
  }

  /// 指针移动采样：算速度、判行进（语义见类注释「指针行进时间线」）。
  void _handlePointerHover(PointerHoverEvent event) {
    final lastPosition = _lastSamplePosition;
    final lastTime = _lastSampleTime;
    // 首个采样只落基线，不算行进：无从算速度。从列表外快速甩入随即
    // 停稳的场景由气泡侧的显现延迟兜底（到期复查抑制位，行进未生效则
    // 放行）。
    if (lastPosition == null || lastTime == null) {
      _lastSamplePosition = event.position;
      _lastSampleTime = event.timeStamp;
      return;
    }
    final dt = event.timeStamp - lastTime;
    if (dt < QiyuHoverGate._minSampleInterval) {
      // 间隔过近不判定，也不推进基线：距离与时间留在窗里累计，凑满
      // 地板再判一次。基线若照推进，高刷新率屏每对样本都过不了地板，
      // 行进判定整体失灵（120Hz 帧间隔约 8ms 全低于 16ms 地板）。
      return;
    }
    _lastSamplePosition = event.position;
    _lastSampleTime = event.timeStamp;
    final speed =
        (event.position - lastPosition).distance /
        (dt.inMicroseconds / Duration.microsecondsPerMillisecond);
    if (speed <= QiyuHoverGate._travelSpeedThreshold) {
      // 慢速样本不续期也不解除：衰减从最后一个快速样本起算。
      return;
    }
    // 快速样本：进入（或维持）行进态，并重启衰减 Timer——持续快速
    // 移动期间每个样本都把窗口向后推，抑制一直保持。
    _travelTimer?.cancel();
    _travelTimer = Timer(QiyuHoverGate.revealDelay, () {
      if (mounted && _travelSuppressed) {
        setState(() => _travelSuppressed = false);
      }
    });
    if (!_travelSuppressed) {
      setState(() => _travelSuppressed = true);
    }
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _travelTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // NotificationListener 在外：要接住 child 里 Scrollable 向上冒泡的
    // 滚动通知；MouseRegion 包住整个 child（列表空白处也有 hover 事件，
    // 跨气泡采样不断线）；InheritedWidget 在内：气泡是它的后代才读得
    // 到抑制位。
    return NotificationListener<ScrollNotification>(
      onNotification: _handleNotification,
      child: MouseRegion(
        onHover: _handlePointerHover,
        child: _QiyuHoverScope(
          suppressed: _scrollSuppressed || _travelSuppressed,
          scrollSuppressed: _scrollSuppressed,
          child: widget.child,
        ),
      ),
    );
  }
}

class _QiyuHoverScope extends InheritedWidget {
  const _QiyuHoverScope({
    required this.suppressed,
    required this.scrollSuppressed,
    required super.child,
  });

  /// 合并抑制位（滚动 || 行进）：气泡的 onEnter/onHover 放行判定与显现
  /// 延迟到期复查都读它。
  final bool suppressed;

  /// 滚动位单独读数：气泡只对它的假→真翻转复位已显现的行。行进抑制
  /// 单独压着时它可能独自变化，[updateShouldNotify] 必须把它算进去。
  final bool scrollSuppressed;

  @override
  bool updateShouldNotify(_QiyuHoverScope oldWidget) {
    // 滚动位必须单独参与比较：行进抑制压着时合并值不变，但行进期间
    // 开始的滚动要能通知到气泡去复位已显现的行。
    return suppressed != oldWidget.suppressed ||
        scrollSuppressed != oldWidget.scrollSuppressed;
  }
}
