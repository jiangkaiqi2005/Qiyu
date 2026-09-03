import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/qiyu_chat_bubble.dart';
import 'package:qiyu_flutter/features/chat/qiyu_scroll_hover_gate.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:qiyu_flutter/features/history/history_view.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/time_format.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

void main() {
  // 本地时刻构造（不走 UTC 换算）：断言与测试机时区无关。
  final moment = DateTime(2026, 9, 2, 23, 41);
  const label = '9月2日 23:41';

  group('formatMessageMoment 口语化时刻', () {
    test('M月D日 HH:mm，时分补零', () {
      expect(formatMessageMoment(DateTime(2026, 12, 31, 9, 5)), '12月31日 09:05');
    });

    test('完整日期跨零点与跨年都不歧义', () {
      expect(formatMessageMoment(DateTime(2026, 1, 1, 0, 7)), '1月1日 00:07');
    });
  });

  group('QiyuChatBubble 消息时刻', () {
    testWidgets('不带时刻的消息任何指针下都不渲染时间', (tester) async {
      await _pump(tester, const QiyuChatBubble(text: '晚安。', fromUser: false));

      expect(find.text(label), findsNothing);
    });

    testWidgets('桌面端默认完全不可见', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
      );

      expect(find.text(label), findsNothing);
    });

    testWidgets('桌面端悬停栖语文本块后淡显时刻，移开后消失', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
      );

      final mouse = await _hoverMouse(tester, find.text('晚安。'));
      expect(find.text(label), findsOneWidget);

      await mouse.moveBy(const Offset(-600, -600));
      await tester.pump();
      expect(find.text(label), findsNothing);
    });

    testWidgets('桌面端悬停用户气泡同样淡显时刻', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '临睡随手记的', fromUser: true, at: moment),
      );

      await _hoverMouse(tester, find.text('临睡随手记的'));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('触屏指针下时刻以约两成透明度常驻', (tester) async {
      await _pump(
        tester,
        Theme(
          data: ThemeData(platform: TargetPlatform.android),
          child: QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
        ),
      );

      expect(find.text(label), findsOneWidget);
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.text(label), matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, closeTo(0.2, 0.001));
    });

    testWidgets('形态随指针事件切换：先触后鼠，常驻转悬停显现', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
      );

      // 尚无指针事件：桌面平台档初始猜测是悬停显现，默认不可见。
      expect(find.text(label), findsNothing);

      // 触屏指针按下：转触屏路径，常驻淡显。
      await tester.tap(find.text('晚安。'));
      await tester.pump();
      expect(find.text(label), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        closeTo(0.2, 0.001),
      );

      // 鼠标悬停接管：转桌面路径——悬停时可见，移开即消失。
      final mouse = await _hoverMouse(tester, find.text('晚安。'));
      expect(find.text(label), findsOneWidget);
      await mouse.moveBy(const Offset(-600, -600));
      await tester.pump();
      expect(find.text(label), findsNothing);
    });

    testWidgets('时刻渲染进语义树，视觉弱化不丢信息', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await _pump(
          tester,
          Theme(
            data: ThemeData(platform: TargetPlatform.android),
            child: QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
          ),
        );

        expect(find.bySemanticsLabel(label), findsOneWidget);
      } finally {
        handle.dispose();
      }
    });
  });

  group('时刻行布局与触屏显现回归锁', () {
    // 用户气泡的装饰容器：带气泡圆角（20/20/6/20）的那个 DecoratedBox。
    final Finder userBubbleBox = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          (widget.decoration as BoxDecoration).borderRadius ==
              QiyuRadii.bubbleBorder,
    );

    testWidgets('用户消息的时刻行渲染在气泡装饰容器之外，右缘与气泡对齐', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '临睡随手记的', fromUser: true, at: moment),
      );

      // 对照组：气泡正文确实住在带气泡圆角的装饰容器里。
      expect(
        find.ancestor(of: find.text('临睡随手记的'), matching: userBubbleBox),
        findsOneWidget,
      );

      await _hoverMouse(tester, find.text('临睡随手记的'));
      expect(find.text(label), findsOneWidget);
      // 时刻行在气泡外部：不是任何装饰容器的后代（旧实现曾住在气泡内，
      // 出现即把气泡撑宽撑高）。
      expect(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
      // 用户消息的时刻行贴气泡尾部：右缘与气泡右缘同线。
      expect(
        tester.getTopRight(find.text(label)).dx,
        tester.getTopRight(userBubbleBox).dx,
      );
    });

    testWidgets('桌面悬停显现时刻行，用户气泡本体尺寸保持不变', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '临睡随手记的', fromUser: true, at: moment),
      );

      final sizeBefore = tester.getSize(userBubbleBox);
      await _hoverMouse(tester, find.text('临睡随手记的'));
      expect(find.text(label), findsOneWidget);
      // 时刻行出现在气泡外，气泡本体不随之变宽变高（旧实现 +102×21px）。
      expect(tester.getSize(userBubbleBox), sizeBefore);
    });

    testWidgets('桌面悬停显现时刻行，栖语文本块尺寸保持不变', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
      );

      // 栖语侧没有气泡装饰容器，改锁包住文本块的定宽 ConstrainedBox：
      // 时刻行若回到文本块内部，它会被撑高。
      final Finder bodyBox = find.byWidgetPredicate(
        (widget) =>
            widget is ConstrainedBox &&
            widget.constraints.maxWidth == QiyuLayout.messageMaxWidth,
      );
      expect(
        find.ancestor(of: find.text('晚安。'), matching: bodyBox),
        findsOneWidget,
      );
      final sizeBefore = tester.getSize(bodyBox);
      await _hoverMouse(tester, find.text('晚安。'));
      expect(find.text(label), findsOneWidget);
      expect(tester.getSize(bodyBox), sizeBefore);
    });

    testWidgets('触屏滑动滚过消息，过程中与结束后时刻都不显现', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
      );

      // 滑动滚动列表的起手式：按下后移动超过触摸 slop，拖拽识别器胜出、
      // tap 被否决——按下（down）本身不得触发触屏常驻显现。
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('晚安。')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, kTouchSlop + 20));
      await tester.pump();
      expect(find.text(label), findsNothing);

      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(find.text(label), findsNothing);

      await gesture.up();
      await tester.pump();
      expect(find.text(label), findsNothing);
    });

    testWidgets('触屏轻点用户气泡显现时刻，仍走常驻 0.2 档', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '临睡随手记的', fromUser: true, at: moment),
      );

      expect(find.text(label), findsNothing);
      await tester.tap(find.text('临睡随手记的'));
      await tester.pump();

      expect(find.text(label), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        closeTo(0.2, 0.001),
      );
    });

    testWidgets('ListView 滚动起手压过消息，拖拽胜出且时刻不显现', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: ListView(
              children: [
                // 20 条确保总高远超测试视口（600px），列表真实可滚。
                for (var i = 0; i < 20; i++)
                  QiyuChatBubble(text: '消息 $i', fromUser: i.isEven, at: moment),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('消息 0')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      // 第一步越过 kTouchSlop：拖拽识别器胜出、tap 被否决（这步增量被
      // 拖拽起点吞掉，列表还没动）；第二步才是真实的滚动位移。
      await gesture.moveBy(const Offset(0, -(kTouchSlop + 10)));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -50));
      await tester.pump();
      // 拖拽真的赢了：列表滚起来了。
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        greaterThan(0),
      );
      expect(find.text(label), findsNothing);

      await gesture.up();
      await tester.pump();
      expect(find.text(label), findsNothing);
    });
  });

  group('恢复链路的时刻', () {
    testWidgets('聊天页恢复的消息悬停可见时刻', (tester) async {
      final viewModel = LocalChatViewModel(
        _RestoredGateway(),
        hostConnectionProbe: _FixedHostConnectionProbe(),
        autoStart: false,
      );
      addTearDown(viewModel.dispose);
      await viewModel.initialize();
      await tester.pumpWidget(_chatHarness(viewModel));
      await tester.pumpAndSettle();

      // 桌面默认不可见，悬停后出现。
      expect(find.text(label), findsNothing);
      await _hoverMouse(tester, find.text('昨晚说的话'));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('历史回看页共用气泡同样悬停可见时刻', (tester) async {
      final viewModel = LocalChatViewModel(
        _RestoredGateway(),
        hostConnectionProbe: _FixedHostConnectionProbe(),
        autoStart: false,
      );
      addTearDown(viewModel.dispose);
      await viewModel.initialize();
      await tester.pumpWidget(
        MultiProvider(
          providers: [ChangeNotifierProvider.value(value: viewModel)],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: const HistorySessionView(sessionId: 'session-moment'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(label), findsNothing);
      await _hoverMouse(tester, find.text('昨晚说的话'));
      expect(find.text(label), findsOneWidget);
    });
  });

  group('悬停热区收紧与滚动抑制回归锁', () {
    // 用户气泡的装饰容器：带气泡圆角（20/20/6/20）的那个 DecoratedBox。
    final Finder userBubbleBox = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          (widget.decoration as BoxDecoration).borderRadius ==
              QiyuRadii.bubbleBorder,
    );

    // 栖语侧没有气泡装饰容器，锁包住文本块的定宽 ConstrainedBox。
    final Finder qiyuBodyBox = find.byWidgetPredicate(
      (widget) =>
          widget is ConstrainedBox &&
          widget.constraints.maxWidth == QiyuLayout.messageMaxWidth,
    );

    // 门控 + 真实 ListView 的共用底座：消息正文足够长，气泡宽度盖过视口
    // 中线——滚轮把消息滑到静止光标下时光标落得进 MouseRegion，不是
    // 落在空白处凑数。
    Future<void> pumpGatedList(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: QiyuScrollHoverGate(
              child: ListView.builder(
                padding: const EdgeInsets.all(QiyuSpacing.lg),
                itemCount: 30,
                itemBuilder: (context, index) => QiyuChatBubble(
                  text:
                      '第 $index 条消息：一段足够长的正文，确保气泡宽度'
                      '盖过视口中线，滚轮把它滑到静止光标下时光标落得进气泡。',
                  fromUser: index.isEven,
                  at: moment,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    // 鼠标指针：先落到起点（自动按命中派发进出场），用完即摘。
    Future<TestGesture> mouseAt(WidgetTester tester, Offset location) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: location);
      addTearDown(mouse.removePointer);
      await tester.pump();
      return mouse;
    }

    testWidgets('用户消息同行空白处悬停不显现时刻（热区收紧为内容块）', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '临睡随手记的', fromUser: true, at: moment),
      );

      // 气泡贴视口右缘，同行空白在其左侧（旧结构里全宽 Align 使这一带
      // 也在 MouseRegion 内，悬停即显现）。
      final emptySpot =
          tester.getTopLeft(userBubbleBox) - const Offset(60, -12);
      final mouse = await mouseAt(tester, const Offset(0, 0));
      await mouse.moveTo(emptySpot);
      await tester.pump();
      expect(find.text(label), findsNothing);

      // 同一指针移到气泡本体：照常显现——空白不显现不是鼠标事件没生效。
      await mouse.moveTo(tester.getCenter(find.text('临睡随手记的')));
      await tester.pump();
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('栖语消息同行空白处悬停不显现时刻（热区收紧为内容块）', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
      );

      // 文本块贴视口左缘，同行空白在其右侧。
      final emptySpot = tester.getTopRight(qiyuBodyBox) + const Offset(60, 12);
      final mouse = await mouseAt(tester, const Offset(780, 20));
      await mouse.moveTo(emptySpot);
      await tester.pump();
      expect(find.text(label), findsNothing);

      await mouse.moveTo(tester.getCenter(find.text('晚安。')));
      await tester.pump();
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('块底消息间距处悬停不显现时刻（相邻热区不再连片）', (tester) async {
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QiyuChatBubble(text: '临睡随手记的', fromUser: true, at: moment),
            QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
          ],
        ),
      );

      // 第一条块底的 sm（12px）间距：气泡底缘之下、第二条文本块之上。
      // 旧结构里这段 padding 在 MouseRegion 内，两条消息热区连成一片。
      final gapSpot =
          tester.getBottomRight(userBubbleBox) - const Offset(10, -3);
      final mouse = await mouseAt(tester, const Offset(0, 0));
      await mouse.moveTo(gapSpot);
      await tester.pump();
      expect(find.text(label), findsNothing);

      await mouse.moveTo(tester.getCenter(find.text('临睡随手记的')));
      await tester.pump();
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('滚动开始即隐藏已显现的行（滚轮一格）', (tester) async {
      await pumpGatedList(tester);
      final anchor = tester.getCenter(find.textContaining('第 1 条'));
      await mouseAt(tester, anchor);
      expect(find.text(label), findsOneWidget);

      // 机制隔离：滚动量小于光标到文本块底缘的余量，滚动后光标仍留在
      // 同一气泡内，onExit 不会派发——隐藏只能来自抑制位翻转触发的
      // didChangeDependencies 复位；之后每帧 MouseTracker 重算命中所
      // 派发的 onEnter 也被门控挡住。
      final textRect = tester.getRect(find.textContaining('第 1 条'));
      expect(textRect.bottom - anchor.dy, greaterThan(12));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: anchor, scrollDelta: const Offset(0, 12)),
      );
      await tester.pump();
      expect(find.text(label), findsNothing);
    });

    testWidgets('静止光标下滚轮滚动：期间与缓冲窗内都不显现，过期后不动也不显现', (tester) async {
      await pumpGatedList(tester);
      // 光标停在列表顶部 padding（任何消息之外），量好消息 3 的落点后
      // 滚动让它滑到光标下——没有门控时这一步会派发 onEnter 并显现。
      const park = Offset(400, 8);
      await mouseAt(tester, park);
      final target = tester.getRect(find.textContaining('第 3 条'));
      final delta = target.center.dy - park.dy;
      expect(delta, greaterThan(0));

      await tester.sendEventToBinding(
        PointerScrollEvent(position: park, scrollDelta: Offset(0, delta)),
      );
      await tester.pump();
      expect(find.text(label), findsNothing);

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(label), findsNothing);
      // 缓冲窗（250ms）已过期：指针没动就不会主动显现。
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsNothing);
    });

    testWidgets('缓冲窗过期后轻移 1px 经 onHover 显现', (tester) async {
      await pumpGatedList(tester);
      const park = Offset(400, 8);
      final mouse = await mouseAt(tester, park);
      final target = tester.getRect(find.textContaining('第 3 条'));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: park,
          scrollDelta: Offset(0, target.center.dy - park.dy),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(label), findsNothing);

      // 轻移 1px：指针没有进出边界，onEnter 不会来，必须由 onHover
      // 放行显现——缺这条会出现「轻移不显现」死角。
      await mouse.moveBy(const Offset(1, 0));
      await tester.pump();
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('jumpTo 滚动同样被门控：期间与缓冲窗内不显现，过期后轻移显现', (tester) async {
      await pumpGatedList(tester);
      const park = Offset(400, 8);
      final mouse = await mouseAt(tester, park);
      final target = tester.getRect(find.textContaining('第 3 条'));
      // 滚轮之外的补充路径：jumpTo 同样成对派发 Start/Update/End。
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .jumpTo(target.center.dy - park.dy);
      await tester.pump();
      expect(find.text(label), findsNothing);

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(label), findsNothing);
      await mouse.moveBy(const Offset(1, 0));
      await tester.pump();
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('气泡→2px 间隙→时刻行移动不产生进出场抖动', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
      );
      final mouse = await _hoverMouse(tester, find.text('晚安。'));
      expect(find.text(label), findsOneWidget);

      // 移进气泡底缘与时刻行之间的 2px 间隙：仍在同一 MouseRegion 内
      // （bounds 包住「气泡 + 时刻行」整体），不触发 onExit。
      final textBottom = tester.getBottomLeft(find.text('晚安。'));
      await mouse.moveTo(textBottom + const Offset(20, 1));
      await tester.pump();
      expect(find.text(label), findsOneWidget);

      // 继续移到时刻行本体：hover 保持。
      await mouse.moveTo(tester.getCenter(find.text(label)));
      await tester.pump();
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('滚轮滚动在真实 Scrollable 下派发 ScrollStart/Update/End 通知（门控依据）', (
      tester,
    ) async {
      final kinds = <Type>[];
      await tester.pumpWidget(
        MaterialApp(
          home: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              kinds.add(notification.runtimeType);
              return false;
            },
            child: ListView(children: const [SizedBox(height: 2000)]),
          ),
        ),
      );
      await tester.pump();

      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(400, 300),
          scrollDelta: Offset(0, 100),
        ),
      );
      await tester.pump();
      // 滚轮路径确实派发全套通知，列表层门控（监听 ScrollNotification）
      // 覆盖滚轮语义；若日后 Flutter 改掉这一点，这里先红。
      expect(
        kinds,
        containsAllInOrder(const [
          ScrollStartNotification,
          ScrollUpdateNotification,
          ScrollEndNotification,
        ]),
      );
    });
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  // 测试绑定默认平台是 android（触屏路径）：桌面断言显式注入 windows。
  TargetPlatform platform = TargetPlatform.windows,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pump();
}

/// 桌面悬停：只有鼠标型指针才触发 MouseRegion 的进出场。
Future<TestGesture> _hoverMouse(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump();
  return gesture;
}

Widget _chatHarness(LocalChatViewModel viewModel) {
  return MultiProvider(
    providers: [ChangeNotifierProvider.value(value: viewModel)],
    child: MaterialApp(
      // 桌面 Web 壳的平台档：悬停显隐是桌面/触屏的分岔点。
      theme: ThemeData(platform: TargetPlatform.windows),
      home: LocalChatView(
        voiceRecorderPlatform: _NoRecorderPlatform(),
        sttSettingsGateway: _FixedSttGateway(),
      ),
    ),
  );
}

final class _FixedHostConnectionProbe implements HostConnectionProbe {
  @override
  Future<bool> isHostAvailable() async => true;
}

final class _NoRecorderPlatform implements VoiceRecorderPlatform {
  @override
  bool get supported => false;

  @override
  Future<VoiceRecordingSession?> start() async => null;

  @override
  Future<RecordedAudio> toWav16kMono(RecordedAudio audio) async => audio;
}

final class _FixedSttGateway implements SttSettingsGateway {
  @override
  Future<SttSettings> read() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<SttSettings> forgetApiKey() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: false,
        status: ProviderTestStatus.notConfigured,
        message: '',
      );
}

/// 恢复缝：带时刻的旧会话（Host 的 `_turnToPublicJson` 已把 `at` 发下来）。
final class _RestoredGateway implements StreamingLocalChatGateway {
  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async {
    return LocalChatSnapshot(
      sessionId: 'session-moment',
      messages: [
        LocalChatMessage(
          requestId: 'old-1',
          speaker: LocalChatSpeaker.user,
          text: '昨晚说的话',
          at: restoredMoment,
        ),
        LocalChatMessage(
          requestId: 'old-1',
          speaker: LocalChatSpeaker.qiyu,
          text: '嗯，我在。',
          at: restoredReplyMoment,
        ),
      ],
    );
  }

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.error,
      requestId: requestId,
      text: '这条测试链路不发送消息。',
    );
  }

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '';
}

final DateTime restoredMoment = DateTime(2026, 9, 2, 23, 41);
final DateTime restoredReplyMoment = DateTime(2026, 9, 2, 23, 42);
