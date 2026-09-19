import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/chat/api_error_dialog.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart'
    show ProviderTestResult;
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

import 'support/shared_fakes.dart';

void main() {
  for (final restored in [false, true]) {
    for (final inset in [160.0, 203.0, 220.0]) {
      for (final textScale in [1.0, 2.0]) {
        testWidgets(
          '横屏键盘下输入和发送完整可点 restored=$restored inset=$inset scale=$textScale',
          (tester) async {
            tester.view.physicalSize = const Size(800, 360);
            tester.view.devicePixelRatio = 1;
            tester.view.padding = const FakeViewPadding(top: 36);
            addTearDown(tester.view.reset);
            tester.platformDispatcher.textScaleFactorTestValue = textScale;
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final gateway = _ConfigurableChatGateway(
              fallbackReasons: const [null],
            );
            if (restored) {
              gateway.restoredMessages = const [
                LocalChatMessage(
                  requestId: 'old',
                  speaker: LocalChatSpeaker.user,
                  text: '已有消息',
                ),
              ];
            }
            final model = await _pumpChatView(tester, gateway: gateway);
            await model.initialize();
            await tester.pumpAndSettle();
            final input = find.byKey(const Key('chat-input'));
            await tester.enterText(input, '横屏输入\n第二行\n第三行\n第四行\n第五行');
            tester.view.viewInsets = FakeViewPadding(bottom: inset);
            await tester.pumpAndSettle();
            for (final key in ['chat-input', 'chat-send', 'voice-mic']) {
              final target = find.byKey(Key(key));
              final rect = tester.getRect(target);
              expect(rect.top, greaterThanOrEqualTo(36));
              expect(rect.bottom, lessThanOrEqualTo(360 - inset));
              expect(target.hitTestable(), findsOneWidget);
              if (key != 'chat-input') {
                expect(rect.width, greaterThanOrEqualTo(48));
                expect(rect.height, greaterThanOrEqualTo(48));
              }
            }
            await tester.tap(find.byKey(const Key('chat-send')));
            await tester.pumpAndSettle();
            expect(gateway.deliverCallCount, 1);
            tester.view.viewInsets = const FakeViewPadding();
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('open-provider-settings')).hitTestable(),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant.only(TargetPlatform.android),
        );
      }
    }
  }
  group('安卓键盘输入意图', () {
    for (final keyboard in [false, true]) {
      testWidgets(
        '逐帧小步回读不会被贴底补跳中断 keyboard=$keyboard',
        (tester) async {
          tester.view.physicalSize = const Size(400, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
          gateway.restoredMessages = _variableHeightSessionWithMoments();
          final model = await _pumpChatView(tester, gateway: gateway);
          await model.initialize();
          await tester.pumpAndSettle();
          final position = tester
              .widget<ListView>(find.byType(ListView))
              .controller!.position;
          expect(position.pixels, closeTo(position.maxScrollExtent, 1));
          if (keyboard) {
            await tester.tap(find.byKey(const Key('chat-input')));
            tester.view.viewInsets = const FakeViewPadding(bottom: 300);
            await tester.pumpAndSettle();
          }
          expect(position.pixels, closeTo(position.maxScrollExtent, 1));
          expect(tester.binding.hasScheduledFrame, isFalse);
          await _dragHistoryInSteps(tester, steps: 30, closeKeyboard: keyboard);
          expect(
            position.maxScrollExtent - position.pixels,
            greaterThan(120),
            reason: '每帧仅移动 8px 的真实触摸必须持续回读，不得被 jumpTo 终止',
          );
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
    for (final send in [false, true]) {
      testWidgets(
        '短距离回读松手保持位置，主动回底或发送恢复跟随 send=$send',
        (tester) async {
          tester.view.physicalSize = const Size(400, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
          gateway.restoredMessages = _variableHeightSessionWithMoments();
          final model = await _pumpChatView(tester, gateway: gateway);
          await model.initialize();
          await tester.pumpAndSettle();
          final position = tester
              .widget<ListView>(find.byType(ListView))
              .controller!.position;
          expect(position.pixels, closeTo(position.maxScrollExtent, 1));
          await _dragHistoryInSteps(tester, steps: 10, closeKeyboard: false);
          final gap = position.maxScrollExtent - position.pixels;
          expect(gap, greaterThan(20));
          expect(gap, lessThan(120));
          final readingOffset = position.pixels;
          await tester.pump(const Duration(seconds: 1));
          expect(position.pixels, closeTo(readingOffset, 1));

          // 短回读即使仍在旧 120px 粘滞带内，键盘变化也不能恢复跟随。
          final field = find.byKey(const Key('chat-input'));
          await tester.tap(field);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          expect(position.pixels, closeTo(readingOffset, 1));
          await tester.tapAt(const Offset(200, 140));
          tester.view.viewInsets = const FakeViewPadding();
          await tester.pumpAndSettle();
          expect(position.pixels, closeTo(readingOffset, 1));

          if (send) {
            await tester.enterText(field, '回到底部');
            await tester.tap(find.byKey(const Key('chat-send')));
            await tester.pumpAndSettle();
          } else {
            await _dragHistoryInSteps(
              tester, steps: 20, closeKeyboard: false, towardBottom: true,
            );
          }
          expect(position.pixels, closeTo(position.maxScrollExtent, 1));
          // 用新的 viewport metrics 验证恢复的是跟随意图，而非仅偶然到底。
          await tester.tap(field);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          expect(position.pixels, closeTo(position.maxScrollExtent, 1));
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
    testWidgets(
      '严格贴底时向尾部拖动不丢贴底意图，弹键盘仍跟随',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
        gateway.restoredMessages = _variableHeightSessionWithMoments();
        final model = await _pumpChatView(tester, gateway: gateway);
        await model.initialize();
        await tester.pumpAndSettle();
        final position = tester
            .widget<ListView>(find.byType(ListView))
            .controller!.position;
        expect(position.pixels, closeTo(position.maxScrollExtent, 1));

        // 已严格贴底时向尾部真实拖动：pixels 已在底缘不再增大，列表只派
        // overscroll 而不派正向 update——这不能被当成回读。
        final gesture = await tester.startGesture(const Offset(200, 140));
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(
            const Offset(0, -8),
            timeStamp: Duration(milliseconds: (i + 1) * 16),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up(timeStamp: const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(position.pixels, closeTo(position.maxScrollExtent, 1));

        // 此后弹键盘必须仍然贴底跟随：用户从未表达回读意图。
        await tester.tap(find.byKey(const Key('chat-input')));
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(
          position.pixels,
          closeTo(position.maxScrollExtent, 1),
          reason: '贴底时朝尾部的边界拖动是误触，不得清除贴底意图',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
    testWidgets(
      '补跳已排队时开始真实拖动，回调不能终止拖动',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
        gateway.restoredMessages = _variableHeightSessionWithMoments();
        final model = await _pumpChatView(tester, gateway: gateway);
        await model.initialize();
        await tester.pumpAndSettle();
        final position = tester
            .widget<ListView>(find.byType(ListView))
            .controller!.position;
        expect(position.pixels, closeTo(position.maxScrollExtent, 1));
        // 仅用通知排入一次布局补跳，不改 position、不伪造回读位置。
        // 通知与后续帧回调之间插入真实手势，确定性锁住排队竞态。
        final scrollContext = tester.element(find.byType(Scrollable).first);
        ScrollMetricsNotification(
          metrics: position.copyWith(maxScrollExtent: position.maxScrollExtent + 8),
          context: scrollContext,
        ).dispatch(scrollContext);
        expect(tester.binding.hasScheduledFrame, isTrue);
        final gesture = await tester.startGesture(const Offset(200, 140));
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(
            const Offset(0, 8),
            timeStamp: Duration(milliseconds: (i + 1) * 16),
          );
          // 前三个 move 先赢得拖动竞技场，再放行已排队的补跳回调。
          if (i >= 2) await tester.pump(const Duration(milliseconds: 16));
        }
        final gap = position.maxScrollExtent - position.pixels;
        expect(gap, greaterThan(20));
        expect(gap, lessThan(120));
        final before = position.pixels;
        await gesture.moveBy(const Offset(0, 8));
        await tester.pump(const Duration(milliseconds: 16));
        expect(position.pixels, closeTo(before - 8, 1));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up(timeStamp: const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(position.pixels, closeTo(before - 8, 1));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
    testWidgets(
      '输入文字可长按选择复制，消息重听按钮仍执行',
      (tester) async {
        final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
        await _pumpChatView(tester, gateway: gateway, autoSpeak: true);
        final field = find.byKey(const Key('chat-input'));
        await tester.enterText(field, 'hello');
        await tester.pumpAndSettle();
        await tester.longPressAt(
          tester.getTopLeft(field) + const Offset(15, 10),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field).controller!.selection.isCollapsed,
          isFalse,
        );
        final copy = find.text('Copy');
        expect(copy, findsOneWidget);
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(find.text('hello'), findsOneWidget);
        await tester.tap(find.byKey(const Key('chat-send')));
        await tester.pumpAndSettle();
        expect(gateway.deliverCallCount, 1);
        final beforeReplay = gateway.speakCallCount;
        await tester.tap(find.byKey(const Key('chat-replay-0')));
        await tester.pumpAndSettle();
        expect(gateway.speakCallCount, beforeReplay + 1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
    testWidgets(
      '恢复长会话不弹键盘，拖列表收键盘且 inset 不拉回尾部',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
        gateway.restoredMessages = List.generate(
          40,
          (index) => LocalChatMessage(
            requestId: 'old-$index',
            speaker: LocalChatSpeaker.user,
            text: '旧消息 $index，保留阅读位置。',
          ),
        );
        final viewModel = await _pumpChatView(tester, gateway: gateway);
        await viewModel.initialize();
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
        final field = find.byKey(const Key('chat-input'));
        await tester.enterText(field, '草稿不丢');
        const selection = TextSelection(baseOffset: 1, extentOffset: 3);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: '草稿不丢', selection: selection),
        );
        await tester.pump();
        await tester.drag(find.byType(ListView), const Offset(0, 500));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.widget<TextField>(field).controller!.selection,
          selection,
        );
        final list = tester.widget<ListView>(find.byType(ListView));
        final offset = list.controller!.offset;
        expect(
          offset,
          lessThan(list.controller!.position.maxScrollExtent - 120),
        );
        await tester.tap(field);
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(tester.getBottomRight(field).dy, lessThanOrEqualTo(500));
        expect(tester.getTopLeft(field).dy, greaterThanOrEqualTo(0));
        expect(list.controller!.offset, closeTo(offset, 1));
        // 点击列表左侧 padding，是聊天态真正的空白区域。
        await tester.tapAt(const Offset(5, 200));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        expect(list.controller!.offset, closeTo(offset, 1));
        expect(find.text('草稿不丢'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
    testWidgets(
      '贴底态键盘弹起，列表重新贴底且最新消息完整落在键盘之上',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
        gateway.restoredMessages = _restoredSessionWithMoments();
        final viewModel = await _pumpChatView(tester, gateway: gateway);
        await viewModel.initialize();
        await tester.pumpAndSettle();
        final controller = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;
        expect(
          controller.offset,
          closeTo(controller.position.maxScrollExtent, 1),
          reason: '前置失败：恢复长会话后没有贴底',
        );

        await tester.tap(find.byKey(const Key('chat-input')));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();

        // 视口被键盘压矮只抬高 maxScrollExtent，滚动位置原地不动——所以贴底
        // 态必须重新跳一次，否则最新消息沉到键盘与输入框之下。
        expect(
          controller.offset,
          closeTo(controller.position.maxScrollExtent, 1),
          reason: '键盘压矮视口后必须重新贴底',
        );
        final lastMessage = find.byKey(const Key('chat-message-39'));
        expect(lastMessage, findsOneWidget, reason: '最新一条消息必须还在树上');
        expect(
          tester.getRect(lastMessage).bottom,
          lessThanOrEqualTo(800 - 300),
          reason: '最新一条消息必须完整落在键盘（视口底 500）之上',
        );
        expect(
          tester.getRect(lastMessage).bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byKey(const Key('home-go-chat'))).top,
          ),
          reason: '最新一条消息必须完整落在输入框之上，不被覆盖层吃掉',
        );

        await tester.tap(find.text('旧消息 39，保留阅读位置。'));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        expect(
          controller.offset,
          closeTo(controller.position.maxScrollExtent, 1),
          reason: '键盘收起后仍应贴底',
        );
        await tester.tap(find.byKey(const Key('chat-input')));
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(
          controller.offset,
          closeTo(controller.position.maxScrollExtent, 1),
          reason: '纯点击消息收键盘不能被误判为永久回读',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
    testWidgets(
      '恢复变高长会话后首次弹键盘，列表收敛到底且最新消息不被输入框遮挡',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
        gateway.restoredMessages = _variableHeightSessionWithMoments();
        final viewModel = await _pumpChatView(tester, gateway: gateway);
        await viewModel.initialize();
        await tester.pumpAndSettle();
        final controller = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;

        // 不通过测试 jumpTo 修正恢复位置：懒加载范围必须由产品自己收敛。
        await tester.tap(find.byKey(const Key('chat-input')));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        // 收敛依赖产品侧监听自身排帧并请求帧（scheduleFrame），不手动补帧：
        // pumpAndSettle 驱动「静止页面自行收敛」，能停即证明无自持排帧。
        await tester.pumpAndSettle();

        expect(
          (controller.position.maxScrollExtent - controller.offset).abs(),
          lessThanOrEqualTo(1),
          reason: '键盘弹起后列表应经范围变化监听收敛到底（离底不超过 1px）',
        );
        final lastMessage = find.byKey(const Key('chat-message-39'));
        expect(lastMessage, findsOneWidget);
        expect(
          tester.getRect(lastMessage).bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byKey(const Key('home-go-chat'))).top,
          ),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
    testWidgets(
      '点消息本体收键盘，草稿与选区保留且拖拽滚动不受影响',
      (tester) async {
        final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
        gateway.restoredMessages = _restoredSessionWithMoments();
        final viewModel = await _pumpChatView(tester, gateway: gateway);
        await viewModel.initialize();
        await tester.pumpAndSettle();
        final controller = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;
        final field = find.byKey(const Key('chat-input'));
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.enterText(field, '还没说完的草稿');
        const selection = TextSelection(baseOffset: 1, extentOffset: 3);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: '还没说完的草稿', selection: selection),
        );
        await tester.pump();
        expect(tester.testTextInput.isVisible, isTrue);

        // 点在消息本体上（不是列表空白）：气泡自带轻点手势，收键盘必须绕开
        // 手势竞技场，否则这一下永远轮不到页面。
        await tester.tap(find.text('旧消息 39，保留阅读位置。'));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.widget<TextField>(field).controller!.selection,
          selection,
        );
        expect(find.text('还没说完的草稿'), findsOneWidget);

        // 收键盘走 down 事件、不进竞技场：拖拽滚动照常。若哪天换成
        // GestureDetector 抢手势，这里会红。
        final offsetBefore = controller.offset;
        await tester.drag(find.byType(ListView), const Offset(0, 200));
        await tester.pumpAndSettle();
        expect(controller.offset, lessThan(offsetBefore));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
    testWidgets(
      '点没有时刻的旧消息也收键盘',
      (tester) async {
        // 没有时刻的气泡不带轻点手势，这一下由页面级手势兜住（消息区 Listener
        // 同样收键盘）；这条锁的是那条防御路径别被当成冗余删掉——生产链路
        // at 恒非空。
        final gateway = _ConfigurableChatGateway(fallbackReasons: const [null]);
        gateway.restoredMessages = const [
          LocalChatMessage(
            requestId: 'old-0',
            speaker: LocalChatSpeaker.qiyu,
            text: '更早的会话没有时刻。',
          ),
        ];
        final viewModel = await _pumpChatView(tester, gateway: gateway);
        await viewModel.initialize();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('chat-input')));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.tap(find.text('更早的会话没有时刻。'));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
    testWidgets(
      '点空白收键盘且保留草稿选区，输入与语音切换仍可用',
      (tester) async {
        await _pumpChatView(
          tester,
          gateway: _ConfigurableChatGateway(fallbackReasons: const [null]),
        );
        final field = find.byKey(const Key('chat-input'));
        await tester.enterText(field, '还没说完的草稿');
        const selection = TextSelection(baseOffset: 1, extentOffset: 4);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: '还没说完的草稿', selection: selection),
        );
        await tester.pump();
        await tester.tapAt(const Offset(15, 250));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.widget<TextField>(field).controller!.selection,
          selection,
        );
        expect(find.text('还没说完的草稿'), findsOneWidget);
        await tester.tap(field);
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.tap(find.byKey(const Key('voice-mic')));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.tap(find.byKey(const Key('voice-text-mode')));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isTrue);
        expect(find.text('还没说完的草稿'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      '关闭错误提示和功能页返回都不重新打开键盘',
      (tester) async {
        await _pumpChatView(
          tester,
          gateway: _ConfigurableChatGateway(
            fallbackReasons: const [FallbackReason.modelRateLimited],
          ),
        );
        await tester.enterText(find.byKey(const Key('chat-input')), '你好');
        await tester.tap(find.byKey(const Key('chat-send')));
        await tester.pumpAndSettle();
        tester.testTextInput.log.clear();
        await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );

        await tester.enterText(find.byKey(const Key('chat-input')), '保留草稿');
        await tester.tap(find.byKey(const Key('open-provider-settings')));
        await tester.pumpAndSettle();
        tester.testTextInput.log.clear();
        GoRouter.of(tester.element(find.text('设置页'))).pop();
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
        expect(find.text('保留草稿'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      '首次进入先阅读，点输入才请求键盘',
      (tester) async {
        await _pumpChatView(
          tester,
          gateway: _ConfigurableChatGateway(fallbackReasons: const [null]),
        );
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
        await tester.tap(find.byKey(const Key('chat-input')));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  });

  group('LocalChatView 接口限流与 40x 异常提示弹窗', () {
    testWidgets('旧事件缺少类别时，不保留上一轮的限流提示', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [
          FallbackReason.modelRateLimited,
          FallbackReason.modelRateLimited,
          FallbackReason.modelProvider,
        ],
      );
      await _pumpChatView(tester, gateway: gateway);
      for (var turn = 0; turn < 3; turn++) {
        await tester.enterText(find.byKey(const Key('chat-input')), '你好 $turn');
        await tester.tap(find.byKey(const Key('chat-send')));
        await tester.pumpAndSettle();
        if (turn == 0) {
          await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
          await tester.pumpAndSettle();
        }
        if (turn == 1) {
          expect(find.textContaining('接口频繁受限 (429)'), findsOneWidget);
        }
      }
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.textContaining('接口频繁受限 (429)'), findsNothing);
    });

    testWidgets('落定延迟期间切换会话，不将旧服务错误弹到新会话', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelProvider],
        serviceErrors: const [ServiceErrorCategory.client],
      );
      final viewModel = await _pumpChatView(tester, gateway: gateway);
      await tester.enterText(find.byKey(const Key('chat-input')), '你好');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      expect(viewModel.latestServiceError, ServiceErrorCategory.client);
      final oldSession = viewModel.sessionId!;
      gateway.sessionId = 'new-session';
      await viewModel.discardSession(oldSession);
      await tester.pumpAndSettle();
      expect(viewModel.sessionId, 'new-session');
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
    });

    testWidgets('429 限流：流式完成后弹出模态弹窗，双按钮直达设置', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelRateLimited],
      );
      await _pumpChatView(tester, gateway: gateway);

      // 发送消息
      await tester.enterText(find.byKey(const Key('chat-input')), '你好');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 流式落定后弹出模态对话框
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('服务请求受限'), findsOneWidget);
      expect(find.textContaining('模型服务返回请求过于频繁（429）'), findsOneWidget);

      // 验证双按钮
      final dismissBtn = find.byKey(const Key('api-error-dialog-dismiss'));
      final settingsBtn = find.byKey(const Key('api-error-dialog-settings'));
      expect(dismissBtn, findsOneWidget);
      expect(settingsBtn, findsOneWidget);

      // 点击【前往设置】直接平滑跳转 /settings
      await tester.tap(settingsBtn);
      await tester.pumpAndSettle();

      expect(find.text('设置页'), findsOneWidget);
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
    });

    testWidgets('点击【知道了】：关闭弹窗且返还焦点到输入框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelRateLimited],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '你好');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);

      // 点击【知道了】
      await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
      expect(input.focusNode?.hasFocus, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('会话级频控去重：同会话第 2 次不再弹窗，状态行展示轻提示与去设置链接', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [
          FallbackReason.modelRateLimited,
          FallbackReason.modelRateLimited,
        ],
      );
      await _pumpChatView(tester, gateway: gateway);

      // 第 1 次发消息，触发 429
      await tester.enterText(find.byKey(const Key('chat-input')), '第一句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 第 1 次弹窗出现，用户点知道了关闭
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);

      // 第 2 次发消息，再次触发 429
      await tester.enterText(find.byKey(const Key('chat-input')), '第二句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 验证不再弹出模态全屏遮罩
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);

      // 状态行展示轻提示与链接
      expect(
        find.textContaining('⚠️ 接口频繁受限 (429)'),
        findsOneWidget,
      );
      final settingsLink = find.text('去设置检查');
      expect(settingsLink, findsOneWidget);

      // 验证状态行暗红底提示条 Container 样式与字体继承
      final bannerFinder = find.byKey(const Key('api-error-notice-banner'));
      expect(bannerFinder, findsOneWidget);
      final banner = tester.widget<Container>(bannerFinder);
      final decoration = banner.decoration as BoxDecoration;
      expect(decoration.borderRadius, QiyuRadii.smallBorder);
      expect(decoration.color, isNotNull);

      final noticeWidget = tester.widget<Text>(
        find.byKey(const Key('api-error-notice-text')),
      );
      expect(noticeWidget.style?.fontFamily, QiyuType.fontFamily);

      // 点击状态行里的【去设置检查】
      await tester.tap(settingsLink);
      await tester.pumpAndSettle();

      expect(find.text('设置页'), findsOneWidget);
    });

    testWidgets('流式落定后约 300ms 缓冲：未到 300ms 前不弹窗，到 300ms 后弹出', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelRateLimited],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '测试延迟');
      await tester.tap(find.byKey(const Key('chat-send')));

      // 推进 100ms：此时 300ms 缓冲未到，不应弹出模态窗口
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);

      // 继续推进 250ms（累计 350ms，超过 300ms）：模态窗口已弹出
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('服务请求受限'), findsOneWidget);
    });

    testWidgets('401 鉴权失败：弹出「API Key 鉴权失败」对话框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelAuthentication],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '测试鉴权');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('API Key 鉴权失败'), findsOneWidget);
      expect(find.textContaining('服务商未通过验证（401/403）'), findsOneWidget);
    });

    testWidgets('404 模型未找到：弹出「模型名称不存在」对话框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelNotFound],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '测试模型');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('模型名称不存在'), findsOneWidget);
      expect(find.textContaining('服务商未找到当前配置的模型（404）'), findsOneWidget);
    });

    testWidgets('边界排除：safety 与 noLlmConfig 绝对不弹窗', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [
          FallbackReason.safety,
          FallbackReason.noLlmConfig,
        ],
      );
      await _pumpChatView(tester, gateway: gateway);

      // 第 1 轮：safety 拦截
      await tester.enterText(find.byKey(const Key('chat-input')), '敏感输入');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.byKey(const Key('api-error-notice-text')), findsNothing);

      // 第 2 轮：noLlmConfig 设计内无模型
      await tester.enterText(find.byKey(const Key('chat-input')), '随便聊聊');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.byKey(const Key('api-error-notice-text')), findsNothing);
    });

    testWidgets('边界排除：modelTimeout 仅状态行轻提示，不弹出模态对话框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelTimeout],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '网络慢');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 绝不弹出模态对话框（避免误导用户改 Key）
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);

      // 仅在状态行展示就地轻提示
      expect(
        find.textContaining('网络连接超时'),
        findsOneWidget,
      );
      // 不引导去改配置
      expect(find.text('去设置检查'), findsNothing);
    });

    testWidgets('边界排除：modelContentParsing 截断轮仅状态行轻提示，不弹模态对话框', (
      tester,
    ) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelContentParsing],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '话说一半');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 截断/解析失败有明确的就地失败信号（票 06），但不弹模态窗
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.textContaining('模型回复不完整'), findsOneWidget);
      expect(find.text('去设置检查'), findsNothing);
    });

    testWidgets('语音链路联动：STT 客户端错误触发「语音服务受限」弹窗', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.noLlmConfig],
      );
      gateway.transcribeError = const LocalChatGatewayException(
        '语音服务请求过于频繁。',
        code: 'stt_client',
      );
      final recorder = _FakeVoiceRecorder();

      await _pumpChatView(
        tester,
        gateway: gateway,
        recorderPlatform: recorder,
      );

      // 点击麦克风开始录音
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();

      // 再次点击麦克风停止录音并触发转写
      await tester.tap(find.byKey(const Key('voice-mic-stop')));
      await tester.pumpAndSettle();

      // 验证弹出语音服务受限弹窗
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('语音服务受限'), findsOneWidget);
      expect(find.textContaining('语音服务请求受限或配置异常'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('收敛 modelProvider：服务端错误类别不弹模态对话框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelProvider],
        serviceErrors: const [ServiceErrorCategory.server],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '测试 500');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 纯 5xx 服务端错误不弹出模态配置弹窗
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
    });

    testWidgets('收敛 modelProvider：明确客户端错误类别时弹出「模型服务异常」对话框', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelProvider],
        serviceErrors: const [ServiceErrorCategory.client],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '测试 400');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('模型服务异常'), findsOneWidget);
      expect(find.textContaining('服务商返回客户端请求异常'), findsOneWidget);
    });

    testWidgets('语音链路联动：TTS 429 依靠错误码精准触发「服务请求受限」弹窗', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.noLlmConfig],
      );
      gateway.speakError = const LocalChatGatewayException(
        '语音合成服务请求过于频繁，请稍后再试。',
        code: 'tts_rate_limited',
      );

      await _pumpChatView(
        tester,
        gateway: gateway,
        autoSpeak: true,
      );

      // 发送消息，回复落盘后触发自动朗读
      await tester.enterText(find.byKey(const Key('chat-input')), '朗读测试');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 验证弹出服务请求受限弹窗
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('服务请求受限'), findsOneWidget);
      expect(find.textContaining('模型服务返回请求过于频繁（429）'), findsOneWidget);
    });

    testWidgets('语音链路联动：TTS 404 触发「模型名称不存在」弹窗', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.noLlmConfig],
      );
      gateway.speakError = const LocalChatGatewayException(
        '模型未找到。',
        code: 'tts_model_not_found',
      );

      await _pumpChatView(
        tester,
        gateway: gateway,
        autoSpeak: true,
      );

      await tester.enterText(find.byKey(const Key('chat-input')), '朗读测试');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('模型名称不存在'), findsOneWidget);
      expect(find.textContaining('服务商未找到当前配置的模型（404）'), findsOneWidget);
    });

    testWidgets('语音链路联动：TTS 通用配置异常触发「语音朗读受限」弹窗', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.noLlmConfig],
      );
      gateway.speakError = const LocalChatGatewayException(
        '语音合成服务异常。',
        code: 'tts_config_invalid',
      );

      await _pumpChatView(
        tester,
        gateway: gateway,
        autoSpeak: true,
      );

      await tester.enterText(find.byKey(const Key('chat-input')), '朗读测试');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('语音朗读受限'), findsOneWidget);
      expect(find.textContaining('语音朗读合成请求受限或配置异常'), findsOneWidget);
    });

    testWidgets('点击【知道了】：焦点返还且弹窗期间写下的草稿保持不变', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.modelRateLimited],
      );
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '你好');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);

      // 弹窗开着时用户继续往输入框写草稿：关闭弹窗不得弄丢它。
      await tester.enterText(find.byKey(const Key('chat-input')), '等下还要发的草稿');
      await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
      expect(input.focusNode?.hasFocus, isTrue);
      expect(input.controller!.text, '等下还要发的草稿');
    });

    testWidgets('sessionId 变化由既有监听复位频控：新会话同类错误再次弹窗且旧提示条清除', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [
          FallbackReason.modelRateLimited,
          FallbackReason.modelRateLimited,
          FallbackReason.modelRateLimited,
        ],
      );
      await _pumpChatView(tester, gateway: gateway);

      // 第 1 次同类错误：弹窗，知道了关闭。
      await tester.enterText(find.byKey(const Key('chat-input')), '第一句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
      await tester.pumpAndSettle();

      // 同会话第 2 次：频控生效，只出提示条。
      await tester.enterText(find.byKey(const Key('chat-input')), '第二句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.byKey(const Key('api-error-notice-banner')), findsOneWidget);

      // 会话切换：sessionId 由网关事件带进视图模型，页面的既有监听负责复位。
      gateway.sessionId = 'test-session-2';
      await tester.enterText(find.byKey(const Key('chat-input')), '第三句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 新会话复位频控：同类错误再次弹窗，旧会话的提示条随复位清除。
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.byKey(const Key('api-error-notice-banner')), findsNothing);
    });

    testWidgets('跨通道共享频控：STT 429 弹窗后同会话文本 429 只出提示条', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [
          // 第 1 轮无错误：本 harness（autoStart:false）挂载时会话尚未恢复，
          // 首轮 accepted 事件首次写入 sessionId 会走一次复位路径。先落定
          // 会话身份，排除它对频控集合的干扰，再对照语音与文本两个通道。
          FallbackReason.noLlmConfig,
          FallbackReason.modelRateLimited,
        ],
      );
      gateway.transcribeError = const LocalChatGatewayException(
        '语音服务请求过于频繁。',
        code: 'stt_rate_limited',
      );

      await _pumpChatView(
        tester,
        gateway: gateway,
        recorderPlatform: _FakeVoiceRecorder(),
      );

      await tester.enterText(find.byKey(const Key('chat-input')), '先把会话安顿下来');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);

      // 语音通道触发通用 429 类别：立即弹窗（无 300ms 缓冲）。
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic-stop')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      expect(find.text('服务请求受限'), findsOneWidget);
      await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
      await tester.pumpAndSettle();

      // 文本通道同类错误：与语音共享类别集合，只出提示条不再弹窗。
      await tester.enterText(find.byKey(const Key('chat-input')), '换个说法');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.byKey(const Key('api-error-notice-banner')), findsOneWidget);
      expect(find.text('去设置检查'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('页面释放撤销本页 TTS 错误回调：onApiError 位置清空', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.noLlmConfig],
      );
      final voiceOutput = VoiceOutputController(
        gateway,
        playerPlatform: _FakeVoicePlayer(),
      );
      await _pumpChatView(tester, gateway: gateway, voiceOutput: voiceOutput);

      // 页面挂载后回调由本页接管。
      expect(voiceOutput.onApiError, isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // 离开页面：本页只撤销自己登记的回调。
      expect(voiceOutput.onApiError, isNull);
      voiceOutput.dispose();
    });

    testWidgets('页面释放不误删其他所有者后来替换的 TTS 错误回调', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.noLlmConfig],
      );
      gateway.speakError = const LocalChatGatewayException(
        '语音合成服务请求过于频繁，请稍后再试。',
        code: 'tts_rate_limited',
      );
      final voiceOutput = VoiceOutputController(
        gateway,
        playerPlatform: _FakeVoicePlayer(),
      );
      await _pumpChatView(tester, gateway: gateway, voiceOutput: voiceOutput);

      // 其他所有者在页面挂载后替换回调：页面释放时不得清掉它。
      final replaced = <ApiErrorCategory>[];
      voiceOutput.onApiError = replaced.add;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(voiceOutput.onApiError, isNotNull);

      // 页面释放后触发一次 TTS 失败：错误仍送达替换者。
      voiceOutput.playNow(
        const VoiceOutputRequest(
          requestId: 'req-x',
          deliveryIndex: 0,
          sessionId: 'session-1',
        ),
      );
      await tester.pumpAndSettle();
      expect(replaced, [ApiErrorCategory.rateLimited]);
      voiceOutput.dispose();
    });

    testWidgets('空态发出第一句：输入框焦点与可用性连续', (tester) async {
      final gateway = _ConfigurableChatGateway(
        fallbackReasons: const [FallbackReason.noLlmConfig],
      );
      final viewModel = await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '你好');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();

      // 空态→聊天态换布局：输入框仍就位、焦点不跳走，草稿按设计清空。
      expect(find.text('你好'), findsOneWidget);
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
      final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
      expect(input.focusNode?.hasFocus, isTrue);
      expect(input.controller!.text, isEmpty);

      // 换位后继续输入与发送照常：没有留下重建副作用。
      await tester.enterText(find.byKey(const Key('chat-input')), '继续说');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(
        viewModel.messages
            .where((message) => message.speaker == LocalChatSpeaker.user)
            .length,
        2,
      );
    });

    testWidgets('历史已有同文，本轮受理前失败仍恢复原稿', (tester) async {
      final gateway = _HangingFailingChatGateway(
        acceptBeforeFailure: false,
        restoredMessages: const [
          LocalChatMessage(
            requestId: 'old-request',
            speaker: LocalChatSpeaker.user,
            text: '今天有点累',
          ),
          LocalChatMessage(
            requestId: 'old-request',
            speaker: LocalChatSpeaker.qiyu,
            text: '嗯，歇一会儿。',
          ),
        ],
      );
      final viewModel = await _pumpChatView(tester, gateway: gateway);
      await viewModel.initialize();
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('chat-input')), '  今天有点累  ');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      gateway.releaseFailure();
      await tester.pumpAndSettle();

      final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
      expect(input.controller!.text, '  今天有点累  ');
      expect(input.controller!.selection.baseOffset, '  今天有点累  '.length);
      expect(viewModel.messages.map((message) => message.requestId), [
        'old-request',
        'old-request',
      ]);
    });

    for (final voice in [false, true]) {
      final inputMode = voice ? '转写' : '文字';
      testWidgets('$inputMode 受理后失败不回填，消息保留原 requestId', (tester) async {
        final gateway = _HangingFailingChatGateway();
        final viewModel = await _pumpChatView(tester, gateway: gateway);
        await _startPendingInput(tester, voice: voice);
        final requestId = viewModel.messages.single.requestId;

        gateway.releaseFailure();
        await tester.pumpAndSettle();

        final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
        expect(input.controller!.text, isEmpty);
        expect(viewModel.messages.single.requestId, requestId);
        expect(viewModel.messages.single.text, '测试转写文本');
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

      testWidgets('$inputMode 受理前失败不恢复用户已编辑又删空的草稿', (tester) async {
        final gateway = _HangingFailingChatGateway(acceptBeforeFailure: false);
        final viewModel = await _pumpChatView(tester, gateway: gateway);
        await _startPendingInput(tester, voice: voice);
        await tester.enterText(find.byKey(const Key('chat-input')), '后来写的新草稿');
        await tester.enterText(find.byKey(const Key('chat-input')), '');

        gateway.releaseFailure();
        await tester.pumpAndSettle();

        final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
        expect(input.controller!.text, isEmpty);
        expect(viewModel.messages, isEmpty);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

      testWidgets('$inputMode 旧会话受理前失败不回填新会话', (tester) async {
        final gateway = _HangingFailingChatGateway(acceptBeforeFailure: false);
        final viewModel = await _pumpChatView(tester, gateway: gateway);
        await viewModel.initialize();
        await tester.pumpAndSettle();
        await _startPendingInput(tester, voice: voice);
        await viewModel.discardSession('session-1');
        await tester.pump();

        gateway.releaseFailure();
        await tester.pumpAndSettle();

        final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
        expect(input.controller!.text, isEmpty);
        expect(viewModel.messages, isEmpty);
        expect(viewModel.errorMessage, isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
    }

    testWidgets('发送失败前用户已重新输入：失败回填不覆盖新草稿', (tester) async {
      final gateway = _HangingFailingChatGateway();
      await _pumpChatView(tester, gateway: gateway);

      await tester.enterText(find.byKey(const Key('chat-input')), '第一句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();

      // 前置：发送已开始（用户轮已进场、输入框已清空），轮次还挂在流上。
      expect(find.text('第一句'), findsOneWidget);
      final inputDuringTurn = tester.widget<TextField>(
        find.byKey(const Key('chat-input')),
      );
      expect(inputDuringTurn.controller!.text, isEmpty);

      // 失败落地前用户已开始写新草稿。
      await tester.enterText(find.byKey(const Key('chat-input')), '新草稿');
      gateway.releaseFailure();
      await tester.pumpAndSettle();

      // 失败不回填「第一句」：输入框非空时回填必须让位给新草稿。
      final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
      expect(input.controller!.text, '新草稿');
      // 已 accepted 的用户轮保留，错误就地提示。
      expect(find.text('第一句'), findsOneWidget);
      expect(find.text('本地聊天暂时不可用，请稍后重试。'), findsOneWidget);
    });

    testWidgets('转写经页面通道送达：空态与聊天态 composer 都已挂载且发送协调发生', (tester) async {
      final gateway = _ConfigurableChatGateway(fallbackReasons: const []);
      final viewModel = await _pumpChatView(
        tester,
        gateway: gateway,
        recorderPlatform: _FakeVoiceRecorder(),
      );

      // 布局事实：composer 常驻空态、聊天态、窄屏三种布局，State 与页面同
      // 生命周期；页面 onTranscribed 通道经 `_composerKey.currentState?.
      // sendTranscribed` 送出转写。锁定现状：两种布局下转写到达即进入发送
      // 协调（本用例发送成功，直接落为用户轮），不得因「恰好未挂载」被
      // 空感知调用静默丢弃。

      // 空态：composer 在问候列里，转写文本直接发送。
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic-stop')));
      await tester.pumpAndSettle();
      expect(
        viewModel.messages
            .where((message) => message.speaker == LocalChatSpeaker.user)
            .map((message) => message.text),
        contains('测试转写文本'),
      );

      // 聊天态：composer 换到消息流上方的覆盖层布局，仍是同一枚键、同一个
      // State，转写照常送达发送协调。
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic-stop')));
      await tester.pumpAndSettle();
      expect(
        viewModel.messages
            .where((message) => message.speaker == LocalChatSpeaker.user)
            .map((message) => message.text),
        ['测试转写文本', '测试转写文本'],
      );
      // composer 仍挂载：输入框在树上，转写链路随时可继续。
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });
}

/// 本文件聊天网关替身的公共形状：聊天事件流 + 语音合成双通道。
abstract interface class _TestChatGateway
    implements StreamingLocalChatGateway, ChatSpeechGateway {}

Future<void> _startPendingInput(WidgetTester tester, {required bool voice}) async {
  if (voice) {
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-mic-stop')));
  } else {
    await tester.enterText(find.byKey(const Key('chat-input')), '测试转写文本');
    await tester.tap(find.byKey(const Key('chat-send')));
  }
  await tester.pump();
}

/// 真实触摸逐帧拖动，按指定步数与方向移动（每步 8px，towardBottom 为真时
/// 向上拖向尾部，否则向下拖向历史），与探针同形：帧间补跳必须在拖动开始后
/// 被取消，不能 `jumpTo` 把活动拖动打回 Idle。
Future<void> _dragHistoryInSteps(
  WidgetTester tester, {
  required int steps,
  required bool closeKeyboard,
  bool towardBottom = false,
}) async {
  final step = Offset(0, towardBottom ? -8 : 8);
  final gesture = await tester.startGesture(
    Offset(200, towardBottom ? 380 : 140),
  );
  if (closeKeyboard) {
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
  }
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(step, timeStamp: Duration(milliseconds: (i + 1) * 16));
    await tester.pump(const Duration(milliseconds: 16));
  }
  tester.view.viewInsets = const FakeViewPadding();
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.up(timeStamp: Duration(milliseconds: steps * 16 + 100));
  await tester.pumpAndSettle();
}

/// 40 条带时刻的**变高**旧消息，用户/栖语交替、行数由固定公式决定：
/// 复现懒加载估算偏差——等高会话范围估算近乎精确，测不出一次跳转后
/// `maxScrollExtent` 还会继续变化、最新消息被 composer 覆盖的缺陷。
List<LocalChatMessage> _variableHeightSessionWithMoments() => List.generate(
  40,
  (index) => LocalChatMessage(
    requestId: 'old-$index',
    speaker: index.isEven ? LocalChatSpeaker.user : LocalChatSpeaker.qiyu,
    text: List.filled(
      ((index * 37 + 22 * 13) % 23) + 1,
      '消息 $index，这是一段不同长度的回复。',
    ).join('\n'),
    at: DateTime(2026, 9, 2, 23, 41),
  ),
);

/// 40 条带时刻的旧消息，与生产同形：Host 恢复的消息都带 `at`，气泡因此带
/// 轻点显隐时刻的手势——正是收键盘必须绕开手势竞技场的原因。
List<LocalChatMessage> _restoredSessionWithMoments() => List.generate(
  40,
  (index) => LocalChatMessage(
    requestId: 'old-$index',
    speaker: LocalChatSpeaker.user,
    text: '旧消息 $index，保留阅读位置。',
    at: DateTime(2026, 9, 2, 23, 41),
  ),
);

Future<LocalChatViewModel> _pumpChatView(
  WidgetTester tester, {
  required _TestChatGateway gateway,
  VoiceRecorderPlatform? recorderPlatform,
  bool autoSpeak = false,
  VoiceOutputController? voiceOutput,
}) async {
  final ttsGateway = _FixedTtsGateway(configured: autoSpeak, autoSpeak: autoSpeak);
  final viewModel = LocalChatViewModel(
    gateway,
    hostConnectionProbe: FakeHostConnectionProbe(const [true]),
    ttsSettingsGateway: ttsGateway,
    voiceOutput:
        voiceOutput ?? VoiceOutputController(gateway, playerPlatform: _FakeVoicePlayer()),
    autoStart: false,
  );
  await viewModel.refreshVoiceOutputStatus();

  final router = GoRouter(
    initialLocation: '/chat',
    routes: [
      GoRoute(
        path: '/chat',
        builder: (context, state) => LocalChatView(
          voiceRecorderPlatform: recorderPlatform ?? _FakeVoiceRecorder(),
          sttSettingsGateway: _FixedSttGateway(configured: true),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const Scaffold(body: Text('设置页')),
      ),
    ],
  );

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: viewModel,
      child: MaterialApp.router(
        theme: qiyuDarkTheme(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return viewModel;
}

/// 可挂起的失败网关：deliver 发出 accepted+waiting 后停住，等测试放行
/// 再抛错——用来在「发送已开始、尚未失败」的窗口里注入用户新输入。
final class _HangingFailingChatGateway implements _TestChatGateway {
  _HangingFailingChatGateway({
    this.acceptBeforeFailure = true,
    this.restoredMessages = const [],
  });

  final bool acceptBeforeFailure;
  final List<LocalChatMessage> restoredMessages;
  final Completer<void> _release = Completer<void>();

  /// 放行挂起的流：随后 deliver 抛错，send 以失败收尾。
  void releaseFailure() => _release.complete();

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      LocalChatSnapshot(sessionId: 'session-1', messages: restoredMessages);

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '测试转写文本';

  @override
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  }) async => Uint8List.fromList([1, 2, 3]);

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    if (acceptBeforeFailure) {
      yield LocalChatDeliveryEvent.accepted(
        requestId: requestId,
        sessionId: 'session-1',
      );
    }
    yield LocalChatDeliveryEvent.waiting(
      requestId: requestId,
    );
    await _release.future;
    throw const LocalChatGatewayException('本地聊天暂时不可用，请稍后重试。');
  }
}

final class _ConfigurableChatGateway implements _TestChatGateway {
  _ConfigurableChatGateway({
    required this.fallbackReasons,
    this.serviceErrors,
  });

  final List<FallbackReason?> fallbackReasons;
  final List<ServiceErrorCategory?>? serviceErrors;
  String sessionId = 'test-session-1';
  int deliverCallCount = 0;
  Object? transcribeError;
  Object? speakError;
  int speakCallCount = 0;
  List<LocalChatMessage> restoredMessages = const [];

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      LocalChatSnapshot(sessionId: this.sessionId, messages: restoredMessages);

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async {
    if (transcribeError != null) {
      throw transcribeError!;
    }
    return '测试转写文本';
  }

  @override
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  }) async {
    speakCallCount += 1;
    if (speakError != null) {
      throw speakError!;
    }
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    final index = deliverCallCount;
    final reason = index < fallbackReasons.length
        ? fallbackReasons[index]
        : (fallbackReasons.isNotEmpty ? fallbackReasons.last : null);
    final serviceError = serviceErrors != null && index < serviceErrors!.length
        ? serviceErrors![index]
        : null;
    deliverCallCount += 1;

    yield LocalChatDeliveryEvent.accepted(
      requestId: requestId,
      sessionId: this.sessionId,
    );
    yield LocalChatDeliveryEvent.waiting(
      requestId: requestId,
    );
    if (reason != null) {
      yield LocalChatDeliveryEvent.fallback(
        requestId: requestId,
        fallbackReason: reason,
        serviceError: serviceError,
      );
    }
    yield LocalChatDeliveryEvent.delta(
      requestId: requestId,
      text: '本地基础回复',
    );
    yield LocalChatDeliveryEvent.message(
      requestId: requestId,
      messages: const ['本地基础回复'],
    );
    yield LocalChatDeliveryEvent.state(
      requestId: requestId,
      source: ReplySource.local,
      fallbackReason: reason,
      serviceError: serviceError,
    );
    yield LocalChatDeliveryEvent.done(
      requestId: requestId,
      sessionId: this.sessionId,
    );
  }
}

final class _FixedSttGateway implements SttSettingsGateway {
  _FixedSttGateway({this.configured = false});

  final bool configured;

  @override
  Future<SttSettings> read() async => SttSettings(
    configured: configured,
    keySet: configured,
    provider: SttServiceKind.openaiCompatible,
    baseUrl: 'https://api.example.com/v1',
    model: 'whisper-1',
  );

  @override
  Future<SttSettings> save(SttSettingsDraft draft) => throw UnimplementedError();

  @override
  Future<SttSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) =>
      throw UnimplementedError();
}

final class _FixedTtsGateway implements TtsSettingsGateway {
  _FixedTtsGateway({this.configured = false, this.autoSpeak = false});

  final bool configured;
  final bool autoSpeak;

  @override
  Future<TtsSettings> read() async => TtsSettings(
    configured: configured,
    keySet: configured,
    autoSpeak: autoSpeak,
  );

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) => throw UnimplementedError();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async => read();

  @override
  Future<TtsSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) =>
      throw UnimplementedError();
}

final class _FakeVoicePlayer implements VoicePlayerPlatform {
  @override
  bool get supported => true;

  @override
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async => null;
}

final class _FakeVoiceRecorder implements VoiceRecorderPlatform {
  @override
  bool get supported => true;

  @override
  Future<VoiceRecordingSession?> start() async => _FakeSession();

  @override
  Future<RecordedAudio> toWav16kMono(RecordedAudio source) async => source;
}

final class _FakeSession implements VoiceRecordingSession {
  @override
  String get mimeType => 'audio/webm';

  @override
  Future<Uint8List> stop() async => Uint8List.fromList([1, 2, 3]);

  @override
  void discard() {}
}
