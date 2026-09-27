import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'shell/qiyu_shell.dart';

/// 当前内容路由的安卓返回入口。模态路由位于它上面，仍由 Navigator 消费。
class QiyuSystemBack extends StatefulWidget {
  const QiyuSystemBack({
    super.key,
    required this.child,
    this.hasUnsubmittedVoice = false,
    this.cancelUnsubmittedVoice,
  });

  final Widget child;
  final bool hasUnsubmittedVoice;
  final VoidCallback? cancelUnsubmittedVoice;

  @override
  State<QiyuSystemBack> createState() => _QiyuSystemBackState();
}

class _QiyuSystemBackState extends State<QiyuSystemBack>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return widget.child;
    }
    final router = GoRouter.maybeOf(context);
    final route = ModalRoute.of(context);
    final location = router?.routeInformationProvider.value.uri.path;
    final shell = context.dependOnInheritedWidgetOfExactType<QiyuShellScope>();
    final drawerOpen = shell?.drawerOpen ?? false;
    // Scaffold 会从内容的 MediaQuery 移除底部 inset；监听指标变化后从
    // 原始 View 读取，输入组件与整页包装因此遵守同一个键盘可见性口径。
    final keyboardOpen = View.of(context).viewInsets.bottom > 0;
    final fallback =
        route?.isCurrent == true &&
        router != null &&
        !router.canPop() &&
        location != '/' &&
        location != '/chat';
    return PopScope(
      canPop:
          !keyboardOpen &&
          !drawerOpen &&
          !widget.hasUnsubmittedVoice &&
          !fallback,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (keyboardOpen) {
          FocusManager.instance.primaryFocus?.unfocus();
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        } else if (drawerOpen) {
          shell!.closeDrawer?.call();
        } else if (widget.hasUnsubmittedVoice) {
          widget.cancelUnsubmittedVoice?.call();
        } else if (fallback) {
          backToPrevious(context);
        }
      },
      child: widget.child,
    );
  }
}

/// 返回键的统一出口：从别的页面 push 进来时回到上一个页面；直接打开
/// 或刷新后没有可回退的栈时，兜底落回壳内的合一页（`/chat`）而不是 `/`。
///
/// `/` 与 `/chat` 渲染的是同一个合一页，但 `/` 挂在 ShellRoute 之外、由
/// `RootView` 自己挂壳：兜底若走 `/`，整只导航壳（侧边栏、背景、玻璃层）
/// 会被销毁重建，`/` 的整页过渡还要重放一次——这正是侧边栏页点返回键时
/// 整页闪白的病根。落 `/chat` 则壳的 State 跨返回存活，与已被实测验证
/// 平静的侧边栏切换同一形态。
void backToPrevious(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/chat');
  }
}

/// 内容跳转的统一出口：目标页面已经在当前返回栈里时，回退到那一层
/// 而不是继续叠加。记忆详情之间会成环（条目 → 这一天 → 条目），
/// 不加这道闸就会无限嵌套。
void openInFront(BuildContext context, String location) {
  final matches = GoRouter.of(
    context,
  ).routerDelegate.currentConfiguration.matches;
  // 目标已在栈里时取最深一个匹配，逐层回退到它而不是继续叠加。
  final targetDepth = matches.lastIndexWhere(
    (match) => match.matchedLocation == location,
  );
  if (targetDepth < 0) {
    context.push(location);
    return;
  }
  for (var i = matches.length - 1; i > targetDepth; i--) {
    context.pop();
  }
}
