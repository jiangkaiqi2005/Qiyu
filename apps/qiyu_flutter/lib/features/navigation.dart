import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 返回键的统一出口：从别的页面 push 进来时回到上一个页面；直接
/// 打开或刷新后没有可回退的栈时回首页。
void backToPrevious(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/');
  }
}

/// 内容跳转的统一出口：目标页面已经在当前返回栈里时，回退到那一层
/// 而不是继续叠加。记忆详情之间会成环（条目 → 这一天 → 条目），
/// 不加这道闸就会无限嵌套。
void openInFront(BuildContext context, String location) {
  final matches =
      GoRouter.of(context).routerDelegate.currentConfiguration.matches;
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
