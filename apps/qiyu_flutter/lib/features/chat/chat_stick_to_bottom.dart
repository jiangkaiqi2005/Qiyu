import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 聊天列表的贴底收敛状态机：会话恢复、新消息、流式增量与键盘压缩视口
/// 都跟在列表尾部，只有用户主动上滑才离开。判定与调度收在本模块，页面
/// 持有 [ScrollController] 并把滚动通知、键盘 inset 与内容签名喂进来，
/// 自身不再包含任何贴底内部细节。
final class ChatStickToBottomController {
  ChatStickToBottomController({
    required this.scrollController,
    required this.android,
    required this.isMounted,
  });

  final ScrollController scrollController;

  /// 平台分流的唯一出处是页面侧的判定 getter；构造时定格（运行期不变）。
  final bool android;

  /// 页面 State 的存活探测：帧后回调可能落在卸载之后。
  final bool Function() isMounted;

  String _lastListSignature = '';

  // 会话恢复与发送后默认跟到底部；只有用户主动上滑才离开，
  // 避免流式增量把正在回读历史的用户拉回底部。
  bool _stickToBottom = true;
  double _lastPixels = 0;

  /// 安卓真实拖动及其惯性阶段；布局修正与程序跳转不代表用户滚动意图。
  bool _userScrolling = false;

  /// 键盘 inset 的上一帧值。软键盘弹出同样压缩列表视口，而「贴底」是按
  /// pixels 与 maxScrollExtent 的关系算的：视口变矮只抬高 max、不动 pixels，
  /// 列表于是停在半空，最新消息沉到键盘与输入框之下。这里只认 inset 的
  /// **上升沿**（键盘弹出、或换成更高的输入法），下降沿不主动跳——收起键盘
  /// 时 clamp 自然把贴底态收回来，正在回读历史的用户位置也不被抢。
  double _lastKeyboardInset = 0;

  /// 贴底跳转的帧后回调在途标记：同帧多次触发只排一次。
  bool _stickToBottomScheduled = false;

  /// 离底多近算「已贴底」。与 [trackScroll] 的 120px 粘滞阈值不同，
  /// 这里是收敛终点的几何判据，超过它才需要再跳。
  static const double _stickToBottomTolerance = 1;

  /// composer 的发送起点回调（手打与转写共用）：发一条消息都视为用户要
  /// 回到底部，与迁移前两条发送路径开头的 `_stickToBottom = true` 同口径。
  void requestFollow() {
    _stickToBottom = true;
  }

  /// build 里读到的键盘 inset 交给状态机：只有上升沿（键盘弹出、或换成
  /// 更高的输入法）才安排补跳，下降沿交给 clamp 收敛（见 [_lastKeyboardInset]）。
  void onKeyboardInset(double inset) {
    if (android && inset > _lastKeyboardInset) {
      _scheduleStickToBottom();
    }
    _lastKeyboardInset = inset;
  }

  /// 列表内容签名（消息数｜瞬时行数｜流式长度）：签名变化时下一帧滚到底。
  void onListContent({
    required int messageCount,
    required int transientCount,
    required int streamingLength,
  }) {
    final signature = '$messageCount|$transientCount|$streamingLength';
    if (signature == _lastListSignature) {
      return;
    }
    _lastListSignature = signature;
    _scheduleStickToBottom();
  }

  // Web/桌面保留原有 120px 粘滞规则；安卓由原生滚动通知判断意图，
  // 不把键盘 clamp、布局修正或普通 metrics 更新误判为用户回到底部。
  void trackScroll() {
    if (android) return;
    final position = scrollController.position;
    if (position.pixels < _lastPixels) {
      _stickToBottom = position.pixels >= position.maxScrollExtent - 120;
    } else if (position.pixels >= position.maxScrollExtent - 120) {
      _stickToBottom = true;
    }
    _lastPixels = position.pixels;
  }

  /// 真实拖动一开始就让位（纯点击不触发），包括已排队的贴底回调。
  /// 松手后仍保留回读意图；只有用户向尾部滚动并实际到达底缘才恢复跟随。
  bool onUserDrag(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrolling = true;
      _stickToBottom = false;
    } else if (notification is ScrollUpdateNotification && _userScrolling) {
      final delta = notification.scrollDelta ?? 0;
      if (delta < 0) {
        _stickToBottom = false;
      } else if (delta > 0 && !_beyondStickTolerance(notification.metrics)) {
        _stickToBottom = true;
      }
    } else if (notification is OverscrollNotification && _userScrolling) {
      // 已严格贴底时向尾部拖动：pixels 已在底缘不再增大，SDK 不派正向
      // update，只派 overscroll。抵住底缘继续向尾部用力仍是「要跟随」，
      // 不得当回读；朝历史方向的 overscroll 维持回读意图不变。
      if (notification.overscroll > 0) {
        _stickToBottom = true;
      }
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _userScrolling = false;
      if (_stickToBottom) _scheduleStickToBottom();
    }
    return false;
  }

  /// 下一帧把列表拉回底部。内容增长与键盘压缩都要等这一帧布局落定后才能读到
  /// 新的 `maxScrollExtent`；只有贴底态才跳，正在回读历史的用户不被抢。
  ///
  /// 非安卓路径与改动前完全一致：无条件一帧后 `jumpTo`，精确贴底、无容差、
  /// 无去重——Web/桌面零变化。
  ///
  /// 安卓路径处理变高、懒加载列表的范围估算：跳一次后继续布局还会修正 max，
  /// pixels 便停在旧估算底部。所以贴底不是「一跳到底」而是**收敛**：跳转后
  /// 的新布局若仍在贴底意图内离底超过容差（[_stickToBottomTolerance]），范围
  /// 变化监听会再安排一次跳转，直到贴底或用户真实拖动取消意图。调度去重避免
  /// 同帧重复排回调；已贴底不再 jump，监听不会自触发循环。
  void _scheduleStickToBottom() {
    if (!android) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isMounted() || !_stickToBottom || !scrollController.hasClients) {
          return;
        }
        scrollController.jumpTo(scrollController.position.maxScrollExtent);
      });
      return;
    }
    if (_stickToBottomScheduled) {
      return;
    }
    _stickToBottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stickToBottomScheduled = false;
      if (!isMounted() || !_stickToBottom || !scrollController.hasClients) {
        return;
      }
      final position = scrollController.position;
      // jumpTo 会终止 Drag/惯性活动；即使发送重新启用跟随，也等滚动结束。
      if (position.isScrollingNotifier.value) return;
      if (_beyondStickTolerance(position)) {
        scrollController.jumpTo(position.maxScrollExtent);
      }
    });
  }

  /// 仅处理主列表的 metrics：普通滚动也会触发，不能据此恢复贴底意图。
  /// 键盘与懒加载范围变化仍可收敛，但用户滚动期间不安排补跳。
  bool onScrollMetrics(ScrollMetricsNotification notification) {
    if (notification.depth != 0) return false;
    if (!_userScrolling &&
        _stickToBottom &&
        _beyondStickTolerance(notification.metrics)) {
      _scheduleStickToBottom();
      // [ScrollMetricsNotification] 在布局帧结束后经微任务派发，此刻页面可能
      // 已静止（键盘动画结束、无输入无动画），而 [addPostFrameCallback] 自身
      // 不请求新帧——滞留的贴底回调会永远不执行。只有真的安排了贴底回调才
      // 请求一帧；已收敛（离底不超过容差）不会走到这里，pumpAndSettle 能正常
      // 停，不产生自持循环。
      SchedulerBinding.instance.scheduleFrame();
    }
    // 不拦截：范围变化继续向上冒泡，别的监听者不受影响。
    return false;
  }

  /// 离底距离是否超过收敛容差（见 [_stickToBottomTolerance]）。
  static bool _beyondStickTolerance(ScrollMetrics metrics) =>
      metrics.maxScrollExtent - metrics.pixels > _stickToBottomTolerance;
}
