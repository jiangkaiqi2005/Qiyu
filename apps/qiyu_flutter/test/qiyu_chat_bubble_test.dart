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
              find.ancestor(of: find.text(label), matching: find.byType(Opacity)),
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
            child: QiyuChatBubble(
              text: '晚安。',
              fromUser: false,
              at: moment,
            ),
          ),
        );

        expect(find.bySemanticsLabel(label), findsOneWidget);
      } finally {
        handle.dispose();
      }
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
