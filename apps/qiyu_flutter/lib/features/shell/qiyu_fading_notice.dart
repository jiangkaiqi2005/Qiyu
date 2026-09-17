import 'dart:async';

import 'package:flutter/material.dart';

import '../accessibility.dart';

/// 全应用唯一的轻提示出口：校验结论、动作结果、语音引导都从这里播报。
///
/// 节奏定死为总时长 5 秒 = 清晰显示 4.4 秒 + 最后 0.6 秒整条（连背景）一起
/// 淡出到零，随后从树上移除——不插进页面布局，因此淡出期间不挤动聊天内容。
/// 语义：重复触发只替换当前提示、不排队；同一句在可见期内再触发不续时；
/// 悬停不暂停。观感沿用主题的 `snackBarTheme`（暗中性底、圆角、文案字号、
/// 动作按钮取 `actionTextColor`），不另起一套色。动作文案与回调的成对校验
/// 归 [QiyuFadingNotice] 自己（本件只转发），不在两层各写一份。
void showQiyuFadingNotice(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  Key? key,
  Color? foregroundColor,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final current = _notices[overlay];
  if (current?.message == message) return;
  current?.close();
  final notice = _NoticeEntry(overlay, message);
  _notices[overlay] = notice;
  final themes = InheritedTheme.capture(from: context, to: overlay.context);
  notice.entry = OverlayEntry(
    builder: (context) => themes.wrap(
      QiyuFadingNotice(
        key: key,
        message: message,
        actionLabel: actionLabel,
        onAction: onAction,
        foregroundColor: foregroundColor,
        onClose: notice.close,
      ),
    ),
  );
  overlay.insert(notice.entry);
}

/// 每个根 Overlay 当前那一条提示。挂在 Overlay 上而不是全局单例，是为了让
/// 「一条只属于它自己那棵树」——测试与多根场景各算各的；键为弱引用，Overlay
/// 消失后这条记录跟着走，不需要谁去清。
final _notices = Expando<_NoticeEntry>();

/// 一条已插入的提示。`close()` 幂等：定时到期、被新提示替换、动作点击、
/// 宿主整体销毁（此时由 [QiyuFadingNotice.dispose] 反向调用）都会走到这里。
final class _NoticeEntry {
  _NoticeEntry(this.overlay, this.message);

  final OverlayState overlay;
  final String message;
  late final OverlayEntry entry;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    if (identical(_notices[overlay], this)) _notices[overlay] = null;
    entry.remove();
    entry.dispose();
  }
}

/// 覆盖层中的整条提示：清晰停留 4.4 秒，最后 0.6 秒连背景一起淡出。
/// reduced-motion 开启时（design-system §9「自绘的淡出…一律归零」）不启动
/// 淡出，提示保持清晰可见直到 5 秒截止再整条移除——两种模式下总时长都是
/// 5 秒。由 [showQiyuFadingNotice] 管理插入、替换和移除。
class QiyuFadingNotice extends StatefulWidget {
  const QiyuFadingNotice({
    super.key,
    required this.message,
    required this.onClose,
    this.actionLabel,
    this.onAction,
    this.foregroundColor,
  }) : assert(
         (actionLabel == null) == (onAction == null),
         '动作按钮的文案与回调必须成对给出：只有文案没有回调会画出一颗点了没反应的按钮。',
       );

  final String message;
  final VoidCallback onClose;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color? foregroundColor;

  @override
  State<QiyuFadingNotice> createState() => _QiyuFadingNoticeState();
}

class _QiyuFadingNoticeState extends State<QiyuFadingNotice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  late final Animation<double> _opacity;
  late final Timer _hold;
  late final Timer _deadline;

  /// 当前 reduced-motion 读数，[didChangeDependencies] 里刷新。淡出是否启动
  /// 由它决定，见 [_beginFade]。
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      // 0.6 秒淡出是用户拍板的产品决策，**有意偏离** §9 的「动效一律
      // 150–250ms」那一档，不要按 `QiyuMotion` 改小；§9 的 reduced-motion
      // 那条（关掉自绘淡出）照常执行，见 [_beginFade]。
      duration: const Duration(milliseconds: 600),
    );
    _opacity = Tween<double>(begin: 1, end: 0).animate(_fade);
    _hold = Timer(const Duration(milliseconds: 4400), _beginFade);
    // 独立截止时间兜住掉帧与后台节流：无论淡出有没有跑、跑到哪，5 秒到点
    // 整条退场。
    _deadline = Timer(const Duration(seconds: 5), widget.onClose);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 只能在 initState 之后读；4.4 秒的定时器远晚于首次依赖
    // 解析，这里读到的是最新值——可见期内用户改了系统开关也照此走。
    _reducedMotion = qiyuReducedMotion(context);
  }

  /// 4.4 秒到点：开启 reduced-motion 就不做淡出（提示保持全不透明到 5 秒
  /// 截止，不是瞬间消失、也不是「透明但仍占位」），否则起 0.6 秒淡出。
  void _beginFade() {
    if (_reducedMotion) {
      return;
    }
    _fade.forward();
  }

  @override
  void dispose() {
    _hold.cancel();
    _deadline.cancel();
    _fade.dispose();
    widget.onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.snackBarTheme;
    final media = MediaQuery.of(context);
    // 成对校验在构造器的 assert 里；release 下 assert 被剥掉，这里再兜一层，
    // 只有文案与回调齐备才画动作按钮——绝不落到 `onAction!` 上。
    final actionLabel = widget.actionLabel;
    final onAction = widget.onAction;
    return Positioned(
      left: 0,
      right: 0,
      bottom: media.viewInsets.bottom,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.all(12),
        child: FadeTransition(
          opacity: _opacity,
          child: Semantics(
            liveRegion: true,
            container: true,
            child: Material(
              color: style.backgroundColor ?? theme.colorScheme.inverseSurface,
              elevation: style.elevation ?? 6,
              shape: style.shape,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: DefaultTextStyle(
                  style: (style.contentTextStyle ?? theme.textTheme.bodyMedium!)
                      .copyWith(color: widget.foregroundColor),
                  child: Row(
                    children: [
                      Expanded(child: Text(widget.message)),
                      if (actionLabel != null && onAction != null) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor:
                                style.actionTextColor ??
                                theme.colorScheme.inversePrimary,
                          ),
                          onPressed: () {
                            widget.onClose();
                            onAction();
                          },
                          child: Text(actionLabel),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
