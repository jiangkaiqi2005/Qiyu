import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/shell/qiyu_shell.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';

import 'support/shared_fakes.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final replaceGuard in [false, true]) {
      testWidgets('页面语音订阅与占用回调按拥有者解绑 $platform $replaceGuard', (tester) async {
        final recorder = _FakeRecorderPlatform();
        final viewModel = _chatViewModel();
        final output = viewModel.voiceOutput;
        bool originalGuard() => true;
        bool replacementGuard() => false;
        output.isMicrophoneInUse = originalGuard;
        await tester.pumpWidget(_harness(viewModel: viewModel, platform: recorder));
        await tester.pumpAndSettle();
        final android = platform == TargetPlatform.android;
        expect(recorder.interrupted.hasListener, android);
        expect(output.isMicrophoneInUse!(), !android);
        if (replaceGuard) output.isMicrophoneInUse = replacementGuard;

        await tester.pumpWidget(const SizedBox.shrink());
        expect(recorder.interrupted.hasListener, isFalse);
        expect(
          output.isMicrophoneInUse,
          replaceGuard ? replacementGuard : (android ? null : originalGuard),
        );
        recorder.interrupted.add(null);
        await tester.pump();
        expect(tester.takeException(), isNull);
        await recorder.interrupted.close();
        viewModel.dispose();
        output.dispose();
      }, variant: TargetPlatformVariant.only(platform));
    }
  }

  for (final failure in [
    (code: 'stt_dns', message: '找不到语音服务域名。'),
    (code: 'stt_network', message: '无法连接语音服务。'),
    (code: 'stt_timeout', message: '连接语音服务超时。'),
    (code: 'stt_tls', message: '语音服务的 TLS 安全连接失败。'),
  ]) {
    testWidgets('安卓网络转写失败只轻提示并可重试 ${failure.code}', (tester) async {
      final gateway = _VoiceChatGateway()
        ..transcribeFailuresRemaining = 1
        ..transcribeError = LocalChatGatewayException(failure.message, code: failure.code);
      final recorder = _FakeRecorderPlatform();
      await tester.pumpWidget(_harness(viewModel: _chatViewModel(gateway), platform: recorder));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      await _recordAndroid(tester);
      await tester.pumpAndSettle();
      expect(find.text(failure.message), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '重试'));
      await tester.pumpAndSettle();
      expect(recorder.starts, 1);
      expect(gateway.transcribeCalls, 2);
      expect(gateway.transcribeAudioCalls.first, gateway.transcribeAudioCalls.last);
      expect(gateway.sentTexts, ['今天有点累']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('安卓无语音结构化错误只提示重录不弹服务受限', (tester) async {
    final gateway = _VoiceChatGateway()
      ..transcribeFailuresRemaining = 1
      ..transcribeError = const LocalChatGatewayException(
        '没有识别到语音，可以再说一次。', code: 'stt_no_speech');
    final recorder = _FakeRecorderPlatform();
    await tester.pumpWidget(_harness(viewModel: _chatViewModel(gateway), platform: recorder));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pumpAndSettle();
    await _recordAndroid(tester);
    await tester.pumpAndSettle();
    expect(find.text('没有识别到语音，可以再说一次。'), findsOneWidget);
    expect(find.text('语音服务受限'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '重新录制'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-hold')), findsOneWidget);
    expect(recorder.starts, 1);
    expect(gateway.sentTexts, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('安卓组合闭环保留草稿、语音只提交一次且重按打断朗读', (tester) async {
    final gateway = _VoiceChatGateway();
    final recorder = _FakeRecorderPlatform();
    final speech = _RecordingSpeakGateway();
    final player = _HoldingPlayerPlatform();
    final output = VoiceOutputController(speech, playerPlatform: player);
    final model = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: output,
      autoStart: false,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      output.dispose();
    });
    await model.refreshVoiceOutputStatus();
    await tester.pumpWidget(_harness(viewModel: model, platform: recorder));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.enterText(find.byKey(const Key('chat-input')), '保留这段草稿');
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await _recordAndroid(tester);
    expect(gateway.sentTexts, ['今天有点累']);
    expect(find.text('今天有点累'), findsOneWidget);
    expect(find.text('咋了'), findsOneWidget);
    expect(speech.calls, hasLength(1));
    expect(player.activeCount, 1);

    final hold = find.byKey(const Key('voice-hold'));
    final gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(player.activeCount, 0);
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(find.textContaining('松开取消'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(gateway.transcribeCalls, 1);
    expect(gateway.sentTexts, ['今天有点累']);
    expect(player.activeCount, 0);
    await tester.tap(find.byKey(const Key('voice-text-mode')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('chat-input'))).controller!.text,
        '保留这段草稿');
    expect(tester.testTextInput.isVisible, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('安卓输入控件具有48像素语义区域且边缘点击不串操作', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final gateway = _VoiceChatGateway()..pendingDelivery = Completer<void>();
    final platform = _FakeRecorderPlatform();
    await tester.pumpWidget(_harness(viewModel: _chatViewModel(gateway), platform: platform, touchTheme: true));
    await tester.pumpAndSettle();
    final mic = find.byKey(const Key('voice-mic'));
    final send = find.byKey(const Key('chat-send'));
    _expectTouchTarget(tester, mic);
    _expectTouchTarget(tester, send);
    expect(tester.getRect(mic).overlaps(tester.getRect(send)), isFalse);
    await tester.enterText(find.byKey(const Key('chat-input')), '边缘发送');
    await tester.tapAt(tester.getRect(send).topLeft + const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(gateway.sentTexts, ['边缘发送']);
    final stop = find.byKey(const Key('chat-stop'));
    _expectTouchTarget(tester, stop);
    await tester.tapAt(tester.getRect(stop).bottomRight - const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(gateway.cancelCalls, 1);
    await tester.tapAt(tester.getRect(mic).topLeft + const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(platform.starts, 0);
    _expectTouchTarget(tester, find.byKey(const Key('voice-hold')));
    final textMode = find.byKey(const Key('voice-text-mode'));
    _expectTouchTarget(tester, textMode);
    await tester.tapAt(tester.getRect(textMode).bottomRight - const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    gateway.pendingDelivery!.complete();
    await tester.pumpAndSettle();
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final viewport in [const Size(320, 640), const Size(640, 360)]) {
    testWidgets('安卓大字体语音触摸区域与边缘操作 $viewport', (tester) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: viewport.width == 320 ? 220 : 100);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final semantics = tester.ensureSemantics();
      final gateway = _VoiceChatGateway()
        ..transcribeFailuresRemaining = 2
        ..transcribeError = const LocalChatGatewayException('没有识别到语音，可以再说一次。');
      final platform = _FakeRecorderPlatform();
      final model = _chatViewModel(gateway);
      await model.send('已有消息');
      for (var i = 0; i < 8; i++) {
        await model.send('更早的消息$i');
      }
      await tester.pumpWidget(_harness(viewModel: model, platform: platform, touchTheme: true, textScale: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      final hold = find.byKey(const Key('voice-hold'));
      _expectTouchTarget(tester, hold);
      await tester.tapAt(tester.getRect(hold).topLeft - const Offset(1, 1));
      expect(platform.starts, 0);
      final gesture = await tester.startGesture(tester.getRect(hold).bottomRight - const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(platform.starts, 1);
      expect(tester.takeException(), isNull);
      await gesture.up();
      await tester.pumpAndSettle();
      for (final label in ['重试', '重新录制', '丢弃']) {
        final button = find.widgetWithText(TextButton, label);
        _expectTouchTarget(tester, button);
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(viewport.height - tester.view.viewInsets.bottom));
      }
      final retry = find.widgetWithText(TextButton, '重试');
      expect(tester.getRect(find.text('咋了').last).bottom,
          lessThanOrEqualTo(tester.getRect(find.byKey(const Key('home-go-chat'))).top));
      await tester.tapAt(tester.getRect(retry).topLeft + const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(gateway.transcribeCalls, 2);
      final rerecord = find.widgetWithText(TextButton, '重新录制');
      await tester.tapAt(tester.getRect(rerecord).bottomRight - const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(hold, findsOneWidget);
      expect(platform.starts, 1);
      gateway.transcribeFailuresRemaining = 1;
      await _recordAndroid(tester);
      final discard = find.widgetWithText(TextButton, '丢弃');
      _expectTouchTarget(tester, discard);
      await tester.tapAt(tester.getRect(discard).topRight + const Offset(-1, 1));
      await tester.pumpAndSettle();
      expect(hold, findsOneWidget);
      gateway.hangTranscribe = true;
      await _recordAndroid(tester);
      final cancel = find.widgetWithText(TextButton, '取消');
      _expectTouchTarget(tester, cancel);
      await tester.tapAt(tester.getRect(cancel).bottomLeft + const Offset(1, -1));
      await tester.pumpAndSettle();
      gateway.completeHungTranscribe('迟到内容');
      await tester.pumpAndSettle();
      expect(gateway.sentTexts, hasLength(9));
      expect(hold, findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final state in [AppLifecycleState.inactive, AppLifecycleState.paused]) {
    testWidgets('安卓聊天朗读在$state停声清队，回前台不续播，主动重听可用', (tester) async {
      final (gateway, player, output) = await _pumpVoiceScene(tester);
      await tester.pumpAndSettle();
      const request = VoiceOutputRequest(requestId: 'r', deliveryIndex: 0);
      output.offer(request, enabled: true);
      output.offer(const VoiceOutputRequest(requestId: 'queued', deliveryIndex: 0), enabled: true);
      await tester.pump();
      expect(player.activeCount, 1);
      if (state == AppLifecycleState.paused) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      }
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
      expect(player.activeCount, 0);
      if (state == AppLifecycleState.paused) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(gateway.calls, hasLength(1));
      output.playNow(request);
      await tester.pump();
      expect(player.activeCount, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
  testWidgets(
    '安卓授权中后台取消且再次主动长按可录音',
    (tester) async {
      final platform = _FakeRecorderPlatform()
        ..pendingPermission = Completer<VoicePermissionResult>();
      final gateway = _VoiceChatGateway();
      await tester.pumpWidget(
        _harness(viewModel: _chatViewModel(gateway), platform: platform),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('voice-hold'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      platform.pendingPermission!.complete(VoicePermissionResult.grantedNow);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(platform.starts, 0);
      platform.pendingPermission = null;
      await _recordAndroid(tester);
      await tester.pumpAndSettle();
      expect(gateway.sentTexts, ['今天有点累']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final interruption in ['平台中断', '后台']) {
    // 设备/音频中断对应准备与采集；离前台覆盖全部尚未提交阶段。
    final stages = interruption == '平台中断'
        ? ['准备', '录音']
        : ['准备', '录音', '转写', '重试', '待发送'];
    for (final stage in stages) {
      testWidgets(
        '安卓$interruption取消$stage且不发送迟到语音',
        (tester) async {
          final gateway = _VoiceChatGateway();
          final platform = _FakeRecorderPlatform();
          void interrupt() {
            if (interruption == '平台中断') {
              platform.interrupted.add(null);
            } else {
              tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
            }
          }
          if (stage == '准备') {
            platform.pendingStart = Completer<VoiceRecordingSession?>();
          }
          if (stage == '转写') gateway.hangTranscribe = true;
          if (stage == '重试') {
            gateway.transcribeFailuresRemaining = 1;
            gateway.transcribeError = const LocalChatGatewayException(
              '没有识别到语音，可以再说一次。',
            );
          }
          if (stage == '待发送') gateway.pendingDelivery = Completer<void>();
          final model = _chatViewModel(gateway);
          await tester.pumpWidget(_harness(viewModel: model, platform: platform));
          await tester.pumpAndSettle();
          if (stage == '待发送') {
            unawaited(model.send('已提交文字'));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byKey(const Key('voice-mic')));
          await tester.pumpAndSettle();
          if (stage == '准备' || stage == '录音') {
            final gesture = await tester.startGesture(
              tester.getCenter(find.byKey(const Key('voice-hold'))),
            );
            await tester.pump(const Duration(milliseconds: 600));
            interrupt();
            await tester.pump();
            if (stage == '准备') {
              final late = _FakeRecordingSession();
              platform.pendingStart!.complete(late);
              await tester.pumpAndSettle();
              expect(late.discardCalls, 1);
            } else {
              expect(platform.session!.discardCalls, 1);
            }
            await gesture.up();
          } else {
            await _recordAndroid(tester);
            interrupt();
          }
          await tester.pumpAndSettle();
          if (stage == '转写') gateway.completeHungTranscribe('迟到语音');
          if (stage == '待发送') gateway.pendingDelivery!.complete();
          await tester.pumpAndSettle();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          expect(gateway.sentTexts, stage == '待发送' ? ['已提交文字'] : isEmpty);
          expect(find.byKey(const Key('voice-hold')), findsOneWidget);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

  }

  for (final stage in ['准备', '录音', '转写', '重试', '待发送']) {
    testWidgets(
      '安卓导航离页取消$stage且回来不自动恢复',
      (tester) async {
        final gateway = _VoiceChatGateway();
        final platform = _FakeRecorderPlatform();
        if (stage == '准备') {
          platform.pendingStart = Completer<VoiceRecordingSession?>();
        }
        if (stage == '转写') gateway.hangTranscribe = true;
        if (stage == '重试') {
          gateway.transcribeFailuresRemaining = 1;
          gateway.transcribeError = const LocalChatGatewayException('没有识别到语音');
        }
        if (stage == '待发送') gateway.pendingDelivery = Completer<void>();
        final model = _chatViewModel(gateway);
        final router = GoRouter(
          initialLocation: '/chat',
          routes: [
            GoRoute(
              path: '/chat',
              builder: (_, _) => LocalChatView(
                voiceRecorderPlatform: platform,
                sttSettingsGateway: const _FixedSttGateway(configured: true),
              ),
            ),
            GoRoute(
              path: '/settings',
              builder: (_, _) => const Scaffold(body: Text('设置页')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: model,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        if (stage == '待发送') {
          unawaited(model.send('已提交文字'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('voice-mic')));
        await tester.pumpAndSettle();
        TestGesture? gesture;
        if (stage == '准备' || stage == '录音') {
          gesture = await tester.startGesture(
            tester.getCenter(find.byKey(const Key('voice-hold'))),
          );
          await tester.pump(const Duration(milliseconds: 600));
        } else {
          await _recordAndroid(tester);
        }
        unawaited(router.push('/settings'));
        await tester.pumpAndSettle();
        if (stage == '准备') {
          final late = _FakeRecordingSession();
          platform.pendingStart!.complete(late);
          await tester.pump();
          expect(late.discardCalls, 1);
        }
        if (stage == '录音') expect(platform.session!.discardCalls, 1);
        await gesture?.up();
        if (stage == '转写') gateway.completeHungTranscribe('迟到语音');
        if (stage == '待发送') gateway.pendingDelivery!.complete();
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('voice-hold')), findsOneWidget);
        expect(gateway.sentTexts, stage == '待发送' ? ['已提交文字'] : isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }


  testWidgets(
    '安卓转写时模态键盘抽屉分别消费返回后才取消语音',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = _VoiceChatGateway()..hangTranscribe = true;
      final model = _chatViewModel(gateway);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => QiyuShell(
              child: LocalChatView(
                voiceRecorderPlatform: _FakeRecorderPlatform(),
                sttSettingsGateway: const _FixedSttGateway(configured: true),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: model,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      await _recordAndroid(tester);
      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pump(const Duration(milliseconds: 300));
      final context = tester.element(find.byType(LocalChatView));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('模态遮挡')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('模态遮挡'), findsNothing);
      expect(find.byKey(const Key('nav-drawer')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const Key('nav-drawer')), findsOneWidget);
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('nav-drawer')), findsNothing);
      expect(find.text('取消'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      gateway.completeHungTranscribe('不应发送');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-hold')), findsOneWidget);
      expect(gateway.sentTexts, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final stage in ['准备', '录音', '转写', '重试', '待发送']) {
    testWidgets(
      '安卓系统返回取消$stage且不发送迟到语音',
      (tester) async {
        final gateway = _VoiceChatGateway();
        final platform = _FakeRecorderPlatform();
        if (stage == '准备') {
          platform.pendingStart = Completer<VoiceRecordingSession?>();
        }
        if (stage == '转写') gateway.hangTranscribe = true;
        if (stage == '重试') {
          gateway.transcribeFailuresRemaining = 1;
          gateway.transcribeError = const LocalChatGatewayException(
            '没有识别到语音，可以再说一次。',
          );
        }
        if (stage == '待发送') gateway.pendingDelivery = Completer<void>();
        final model = _chatViewModel(gateway);
        await tester.pumpWidget(_harness(viewModel: model, platform: platform));
        await tester.pumpAndSettle();
        if (stage == '待发送') {
          unawaited(model.send('已提交文字'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('voice-mic')));
        await tester.pumpAndSettle();
        if (stage == '准备' || stage == '录音') {
          final gesture = await tester.startGesture(
            tester.getCenter(find.byKey(const Key('voice-hold'))),
          );
          await tester.pump(const Duration(milliseconds: 600));
          await tester.binding.handlePopRoute();
          await tester.pump();
          if (stage == '准备') {
            final late = _FakeRecordingSession();
            platform.pendingStart!.complete(late);
            await tester.pumpAndSettle();
            expect(late.discardCalls, 1);
          } else {
            expect(platform.session!.discardCalls, 1);
          }
          await gesture.up();
        } else {
          await _recordAndroid(tester);
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        if (stage == '转写') gateway.completeHungTranscribe('迟到语音');
        if (stage == '待发送') gateway.pendingDelivery!.complete();
        await tester.pumpAndSettle();
        expect(gateway.sentTexts, stage == '待发送' ? ['已提交文字'] : isEmpty);
        expect(find.byKey(const Key('voice-hold')), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final action in ['重试', '重新录制', '丢弃']) {
    testWidgets(
      '安卓转写失败可点 $action 且保留草稿',
      (tester) async {
        final gateway = _VoiceChatGateway()
          ..transcribeFailuresRemaining = 1
          ..transcribeError = const LocalChatGatewayException(
            '没有识别到语音，可以再说一次。',
          );
        final platform = _FakeRecorderPlatform();
        await tester.pumpWidget(
          _harness(viewModel: _chatViewModel(gateway), platform: platform),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('chat-input')), '原草稿');
        await tester.tap(find.byKey(const Key('voice-mic')));
        await tester.pumpAndSettle();
        await _recordAndroid(tester);
        expect(find.textContaining('Esc'), findsNothing);
        expect(find.text('重试'), findsOneWidget);
        expect(find.text('重新录制'), findsOneWidget);
        expect(find.text('丢弃'), findsOneWidget);
        if (action == '重试') gateway.hangTranscribe = true;
        await tester.tap(find.text(action));
        // 重复点击同一帧也不能重入上传或开麦。
        await tester.tap(find.text(action));
        await tester.pump();
        expect(platform.starts, 1);
        if (action == '重试') {
          expect(gateway.transcribeCalls, 2);
          expect(
            gateway.transcribeAudioCalls.first,
            gateway.transcribeAudioCalls.last,
          );
          gateway.completeHungTranscribe('重试成功');
          await tester.pumpAndSettle();
          expect(gateway.sentTexts, ['重试成功']);
        } else {
          expect(gateway.sentTexts, isEmpty);
          expect(find.byKey(const Key('voice-hold')), findsOneWidget);
          await _recordAndroid(tester);
          await tester.pumpAndSettle();
          expect(gateway.sentTexts, ['今天有点累']);
        }
        await tester.tap(find.byKey(const Key('voice-text-mode')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('chat-input')))
              .controller!
              .text,
          '原草稿',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final cancelFirst in [true, false]) {
    testWidgets(
      '安卓等待发送提交与取消竞争 cancelFirst=$cancelFirst',
      (tester) async {
        final gateway = _VoiceChatGateway()
          ..pendingDelivery = Completer<void>();
        final model = _chatViewModel(gateway);
        await tester.pumpWidget(
          _harness(viewModel: model, platform: _FakeRecorderPlatform()),
        );
        await tester.pumpAndSettle();
        unawaited(model.send('先前文字'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('voice-mic')));
        await tester.pumpAndSettle();
        await _recordAndroid(tester);
        final cancel = tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
            .onPressed!;
        if (cancelFirst) cancel();
        gateway.pendingDelivery!.complete();
        await tester.pumpAndSettle();
        cancel();
        await tester.pumpAndSettle();
        expect(gateway.sentTexts, cancelFirst ? ['先前文字'] : ['先前文字', '今天有点累']);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    '安卓排队转写随会话丢弃而退出等待，之后仍可录音发送',
    (tester) async {
      final gateway = _VoiceChatGateway()..pendingDelivery = Completer<void>();
      final model = _chatViewModel(gateway);
      await tester.pumpWidget(
        _harness(viewModel: model, platform: _FakeRecorderPlatform()),
      );
      await tester.pumpAndSettle();
      unawaited(model.send('旧会话文字'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      await _recordAndroid(tester);
      expect(find.text('语音待发送，等待当前回复结束'), findsOneWidget);

      await model.discardSession('session-voice');
      await tester.pumpAndSettle();
      expect(find.text('语音待发送，等待当前回复结束'), findsNothing);
      gateway.pendingDelivery!.complete();
      await tester.pumpAndSettle();
      expect(gateway.sentTexts, ['旧会话文字']);
      expect(model.messages, isEmpty);

      gateway.pendingDelivery = null;
      await _recordAndroid(tester);
      await tester.pumpAndSettle();
      expect(gateway.sentTexts, ['旧会话文字', '今天有点累']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    '安卓停止录音等待中取消不上传迟到字节',
    (tester) async {
      final gateway = _VoiceChatGateway();
      final platform = _FakeRecorderPlatform()
        ..pendingStop = Completer<Uint8List>();
      await tester.pumpWidget(
        _harness(viewModel: _chatViewModel(gateway), platform: platform),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      await _recordAndroid(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      platform.pendingStop!.complete(Uint8List.fromList([4, 5, 6]));
      await tester.pumpAndSettle();
      expect(gateway.transcribeCalls, 0);
      expect(gateway.sentTexts, isEmpty);
      platform.pendingStop = null;
      await _recordAndroid(tester);
      await tester.pumpAndSettle();
      expect(gateway.sentTexts, ['今天有点累']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    '安卓取消等待发送的语音不停止已提交文字或回填草稿',
    (tester) async {
      final gateway = _VoiceChatGateway()..pendingDelivery = Completer<void>();
      final model = _chatViewModel(gateway);
      await tester.pumpWidget(
        _harness(viewModel: model, platform: _FakeRecorderPlatform()),
      );
      await tester.pumpAndSettle();
      unawaited(model.send('已提交文字'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('chat-input')), '后来草稿');
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      await _recordAndroid(tester);
      await tester.pump();
      expect(find.text('语音待发送，等待当前回复结束'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(model.sending, isTrue);
      gateway.pendingDelivery!.complete();
      await tester.pumpAndSettle();
      expect(gateway.sentTexts, ['已提交文字']);
      await tester.tap(find.byKey(const Key('voice-text-mode')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-input')))
            .controller!
            .text,
        '后来草稿',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    '安卓转写取消丢弃迟到结果并可重新录音',
    (tester) async {
      final gateway = _VoiceChatGateway()..hangTranscribe = true;
      final platform = _FakeRecorderPlatform();
      await tester.pumpWidget(
        _harness(viewModel: _chatViewModel(gateway), platform: platform),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      await _recordAndroid(tester);
      expect(find.textContaining('Esc'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      gateway.completeHungTranscribe('已取消的内容');
      await tester.pumpAndSettle();
      expect(gateway.sentTexts, isEmpty);
      gateway.hangTranscribe = false;
      await _recordAndroid(tester);
      await tester.pumpAndSettle();
      expect(gateway.sentTexts, ['今天有点累']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
  testWidgets(
    '安卓按住录音松手只发送一次并保留草稿',
    (tester) async {
      final gateway = _VoiceChatGateway();
      final platform = _FakeRecorderPlatform();
      await tester.pumpWidget(
        _harness(viewModel: _chatViewModel(gateway), platform: platform),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('chat-input')), '文字草稿');
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      expect(platform.session, isNull);
      final hold = find.byKey(const Key('voice-hold'));
      expect(hold, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(hold));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(gateway.transcribeCalls, 1);
      expect(gateway.sentTexts, ['今天有点累']);
      await tester.tap(find.byKey(const Key('voice-text-mode')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-input')))
            .controller!
            .text,
        '文字草稿',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
  for (final action in ['上滑', '移回', '短点', '短录音', '指针取消', '多指', '上限', '取消区上限']) {
    testWidgets(
      '安卓手势 $action 的发送边界',
      (tester) async {
        final gateway = _VoiceChatGateway();
        final platform = _FakeRecorderPlatform();
        await tester.pumpWidget(
          _harness(viewModel: _chatViewModel(gateway), platform: platform),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('voice-mic')));
        await tester.pumpAndSettle();
        final hold = find.byKey(const Key('voice-hold'));
        final origin = tester.getCenter(hold);
        final gesture = await tester.startGesture(origin, pointer: 1);
        if (action != '短点') {
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump();
        }
        if (action != '短点' && action != '短录音') {
          await tester.pump(const Duration(milliseconds: 600));
        }
        if (['上滑', '移回', '取消区上限'].contains(action)) {
          await gesture.moveTo(origin - const Offset(0, 48));
          await tester.pump();
          expect(find.text('松开取消'), findsOneWidget);
        }
        if (action == '移回') {
          await gesture.moveTo(origin - const Offset(0, 47));
          await tester.pump();
          expect(find.text('松开发送，上滑取消'), findsOneWidget);
        }
        if (action == '多指') {
          final other = await tester.startGesture(origin, pointer: 2);
          await other.up();
        }
        if (action.endsWith('上限')) {
          await tester.pump(const Duration(seconds: 60));
          await tester.pumpAndSettle();
        }
        if (action == '指针取消') {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pumpAndSettle();
        final sends = action == '移回' || action == '上限';
        expect(gateway.transcribeCalls, sends ? 1 : 0);
        expect(gateway.sentTexts, sends ? ['今天有点累'] : isEmpty);
        if (action == '短录音') {
          expect(find.text('说话时间太短，请重新按住说话'), findsOneWidget);
        }
        if (!sends && action != '短点') expect(platform.session!.discardCalls, 1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final permission in [
    VoicePermissionResult.grantedNow,
    VoicePermissionResult.denied,
  ]) {
    testWidgets(
      '安卓首次授权 $permission 不自行起录',
      (tester) async {
        final gateway = _VoiceChatGateway();
        final platform = _FakeRecorderPlatform()..permission = permission;
        await tester.pumpWidget(
          _harness(viewModel: _chatViewModel(gateway), platform: platform),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('voice-mic')));
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('voice-hold'))),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(platform.starts, 0);
        expect(
          find.textContaining(
            permission == VoicePermissionResult.grantedNow ? '重新按住' : '安卓系统设置',
          ),
          findsOneWidget,
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(gateway.transcribeCalls, 0);
        platform.permission = VoicePermissionResult.ready;
        final next = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('voice-hold'))),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        await next.up();
        await tester.pumpAndSettle();
        expect(gateway.sentTexts, ['今天有点累']);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final waiting in ['设备', '授权']) {
    testWidgets(
      '安卓等待$waiting时松手作废迟到结果且不并发起录',
      (tester) async {
        final gateway = _VoiceChatGateway();
        final platform = _FakeRecorderPlatform();
        if (waiting == '设备') {
          platform.pendingStart = Completer<VoiceRecordingSession?>();
        } else {
          platform.pendingPermission = Completer<VoicePermissionResult>();
        }
        await tester.pumpWidget(
          _harness(viewModel: _chatViewModel(gateway), platform: platform),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('voice-mic')));
        await tester.pumpAndSettle();
        final origin = tester.getCenter(find.byKey(const Key('voice-hold')));
        final gesture = await tester.startGesture(origin);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(find.text('正在准备麦克风…'), findsWidgets);
        await gesture.up();
        await tester.pump();
        final repeat = await tester.startGesture(origin);
        await tester.pump(const Duration(milliseconds: 600));
        await repeat.up();
        final late = _FakeRecordingSession();
        if (waiting == '设备') {
          platform.pendingStart!.complete(late);
        } else {
          platform.pendingPermission!.complete(
            VoicePermissionResult.grantedNow,
          );
        }
        await tester.pumpAndSettle();
        expect(platform.starts, waiting == '设备' ? 1 : 0);
        expect(late.discardCalls, waiting == '设备' ? 1 : 0);
        expect(gateway.sentTexts, isEmpty);
        expect(gateway.transcribeCalls, 0);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets('安卓起录前停止朗读', (tester) async {
    await _pumpVoiceScene(tester);
    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('voice-hold'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.byKey(const Key('voice-output-status')), findsNothing);
    await gesture.cancel();
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    '安卓未配置时切模式和查询完成均不自动起录',
    (tester) async {
      final platform = _FakeRecorderPlatform();
      final settings = _MutableSttGateway();
      await tester.pumpWidget(
        _harness(
          viewModel: _chatViewModel(),
          platform: platform,
          sttGateway: settings,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有配置语音服务'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-text-mode')));
      await tester.pumpAndSettle();
      settings.configured = true;
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      expect(platform.starts, 0);
      expect(find.byKey(const Key('voice-hold')), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    '安卓慢设备在页面销毁后成功返回也释放',
    (tester) async {
      final gateway = _VoiceChatGateway();
      final platform = _FakeRecorderPlatform()
        ..pendingStart = Completer<VoiceRecordingSession?>();
      await tester.pumpWidget(
        _harness(viewModel: _chatViewModel(gateway), platform: platform),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('voice-hold'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox.shrink());
      final late = _FakeRecordingSession();
      platform.pendingStart!.complete(late);
      await tester.pump();
      await gesture.up();
      expect(late.discardCalls, 1);
      expect(gateway.sentTexts, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );


  testWidgets('安卓读屏提供等价的开始结束和取消录音动作', (tester) async {
    final semantics = tester.ensureSemantics();
    final gateway = _VoiceChatGateway();
    final platform = _FakeRecorderPlatform();
    await tester.pumpWidget(_harness(viewModel: _chatViewModel(gateway), platform: platform));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pumpAndSettle();
    void act(String label) {
      final node = tester.getSemantics(find.byKey(const Key('voice-hold')));
      expect(node.rect.width, greaterThanOrEqualTo(48));
      expect(node.rect.height, greaterThanOrEqualTo(48));
      final id = node.getSemanticsData().customSemanticsActionIds!.singleWhere(
        (id) => CustomSemanticsAction.getAction(id)!.label == label,
      );
      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(node.id, SemanticsAction.customAction, id);
    }
    act('开始录音');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    act('结束并发送');
    await tester.pumpAndSettle();
    expect(gateway.sentTexts, ['今天有点累']);
    act('开始录音');
    await tester.pumpAndSettle();
    act('取消录音');
    await tester.pumpAndSettle();
    expect(platform.session!.discardCalls, 1);
    expect(gateway.transcribeCalls, 1);
    final textMode = tester.getSemantics(find.byKey(const Key('voice-text-mode')));
    expect(textMode.getSemanticsData().tooltip, '切换到文字输入');
    tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(textMode.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    final mic = tester.getSemantics(find.byKey(const Key('voice-mic')));
    tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(mic.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.byKey(const Key('voice-hold'))).label, '按住说话');
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final preparing in [true, false]) {
    testWidgets('安卓${preparing ? '准备' : '录音'}中迟到回复和主动重听均不发声', (tester) async {
      final gateway = _VoiceChatGateway()..pendingDelivery = Completer<void>();
      final speak = _RecordingSpeakGateway();
      final output = VoiceOutputController(speak, playerPlatform: _HoldingPlayerPlatform());
      final platform = _FakeRecorderPlatform();
      if (preparing) platform.pendingStart = Completer<VoiceRecordingSession?>();
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: FakeHostConnectionProbe(const [true]),
        ttsSettingsGateway: _FixedTtsGateway(configured: true),
        voiceOutput: output,
        autoStart: false,
      );
      await viewModel.refreshVoiceOutputStatus();
      await tester.pumpWidget(_harness(viewModel: viewModel, platform: platform));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-mic')));
      await tester.pumpAndSettle();
      final hold = await tester.startGesture(tester.getCenter(find.byKey(const Key('voice-hold'))), pointer: 1);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      gateway.pendingDelivery!.complete();
      await tester.pumpAndSettle();
      expect(find.text('咋了'), findsOneWidget);
      expect(speak.calls, isEmpty);
      await tester.tap(find.byKey(const Key('chat-replay-0')), pointer: 2);
      await tester.pumpAndSettle();
      expect(speak.calls, isEmpty);
      expect(find.byKey(const Key('voice-output-status')), findsNothing);
      await hold.cancel();
      if (preparing) platform.pendingStart!.complete(_FakeRecordingSession());
      await tester.pumpAndSettle();
      expect(speak.calls, isEmpty); // 结束录音不会补播录音期间的内容。
      await tester.tap(find.byKey(const Key('chat-replay-0')));
      await tester.pumpAndSettle();
      expect(speak.calls, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      viewModel.dispose();
      output.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('模型回复完整交付后自动朗读：指示与停止按钮', (tester) async {
    final (speakGateway, _, _) = await _pumpVoiceScene(tester);

    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    // 完整交付后自动朗读一次（且仅一次）：状态行、气泡指示、停止按钮。
    expect(speakGateway.calls, hasLength(1));
    expect(find.byKey(const Key('voice-output-status')), findsOneWidget);
    expect(find.byKey(const Key('voice-output-stop')), findsOneWidget);
    expect(find.text('正在读'), findsOneWidget);

    // 停止按钮：立即停播收起状态。
    await tester.tap(find.byKey(const Key('voice-output-stop')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsNothing);
    expect(find.text('正在读'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('点麦克风与 Esc 都让栖语立即闭嘴（防自我循环）', (tester) async {
    await _pumpVoiceScene(tester);

    // 一轮回复后自动朗读中。
    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsOneWidget);

    // 点麦克风：立即停播清队列（否则她的声音会被录进转写自我循环）。
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsNothing);

    // 再触发一轮朗读，Esc 同样停播。
    await tester.enterText(find.byKey(const Key('chat-input')), '还在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-status')), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('离开聊天页立即停止朗读并清空队列', (tester) async {
    final player = _HoldingPlayerPlatform();
    final controller = VoiceOutputController(
      _RecordingSpeakGateway(),
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      _VoiceChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    final router = GoRouter(
      initialLocation: '/chat',
      routes: [
        GoRoute(
          path: '/chat',
          builder: (context, state) => LocalChatView(
            voiceRecorderPlatform: _FakeRecorderPlatform(),
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
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(controller.phase, VoiceOutputPhase.playing);
    expect(player.activeCount, 1);

    await tester.tap(find.byKey(const Key('open-provider-settings')));
    await tester.pumpAndSettle();
    expect(find.text('设置页'), findsOneWidget);
    expect(controller.phase, VoiceOutputPhase.idle);
    expect(player.activeCount, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    viewModel.dispose();
    controller.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('气泡小喇叭重听：播完后点喇叭立即再读一次', (tester) async {
    final (speakGateway, player, _) = await _pumpVoiceScene(tester);

    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    // 自动朗读一次；播完后气泡出现重听小喇叭。
    expect(speakGateway.calls, hasLength(1));
    player.finishAll();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-replay-0')), findsOneWidget);

    // 点小喇叭：重听 = 重新合成再播一次。
    await tester.tap(find.byKey(const Key('chat-replay-0')));
    await tester.pumpAndSettle();
    expect(speakGateway.calls, hasLength(2));
    expect(speakGateway.calls.last.deliveryIndex, 0);
    expect(speakGateway.calls.map((call) => call.sessionId), [
      'session-voice',
      'session-voice',
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('朗读开关：配了才显示，点按切 autoSpeak 并停播', (tester) async {
    final speakGateway = _RecordingSpeakGateway();
    final player = _HoldingPlayerPlatform();
    final controller = VoiceOutputController(
      speakGateway,
      playerPlatform: player,
    );
    final mutableTts = _MutableTtsGateway(configured: true, autoSpeak: true);
    final viewModel = LocalChatViewModel(
      _VoiceChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      ttsSettingsGateway: mutableTts,
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );

    // 配了 TTS：顶部出现朗读小喇叭（开着）。
    expect(find.byKey(const Key('voice-output-toggle-on')), findsOneWidget);

    // 点小喇叭弹出音量与静音卡片。
    await tester.tap(find.byKey(const Key('voice-output-toggle-on')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('voice-output-volume-slider')), findsOneWidget);
    expect(
      find.byKey(const Key('voice-output-popover-mute-button')),
      findsOneWidget,
    );

    // 点弹窗里的静音按钮关掉朗读：写 Host autoSpeak=false，图标切换。
    await tester.tap(find.byKey(const Key('voice-output-popover-mute-button')));
    await tester.pumpAndSettle();
    expect(mutableTts.autoSpeakWrites, [false]);
    expect(find.byKey(const Key('voice-output-toggle-off')), findsOneWidget);

    // 弹窗开着时全屏遮罩盖住 composer：先点遮罩收起弹窗，发送才点得到。
    await tester.tapAt(const Offset(10, 590));
    await tester.pumpAndSettle();

    // 关了之后自动朗读不触发（纯文字）。
    await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    // 发送真实触发：回复落屏；只是不朗读。
    expect(find.text('咋了'), findsOneWidget);
    expect(speakGateway.calls, isEmpty);
    expect(find.byKey(const Key('voice-output-status')), findsNothing);

    // 再点开小喇叭弹窗，点静音按钮解除静音：恢复自动朗读。
    await tester.tap(find.byKey(const Key('voice-output-toggle-off')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-output-popover-mute-button')));
    await tester.pumpAndSettle();
    expect(mutableTts.autoSpeakWrites, [false, true]);
    expect(find.byKey(const Key('voice-output-toggle-on')), findsOneWidget);

    // 调节滑块
    await tester.drag(
      find.byKey(const Key('voice-output-volume-slider')),
      const Offset(0, -30),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('未配语音合成：不显示朗读开关', (tester) async {
    final viewModel = LocalChatViewModel(
      _VoiceChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      ttsSettingsGateway: _FixedTtsGateway(configured: false),
      voiceOutput: VoiceOutputController(
        _RecordingSpeakGateway(),
        playerPlatform: _HoldingPlayerPlatform(),
      ),
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-output-toggle-on')), findsNothing);
    expect(find.byKey(const Key('voice-output-toggle-off')), findsNothing);
    viewModel.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('未配置语音服务：置灰点按引导去设置页', (tester) async {
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(),
        platform: _FakeRecorderPlatform(),
        sttConfigured: false,
      ),
    );
    await tester.pump();

    final mic = find.byKey(const Key('voice-mic'));
    expect(mic, findsOneWidget);
    await tester.tap(mic);
    await tester.pump();

    expect(find.textContaining('还没有配置语音服务'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 5500));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有配置语音服务'), findsNothing);
    expect(find.text('去设置'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('浏览器不支持录音：明确提示而不是无声失败', (tester) async {
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(),
        platform: _FakeRecorderPlatform(supported: false),
        sttConfigured: false,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();

    expect(find.textContaining('不支持语音输入'), findsOneWidget);
    expect(find.text('去设置'), findsNothing);
    await tester.pump(const Duration(milliseconds: 5500));
    await tester.pumpAndSettle();
    expect(find.textContaining('不支持语音输入'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('麦克风权限被拒（安卓系统弹窗拒绝）：入口如实报错，文字主链路照常', (tester) async {
    // 安卓真机上的拒绝路径：能力可用但系统权限被拒，start 返回 null。
    final gateway = _VoiceChatGateway();
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(gateway),
        platform: _FakeRecorderPlatform(permissionDenied: true),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();

    // 录音入口如实报告不可用（就近平铺，留在 idle 可再试），不弹错误对话框。
    expect(find.textContaining('无法使用麦克风'), findsOneWidget);
    expect(find.byKey(const Key('voice-mic')), findsOneWidget);

    // 拒绝不伤文字主链路：输入与发送一切照旧。
    await tester.enterText(find.byKey(const Key('chat-input')), '今晚有点闷');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(gateway.sentTexts, ['今晚有点闷']);
    expect(find.text('今晚有点闷'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('配置完成后置灰麦克风直接开始录音（无需刷新页面）', (tester) async {
    final sttGateway = _MutableSttGateway()..configured = false;
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(),
        platform: _FakeRecorderPlatform(),
        sttGateway: sttGateway,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('voice-mic')), findsOneWidget);

    // 用户在设置页配好语音服务后回到聊天页再点麦克风。
    sttGateway.configured = true;
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();

    // 重查成功：不弹引导，直接进入录音。
    expect(find.textContaining('还没有配置语音服务'), findsNothing);
    expect(find.byKey(const Key('voice-mic-stop')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('录音 → 转写 → 成功只发一条用户消息', (tester) async {
    // 先挂起转写以观察「正在转文字」中间态，再放行到成功。
    final gateway = _VoiceChatGateway()..hangTranscribe = true;
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(gateway),
        platform: _FakeRecorderPlatform(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-stop')), findsOneWidget);
    expect(find.textContaining('正在录音'), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice-mic-stop')));
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-busy')), findsOneWidget);
    expect(find.textContaining('正在转文字'), findsOneWidget);
    expect(gateway.sentTexts, isEmpty);

    gateway.completeHungTranscribe('今天有点累');
    await tester.pumpAndSettle();

    // 转写文本经既有发送链路变成唯一一条用户消息与栖语回复。
    expect(gateway.sentTexts, ['今天有点累']);
    expect(find.text('今天有点累'), findsOneWidget);
    expect(find.text('咋了'), findsOneWidget);
    expect(find.byKey(const Key('voice-mic')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('说完按停止先取得播放许可，异步转写和回复后仍自动朗读', (tester) async {
    final gateway = _VoiceChatGateway()..hangTranscribe = true;
    final player = _GestureLockedPlayerPlatform();
    final controller = VoiceOutputController(
      _RecordingSpeakGateway(),
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    player.gestureActive = true;
    await tester.tap(find.byKey(const Key('voice-mic-stop')));
    player.gestureActive = false;
    await tester.pump();

    gateway.completeHungTranscribe('今天有点累');
    await tester.pumpAndSettle();

    expect(player.started, isTrue);
    expect(controller.failureNotice, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('60 秒自动收尾仍沿用开始录音的许可自动朗读', (tester) async {
    final gateway = _VoiceChatGateway()..hangTranscribe = true;
    final player = _GestureLockedPlayerPlatform();
    final controller = VoiceOutputController(
      _RecordingSpeakGateway(),
      playerPlatform: player,
    );
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      ttsSettingsGateway: _FixedTtsGateway(configured: true),
      voiceOutput: controller,
      autoStart: false,
    );
    await viewModel.refreshVoiceOutputStatus();
    await tester.pumpWidget(
      _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
    );
    await tester.pump();

    player.gestureActive = true;
    await tester.tap(find.byKey(const Key('voice-mic')));
    player.gestureActive = false;
    await tester.pump(const Duration(seconds: 60));
    expect(find.byKey(const Key('voice-mic-busy')), findsOneWidget);

    gateway.completeHungTranscribe('今天有点累');
    await tester.pumpAndSettle();

    expect(player.started, isTrue);
    expect(controller.failureNotice, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('转写失败进重试态，点麦克风重传后照常发送', (tester) async {
    final gateway = _VoiceChatGateway()
      ..transcribeFailuresRemaining = 1
      ..transcribeError = const LocalChatGatewayException('没有识别到语音，可以再说一次。');
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(gateway),
        platform: _FakeRecorderPlatform(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-mic-stop')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('voice-mic-retry')), findsOneWidget);
    expect(find.textContaining('没有识别到语音'), findsOneWidget);
    expect(gateway.sentTexts, isEmpty);
    expect(gateway.transcribeCalls, 1);

    // 重试：不重录、同一段音频再传一次。
    await tester.tap(find.byKey(const Key('voice-mic-retry')));
    await tester.pumpAndSettle();

    expect(gateway.transcribeCalls, 2);
    expect(
      gateway.transcribeAudioCalls.first,
      gateway.transcribeAudioCalls.last,
    );
    expect(gateway.sentTexts, ['今天有点累']);
    expect(find.text('今天有点累'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('录音中按 Esc 丢弃：不转写也不发送', (tester) async {
    final platform = _FakeRecorderPlatform();
    final gateway = _VoiceChatGateway();
    await tester.pumpWidget(
      _harness(viewModel: _chatViewModel(gateway), platform: platform),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-stop')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.byKey(const Key('voice-mic')), findsOneWidget);
    expect(find.textContaining('正在录音'), findsNothing);
    expect(gateway.transcribeCalls, 0);
    expect(platform.session!.discardCalls, 1);
    expect(gateway.sentTexts, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('转写中按 Esc 中止：回重试态且迟到结果不发送', (tester) async {
    final gateway = _VoiceChatGateway()..hangTranscribe = true;
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(gateway),
        platform: _FakeRecorderPlatform(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-mic-stop')));
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-busy')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('voice-mic-retry')), findsOneWidget);

    // 迟到的转写结果到达：不触发发送，重试态保持。
    gateway.completeHungTranscribe('迟到的话');
    await tester.pumpAndSettle();
    expect(gateway.sentTexts, isEmpty);
    expect(find.byKey(const Key('voice-mic-retry')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('转写发送失败：原文按既有条件回填输入框', (tester) async {
    final gateway = _VoiceChatGateway()
      ..deliverError = const LocalChatGatewayException('本地聊天暂时不可用，请稍后重试。')
      ..deliverFailuresRemaining = 1;
    await tester.pumpWidget(
      _harness(
        viewModel: _chatViewModel(gateway),
        platform: _FakeRecorderPlatform(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-mic-stop')));
    await tester.pumpAndSettle();

    // 发送失败且输入框为空：转写文本回填，等待用户重发，不重复显示消息。
    expect(gateway.sentTexts, ['今天有点累']);
    expect(find.text('本地聊天暂时不可用，请稍后重试。'), findsOneWidget);
    final input = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(input.controller!.text, '今天有点累');
    expect(find.byKey(const Key('voice-mic')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

void _expectTouchTarget(WidgetTester tester, Finder finder) {
  final rect = tester.getRect(finder);
  expect(rect.width, greaterThanOrEqualTo(48));
  expect(rect.height, greaterThanOrEqualTo(48));
  final semanticRect = tester.getSemantics(finder).rect;
  expect(semanticRect.width, greaterThanOrEqualTo(48));
  expect(semanticRect.height, greaterThanOrEqualTo(48));
}

Widget _harness({
  required LocalChatViewModel viewModel,
  required VoiceRecorderPlatform platform,
  bool sttConfigured = true,
  SttSettingsGateway? sttGateway,
  bool touchTheme = false,
  double textScale = 1,
}) {
  return MultiProvider(
    providers: [ChangeNotifierProvider.value(value: viewModel)],
    child: MaterialApp(
      theme: touchTheme ? qiyuDarkTheme(narrow: true) : null,
      builder: textScale == 1 ? null : (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: LocalChatView(
        voiceRecorderPlatform: platform,
        sttSettingsGateway:
            sttGateway ?? _FixedSttGateway(configured: sttConfigured),
      ),
    ),
  );
}

/// 装配语音聊天场景：朗读网关 + 挂起播放器 + 朗读控制器 + 聊天 ViewModel，
/// 推进到可朗读状态后挂上 harness；测试结束后按 pumpWidget(shrink) →
/// viewModel.dispose() → controller.dispose() 的顺序释放。返回
/// （朗读网关, 播放平台, 朗读控制器）三元组。
Future<(_RecordingSpeakGateway, _HoldingPlayerPlatform, VoiceOutputController)>
_pumpVoiceScene(WidgetTester tester) async {
  final speakGateway = _RecordingSpeakGateway();
  final player = _HoldingPlayerPlatform();
  final controller = VoiceOutputController(
    speakGateway,
    playerPlatform: player,
  );
  final viewModel = LocalChatViewModel(
    _VoiceChatGateway(),
    hostConnectionProbe: FakeHostConnectionProbe(const [true]),
    ttsSettingsGateway: _FixedTtsGateway(configured: true),
    voiceOutput: controller,
    autoStart: false,
  );
  await viewModel.refreshVoiceOutputStatus();
  await tester.pumpWidget(
    _harness(viewModel: viewModel, platform: _FakeRecorderPlatform()),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    controller.dispose();
  });
  return (speakGateway, player, controller);
}

LocalChatViewModel _chatViewModel([StreamingLocalChatGateway? gateway]) =>
    LocalChatViewModel(
      gateway ?? _VoiceChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      autoStart: false,
    );

/// configured 可翻转的 STT 设置网关：模拟设置页保存前后的状态。
final class _MutableSttGateway implements SttSettingsGateway {
  var configured = false;

  @override
  Future<SttSettings> read() async =>
      SttSettings(configured: configured, keySet: configured);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async =>
      const SttSettings(configured: true, keySet: true);

  @override
  Future<SttSettings> forgetApiKey() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: true,
        status: ProviderTestStatus.success,
        message: '连接成功，语音输入可以使用。',
      );
}

final class _FixedSttGateway implements SttSettingsGateway {
  const _FixedSttGateway({required this.configured});

  final bool configured;

  @override
  Future<SttSettings> read() async =>
      SttSettings(configured: configured, keySet: configured);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async =>
      const SttSettings(configured: true, keySet: true);

  @override
  Future<SttSettings> forgetApiKey() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: true,
        status: ProviderTestStatus.success,
        message: '连接成功，语音输入可以使用。',
      );
}

/// 聊天 + 转写双通道 fake：转写与发送行为均可编程（失败次数、挂起等待）。
final class _VoiceChatGateway implements StreamingLocalChatGateway {
  int cancelCalls = 0;
  final sentTexts = <String>[];
  final transcribeAudioCalls = <List<int>>[];
  int transcribeCalls = 0;
  int transcribeFailuresRemaining = 0;
  LocalChatGatewayException? transcribeError;
  bool hangTranscribe = false;
  final _hungCompleters = <Completer<String>>[];
  int deliverFailuresRemaining = 0;
  Completer<void>? pendingDelivery;
  LocalChatGatewayException? deliverError;

  void completeHungTranscribe(String text) {
    for (final completer in _hungCompleters) {
      if (!completer.isCompleted) {
        completer.complete(text);
      }
    }
  }

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-voice', messages: []);

  @override
  Future<bool> cancel(String requestId) async {
    cancelCalls++;
    return true;
  }

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async {
    transcribeCalls += 1;
    transcribeAudioCalls.add(audio.toList());
    if (hangTranscribe) {
      final completer = Completer<String>();
      _hungCompleters.add(completer);
      return completer.future;
    }
    if (transcribeFailuresRemaining > 0) {
      transcribeFailuresRemaining -= 1;
      throw transcribeError ?? const LocalChatGatewayException('转写失败。');
    }
    return '今天有点累';
  }

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    sentTexts.add(text);
    if (deliverError case final error? when deliverFailuresRemaining > 0) {
      deliverFailuresRemaining -= 1;
      throw error;
    }
    yield LocalChatDeliveryEvent.accepted(
      requestId: requestId,
      sessionId: 'session-voice',
    );
    if (pendingDelivery != null) await pendingDelivery!.future;
    yield LocalChatDeliveryEvent.message(
      requestId: requestId,
      messages: ['咋了'],
    );
    yield LocalChatDeliveryEvent.state(
      requestId: requestId,
      source: ReplySource.local,
      fallbackReason: FallbackReason.noLlmConfig,
    );
    yield LocalChatDeliveryEvent.done(
      requestId: requestId,
    );
  }
}

final class _FakeRecorderPlatform
    implements VoiceRecorderPlatform, PermissionAwareVoiceRecorderPlatform, InterruptibleVoiceRecorderPlatform {
  final interrupted = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get interruptions => interrupted.stream;
  @override
  Future<void> prepareInput() async {}
  @override
  void cancelPreparation() {}
  _FakeRecorderPlatform({this.supported = true, this.permissionDenied = false});

  @override
  final bool supported;

  /// 模拟安卓系统权限弹窗被拒：能力可用但 start 返回 null。
  final bool permissionDenied;
  _FakeRecordingSession? session;
  Completer<VoiceRecordingSession?>? pendingStart;
  Completer<VoicePermissionResult>? pendingPermission;
  VoicePermissionResult permission = VoicePermissionResult.ready;
  int starts = 0;
  Completer<Uint8List>? pendingStop;

  @override
  Future<VoicePermissionResult> preparePermission() async =>
      pendingPermission?.future ?? permission;

  @override
  Future<VoiceRecordingSession?> start() async {
    starts++;
    if (pendingStart != null) return pendingStart!.future;
    return supported && !permissionDenied
        ? (session = _FakeRecordingSession()..pendingStop = pendingStop)
        : null;
  }

  @override
  Future<RecordedAudio> toWav16kMono(RecordedAudio audio) async =>
      RecordedAudio(bytes: audio.bytes, mimeType: 'audio/wav');
}

final class _FakeRecordingSession implements VoiceRecordingSession {
  Completer<Uint8List>? pendingStop;
  int discardCalls = 0;

  @override
  String get mimeType => 'audio/webm';

  @override
  Future<Uint8List> stop() async => pendingStop == null ? Uint8List.fromList([1, 2, 3]) : await pendingStop!.future;

  @override
  void discard() {
    discardCalls += 1;
  }
}

/// TTS 设置 fake：朗读可用性可编程。
final class _FixedTtsGateway implements TtsSettingsGateway {
  _FixedTtsGateway({required this.configured});

  final bool configured;

  @override
  Future<TtsSettings> read() async =>
      TtsSettings(configured: configured, keySet: configured);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> forgetApiKey() async => throw UnimplementedError();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      throw UnimplementedError();
}

/// 朗读 fake：记录调用，播放挂起直到测试放行。
final class _RecordingSpeakGateway implements ChatSpeechGateway {
  final List<({String requestId, int deliveryIndex, String? sessionId})> calls =
      [];

  @override
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  }) async {
    calls.add((
      requestId: requestId,
      deliveryIndex: deliveryIndex,
      sessionId: sessionId,
    ));
    return Uint8List.fromList([1]);
  }
}

/// 播放挂起型 fake：正在读的状态保持到 finish 被调用。
final class _HoldingPlayerPlatform implements VoicePlayerPlatform {
  final _playbacks = <Completer<void>>[];

  int get activeCount => _playbacks.length;

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
  }) async {
    final playback = _HoldingPlayback(this);
    _playbacks.add(playback._done);
    return playback;
  }

  void finishAll() {
    for (final done in _playbacks) {
      if (!done.isCompleted) {
        done.complete();
      }
    }
    _playbacks.clear();
  }
}

final class _HoldingPlayback implements VoicePlayback {
  _HoldingPlayback(this._platform);

  final _HoldingPlayerPlatform _platform;
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  void setVolume(double volume) {}

  @override
  void stop() {
    _platform._playbacks.remove(_done);
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

final class _GestureLockedPlayerPlatform
    implements VoicePlayerPlatform, UserGestureVoicePlayerPlatform {
  bool gestureActive = false;
  bool _prepared = false;
  bool started = false;

  @override
  bool get supported => true;

  @override
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  void prepareForPlayback() {
    if (gestureActive) {
      _prepared = true;
    }
  }

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async {
    if (!_prepared) {
      return null;
    }
    started = true;
    return const _CompletedPlayback();
  }
}

final class _CompletedPlayback implements VoicePlayback {
  const _CompletedPlayback();

  @override
  Future<void> get done => Future<void>.value();

  @override
  void setVolume(double volume) {}

  @override
  void stop() {}
}

/// 可翻转的 TTS 设置 fake：记录 autoSpeak 写入。
final class _MutableTtsGateway implements TtsSettingsGateway {
  _MutableTtsGateway({required this.configured, this.autoSpeak = true});

  bool configured;
  bool autoSpeak;
  final autoSpeakWrites = <bool>[];

  @override
  Future<TtsSettings> read() async => TtsSettings(
    configured: configured,
    keySet: configured,
    autoSpeak: autoSpeak,
  );

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async {
    autoSpeakWrites.add(enabled);
    autoSpeak = enabled;
    return TtsSettings(
      configured: configured,
      keySet: configured,
      autoSpeak: autoSpeak,
    );
  }

  @override
  Future<TtsSettings> forgetApiKey() async => throw UnimplementedError();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      throw UnimplementedError();
}

Future<void> _recordAndroid(WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('voice-hold'))));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 300));
}
