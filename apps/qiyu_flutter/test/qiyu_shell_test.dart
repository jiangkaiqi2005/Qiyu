import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/history/history_client.dart';
import 'package:qiyu_flutter/features/history/history_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/navigation.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/shell/qiyu_connection_status.dart';
import 'package:qiyu_flutter/features/shell/qiyu_shell.dart';
import 'package:qiyu_flutter/features/shell/qiyu_strings.dart';
import 'package:qiyu_flutter/theme/qiyu_icons.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';
import 'support/focus_ring_probe.dart';

/// 第 2 段：合一页 + 毛玻璃导航壳 + 连接状态 + 玻璃 composer + 自绘焦点环
/// + reduced-motion。
///
/// 定位一律按 Key：侧边栏与抽屉渲染同一批导航文案，`find.text` 命中两处即
/// 歧义（Spec Testing Decisions 第 8 条）。

void main() {
  testWidgets('安卓页头和抽屉48像素命中区域边缘导航不重叠', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(QiyuApp(
      viewModel: await _viewModel(_StubChatGateway()),
      onboardingViewModel: await _onboardingViewModel(),
    ));
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(QiyuShell)));
    Rect target(String key) {
      final finder = find.byKey(Key(key));
      final rect = tester.getRect(finder);
      expect(rect.width, greaterThanOrEqualTo(48), reason: key);
      expect(rect.height, greaterThanOrEqualTo(48), reason: key);
      expect(tester.getSemantics(finder).rect.width, greaterThanOrEqualTo(48), reason: key);
      expect(tester.getSemantics(finder).rect.height, greaterThanOrEqualTo(48), reason: key);
      return rect;
    }
    final menu = target('nav-menu-button');
    final history = target('open-history');
    final settings = target('open-provider-settings');
    expect(menu.overlaps(history), isFalse);
    expect(history.overlaps(settings), isFalse);
    await tester.tapAt(history.topLeft + const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(_location(tester), '/history');
    expect(tester.takeException(), isNull, reason: '历史');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tapAt(target('open-provider-settings').bottomRight - const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(_location(tester), '/settings');
    expect(tester.takeException(), isNull, reason: '设置');
    await tester.tapAt(target('nav-menu-button').topLeft + const Offset(1, 1));
    await tester.pumpAndSettle();
    final memory = target('home-go-memory');
    await tester.tapAt(memory.bottomRight - const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/memory');
    expect(tester.takeException(), isNull, reason: '记忆中心');
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '大字体记忆页头');
    await tester.tapAt(target('nav-menu-button').bottomRight - const Offset(1, 1));
    await tester.pumpAndSettle();
    target('home-go-history');
    target('home-go-memory');
    target('home-go-settings');
    expect(tester.takeException(), isNull, reason: '大字体抽屉');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    for (final detail in {
      '/privacy': 'privacy-back',
      '/settings/diagnostics': 'diagnostics-back',
      '/history/existing': 'history-session-back',
      '/memory/item/existing': 'memory-item-back',
    }.entries) {
      router.go(detail.key);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: detail.key);
      await tester.tapAt(target(detail.value).topLeft + const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/chat');
    }
    expect(tester.takeException(), isNull);
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final detail in {
    '/privacy': 'privacy-back',
    '/settings/diagnostics': 'diagnostics-back',
    '/history/existing': 'history-session-back',
    '/memory/item/existing': 'memory-item-back',
  }.entries) {
    testWidgets(
      '安卓详情 ${detail.key} 系统与页头返回有栈回原路无栈回合一页',
      (tester) async {
        await tester.pumpWidget(
          QiyuApp(
            viewModel: await _viewModel(_StubChatGateway()),
            onboardingViewModel: await _onboardingViewModel(),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(QiyuShell));
        final router = GoRouter.of(context);
        router.go('/history');
        await tester.pumpAndSettle();
        for (final system in [true, false]) {
          openInFront(tester.element(find.byType(QiyuShell)), detail.key);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byKey(Key(detail.value)), findsOneWidget);
          if (system) {
            await tester.binding.handlePopRoute();
          } else {
            await tester.tap(find.byKey(Key(detail.value)));
          }
          await tester.pumpAndSettle();
          expect(router.routeInformationProvider.value.uri.path, '/history');
        }
        for (final system in [true, false]) {
          router.go(detail.key);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          if (system) {
            await tester.binding.handlePopRoute();
          } else {
            await tester.tap(find.byKey(Key(detail.value)));
          }
          await tester.pumpAndSettle();
          expect(router.routeInformationProvider.value.uri.path, '/chat');
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    '安卓内容入栈返回原路且根页交给系统退出',
    (tester) async {
      final platformCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platformCalls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pumpShell(tester, width: 420, height: 900, at: '/chat');
      final shell = tester.state(find.byType(QiyuShell));
      await tester.tap(find.byKey(const Key('open-history')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/history');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_location(tester), '/chat');
      expect(tester.state(find.byType(QiyuShell)), same(shell));
      expect(platformCalls, isNot(contains('SystemNavigator.pop')));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        platformCalls.where((call) => call == 'SystemNavigator.pop'),
        hasLength(1),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final destination in ['settings', 'memory', 'history']) {
    testWidgets(
      '安卓抽屉换栈 $destination 返回与页头同目标并保留会话',
      (tester) async {
        tester.view.physicalSize = const Size(420, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final model = await _viewModel(_StubChatGateway());
        await model.send('已有对话');
        final session = model.sessionId;
        final messages = model.messages.toList();
        await tester.pumpWidget(
          QiyuApp(
            viewModel: model,
            onboardingViewModel: await _onboardingViewModel(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-menu-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('home-go-$destination')));
        await tester.pumpAndSettle();
        final shell = tester.state(find.byType(QiyuShell));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(_location(tester), '/chat');
        expect(tester.state(find.byType(QiyuShell)), same(shell));
        expect(model.sessionId, session);
        expect(model.messages, messages);
        tester.view.physicalSize = const Size(1200, 900);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('home-go-$destination')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('$destination-back')));
        await tester.pumpAndSettle();
        expect(_location(tester), '/chat');
        expect(model.sessionId, session);
        expect(model.messages, messages);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    '安卓系统返回依次关闭模态、键盘、抽屉和功能页',
    (tester) async {
      await _pumpShell(
        tester,
        width: 420,
        height: 900,
        at: '/history',
        drawerOpen: true,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pump();
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(QiyuShell)),
          builder: (_) => const AlertDialog(content: Text('当前模态')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('当前模态'), findsNothing);
      expect(find.byKey(const Key('nav-drawer')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-drawer')), findsOneWidget);
      expect(_location(tester), '/history');
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-drawer')), findsNothing);
      expect(_location(tester), '/history');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_location(tester), '/chat');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final path in ['/', '/chat', '/history']) {
    testWidgets(
      '安卓系统返回先关闭 $path 的抽屉而不离页',
      (tester) async {
        await _pumpShell(
          tester,
          width: 420,
          height: 900,
          at: path,
          drawerOpen: true,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('nav-drawer')), findsNothing);
        expect(_location(tester), path);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
  testWidgets(
    '安卓系统返回从无栈历史回合一页并保留导航壳',
    (tester) async {
      await _pumpShell(tester, width: 420, height: 900, at: '/history');
      final shell = tester.state(find.byType(QiyuShell));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_location(tester), '/chat');
      expect(tester.state(find.byType(QiyuShell)), same(shell));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  group('导航壳 QiyuShell', () {
    testWidgets('桌面默认展开 240px 毛玻璃侧边栏：品牌图标 + 三项导航 + 连接状态，没有任何回合一页入口', (
      tester,
    ) async {
      await _pumpShell(tester, width: 1200, height: 800);

      // 品牌图标是**常驻**的开合开关（2026-08-31 二次裁定）：默认展开时它在，
      // 收起后它还在同一位置（位置恒定由后续几何用例钉）。
      expect(find.byKey(const Key('nav-brand')), findsOneWidget);
      expect(find.byKey(const Key('nav-history')), findsOneWidget);
      expect(find.byKey(const Key('nav-memory')), findsOneWidget);
      expect(find.byKey(const Key('nav-settings')), findsOneWidget);
      // 桌面不设任何形式的「回合一页」入口：键与文案都找不到。
      expect(find.byKey(const Key('go-home')), findsNothing);
      expect(find.text('回合一页'), findsNothing);
      expect(find.byKey(const Key('conn-status')), findsOneWidget);
      // 桌面不出现三条杠，也不出现底部导航。
      expect(find.byKey(const Key('nav-menu-button')), findsNothing);
      expect(find.byType(BottomNavigationBar), findsNothing);

      // 面板宽度取 token 的 240；品牌图标占位不越出面板宽度。
      expect(
        tester.getSize(find.byKey(const Key('nav-sidebar-size'))).width,
        QiyuLayout.sidebarWidth,
      );
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
      await _pumpShell(tester, width: 1200, height: 800, at: '/history');
      // 生产路由把壳挂在功能页上（User Story 5），所以 `/history` 这一跳
      // 是真的落在挂着侧边栏的历史页上，选中态才有得验。

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

    testWidgets('窄屏抽屉开着时三条杠不在树里：点遮罩收回后回到树里', (tester) async {
      await _pumpShell(tester, width: 420, height: 900);
      // 抽屉合上时点三条杠打开（关态覆盖，见上条开合用例）。
      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-history')), findsOneWidget);

      // 抽屉一开三条杠就整块摘出树：它的命中盒正压在品牌槽的栖语图标上，
      // 关闭手段移交遮罩（点按/Esc）与抽屉内导航项。
      expect(find.byKey(const Key('nav-menu-button')), findsNothing);
      expect(find.byKey(const Key('nav-scrim')), findsOneWidget);

      // 点抽屉之外的遮罩收回，三条杠回到树里，抽屉可以再次打开。
      final drawerRect = tester.getRect(find.byKey(const Key('nav-drawer')));
      await tester.tapAt(Offset(drawerRect.right + 40, 450));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-history')), findsNothing);
      expect(find.byKey(const Key('nav-menu-button')), findsOneWidget);
    });

    testWidgets('窄屏按 Esc 收回抽屉后焦点回到三条杠', (tester) async {
      await _pumpShell(tester, width: 420, height: 900);
      final menu = _menuButtonFocusNode(tester);

      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pumpAndSettle();
      // 前提：抽屉开着时是遮罩接管键盘（Esc 才接得住），焦点不在三条杠上。
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-scrim');
      expect(menu.hasFocus, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // 关掉了还得回到原来那一处：三条杠重新持焦，键盘用户不用从头 Tab。
      expect(find.byKey(const Key('nav-history')), findsNothing);
      expect(menu.hasFocus, isTrue);
      expect(FocusManager.instance.primaryFocus, menu);
    });

    testWidgets('桌面品牌图标是纯开合开关：点击只收起/展开，不带任何导航；桌面树上没有 go-home', (tester) async {
      await _pumpShell(tester, width: 1200, height: 800, at: '/chat');
      expect(_location(tester), '/chat');
      expect(find.byKey(const Key('nav-history')), findsOneWidget);
      expect(find.byKey(const Key('go-home')), findsNothing);

      await tester.tap(find.byKey(const Key('nav-brand')));
      await tester.pumpAndSettle();

      // 收起：面板整体离场（导航项不再占用焦点/语义树），路由纹丝不动。
      expect(find.byKey(const Key('nav-history')), findsNothing);
      expect(_location(tester), '/chat', reason: '点击只管开合，不回合一页、不跳路由');
      expect(find.byKey(const Key('go-home')), findsNothing);
      // 内容区自然变宽，不产生溢出。
      expect(tester.takeException(), isNull);

      // 再点展开：导航项回来，同样不导航。
      await tester.tap(find.byKey(const Key('nav-brand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-history')), findsOneWidget);
      expect(_location(tester), '/chat', reason: '展开同样不回合一页');
      expect(tester.takeException(), isNull);
    });

    testWidgets('品牌图标位置恒定：开合两态与过渡中途矩形逐帧一致，树上始终只有一枚', (tester) async {
      await _pumpShell(tester, width: 1200, height: 800, at: '/chat');
      final brand = find.byKey(const Key('nav-brand'));
      final rect = tester.getRect(brand);

      // 收起：起步帧、中途帧、收到底，图标矩形与初帧完全一致，没有重影，
      // 也不得出现第二枚品牌图标（2026-08-31 二次裁定第 3、4 条）。
      await tester.tap(brand);
      await tester.pump();
      expect(tester.getRect(brand), rect);
      expect(brand, findsOneWidget);
      await tester.pump(QiyuMotion.drawer ~/ 2);
      expect(tester.getRect(brand), rect, reason: '过渡中途图标不得漂移');
      expect(brand, findsOneWidget, reason: '任何时刻树上只有一枚品牌图标');
      await tester.pumpAndSettle();
      expect(tester.getRect(brand), rect, reason: '收起后图标留在原处');
      expect(brand, findsOneWidget);

      // 展开：同样逐帧不动。
      await tester.tap(brand);
      await tester.pump();
      await tester.pump(QiyuMotion.drawer ~/ 2);
      expect(tester.getRect(brand), rect);
      expect(brand, findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.getRect(brand), rect, reason: '展开后图标仍在原处');
      expect(brand, findsOneWidget);
    });

    testWidgets('开合的宽度过渡走 QiyuMotion：默认有途中值，收到底才离场；reduced-motion 一帧到位', (
      tester,
    ) async {
      await _pumpShell(tester, width: 1200, height: 800);
      await tester.tap(find.byKey(const Key('nav-brand')));
      await tester.pump();
      await tester.pump(QiyuMotion.drawer ~/ 2);
      expect(
        tester.getSize(find.byKey(const Key('nav-sidebar-size'))).width,
        inInclusiveRange(1, QiyuLayout.sidebarWidth - 1),
        reason: '默认动效下收起应处于宽度过渡途中，不是瞬间塌掉',
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('nav-sidebar-size'))).width,
        0,
      );
      expect(
        find.byKey(const Key('nav-history')),
        findsNothing,
        reason: '收到底后面板离场，不占焦点与语义树',
      );

      // reduced-motion：时长压成 0，两帧内直接塌到底，不留途中值。
      await _pumpShell(tester, width: 1200, height: 800, reducedMotion: true);
      await tester.tap(find.byKey(const Key('nav-brand')));
      await tester.pump();
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const Key('nav-sidebar-size'))).width,
        0,
      );
      expect(find.byKey(const Key('nav-history')), findsNothing);
    });

    testWidgets('桌面品牌图标键盘可达：Tab 落焦、Enter 开合，两态都有 tooltip 与显式语义标签', (
      tester,
    ) async {
      // 句柄必须在用例体内释放：框架在 tearDown 回调之前就校验句柄是否清空。
      final semantics = tester.ensureSemantics();
      await _pumpShell(tester, width: 1200, height: 800);

      // 展开态标签说「收起侧边栏」：无字图标按钮的读屏名必须显式给
      // （决策日志第五轮 #17 的口径）。
      expect(find.byTooltip('收起侧边栏'), findsOneWidget);
      expect(find.bySemanticsLabel('收起侧边栏'), findsOneWidget);

      final focusNode = tester
          .widget<InkWell>(find.byKey(const Key('nav-sidebar-toggle')))
          .focusNode!;
      var landed = false;
      for (var i = 0; i < 12 && !landed; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        landed = focusNode.hasFocus;
      }
      expect(landed, isTrue, reason: '品牌图标必须能被键盘 Tab 走到');

      // Enter 收起；两态标签随状态切换，同一枚按钮不留旧态文案。
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nav-history')),
        findsNothing,
        reason: 'Enter 激活应收起侧边栏',
      );
      expect(find.byTooltip('展开侧边栏'), findsOneWidget);
      expect(find.bySemanticsLabel('展开侧边栏'), findsOneWidget);
      expect(find.byTooltip('收起侧边栏'), findsNothing);

      // 再按一次展开。
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nav-history')),
        findsOneWidget,
        reason: '同一枚图标再按一次应展开侧边栏',
      );
      semantics.dispose();
    });

    testWidgets('窄屏抽屉不回归：品牌槽仍回合一页（go-home），桌面开合开关不进抽屉', (tester) async {
      await _pumpShell(tester, width: 420, height: 900, at: '/chat');
      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pumpAndSettle();

      // `go-home` 键只保留在抽屉品牌槽上；桌面那枚开合开关与「回合一页」
      // 文案都不出现在窄屏。
      expect(find.byKey(const Key('go-home')), findsOneWidget);
      expect(find.byKey(const Key('nav-sidebar-toggle')), findsNothing);
      expect(find.text('回合一页'), findsNothing);

      await tester.tap(find.byKey(const Key('go-home')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nav-history')),
        findsNothing,
        reason: '抽屉收回',
      );
      expect(_location(tester), '/');
    });

    testWidgets('窄屏抽屉打开后点栖语图标中心必须回合一页：不被浮在上层的三条杠拦截', (tester) async {
      await _pumpShell(tester, width: 420, height: 900, at: '/chat');
      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('go-home')), findsOneWidget);

      // 用户点的是左上角那枚**品牌图形本身**（三条杠后露出月牙边的那枚圆），
      // 不是整条品牌槽 hit 区的中点：图形贴着抽屉左上角，与浮层三条杠同位。
      // 点它必须回合一页；被三条杠吃掉、只收回抽屉不导航，就是这个缺陷。
      await tester.tap(find.byKey(const Key('nav-brand')));
      await tester.pumpAndSettle();

      expect(_location(tester), '/', reason: '点栖语图标必须回合一页，而不是被三条杠拦截');
    });

    testWidgets('双视口溢出冒烟：800x600 与 420x900 都不许溢出', (tester) async {
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
    testWidgets('正常态：6px 中性圆点 + 13px muted 文案，既不着紫也不用 danger', (tester) async {
      await _pumpShell(tester, width: 1200, height: 800);

      final dot = tester.widget<Container>(
        find.byKey(const Key('conn-status-dot')),
      );
      final dotSize = tester.getSize(find.byKey(const Key('conn-status-dot')));
      expect(dotSize, const Size(6, 6));
      final dotColor = (dot.decoration! as BoxDecoration).color;
      final textColor = tester
          .widget<Text>(find.byKey(const Key('conn-status-text')))
          .style!
          .color!;

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
        tester
            .widget<Text>(find.byKey(const Key('conn-status-text')))
            .style!
            .fontSize,
        QiyuType.secondarySize,
      );
    });

    testWidgets('一次都还没探过时不宣称正常：中性形态 + 进行时措辞，不给重试', (tester) async {
      // 三态里的第一态：构造出 view model 但**不调用 initialize**，探测结果
      // 还是 null（hostStatusKnown == false）。这时既不能说「栖语在本机」，
      // 也不能说连不上。
      final chat = LocalChatViewModel(
        _StubChatGateway(),
        hostConnectionProbe: _StubProbe(available: true),
        autoStart: false,
      );
      expect(chat.hostStatusKnown, isFalse, reason: '前提：一次都还没探过');
      await _pumpShell(tester, width: 1200, height: 800, viewModel: chat);

      final text = tester.widget<Text>(
        find.byKey(const Key('conn-status-text')),
      );
      final dotColor =
          (tester
                      .widget<Container>(
                        find.byKey(const Key('conn-status-dot')),
                      )
                      .decoration!
                  as BoxDecoration)
              .color;
      // 形态与正常态同款：中性圆点 + muted 次要字，不加第三种颜色。
      expect(text.data, QiyuConnectionStatus.probingLabel);
      expect(dotColor, QiyuColors.muted);
      expect(text.style!.color, QiyuColors.muted);
      // 但结论不给：既不宣称本机正常，也不宣称故障，也不是可点的重试。
      expect(text.data, isNot(QiyuConnectionStatus.normalLabel));
      expect(text.data, isNot(QiyuConnectionStatus.failedLabel));
      expect(dotColor, isNot(QiyuColors.danger));
      expect(text.style!.color, isNot(QiyuColors.danger));
      expect(find.byKey(const Key('conn-status-retry')), findsNothing);
      expect(find.text(QiyuConnectionStatus.normalLabel), findsNothing);
    });

    testWidgets('探测失败态：圆点与文案同转 danger，点击重新探测', (tester) async {
      final probe = _StubProbe(available: false);
      await _pumpShell(tester, width: 1200, height: 800, probe: probe);

      final dotColor =
          (tester
                      .widget<Container>(
                        find.byKey(const Key('conn-status-dot')),
                      )
                      .decoration!
                  as BoxDecoration)
              .color;
      final text = tester.widget<Text>(
        find.byKey(const Key('conn-status-text')),
      );

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
      expect(find.text('栖语本机程序未在运行或已更新。'), findsOneWidget);
      expect(find.text('请在电脑上重新启动栖语，然后刷新这个页面。'), findsOneWidget);
    });

    testWidgets('桌面侧边栏与窄屏抽屉底部均挂载微型双语切换项，初始为中文高亮', (tester) async {
      // 桌面形态
      await _pumpShell(tester, width: 1200, height: 800);
      expect(find.byKey(const Key('language-toggle')), findsOneWidget);
      expect(find.byKey(const Key('language-toggle-zh')), findsOneWidget);
      expect(find.byKey(const Key('language-toggle-en')), findsOneWidget);

      final zhTextDesktop = _toggleText(tester, 'language-toggle-zh');
      final enTextDesktop = _toggleText(tester, 'language-toggle-en');
      expect(zhTextDesktop.style!.color, QiyuColors.ink);
      expect(enTextDesktop.style!.color, QiyuColors.muted);
      expect(
        tester.widget<Text>(find.byKey(const Key('conn-status-text'))).data,
        '栖语在本机',
      );

      // 窄屏抽屉形态
      await _pumpShell(tester, width: 420, height: 900, drawerOpen: true);
      expect(find.byKey(const Key('language-toggle')), findsOneWidget);
      final zhTextDrawer = _toggleText(tester, 'language-toggle-zh');
      final enTextDrawer = _toggleText(tester, 'language-toggle-en');
      expect(zhTextDrawer.style!.color, QiyuColors.ink);
      expect(enTextDrawer.style!.color, QiyuColors.muted);
      expect(
        tester.widget<Text>(find.byKey(const Key('conn-status-text'))).data,
        '栖语在本机',
      );
    });

    testWidgets('点击 EN 立即无感热切，英文字体应用 Noto Serif，状态文案变更为 Qiyu is local，保留输入草稿与路由', (
      tester,
    ) async {
      await _pumpShell(tester, width: 1200, height: 800, at: '/chat');
      expect(_location(tester), '/chat');

      // 输入草稿文本
      await tester.enterText(find.byKey(const Key('chat-input')), '测试草稿未发送文本');
      await tester.pump();
      expect(find.text('测试草稿未发送文本'), findsOneWidget);

      // 点击 EN
      await tester.tap(find.byKey(const Key('language-toggle-en')));
      await tester.pumpAndSettle();

      // 断言高亮反转与英文字体
      final zhText = _toggleText(tester, 'language-toggle-zh');
      final enText = _toggleText(tester, 'language-toggle-en');
      expect(zhText.style!.color, QiyuColors.muted);
      expect(enText.style!.color, QiyuColors.ink);
      expect(enText.style!.fontFamily, QiyuType.enFontFamily);

      // 状态文案更新
      expect(
        tester.widget<Text>(find.byKey(const Key('conn-status-text'))).data,
        'Qiyu is local',
      );

      // 路由未变、输入框草稿完好保留
      expect(_location(tester), '/chat');
      expect(find.text('测试草稿未发送文本'), findsOneWidget);

      // 点击 中 切回中文
      await tester.tap(find.byKey(const Key('language-toggle-zh')));
      await tester.pumpAndSettle();

      final zhTextBack = _toggleText(tester, 'language-toggle-zh');
      final enTextBack = _toggleText(tester, 'language-toggle-en');
      expect(zhTextBack.style!.color, QiyuColors.ink);
      expect(enTextBack.style!.color, QiyuColors.muted);
      expect(
        tester.widget<Text>(find.byKey(const Key('conn-status-text'))).data,
        '栖语在本机',
      );
      expect(find.text('测试草稿未发送文本'), findsOneWidget);
    });
  });

  group('合一页：空状态首页与对话态', () {
    testWidgets('/ 与 /chat 渲染同一个对话视图，路由一条都没改', (tester) async {
      for (final location in const ['/', '/chat']) {
        await tester.pumpWidget(await _app(at: location));
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

    testWidgets('空状态：夜景背景 + 时段问候 + 居中 composer；发出第一句后背景淡出', (tester) async {
      final gateway = _StubChatGateway();
      await tester.pumpWidget(await _app(viewModel: await _viewModel(gateway)));
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

    testWidgets('问候跟着切换淡出，不是立即消失（Story 2）', (tester) async {
      final gateway = _StubChatGateway();
      await tester.pumpWidget(await _app(viewModel: await _viewModel(gateway)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-greeting')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();

      // 聊天态已经挂上，但问候还留在原位：它这一帧正从完全不透明开始淡。
      expect(find.byKey(const Key('home-greeting')), findsOneWidget);
      expect(_greetingFadeOpacity(tester), greaterThan(0.0));

      await tester.pump(QiyuMotion.base ~/ 2);
      expect(
        _greetingFadeOpacity(tester),
        inInclusiveRange(0.1, 0.9),
        reason: '切换后处于淡出途中，背景与问候走同一套 QiyuMotion 时长',
      );

      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-greeting')), findsNothing);
      expect(find.byKey(const Key('home-greeting-fade')), findsNothing);
    });

    testWidgets('reduced-motion 下问候不留中间值（Story 22）', (tester) async {
      final gateway = _StubChatGateway();
      await tester.pumpWidget(
        await _app(viewModel: await _viewModel(gateway), reducedMotion: true),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();

      expect(_greetingFadeOpacity(tester), 0.0, reason: '动效归零，不留淡出途中');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-greeting')), findsNothing);
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
    testWidgets('发送钮：玻璃紫渐变 + onAccent 图标，无描边无白色高光', (tester) async {
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
        tester.widget<Icon>(find.byIcon(QiyuIcons.arrow_upward)).color,
        QiyuColors.onAccent,
      );
      expect(tester.getSize(find.byKey(const Key('chat-send'))), const Size(34, 34));
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('composer：胶囊全圆角 + line 发丝描边，聚焦描边紫度 0.13', (tester) async {
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
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('生成中发送钮变停止钮（chat-send → chat-stop）', (tester) async {
      final gateway = _StubChatGateway(hold: true);
      await tester.pumpWidget(await _app(viewModel: await _viewModel(gateway)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      expect(find.byKey(const Key('chat-stop')), findsOneWidget);
      expect(find.byKey(const Key('chat-send')), findsNothing);
      expect(find.byIcon(QiyuIcons.stop), findsOneWidget);

      gateway.release();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-send')), findsOneWidget);
    });
  });

  group('焦点环与 reduced-motion', () {
    testWidgets('自绘焦点环：2px accentBright 带 offset 外环，随键盘焦点出现', (tester) async {
      await _pumpShell(tester, width: 1200, height: 800);
      // 初始焦点在 composer，导航项的环是透明的：留白常驻，出现与消失都不跳版。
      expect(
        readFocusRingBorderIn(tester, const Key('nav-history')).color,
        isNot(QiyuColors.accentBright),
      );

      // 遍历顺序按阅读序、且起点在输入框，所以逐次 Tab 直到落进导航项；
      // 落不进去就是缺陷，不能靠放宽断言蒙过去。
      var landed = false;
      for (var i = 0; i < 8 && !landed; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        landed =
            readFocusRingBorderIn(tester, const Key('nav-history')).color == QiyuColors.accentBright;
      }
      expect(landed, isTrue, reason: '键盘 Tab 落到导航项必须出现 accentBright 外环');

      final border = readFocusRingBorderIn(tester, const Key('nav-history'));
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

  group('导航返回栈（行为不变量，本轮纯视觉换皮不动它）', () {
    testWidgets('换栈进功能页后，侧边栏选中态跟着当前目的地走', (tester) async {
      await _pumpShell(tester, width: 1200, height: 800);

      await tester.tap(find.byKey(const Key('home-go-history')));
      await tester.pumpAndSettle();

      expect(_location(tester), '/history');
      expect(find.byType(QiyuShell), findsOneWidget, reason: '功能页也挂着壳');
      expect(
        _navItemContainer(tester, 'nav-history').color,
        QiyuColors.selectedNeutral,
        reason: '`go` 换栈之后当前位置就是历史，选中态必须落在它上面',
      );
      expect(
        _navItemContainer(tester, 'nav-memory').color,
        isNot(QiyuColors.selectedNeutral),
      );
    });

    testWidgets('侧边栏是换栈：过去的一站不留在栈里，页内返回落回合一页', (tester) async {
      await _pumpShell(tester, width: 1200, height: 800, at: '/chat');
      expect(_location(tester), '/chat');

      await tester.tap(find.byKey(const Key('home-go-history')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/history');

      await tester.tap(find.byKey(const Key('history-back')));
      await tester.pumpAndSettle();

      // 常驻顶层导航每次换掉当前位置，所以这一跳没有可弹的层，返回兜底落回
      // 合一页：`backToPrevious` 走 `/chat` 而不是 `/`——`/` 在壳外，跳过去
      // 会销毁重建整只导航壳；落点页面是同一个，断言的是路由位置。上一段
      // 那种「目标不在栈里就 push 叠栈」的写法会回到路过的 /chat。
      expect(_location(tester), '/chat');
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
    });

    testWidgets('工具条入口是叠栈：进历史再返回，回到的是原来那段会话', (tester) async {
      final gateway = _StubChatGateway(
        restored: const [
          LocalChatMessage(
            requestId: 'r-1',
            speaker: LocalChatSpeaker.user,
            text: '昨晚聊到一半',
          ),
        ],
      );
      await _pumpShell(
        tester,
        width: 1200,
        height: 800,
        at: '/chat',
        viewModel: await _viewModel(gateway),
      );
      expect(find.text('昨晚聊到一半'), findsOneWidget);

      await tester.tap(find.byKey(const Key('open-history')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/history');

      await tester.tap(find.byKey(const Key('history-back')));
      await tester.pumpAndSettle();

      expect(_location(tester), '/chat', reason: '弹出的是刚压上去的那一层');
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
      expect(find.text('昨晚聊到一半'), findsOneWidget, reason: '还是原来那个会话');
    });
  });
}

// ---------- 装配 ----------

/// 壳 + 合一页的 harness：视口、路由位置、探测结果与 reduced-motion
/// 都在这里注入，用例只断言外部可观察行为。
///
/// 路由表**就是生产的 [qiyuRoutes]**，harness 只额外指定初始位置。之前这里
/// 自抄了一份九条路由的副本（注释还写着「与 lib/app.dart 完全一致」），验的
/// 其实是副本：生产把壳挂到哪些页、路径集合怎么改，这里都不会变红。
///
/// 页面需要的依赖仍在外层注入：合一页要 [LocalChatViewModel]，`/` 的初见门禁
/// 要一个已完成的 [OnboardingViewModel]，`/history` 要 [HistoryViewModel]。
Future<void> _pumpShell(
  WidgetTester tester, {
  required double width,
  required double height,
  String at = '/',
  bool drawerOpen = false,
  bool settle = true,
  bool reducedMotion = false,
  _StubProbe? probe,
  LocalChatViewModel? viewModel,
  LocaleController? localeController,
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
      localeController: localeController,
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
  LocaleController? localeController,
}) async {
  final ctrl = localeController ?? LocaleController();
  final chat = viewModel ??
      await _viewModel(_StubChatGateway(), probe: probe, localeController: ctrl);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<LocaleController>.value(value: ctrl),
      ChangeNotifierProvider.value(value: chat),
      ChangeNotifierProvider.value(value: await _onboardingViewModel()),
      ChangeNotifierProvider.value(value: _historyViewModel()),
    ],
    child: MaterialApp.router(
      routerConfig: GoRouter(initialLocation: at, routes: qiyuRoutes()),
      theme: qiyuDarkTheme(),
      // reduced-motion：Web 引擎把 prefers-reduced-motion 映射到
      // AccessibilityFeatures.disableAnimations，测试侧同样从这一位进。
      builder: reducedMotion
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child ?? const SizedBox.shrink(),
            )
          : null,
    ),
  );
}

/// 初见已完成：`/` 走 [RootView] 的门禁后落回合一页，而不是停在初见页。
Future<OnboardingViewModel> _onboardingViewModel() async {
  final viewModel = OnboardingViewModel(
    _CompletedOnboardingGateway(),
    _UnconfiguredProviderGateway(),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}

/// 历史页的 view model：本文件只借它的页面外壳验壳的位置与返回栈，
/// 不验内容，所以 autoStart 关掉（列表保持空态，不留下转个不停的进度条）。
HistoryViewModel _historyViewModel() => HistoryViewModel(
  _EmptyHistoryGateway(),
  onSessionDeleted: (_) {},
  autoStart: false,
);

/// 当前路由路径：go_router 17 的 `GoRouterState` 没有对外可读的当前位置，只能
/// 从代理的匹配列表读。四条挂壳路由收在同一个壳路由下（见 [qiyuRoutes] 的
/// 注释），壳页之间的切换与叠栈都发生在壳匹配的内层，所以取最里层叶子的
/// `matchedLocation`：直接读最外一层会把叠栈与换页都看成停在原地。
String _location(WidgetTester tester) {
  final matches = GoRouter.of(
    tester.element(find.byType(QiyuShell).last),
  ).routerDelegate.currentConfiguration.matches;
  var last = matches.last;
  while (last is ShellRouteMatch) {
    last = last.matches.last;
  }
  return last.matchedLocation;
}

Future<LocalChatViewModel> _viewModel(
  StreamingLocalChatGateway gateway, {
  HostConnectionProbe? probe,
  bool hostStopped = false,
  LocaleController? localeController,
}) async {
  final viewModel = LocalChatViewModel(
    gateway,
    hostConnectionProbe: probe ?? _StubProbe(available: !hostStopped),
    autoStart: false,
    localeController: localeController,
  );
  await viewModel.initialize();
  return viewModel;
}

/// 问候淡出层当前的透明度：按固定键定位这一层，读它的 `FadeTransition`。
/// 量的就是「问候淡到哪了」，不碰页面结构。
double _greetingFadeOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: find.byKey(const Key('home-greeting-fade')),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

/// 三条杠的焦点节点：壳持有它并同时交给焦点环与 `InkWell`，测试从按钮上读
/// 到的就是同一个节点——断言的是「焦点有没有落在这个可激活控件上」，不是树结构。
FocusNode _menuButtonFocusNode(WidgetTester tester) =>
    tester.widget<InkWell>(find.byKey(const Key('nav-menu-button'))).focusNode!;

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
  find
      .descendant(of: find.byKey(Key(ringKey)), matching: find.byType(Text))
      .last,
);

Text _toggleText(WidgetTester tester, String key) => tester.widget<Text>(
  find
      .descendant(of: find.byKey(Key(key)), matching: find.byType(Text))
      .first,
);
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

/// 初见已完成：让 `/` 过 [RootView] 的门禁后回到合一页。
final class _CompletedOnboardingGateway implements OnboardingGateway {
  @override
  Future<OnboardingState> read() async =>
      const OnboardingState(completed: true);

  @override
  Future<void> complete({String? appellation}) async {}
}

/// 未配置模型服务：初见门禁只读这一个方法判断「配好了没有」。
final class _UnconfiguredProviderGateway implements ProviderSettingsGateway {
  @override
  Future<ProviderSettings> read() async =>
      const ProviderSettings(configured: false, keySet: false);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
}

/// 空历史：本文件只借历史页的外壳验壳的位置与返回栈，不验列表内容。
final class _EmptyHistoryGateway implements HistoryGateway {
  @override
  Future<HistoryListing> fetchHistory() async =>
      const HistoryListing(latestSessionId: null, days: [], unavailable: []);

  @override
  Future<void> deleteSession(String sessionId) async {}
}

final class _StubChatGateway implements StreamingLocalChatGateway {
  _StubChatGateway({
    List<LocalChatMessage> restored = const [],
    this.hold = false,
  }) : _restored = LocalChatSnapshot(
         sessionId: 'session-1',
         messages: restored,
       );

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
  Future<bool> stopVoice(String requestId) async => true;

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
    yield LocalChatDeliveryEvent.accepted(
      requestId: requestId,
      sessionId: _restored.sessionId,
    );
    yield LocalChatDeliveryEvent.waiting(
      requestId: requestId,
    );
    if (hold) {
      await _gate.future;
    }
    yield LocalChatDeliveryEvent.delta(
      requestId: requestId,
      text: '在的。',
    );
    yield LocalChatDeliveryEvent.message(
      requestId: requestId,
      messages: const ['在的。'],
    );
    yield LocalChatDeliveryEvent.state(
      requestId: requestId,
      source: ReplySource.local,
    );
    yield LocalChatDeliveryEvent.done(
      requestId: requestId,
    );
  }
}
