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
