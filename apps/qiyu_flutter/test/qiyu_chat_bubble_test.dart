import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/qiyu_chat_bubble.dart';
import 'package:qiyu_flutter/features/chat/qiyu_hover_gate.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:qiyu_flutter/features/history/history_view.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/time_format.dart';
import 'package:qiyu_flutter/theme/qiyu_icons.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

import 'support/shared_fakes.dart';

void main() {
  // 本地时刻构造（不走 UTC 换算）：断言与测试机时区无关。
  final moment = DateTime(2026, 9, 2, 23, 41);
  const label = '9月2日 23:41';

  // 门控 + 真实 ListView 的共用底座：消息正文足够长，气泡宽度盖过视口
  // 中线——滚轮把它滑到静止光标下时光标落得进 MouseRegion，不是落在
  // 空白处凑数；正文两行多行高，快扫跨气泡的样本距离也够拉开。
  Future<void> pumpGatedList(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: QiyuHoverGate(
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

  // 鼠标指针：先落到起点（自动按命中派发进出场），用完即摘。起点若压
  // 着气泡，多泵一拍让显现延迟阀（80ms）到期——门控组里「滚动开始即
  // 隐藏已显现的行」等用例依赖这一步真的显出来；起点在空白处时这一拍
  // 无副作用。
  Future<TestGesture> mouseAt(WidgetTester tester, Offset location) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: location);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return mouse;
  }

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

    testWidgets('桌面悬停显现时刻行，后续消息位置不变（时刻位常驻预留）', (tester) async {
      final first = QiyuChatBubble(text: '临睡随手记的', fromUser: true, at: moment);
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            first,
            QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
          ],
        ),
      );

      // 未显现：时刻行不进树，但 30px 槽位已常驻占位——所以显现前后
      // 第二条消息 top 必须逐像素相同（旧条件进树实现实测下移 21px）。
      expect(find.text(label), findsNothing);
      final topBefore = tester.getTopLeft(find.text('晚安。')).dy;

      await mouseAt(tester, tester.getCenter(find.text('临睡随手记的')));
      expect(find.text(label), findsOneWidget);

      final topAfter = tester.getTopLeft(find.text('晚安。')).dy;
      expect(topAfter, topBefore, reason: '显现时刻不得推移后续消息');

      // 几何保真：显现后时刻文字顶 = 气泡底 + 2px（槽位内的显隐间隙
      // 语义与旧条件进树形态逐像素一致）。
      expect(
        tester.getTopLeft(find.text(label)).dy,
        tester.getBottomLeft(userBubbleBox).dy + 2,
      );
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
        hostConnectionProbe: FakeHostConnectionProbe(const [true]),
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
        hostConnectionProbe: FakeHostConnectionProbe(const [true]),
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

    // 门控底座 pumpGatedList 与 mouseAt 提升到 main 作用域：
    // 「指针行进抑制与显现延迟回归锁」组同样要用。

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
      // 显现经 80ms 延迟阀，多泵一拍余量。
      await mouse.moveTo(tester.getCenter(find.text('临睡随手记的')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
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
      await tester.pump(const Duration(milliseconds: 100));
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

      // 第一条块底的 sm（12px）间距：时刻位常驻预留后，气泡底缘之下
      // 2…30px 已是本条消息的空槽带（悬停即显现本条时刻），落点取槽位
      // 带之下的块底间距内（气泡底 +33px）——这段 padding 在 MouseRegion
      // 外，两条消息热区以此带分界不连片。
      final gapSpot =
          tester.getBottomRight(userBubbleBox) - const Offset(10, -33);
      final mouse = await mouseAt(tester, const Offset(0, 0));
      await mouse.moveTo(gapSpot);
      await tester.pump();
      expect(find.text(label), findsNothing, reason: '空槽带之下才是块底间距，仍在热区外不显现');

      await mouse.moveTo(tester.getCenter(find.text('临睡随手记的')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('空槽带（时刻位置）悬停即显现，槽下块底间距不显现', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(text: '临睡随手记的', fromUser: true, at: moment),
      );

      // 气泡正下方的空槽带（气泡底 +2…+30，时刻的常驻预留位）属于本条
      // 消息热区：悬停即显现——「时间本来就在那里，鼠标挪到那个地方
      // 自动显示」。落点取带内中段（气泡底 +12）。
      final bubbleBottomRight = tester.getBottomRight(userBubbleBox);
      final mouse = await mouseAt(
        tester,
        bubbleBottomRight - const Offset(10, -12),
      );
      expect(find.text(label), findsOneWidget, reason: '空槽带属于本条消息热区：悬停时刻位置即显现');

      // 移到槽位带之下的块底 sm 间距（气泡底 +33）：出热区立即隐藏。
      await mouse.moveTo(bubbleBottomRight - const Offset(10, -33));
      await tester.pump();
      expect(find.text(label), findsNothing, reason: '槽位带之下的块底间距仍在热区外');
    });

    testWidgets('无时刻数据不占位：at 为 null 的消息块不含预留带', (tester) async {
      // 对照设计：第一条不带时刻，第二条带时刻。at 为 null（生产链路
      // 恒非空，这里只剩测试与防御路径）必须回到无时刻语义——气泡底
      // 直接接块底 sm 间距，不出现 30px 常驻槽位。
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QiyuChatBubble(text: '临睡随手记的', fromUser: true),
            QiyuChatBubble(text: '晚安。', fromUser: false, at: moment),
          ],
        ),
      );
      final nextTopWithoutAt = tester.getTopLeft(find.text('晚安。')).dy;
      final bubbleBottomWithoutAt = tester.getBottomLeft(userBubbleBox).dy;
      expect(
        nextTopWithoutAt - bubbleBottomWithoutAt,
        QiyuSpacing.sm,
        reason: 'at 为 null 不占位：块底间距就是 sm（12px）',
      );

      // 对照：at 非空（未显现）时恰好多出 30px 常驻槽位。
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
      final nextTopWithAt = tester.getTopLeft(find.text('晚安。')).dy;
      final bubbleBottomWithAt = tester.getBottomLeft(userBubbleBox).dy;
      expect(
        nextTopWithAt - bubbleBottomWithAt,
        QiyuSpacing.sm + 30,
        reason: 'at 非空未显现时槽位常驻：sm 间距 + 30px 槽位',
      );
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

    testWidgets('静止光标下滚轮滚动：期间与缓冲窗内不显现，过期后指针停在块上自动显现', (tester) async {
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

      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(label), findsNothing);
      // 缓冲窗（500ms）已过期：指针停在消息块上，无需任何新指针事件
      // 自动显现（死区修复的主语义）。抑制解除发生在过窗那一拍的帧末，
      // 气泡侧 80ms 显现阀随后到期——再多泵一拍。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
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
      // 缓冲窗加长到 500ms：窗内不显现（400ms < 500ms 不贴边）。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsNothing);

      // 轻移 1px：指针没有进出边界，onEnter 不会来，必须由 onHover
      // 放行显现——缺这条会出现「轻移不显现」死角。放行经 80ms 延迟阀，
      // 多泵一拍余量。
      await tester.pump(const Duration(milliseconds: 200));
      await mouse.moveBy(const Offset(1, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
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

      // 缓冲窗（500ms）内不显现；过期后轻移放行（经 80ms 延迟阀）。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      await mouse.moveBy(const Offset(1, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('抑制解除时指针停在消息块上：不派发任何新指针事件也自动显现', (tester) async {
      await pumpGatedList(tester);
      const park = Offset(400, 8);
      await mouseAt(tester, park);
      final target = tester.getRect(find.textContaining('第 3 条'));
      // 滚动把第 3 条滑到静止光标下：光标落进气泡，onEnter 被门控拦下
      // 但指针已停在块上（旧实现拦下时什么都不记，解除后无从恢复）。
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: park,
          scrollDelta: Offset(0, target.center.dy - park.dy),
        ),
      );
      await tester.pump();
      expect(find.text(label), findsNothing, reason: '缓冲窗内不显现');

      // 缓冲窗（500ms）整体过期 + 余量：全程零指针事件，时刻应自动
      // 显现——指针停稳后 Flutter 不再派发事件，若显现只认新的
      // onEnter/onHover，这里就是死区。抑制解除发生在过窗那一拍的帧
      // 末，80ms 显现阀随后到期——再多泵一拍。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('抑制解除时指针在列表空白处：不显现，轻移 1px 才显', (tester) async {
      await pumpGatedList(tester);
      // 量出第 0 条（用户气泡）的块顶（MouseRegion 上缘 = 气泡容器顶 =
      // 文本顶 - 容器纵向内边距 sm），滚动量让它停在光标下方 1px 处：
      // 指针全程停在顶部 padding 空白里，没有任何气泡滑到光标下。
      const park = Offset(400, 8);
      final mouse = await mouseAt(tester, park);
      final textTop = tester.getTopLeft(find.textContaining('第 0 条')).dy;
      final blockTop = textTop - QiyuSpacing.sm;
      final delta = blockTop - park.dy - 1;
      await tester.sendEventToBinding(
        PointerScrollEvent(position: park, scrollDelta: Offset(0, delta)),
      );
      await tester.pump();
      expect(find.text(label), findsNothing, reason: '缓冲窗内不显现');

      // 缓冲窗整体过期 + 80ms 显现阀余量：指针不在任何消息块上，自动
      // 显现不触发——与主锁互为对照，主动显现只落在「指针停在块上」
      // 的情形。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsNothing, reason: '空白处不自动显现');

      // 轻移 1px 跨进气泡块：enter 放行（经 80ms 显现阀）后显现。
      await mouse.moveBy(const Offset(0, 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
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

  group('指针行进抑制与显现延迟回归锁', () {
    // 快速移动与滚轮同属「行进」：门控对 hover 事件做速度采样
    // （0.5px/ms 阈值、16ms 采样地板），超速即压上与滚动相同的抑制位；
    // 气泡侧显现经 80ms 延迟阀，兜「同一事件里气泡 onEnter 先于门控
    // onHover」的一事件滞后。事件时间戳经 TestGesture 的 timeStamp 参数
    // 显式给定——速度判定只看事件时间戳，与挂钟无关；衰减窗走 FakeAsync
    // 挂钟，用 pump 推进，快慢样本的时间戳间距刻意远离阈值（0.5px/ms）
    // 与地板（16ms），不贴边。
    testWidgets('快速移动扫过多颗气泡：行进中与缓冲窗内不显现，过期后停在块上自动显现', (tester) async {
      await pumpGatedList(tester);
      final mouse = await mouseAt(tester, const Offset(400, 8));
      // 三个高速样本：第 1 → 3 → 4 条。第 1→3 步距跨过整颗第 2 条高
      // 气泡（正文多行），高速样本跨大气泡的覆盖就在这一步。
      var t = const Duration(milliseconds: 20);
      await mouse.moveTo(
        tester.getCenter(find.textContaining('第 1 条')),
        timeStamp: t,
      );
      await tester.pump();
      t += const Duration(milliseconds: 20);
      await mouse.moveTo(
        tester.getCenter(find.textContaining('第 3 条')),
        timeStamp: t,
      );
      await tester.pump();
      t += const Duration(milliseconds: 20);
      await mouse.moveTo(
        tester.getCenter(find.textContaining('第 4 条')),
        timeStamp: t,
      );
      await tester.pump();
      expect(find.text(label), findsNothing, reason: '行进中不显现');

      // 停稳：衰减窗（最后快速样本 +500ms）未过期，仍不显现。
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(label), findsNothing);

      // 缓冲窗过期：指针停在消息块上，无需新指针事件自动显现。抑制
      // 解除发生在过窗那一拍的帧末，80ms 显现阀随后到期——多泵一拍。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('快速移动停稳满缓冲窗后：停在块上自动显现，随后的轻移不再必要', (tester) async {
      await pumpGatedList(tester);
      final mouse = await mouseAt(tester, const Offset(400, 8));
      // 先原地轻挪落一个采样，再单步高速甩到第 2 条上（约 12px/ms），
      // 随即停稳。
      await mouse.moveBy(
        const Offset(0, 12),
        timeStamp: const Duration(milliseconds: 10),
      );
      await tester.pump();
      await mouse.moveTo(
        tester.getCenter(find.textContaining('第 2 条')),
        timeStamp: const Duration(milliseconds: 30),
      );
      await tester.pump();

      // 缓冲窗（500ms）过期前不显现；过期后指针停在块上自动显现，
      // 无需任何新指针事件（抑制解除在过窗那一拍的帧末生效，80ms 显
      // 现阀多泵一拍到期）。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);

      // 已显现后的轻移无感：hover 放行路径仍在，但不改变状态。
      await mouse.moveBy(
        const Offset(1, 0),
        timeStamp: const Duration(milliseconds: 620),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('持续快速移动期间行进抑制一直保持（每个快速样本都重启衰减窗）', (tester) async {
      await pumpGatedList(tester);
      final center1 = tester.getCenter(find.textContaining('第 1 条'));
      final center2 = tester.getCenter(find.textContaining('第 2 条'));
      final mouse = await mouseAt(tester, const Offset(400, 8));
      // 在两颗气泡间来回快速扫 12 趟：每趟约 100px/50ms = 2px/ms，挂钟
      // 每趟推进 50ms——总时长 600ms 超过缓冲窗，若衰减窗不从最后一个
      // 快速样本重算，停稳后轻移的时刻就对不上。
      var t = const Duration(milliseconds: 20);
      for (var i = 0; i < 12; i++) {
        await mouse.moveTo(i.isEven ? center2 : center1, timeStamp: t);
        await tester.pump(const Duration(milliseconds: 50));
        t += const Duration(milliseconds: 50);
        if (i == 5) {
          expect(find.text(label), findsNothing, reason: '行进中不显现');
        }
      }
      expect(find.text(label), findsNothing);

      // 停稳：衰减窗从最后一个快速样本起算，停稳点 +500ms 内轻移被压住。
      await tester.pump(const Duration(milliseconds: 150));
      await mouse.moveBy(const Offset(1, 0), timeStamp: t);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsNothing, reason: '缓冲窗未过期：轻移不显现');

      // 窗口过期后轻移放行。
      await tester.pump(const Duration(milliseconds: 400));
      await mouse.moveBy(
        const Offset(1, 0),
        timeStamp: t + const Duration(milliseconds: 550),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('慢速移动挪到气泡上：速度低于阈值不触发行进，经显现延迟后照常出现', (tester) async {
      await pumpGatedList(tester);
      final target = tester.getCenter(find.textContaining('第 1 条'));
      final mouse = await mouseAt(tester, const Offset(400, 8));
      // 三步慢速（每步约 50px/200ms ≈ 0.25px/ms，低于 0.5 阈值）挪到
      // 第 1 条上：不触发行进抑制，显现只过多态延迟。
      var t = const Duration(milliseconds: 200);
      var position = const Offset(400, 8);
      for (var i = 0; i < 3; i++) {
        position += Offset(0, (target.dy - position.dy) / (3 - i));
        await mouse.moveTo(position, timeStamp: t);
        await tester.pump();
        t += const Duration(milliseconds: 200);
      }
      expect(find.text(label), findsNothing, reason: '显现延迟（80ms）未到');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('快速甩入气泡随即停稳：延迟到期复查丢弃，缓冲窗过期后停在块上自动显现', (tester) async {
      await pumpGatedList(tester);
      final mouse = await mouseAt(tester, const Offset(400, 8));
      // 先原地轻挪落一个采样，再单步高速甩进第 1 条——同一事件里气泡的
      // onEnter 先于门控的 onHover 派发（一事件滞后），裸判会闪：显现
      // 延迟到期复查时行进抑制已生效，丢弃不显现。
      await mouse.moveBy(
        const Offset(0, 12),
        timeStamp: const Duration(milliseconds: 10),
      );
      await tester.pump();
      await mouse.moveTo(
        tester.getCenter(find.textContaining('第 1 条')),
        timeStamp: const Duration(milliseconds: 30),
      );
      await tester.pump();
      expect(find.text(label), findsNothing, reason: '显现延迟内');

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsNothing, reason: '延迟到期复查：行进抑制已生效，丢弃');

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget, reason: '缓冲窗过期：停在块上自动显现，无需轻移');

      // 已显现后的轻移无感：hover 放行路径仍在，但不改变状态。
      await mouse.moveBy(
        const Offset(1, 0),
        timeStamp: const Duration(milliseconds: 620),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('滚动缓冲期内快速移动：抑制无缝衔接，滚动窗过期后行进继续压住', (tester) async {
      await pumpGatedList(tester);
      const park = Offset(400, 8);
      final mouse = await mouseAt(tester, park);
      final item3 = tester.getRect(find.textContaining('第 3 条'));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: park,
          scrollDelta: Offset(0, item3.center.dy - park.dy),
        ),
      );
      await tester.pump();
      final item4 = tester.getRect(find.textContaining('第 4 条'));
      // 滚动缓冲期内快速移动：先在原地落一个采样（挂钟推进到滚动窗中
      // 段），再单步高速甩到第 4 条上——行进窗从这一样本起算，晚于
      // 滚动窗过期。
      await mouse.moveBy(
        const Offset(0, 12),
        timeStamp: const Duration(milliseconds: 200),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await mouse.moveTo(
        item4.center,
        timeStamp: const Duration(milliseconds: 220),
      );
      await tester.pump();

      // 滚动窗（≈600ms）过期、行进窗（≈800ms）未过期：轻移仍被压住。
      await tester.pump(const Duration(milliseconds: 400));
      await mouse.moveBy(
        const Offset(1, 0),
        timeStamp: const Duration(milliseconds: 700),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsNothing, reason: '滚动窗已过期，行进窗未过期——无缝衔接');

      // 行进窗也过期后：轻移放行显现。
      await tester.pump(const Duration(milliseconds: 200));
      await mouse.moveBy(
        const Offset(1, 0),
        timeStamp: const Duration(milliseconds: 910),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget, reason: '两窗都过期后轻移放行');
    });

    testWidgets('行进缓冲期内开始滚动：ScrollStart 接管并复位已显现的行，衔接无缝', (tester) async {
      await pumpGatedList(tester);
      final center = tester.getCenter(find.textContaining('第 3 条'));
      final mouse = await mouseAt(tester, const Offset(400, 8));
      // 单步慢速挪到第 3 条上（首采样不判行进），经延迟显现。
      await mouse.moveTo(center, timeStamp: const Duration(milliseconds: 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);

      // 气泡内快速小幅晃动（80px/20ms）：行进置位，已显现的行不复位。
      await mouse.moveBy(
        const Offset(80, 0),
        timeStamp: const Duration(milliseconds: 30),
      );
      await tester.pump();
      await mouse.moveBy(
        const Offset(-80, 0),
        timeStamp: const Duration(milliseconds: 50),
      );
      await tester.pump();
      expect(find.text(label), findsOneWidget, reason: '行进抑制不复位已显现的行');

      // 行进缓冲期内开始滚动（12px：光标留在第 3 条内，onExit 不派发，
      // 复位只能来自滚动位翻转）——行进抑制压不住 ScrollStart 的复位。
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 12)),
      );
      await tester.pump();
      expect(find.text(label), findsNothing, reason: 'ScrollStart 复位已显现的行');

      // 行进窗与滚动窗先后过期之间无缝：任一未过期都压住轻移。
      await tester.pump(const Duration(milliseconds: 300));
      await mouse.moveBy(
        const Offset(1, 0),
        timeStamp: const Duration(milliseconds: 380),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsNothing, reason: '两窗均未过期：轻移不显现');

      await tester.pump(const Duration(milliseconds: 400));
      await mouse.moveBy(
        const Offset(1, 0),
        timeStamp: const Duration(milliseconds: 890),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget, reason: '两窗都过期后轻移放行');
    });

    testWidgets('行进抑制不复位已显现的行：气泡上快晃时间保持，移出即隐藏', (tester) async {
      await pumpGatedList(tester);
      final center = tester.getCenter(find.textContaining('第 1 条'));
      final mouse = await mouseAt(tester, const Offset(400, 8));
      await mouse.moveTo(center, timeStamp: const Duration(milliseconds: 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);

      // 气泡内快速小幅晃动：行进置位，但已显现的行不复位——人还在
      // 气泡上，时刻保持已显是合理的。
      await mouse.moveBy(
        const Offset(80, 0),
        timeStamp: const Duration(milliseconds: 30),
      );
      await tester.pump();
      await mouse.moveBy(
        const Offset(-80, 0),
        timeStamp: const Duration(milliseconds: 50),
      );
      await tester.pump();
      expect(find.text(label), findsOneWidget, reason: '行进抑制不复位已显现的时刻');

      // 移出气泡：onExit 立即隐藏（不门控），行进抑制拦不住退出路径。
      await mouse.moveBy(
        const Offset(-600, -600),
        timeStamp: const Duration(milliseconds: 70),
      );
      await tester.pump();
      expect(find.text(label), findsNothing);
    });

    testWidgets('高刷新率采样（逐帧间隔低于地板）：距离累计过地板仍判行进', (tester) async {
      await pumpGatedList(tester);
      final mouse = await mouseAt(tester, const Offset(400, 8));
      // 120Hz 屏的 pointermove 逐帧间隔约 8ms，全都低于 16ms 地板：
      // 基线若逐事件推进，每对样本都过不了地板，行进判定静默失灵，
      // 「快移闪时刻」原样复发。三段 8ms 间距样本在第 3 个事件（首个
      // 累计满地板者）以 12px/16ms = 0.75px/ms 过阈值判出行进——随后
      // 甩进第 2 条的显现经延迟阀到期复查被丢弃。
      var t = const Duration(milliseconds: 8);
      await mouse.moveTo(const Offset(400, 14), timeStamp: t);
      await tester.pump();
      t += const Duration(milliseconds: 8);
      await mouse.moveTo(const Offset(400, 20), timeStamp: t);
      await tester.pump();
      t += const Duration(milliseconds: 8);
      await mouse.moveTo(
        tester.getCenter(find.textContaining('第 2 条')),
        timeStamp: t,
      );
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsNothing, reason: '延迟到期复查：行进已由累计样本判定');

      await tester.pump(const Duration(milliseconds: 600));
      await mouse.moveBy(
        const Offset(1, 0),
        timeStamp: const Duration(milliseconds: 700),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget, reason: '缓冲窗过期后轻移放行');
    });

    testWidgets('单步甩入随即停稳：首采样只落基线不判行进，延迟阀放行显现', (tester) async {
      await pumpGatedList(tester);
      // 指针在列表内只产生一个采样（甩入气泡这一步）：首个采样只落基
      // 线，无从判行进——显现延迟到期复查放行。与「先有采样再甩入」
      // 的用例（到期被行进压制）互补，锁住文档登记的兜底路径；快速扫
      // 过则由 onExit 在延迟内撤销，不会闪。
      final mouse = await mouseAt(tester, const Offset(400, 8));
      await mouse.moveTo(
        tester.getCenter(find.textContaining('第 2 条')),
        timeStamp: const Duration(milliseconds: 20),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget, reason: '首采样不判行进：延迟到期放行');
    });

    testWidgets('死区中的快速轻移不再拖慢显现：窗过期后自动显现，无需恰好慢速的一下', (tester) async {
      await pumpGatedList(tester);
      final mouse = await mouseAt(tester, const Offset(400, 8));
      // 原地落基线，再单步高速甩到第 2 条上，随即停稳（行进窗 500ms）。
      await mouse.moveBy(
        const Offset(0, 12),
        timeStamp: const Duration(milliseconds: 10),
      );
      await tester.pump();
      await mouse.moveTo(
        tester.getCenter(find.textContaining('第 2 条')),
        timeStamp: const Duration(milliseconds: 30),
      );
      await tester.pump();

      // 窗内的「快速轻移」：起手颗距上次采样 200ms+，速度被摊薄成慢速
      // （放行、基线推进）；随后加速颗 11px/16ms 判行进、衰减窗重启。
      // 旧行为里起手颗调起的 80ms 显现阀被到期复查丢弃，动一下白动，
      // 用户只能靠某次恰好慢速的轻移脱困。
      await tester.pump(const Duration(milliseconds: 200));
      await mouse.moveBy(
        const Offset(1, 0),
        timeStamp: const Duration(milliseconds: 230),
      );
      await tester.pump();
      await mouse.moveBy(
        const Offset(11, 0),
        timeStamp: const Duration(milliseconds: 246),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text(label), findsNothing, reason: '快速轻移被行进抑制压住');

      // 衰减窗（从加速样本起算）过期：零指针事件，自动显现——不再需
      // 要恰好慢速的一下。抑制解除在过窗那一拍的帧末生效，80ms 显现阀
      // 多泵一拍到期。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
    });
  });

  group('消息一键复制（用户与栖语）', () {
    // 剪贴板桩：捕获 setData 写进来的全文，用完即撤，不污染别的用例。
    void mockClipboard(WidgetTester tester, ValueChanged<String?> onData) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (message) async {
          if (message.method == 'Clipboard.setData') {
            onData(
              (message.arguments as Map<Object?, Object?>)['text'] as String?,
            );
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
    }

    testWidgets('点复制钮：本条全文原样写进剪贴板', (tester) async {
      String? clipText;
      mockClipboard(tester, (text) => clipText = text);
      const fullText = '今晚想把这段话原样发给朋友，一个字都不要丢。';
      final handle = tester.ensureSemantics();
      try {
        await _pump(
          tester,
          QiyuChatBubble(
            text: fullText,
            fromUser: true,
            enableCopy: true,
            at: moment,
          ),
        );

        // 桌面路径：复制钮与时刻同一显隐，未悬停不在树里。
        expect(find.bySemanticsLabel('复制这条消息'), findsNothing);
        await _hoverMouse(tester, find.text(fullText));
        expect(find.bySemanticsLabel('复制这条消息'), findsOneWidget);

        await tester.tap(find.byIcon(QiyuIcons.content_copy));
        await tester.pump();

        expect(clipText, fullText, reason: '复制内容必须是这条消息的全文');
      } finally {
        handle.dispose();
      }
    });

    testWidgets('桌面悬停：复制钮与时刻同显同隐，落在时刻右侧同一行', (
      tester,
    ) async {
      await _pump(
        tester,
        QiyuChatBubble(
          text: '刚发的一句',
          fromUser: true,
          enableCopy: true,
          at: moment,
        ),
      );

      // 未悬停：时刻与复制钮都不在树里（摘除而非透明，语义树同样干净）。
      expect(find.text(label), findsNothing);
      expect(find.byIcon(QiyuIcons.content_copy), findsNothing);

      final mouse = await _hoverMouse(tester, find.text('刚发的一句'));

      // 悬停：同一行——时刻在左、复制钮在右，钮身右缘贴气泡尾缘。
      expect(find.text(label), findsOneWidget);
      expect(find.byIcon(QiyuIcons.content_copy), findsOneWidget);
      final momentRect = tester.getRect(find.text(label));
      final copyRect = tester.getRect(
        find.ancestor(
          of: find.byIcon(QiyuIcons.content_copy),
          matching: find.byType(IconButton),
        ),
      );
      expect(copyRect.left, greaterThan(momentRect.right));
      final bubbleRect = tester.getRect(
        find
            .ancestor(
              of: find.text('刚发的一句'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(copyRect.right, moreOrLessEquals(bubbleRect.right, epsilon: 0.5));

      // 移开空白：一起收起（同一个 revealed 开关，无第二套显隐逻辑）。
      await mouse.moveBy(const Offset(-600, -600));
      await tester.pump();
      expect(find.text(label), findsNothing);
      expect(find.byIcon(QiyuIcons.content_copy), findsNothing);
    });

    testWidgets('复制钮用户消息与栖语消息都出：各自落在本条时刻右侧', (
      tester,
    ) async {
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QiyuChatBubble(
              text: '我发的话',
              fromUser: true,
              enableCopy: true,
              at: moment,
            ),
            QiyuChatBubble(
              text: '她回的话',
              fromUser: false,
              enableCopy: true,
              at: moment,
            ),
          ],
        ),
      );

      // 未悬停：两条消息的时刻与复制钮都不在树里（摘除而非透明）。
      expect(find.text(label), findsNothing);
      expect(find.byIcon(QiyuIcons.content_copy), findsNothing);

      // 悬停用户气泡：时刻在左、复制在右同一行，整行右缘贴气泡尾缘。
      final mouse = await _hoverMouse(tester, find.text('我发的话'));
      expect(find.text(label), findsOneWidget);
      expect(find.byIcon(QiyuIcons.content_copy), findsOneWidget);
      var momentRect = tester.getRect(find.text(label));
      var copyRect = tester.getRect(
        find.ancestor(
          of: find.byIcon(QiyuIcons.content_copy),
          matching: find.byType(IconButton),
        ),
      );
      expect(copyRect.left, greaterThan(momentRect.right));
      expect(copyRect.top, moreOrLessEquals(momentRect.top, epsilon: 0.5));
      final bubbleRect = tester.getRect(
        find
            .ancestor(
              of: find.text('我发的话'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(copyRect.right, moreOrLessEquals(bubbleRect.right, epsilon: 0.5));

      // 移开：一起收。
      await mouse.moveBy(const Offset(0, -400));
      await tester.pump();
      expect(find.text(label), findsNothing);
      expect(find.byIcon(QiyuIcons.content_copy), findsNothing);

      // 悬停栖语消息：时刻照常显现，复制钮同样落在时刻右侧同一行；
      // 栖语的时刻行靠左——时刻文字左缘贴着文本块左缘。
      await mouse.moveTo(tester.getCenter(find.text('她回的话')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(label), findsOneWidget);
      expect(find.byIcon(QiyuIcons.content_copy), findsOneWidget);
      momentRect = tester.getRect(find.text(label));
      copyRect = tester.getRect(
        find.ancestor(
          of: find.byIcon(QiyuIcons.content_copy),
          matching: find.byType(IconButton),
        ),
      );
      expect(copyRect.left, greaterThan(momentRect.right));
      expect(copyRect.top, moreOrLessEquals(momentRect.top, epsilon: 0.5));
      final qiyuTextRect = tester.getRect(find.text('她回的话'));
      expect(
        momentRect.left,
        moreOrLessEquals(qiyuTextRect.left, epsilon: 1),
        reason: '栖语的时刻行应靠左，与文本块左缘齐平',
      );
    });

    testWidgets('触屏长按用户气泡：按压处弹出复制菜单，点它写剪贴板', (
      tester,
    ) async {
      String? clipText;
      mockClipboard(tester, (text) => clipText = text);
      await _pump(
        tester,
        Theme(
          data: ThemeData(platform: TargetPlatform.android),
          child: QiyuChatBubble(
            text: '手机上发的一句',
            fromUser: true,
            enableCopy: true,
            at: moment,
          ),
        ),
      );

      // 触屏路径没有常驻复制钮，也不随轻点确认显时刻而出现。
      expect(find.byIcon(QiyuIcons.content_copy), findsNothing);

      await tester.longPress(find.text('手机上发的一句'));
      // 菜单路由有入场动画，settle 后再断言与点击——半途的几何是动画
      // 中间态，不是最终落点。
      await tester.pumpAndSettle();
      expect(find.text('复制这条消息'), findsOneWidget);

      await tester.tap(find.text('复制这条消息'));
      await tester.pumpAndSettle();

      expect(clipText, '手机上发的一句', reason: '菜单项复制的必须是本条全文');
    });

    testWidgets('触屏长按栖语气泡：同样出复制菜单，点它写剪贴板', (
      tester,
    ) async {
      String? clipText;
      mockClipboard(tester, (text) => clipText = text);
      await _pump(
        tester,
        Theme(
          data: ThemeData(platform: TargetPlatform.android),
          child: QiyuChatBubble(
            text: '手机上回的一句',
            fromUser: false,
            enableCopy: true,
            at: moment,
          ),
        ),
      );

      // 触屏路径没有常驻复制钮，也不随轻点确认显时刻而出现。
      expect(find.byIcon(QiyuIcons.content_copy), findsNothing);

      await tester.longPress(find.text('手机上回的一句'));
      await tester.pumpAndSettle();
      expect(find.text('复制这条消息'), findsOneWidget);

      await tester.tap(find.text('复制这条消息'));
      await tester.pumpAndSettle();

      expect(clipText, '手机上回的一句', reason: '菜单项复制的必须是本条全文');
    });

    testWidgets('触屏长按起手滑动：拖拽胜出，不出复制菜单', (tester) async {
      await _pump(
        tester,
        Theme(
          data: ThemeData(platform: TargetPlatform.android),
          child: QiyuChatBubble(
            text: '手机上发的一句',
            fromUser: true,
            enableCopy: true,
            at: moment,
          ),
        ),
      );

      final touch = await tester.startGesture(
        tester.getCenter(find.text('手机上发的一句')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      // 滑动起手越过触摸 slop：拖拽识别器胜出、长按被否决。
      await touch.moveBy(const Offset(0, kTouchSlop + 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await touch.up();
      await tester.pump();

      expect(find.text('复制这条消息'), findsNothing);
    });

    testWidgets('鼠标长按不出菜单：桌面的入口只有悬停', (tester) async {
      await _pump(
        tester,
        QiyuChatBubble(
          text: '握住不放的一句',
          fromUser: true,
          enableCopy: true,
          at: moment,
        ),
      );

      // 悬停位复制钮在（桌面入口）：addPointer 落点（派发进出场）后
      // 过显现延迟阀。
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final center = tester.getCenter(find.text('握住不放的一句'));
      await mouse.addPointer(location: center);
      addTearDown(mouse.removePointer);
      await tester.pump();
      // 按住不放：down 落在同一点、之后零位移（先大幅移动再按住会超
      // slop 毙掉长按识别器，测不到真路径）。
      await mouse.down(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(QiyuIcons.content_copy), findsOneWidget);

      // 按住超过长按时长也不出菜单：不为鼠标造第二套入口。
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('复制这条消息'), findsNothing);
    });

    testWidgets('at 为 null 的防御路径：用户与栖语都在消息下方常驻一枚', (
      tester,
    ) async {
      await _pump(
        tester,
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QiyuChatBubble(
              text: '没有时刻的一条',
              fromUser: true,
              enableCopy: true,
            ),
            QiyuChatBubble(
              text: '她回的没有时刻',
              fromUser: false,
              enableCopy: true,
            ),
          ],
        ),
      );

      // 生产链路 at 恒非空；该路径没有悬停机制可用（MouseRegion 只在
      // at 非空时挂），复制钮常驻在位，不至于把入口彻底丢掉。
      expect(find.byIcon(QiyuIcons.content_copy), findsNWidgets(2));
      // 两枚都落在各自消息内容的下方：按纵向位置排序，上面的属用户
      // 消息、下面的属栖语消息。
      final userTextRect = tester.getRect(find.text('没有时刻的一条'));
      final qiyuTextRect = tester.getRect(find.text('她回的没有时刻'));
      final copyRects = tester
          .widgetList<IconButton>(find.byType(IconButton))
          .map((button) => tester.getRect(find.byWidget(button)))
          .toList()
        ..sort((a, b) => a.top.compareTo(b.top));
      expect(copyRects[0].top, greaterThan(userTextRect.bottom));
      expect(copyRects[1].top, greaterThan(qiyuTextRect.bottom));
    });

    testWidgets('默认不开启复制（历史回看档）：整页可选中，不给复制钮', (tester) async {
      await _pump(
        tester,
        const QiyuChatBubble(text: '我发的话', fromUser: true),
      );

      expect(find.byIcon(QiyuIcons.content_copy), findsNothing);
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

/// 桌面悬停：只有鼠标型指针才触发 MouseRegion 的进出场。显现经 80ms
/// 延迟阀，这里多泵一拍余量让时刻真的显出来（pump() 不推进时钟，Timer
/// 不会到期）。
Future<TestGesture> _hoverMouse(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
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
    yield LocalChatDeliveryEvent.error(
      requestId: requestId,
      code: 'chat_failed',
      text: '这条测试链路不发送消息。',
      retryable: false,
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
