import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/shell/qiyu_connection_status.dart';
import 'package:qiyu_flutter/features/shell/qiyu_shell.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// 第 2 段：合一页 + 毛玻璃导航壳 + 连接状态 + 玻璃 composer + 自绘焦点环
/// + reduced-motion。
///
/// 定位一律按 Key：侧边栏与抽屉渲染同一批导航文案，`find.text` 命中两处即
/// 歧义（Spec Testing Decisions 第 8 条）。

void main() {
  group('导航壳 QiyuShell', () {
    testWidgets('桌面常驻 240px 毛玻璃侧边栏：品牌槽 + 三项导航 + 连接状态', (
      tester,
    ) async {
      await _pumpShell(tester, width: 1200, height: 800);

      expect(find.byKey(const Key('nav-brand')), findsOneWidget);
      expect(find.byKey(const Key('nav-history')), findsOneWidget);
      expect(find.byKey(const Key('nav-memory')), findsOneWidget);
      expect(find.byKey(const Key('nav-settings')), findsOneWidget);
      expect(find.byKey(const Key('conn-status')), findsOneWidget);
      // 桌面不出现三条杠，也不出现底部导航。
      expect(find.byKey(const Key('nav-menu-button')), findsNothing);
      expect(find.byType(BottomNavigationBar), findsNothing);

      // 宽度取 token 的 240，而不是页面里另写一份。
      expect(
        tester.getSize(find.byKey(const Key('nav-brand'))).width,
        lessThanOrEqualTo(QiyuLayout.sidebarWidth),
      );
      expect(
        tester.getRect(find.byType(QiyuShell).last).width,
        greaterThanOrEqualTo(QiyuLayout.sidebarWidth),
      );
    });

    testWidgets('导航项选中态取中性暗底 + 近白文字，绝不用紫', (tester) async {
      await _pumpShell(
        tester,
        width: 1200,
        height: 800,
        at: '/history',
        // 选中态只有在「功能页也套着壳」时才看得见；真实 app.dart 本段只把壳
        // 挂在 / 与 /chat（路由一条没动），壳包住历史/记忆/设置是第 3–5 段的事。
        // 这里由 harness 给占位页套上同一个壳，专门验导航项的选中绘制。
        shellOnFeaturePages: true,
      );

      final selected = _navItemContainer(tester, 'nav-history');
      expect(selected.color, QiyuColors.selectedNeutral);
      // 选中态不得落紫，也不得落暗红（三色纪律）。
      expect(selected.color, isNot(QiyuColors.accentBright));
      expect(selected.color, isNot(QiyuColors.danger));
      final labelColor = _navItemLabel(tester, 'nav-history').style!.color;
      expect(labelColor, QiyuColors.neutralEmphasis);

      // 未选中项保持 muted。
      expect(
        _navItemContainer(tester, 'nav-memory').color,
        isNot(QiyuColors.selectedNeutral),
      );
    });

    testWidgets('窄屏三条杠开合毛玻璃抽屉，内容与桌面同源', (tester) async {
      await _pumpShell(tester, width: 420, height: 900);

      // 窄屏无常驻导航：抽屉没开时导航项不在树里。
      expect(find.byKey(const Key('nav-menu-button')), findsOneWidget);
      expect(find.byKey(const Key('nav-history')), findsNothing);
      expect(find.byKey(const Key('conn-status')), findsNothing);

      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('nav-history')), findsOneWidget);
      expect(find.byKey(const Key('nav-memory')), findsOneWidget);
      expect(find.byKey(const Key('nav-settings')), findsOneWidget);
      // 连接状态与桌面同款形态收进抽屉底部，不另设降级形态。
      expect(find.byKey(const Key('conn-status')), findsOneWidget);
      // 抽屉宽约视口 2/3（按 nav-drawer 量抽屉本体，不是量导航项）。
      final drawerRect = tester.getRect(find.byKey(const Key('nav-drawer')));
      expect(drawerRect.width, 420 * QiyuLayout.drawerWidthFraction);
      // 抽屉贴左缘停靠，右侧留出可点的遮罩。
      expect(drawerRect.left, 0);

      // 点遮罩收回：必须落在抽屉之外的遮罩区域，点在抽屉上不算点遮罩。
      await tester.tapAt(Offset(drawerRect.right + 40, 450));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-history')), findsNothing);
      expect(find.byKey(const Key('nav-scrim')), findsNothing);
    });

    testWidgets('窄屏点三条杠同样收回抽屉', (tester) async {
      await _pumpShell(tester, width: 420, height: 900);
      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-history')), findsOneWidget);

      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-history')), findsNothing);
    });

    testWidgets('点品牌槽回空状态首页', (tester) async {
      await _pumpShell(tester, width: 1200, height: 800, at: '/chat');
      expect(_location(tester), '/chat');

      await tester.tap(find.byKey(const Key('go-home')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/');
    });

    testWidgets('双视口溢出冒烟：800x600 与 420x900 都不许溢出', (
      tester,
    ) async {
      // 测试默认视口正好压在桌面断点上：240 rail 会挤掉内容宽度，
      // 因此两个视口都要真跑一遍。
      for (final size in const [Size(800, 600), Size(420, 900)]) {
        await _pumpShell(
          tester,
          width: size.width,
          height: size.height,
          drawerOpen: size.width < QiyuLayout.desktopBreakpoint,
        );
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });
  });

  group('连接状态 conn-status（三色纪律的可执行化）', () {
    testWidgets('正常态：6px 中性圆点 + 13px muted 文案，既不着紫也不用 danger', (
      tester,
    ) async {
      await _pumpShell(tester, width: 1200, height: 800);

      final dot = tester.widget<Container>(find.byKey(const Key('conn-status-dot')));
      final dotSize = tester.getSize(find.byKey(const Key('conn-status-dot')));
      expect(dotSize, const Size(6, 6));
      final dotColor = (dot.decoration! as BoxDecoration).color;
      final textColor = tester.widget<Text>(
        find.byKey(const Key('conn-status-text')),
      ).style!.color!;

      expect(dotColor, QiyuColors.muted);
      expect(textColor, QiyuColors.muted);
      // 正常态不得出现任何紫，也不得出现 danger。
      for (final purple in const [
        QiyuColors.accentBright,
        QiyuColors.accentGlassA,
        QiyuColors.accentGlassB,
      ]) {
        expect(dotColor, isNot(purple));
        expect(textColor, isNot(purple));
      }
      expect(dotColor, isNot(QiyuColors.danger));
      expect(textColor, isNot(QiyuColors.danger));
      expect(
        tester.widget<Text>(find.byKey(const Key('conn-status-text'))).data,
        QiyuConnectionStatus.normalLabel,
      );
      // 字号取 13 档（次要字），不是随手写的值。
      expect(
        tester.widget<Text>(find.byKey(const Key('conn-status-text'))).style!.fontSize,
        QiyuType.secondarySize,
      );
    });

    testWidgets('探测失败态：圆点与文案同转 danger，点击重新探测', (
      tester,
    ) async {
      final probe = _StubProbe(available: false);
      await _pumpShell(tester, width: 1200, height: 800, probe: probe);

      final dotColor =
          (tester
                      .widget<Container>(find.byKey(const Key('conn-status-dot')))
                      .decoration!
                  as BoxDecoration)
              .color;
      final text = tester.widget<Text>(find.byKey(const Key('conn-status-text')));

      // 圆点与文案必须同时转色，不允许只改文案。
      expect(dotColor, QiyuColors.danger);
      expect(text.style!.color, QiyuColors.danger);
      expect(text.data, QiyuConnectionStatus.failedLabel);

      final callsBefore = probe.calls;
      await tester.tap(find.byKey(const Key('conn-status-retry')));
      await tester.pumpAndSettle();
      expect(probe.calls, greaterThan(callsBefore), reason: '点一下就要重新探测本机 Host');
    });

    testWidgets('Host 停止遮罩仍然压住整页（行为不变量）', (tester) async {
      await _pumpShell(
        tester,
        width: 1200,
        height: 800,
        probe: _StubProbe(available: false),
      );
      expect(find.text('本机程序已停止'), findsOneWidget);
    });
  });

  group('合一页：空状态首页与对话态', () {
    testWidgets('/ 与 /chat 渲染同一个对话视图，路由一条都没改', (tester) async {
      for (final location in const ['/', '/chat']) {
        await tester.pumpWidget(
          await _app(at: location),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('chat-input')),
          findsOneWidget,
          reason: '$location 也要直接可聊',
        );
        expect(find.byType(QiyuShell), findsOneWidget, reason: location);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('空状态：夜景背景 + 时段问候 + 居中 composer；发出第一句后背景淡出', (
      tester,
    ) async {
      final gateway = _StubChatGateway();
      await tester.pumpWidget(
        await _app(viewModel: await _viewModel(gateway)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-backdrop')), findsOneWidget);
      expect(find.byKey(const Key('home-greeting')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('home-greeting'))).data,
        qiyuEmptyChatHint(DateTime.now()),
      );
      // 桌面两段式：空状态时 composer 落在视口中线以下、底部之上之间。
      final composerCenter = tester
          .getRect(find.byKey(const Key('home-go-chat')))
          .center;
      expect(composerCenter.dy, lessThan(600 * 0.75));

      await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 背景与问候淡出，消息流生长，composer 落底。
      expect(find.byKey(const Key('home-backdrop')), findsNothing);
      expect(find.byKey(const Key('home-greeting')), findsNothing);
      expect(find.byKey(const Key('chat-message-0')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const Key('home-go-chat'))).bottom,
        greaterThan(600 * 0.7),
      );
    });

    testWidgets('用户水滴气泡与栖语无气泡（§7）', (tester) async {
      final gateway = _StubChatGateway(
        restored: const [
          LocalChatMessage(
            requestId: 'r-1',
            speaker: LocalChatSpeaker.user,
            text: '今晚有点睡不着',
          ),
          LocalChatMessage(
            requestId: 'r-1',
            speaker: LocalChatSpeaker.qiyu,
            text: '嗯，坐着说。',
            source: ReplySource.local,
          ),
        ],
      );
      await tester.pumpWidget(await _app(viewModel: await _viewModel(gateway)));
      await tester.pumpAndSettle();

      final user = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const Key('chat-message-0')),
          matching: find.byType(Container),
        ),
      );
      final userDecoration = user.decoration! as BoxDecoration;
      expect(userDecoration.color, QiyuColors.bubbleUser);
      // 水滴形：20/20/6/20，指向角柔和不尖锐，且平时不给描边。
      expect(userDecoration.borderRadius, QiyuRadii.bubbleBorder);
      expect(userDecoration.border, Border.fromBorderSide(BorderSide.none));
      expect(
        tester.getRect(find.byKey(const Key('chat-message-0'))).centerRight.dx,
        greaterThan(
          tester.getRect(find.byKey(const Key('chat-message-1'))).center.dx,
        ),
        reason: '用户消息右对齐，栖语的话靠左',
      );
      // 栖语的话没有装饰盒。
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-message-1')),
          matching: find.byType(Container),
        ),
        findsNothing,
      );
    });
  });

  group('玻璃 composer 与发送钮', () {
    testWidgets('发送钮：玻璃紫渐变 + onAccent 图标，无描边无白色高光', (
      tester,
    ) async {
      final gateway = _StubChatGateway();
      await tester.pumpWidget(await _app(viewModel: await _viewModel(gateway)));
      await tester.pumpAndSettle();

      // 渐变画在 Ink 上，chat-send 键在内层 InkWell 上：Ink 是它的祖先。
      final ink = tester.widget<Ink>(
        find
            .ancestor(
              of: find.byKey(const Key('chat-send')),
              matching: find.byType(Ink),
            )
            .first,
      );
      final decoration = ink.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      final gradient = decoration.gradient! as LinearGradient;
      expect(gradient.colors, [
        QiyuColors.accentGlassA,
        QiyuColors.accentGlassB,
      ]);
      // 无描边（也没有白色发丝高光）。
      expect(decoration.border, null);
      // 光晕：往外找第一个带 boxShadow 的 DecoratedBox。
      final glowBox = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.byKey(const Key('chat-send')),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is DecoratedBox &&
                    widget.decoration is BoxDecoration &&
                    (widget.decoration as BoxDecoration).boxShadow != null,
              ),
            )
            .first,
      );
      final glow = (glowBox.decoration as BoxDecoration).boxShadow!;
      expect(glow.single.color, QiyuColors.sendGlow);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.arrow_upward_rounded)).color,
        QiyuColors.onAccent,
      );
    });

    testWidgets('composer：胶囊全圆角 + line 发丝描边，聚焦描边紫度 0.13', (
      tester,
    ) async {
      final gateway = _StubChatGateway();
      await tester.pumpWidget(await _app(viewModel: await _viewModel(gateway)));
      await tester.pumpAndSettle();

      BoxDecoration panel() =>
          (tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byKey(const Key('home-go-chat')),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration);

      // 空态里 TextField 自动获焦：胶囊全圆角 + 聚焦描边 composerFocusLine，
      // 紫度 0.13（§8 组件 5），线宽走 QiyuLine.hairline 不另写数字。
      expect(panel().borderRadius, QiyuRadii.pillBorder);
      expect(panel().border!.top.color, QiyuColors.composerFocusLine);
      expect(panel().border!.top.color.a, closeTo(0.13, 0.005));
      expect(panel().border!.top.width, QiyuLine.hairline);

      // 显式弃焦（点空白不会把焦点从输入框拿走）后回到 line 发丝线。
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(panel().border!.top.color, QiyuColors.line);
    });

    testWidgets('生成中发送钮变停止钮（chat-send → chat-stop）', (tester) async {
      final gateway = _StubChatGateway(hold: true);
      await tester.pumpWidget(await _app(viewModel: await _viewModel(gateway)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      expect(find.byKey(const Key('chat-stop')), findsOneWidget);
      expect(find.byKey(const Key('chat-send')), findsNothing);
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);

      gateway.release();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-send')), findsOneWidget);
    });
  });

  group('焦点环与 reduced-motion', () {
    testWidgets('自绘焦点环：2px accentBright 带 offset 外环，随键盘焦点出现', (
      tester,
    ) async {
      await _pumpShell(tester, width: 1200, height: 800);
      // 初始焦点在 composer，导航项的环是透明的：留白常驻，出现与消失都不跳版。
      expect(
        _ringBorder(tester, 'nav-history').color,
        isNot(QiyuColors.accentBright),
      );

      // 遍历顺序按阅读序、且起点在输入框，所以逐次 Tab 直到落进导航项；
      // 落不进去就是缺陷，不能靠放宽断言蒙过去。
      var landed = false;
      for (var i = 0; i < 8 && !landed; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        landed =
            _ringBorder(tester, 'nav-history').color == QiyuColors.accentBright;
      }
      expect(landed, isTrue, reason: '键盘 Tab 落到导航项必须出现 accentBright 外环');

      final border = _ringBorder(tester, 'nav-history');
      expect(border.width, QiyuLayout.focusRingWidth);
      expect(border.color, QiyuColors.accentBright);
      // offset 由环外那圈**常驻**留白给出（未聚焦时也占位，所以出现与消失
      // 都不跳版）：留白必须是 focusRingOffset，配上上面的环宽才是定稿的
      // 「2px accentBright + offset 3px」——Material 的 focusColor 只会把
      // 高亮铺在控件表面上，给不出这一圈留白外环。
      expect(
        find.descendant(
          of: find.byKey(const Key('nav-history')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Padding &&
                widget.padding ==
                    const EdgeInsets.all(QiyuLayout.focusRingOffset),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('reduced-motion 下抽屉直接到位，不做平移动效', (tester) async {
      await _pumpShell(
        tester,
        width: 420,
        height: 900,
        reducedMotion: true,
        settle: false,
      );
      await tester.tap(find.byKey(const Key('nav-menu-button')));
      // 只推进一帧：时长被压成 0，抽屉直接落到与桌面侧边栏同一条基线上
      // （面板有 16px 水平内边距，导航项的落位左边就是那个内边距）。
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const Key('nav-history'))).left,
        QiyuLayout.sidebarPaddingHorizontal,
      );
    });

    testWidgets('默认（未开启减少动态效果）抽屉仍要滑进来', (tester) async {
      await _pumpShell(tester, width: 420, height: 900, settle: false);
      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pump();
      // 同一帧里抽屉还在屏幕外，说明 150–250ms 的过渡确实在跑。
      expect(
        tester.getRect(find.byKey(const Key('nav-history'))).left,
        lessThan(0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('nav-history'))).left,
        QiyuLayout.sidebarPaddingHorizontal,
      );
    });
  });
}

// ---------- 装配 ----------

/// 只壳 + 合一页的 harness：视口、路由位置、探测结果与 reduced-motion
/// 都在这里注入，用例只断言外部可观察行为。
Future<void> _pumpShell(
  WidgetTester tester, {
  required double width,
  required double height,
  String at = '/',
  bool drawerOpen = false,
  bool settle = true,
  bool reducedMotion = false,
  bool shellOnFeaturePages = false,
  _StubProbe? probe,
  LocalChatViewModel? viewModel,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    await _app(
      at: at,
      probe: probe,
      viewModel: viewModel,
      reducedMotion: reducedMotion,
      shellOnFeaturePages: shellOnFeaturePages,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  if (drawerOpen) {
    await tester.tap(find.byKey(const Key('nav-menu-button')));
    await tester.pumpAndSettle();
  }
}

Future<Widget> _app({
  String at = '/',
  _StubProbe? probe,
  LocalChatViewModel? viewModel,
  bool reducedMotion = false,
  bool shellOnFeaturePages = false,
}) async {
  final chat =
      viewModel ?? await _viewModel(_StubChatGateway(), probe: probe);
  return MultiProvider(
    providers: [ChangeNotifierProvider.value(value: chat)],
    child: MaterialApp.router(
      routerConfig: _router(at, shellOnFeaturePages: shellOnFeaturePages),
      theme: qiyuDarkTheme(),
      // reduced-motion：Web 引擎把 prefers-reduced-motion 映射到
      // AccessibilityFeatures.disableAnimations，测试侧同样从这一位进。
      builder: reducedMotion
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: true),
              child: child ?? const SizedBox.shrink(),
            )
          : null,
    ),
  );
}

/// 与被改造应用同构的最小路由：9 条路径与 `lib/app.dart` 完全一致（本段一条
/// 都没改），功能页用占位页，本段只验壳与合一页。
GoRouter _router(String initialLocation, {bool shellOnFeaturePages = false}) {
  // 三个导航目标占位页是否套壳由用例决定（见 _pumpShell 的注释）；路径本身
  // 与 lib/app.dart 的 9 条一一对应，本段一条都没动。
  Widget page(Widget child) =>
      shellOnFeaturePages ? QiyuShell(child: child) : child;
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const QiyuShell(child: LocalChatView()),
      ),
      GoRoute(
        path: '/chat',
        builder: (context, state) => const QiyuShell(child: LocalChatView()),
      ),
      GoRoute(
        path: '/history',
        builder: (context, state) =>
            page(const Scaffold(body: Center(child: Text('历史占位页')))),
      ),
      GoRoute(
        path: '/history/:sessionId',
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('历史会话占位页')),
        ),
      ),
      GoRoute(
        path: '/memory',
        builder: (context, state) =>
            page(const Scaffold(body: Center(child: Text('记忆中心占位页')))),
      ),
      GoRoute(
        path: '/memory/item/:itemId',
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('记忆条目占位页')),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) =>
            page(const Scaffold(body: Center(child: Text('设置占位页')))),
      ),
      GoRoute(
        path: '/settings/diagnostics',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('诊断占位页'))),
      ),
      GoRoute(
        path: '/privacy',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('隐私占位页'))),
      ),
    ],
  );
}

/// 当前路由路径：go_router 17 的 `GoRouterState` 没有对外可读的当前位置，
/// 只能从 delegate 读。壳在 `/` 与 `/chat` 都在树里，所以拿它当锚点。
String _location(WidgetTester tester) =>
    GoRouter.of(
      tester.element(find.byType(QiyuShell)),
    ).routerDelegate.currentConfiguration.uri.path;

Future<LocalChatViewModel> _viewModel(
  StreamingLocalChatGateway gateway, {
  HostConnectionProbe? probe,
  bool hostStopped = false,
}) async {
  final viewModel = LocalChatViewModel(
    gateway,
    hostConnectionProbe: probe ?? _StubProbe(available: !hostStopped),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}

BoxDecoration _navItemContainer(WidgetTester tester, String ringKey) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(Key(ringKey)),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return container.decoration! as BoxDecoration;
}

Text _navItemLabel(WidgetTester tester, String ringKey) => tester.widget<Text>(
  find.descendant(
    of: find.byKey(Key(ringKey)),
    matching: find.byType(Text),
  ).last,
);

/// 焦点环的描边：环是本仓库自绘的 2px 边框 DecoratedBox（玻璃面板 1px、
/// 导航项容器没有 border），按宽度取它。
BorderSide _ringBorder(WidgetTester tester, String ringKey) {
  final ring = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.byKey(Key(ringKey)),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).border?.top.width ==
                    QiyuLayout.focusRingWidth,
          ),
        )
        .first,
  );
  return (ring.decoration as BoxDecoration).border!.top;
}

final class _StubProbe implements HostConnectionProbe {
  _StubProbe({required this.available});

  bool available;
  int calls = 0;

  @override
  Future<bool> isHostAvailable() async {
    calls += 1;
    return available;
  }
}

final class _StubChatGateway implements StreamingLocalChatGateway {
  _StubChatGateway({List<LocalChatMessage> restored = const [], this.hold = false})
    : _restored = LocalChatSnapshot(sessionId: 'session-1', messages: restored);

  final LocalChatSnapshot _restored;

  /// true 时回复流停在最后一个事件之前：用来验「生成中」态与停止钮。
  final bool hold;
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async => _restored;

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: _restored.sessionId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: requestId,
    );
    if (hold) {
      await _gate.future;
    }
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      text: '在的。',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      messages: const ['在的。'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      source: ReplySource.local,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
    );
  }
}
