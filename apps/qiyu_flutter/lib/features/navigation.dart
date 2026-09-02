import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
