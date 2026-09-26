import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/qiyu_voice_output_control.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/theme/qiyu_icons.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';

import 'support/shared_fakes.dart';

void main() {
  testWidgets('初始音量分档渲染开关图标：正常、低音量与静音三档', (tester) async {
    final bundle = await _pumpControl(tester);
    expect(find.byKey(const Key('voice-output-toggle-on')), findsOneWidget);
    expect(_toggleIcon(tester), QiyuIcons.volume_up);

    bundle.voiceOutput.setVolume(0.3);
    await tester.pumpAndSettle();
    expect(_toggleIcon(tester), QiyuIcons.volume_down);

    bundle.voiceOutput.setVolume(0);
    await tester.pumpAndSettle();
    expect(_toggleIcon(tester), QiyuIcons.volume_off);

    bundle.voiceOutput.setVolume(0.9);
    await tester.pumpAndSettle();
    expect(_toggleIcon(tester), QiyuIcons.volume_up);

    _dispose(bundle);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('点开关弹出音量卡片：滑块、静音键与百分比就位', (tester) async {
    final bundle = await _pumpControl(tester);
    await tester.tap(find.byKey(const Key('voice-output-toggle-on')));
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(
      find.byKey(const Key('voice-output-volume-slider')),
    );
    expect(slider.value, 0.5);
    expect(
      find.byKey(const Key('voice-output-popover-mute-button')),
      findsOneWidget,
    );
    expect(find.text('50%'), findsOneWidget);

    _dispose(bundle);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('拖动滑块调音量：音量上升并持久化偏好', (tester) async {
    final bundle = await _pumpControl(tester);
    await tester.tap(find.byKey(const Key('voice-output-toggle-on')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('voice-output-volume-slider')),
      const Offset(0, -40),
    );
    await tester.pumpAndSettle();

    expect(bundle.voiceOutput.volume, greaterThan(0.6));
    expect(bundle.player.saved, isNotEmpty);
    expect(find.text('50%'), findsNothing);

    _dispose(bundle);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('静音按钮写回 autoSpeak=false：键切换、滑块归零、百分比归零', (tester) async {
    final bundle = await _pumpControl(tester);
    await tester.tap(find.byKey(const Key('voice-output-toggle-on')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('voice-output-popover-mute-button')));
    await tester.pumpAndSettle();

    expect(bundle.tts.autoSpeakWrites, [false]);
    expect(find.byKey(const Key('voice-output-toggle-off')), findsOneWidget);
    final slider = tester.widget<Slider>(
      find.byKey(const Key('voice-output-volume-slider')),
    );
    expect(slider.value, 0.0);
    expect(find.text('0%'), findsOneWidget);

    _dispose(bundle);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('静音态拖动滑块到非零音量：自动恢复自动朗读', (tester) async {
    final bundle = await _pumpControl(tester, autoSpeak: false);
    expect(find.byKey(const Key('voice-output-toggle-off')), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-output-toggle-off')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('voice-output-volume-slider')),
      const Offset(0, -40),
    );
    await tester.pumpAndSettle();

    expect(bundle.tts.autoSpeakWrites, isNotEmpty);
    expect(bundle.tts.autoSpeakWrites.last, isTrue);
    expect(find.byKey(const Key('voice-output-toggle-on')), findsOneWidget);
    expect(bundle.voiceOutput.volume, greaterThan(0));

    _dispose(bundle);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('弹层开着时点遮罩收起：滑块与静音键出树', (tester) async {
    final bundle = await _pumpControl(tester);
    await tester.tap(find.byKey(const Key('voice-output-toggle-on')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('voice-output-volume-slider')),
      findsOneWidget,
    );

    await tester.tapAt(const Offset(10, 590));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('voice-output-volume-slider')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('voice-output-popover-mute-button')),
      findsNothing,
    );

    _dispose(bundle);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

IconData _toggleIcon(WidgetTester tester) {
  final icon = tester.widget<Icon>(
    find.byWidgetPredicate(
      (widget) =>
          widget is Icon &&
          (widget.icon == QiyuIcons.volume_up ||
              widget.icon == QiyuIcons.volume_down ||
              widget.icon == QiyuIcons.volume_off),
    ),
  );
  return icon.icon!;
}

void _dispose(_ControlBundle bundle) {
  bundle.viewModel.dispose();
  bundle.voiceOutput.dispose();
}

Future<_ControlBundle> _pumpControl(
  WidgetTester tester, {
  bool autoSpeak = true,
  double initialVolume = 0.5,
}) async {
  final tts = _FixedTtsGateway(autoSpeak: autoSpeak);
  final player = _VolumePlayerPlatform(initialVolume);
  final gateway = _SilentChatGateway();
  final voiceOutput = VoiceOutputController(gateway, playerPlatform: player);
  final viewModel = LocalChatViewModel(
    gateway,
    hostConnectionProbe: FakeHostConnectionProbe(const [true]),
    ttsSettingsGateway: tts,
    voiceOutput: voiceOutput,
    autoStart: false,
  );
  await viewModel.refreshVoiceOutputStatus();

  await tester.pumpWidget(
    MaterialApp(
      theme: qiyuDarkTheme(),
      home: Scaffold(
        // 页面侧经 context.watch 重建把 voiceOutputEnabled 送进控件；
        // 独立泵装用同一语义的 ListenableBuilder 代替。
        body: ListenableBuilder(
          listenable: viewModel,
          builder: (context, _) => QiyuVoiceOutputControl(viewModel: viewModel),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    viewModel: viewModel,
    voiceOutput: voiceOutput,
    tts: tts,
    player: player,
  );
}

typedef _ControlBundle = ({
  LocalChatViewModel viewModel,
  VoiceOutputController voiceOutput,
  _FixedTtsGateway tts,
  _VolumePlayerPlatform player,
});

/// 不发任何事件的聊天网关替身：弹层用例只走开关与音量，不触达交付链路。
final class _SilentChatGateway
    implements StreamingLocalChatGateway, ChatSpeechGateway {
  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);

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
  }) async* {}
}

/// 音量可配的播放平台替身：记录持久化写，读回构造时给定的初始音量。
final class _VolumePlayerPlatform implements VoicePlayerPlatform {
  _VolumePlayerPlatform(this.initialVolume);

  final double initialVolume;
  final List<double> saved = [];

  @override
  bool get supported => true;

  @override
  double getInitialVolume() => initialVolume;

  @override
  void saveVolume(double volume) => saved.add(volume);

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async => null;
}

/// 固定读数的 TTS 设置网关替身：setAutoSpeak 只记录写并回读最新值。
final class _FixedTtsGateway implements TtsSettingsGateway {
  _FixedTtsGateway({required this.autoSpeak});

  final bool autoSpeak;
  final List<bool> autoSpeakWrites = [];

  @override
  Future<TtsSettings> read() async => TtsSettings(
    configured: true,
    keySet: true,
    autoSpeak: autoSpeakWrites.isEmpty ? autoSpeak : autoSpeakWrites.last,
  );

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async {
    autoSpeakWrites.add(enabled);
    return read();
  }

  @override
  Future<TtsSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) =>
      throw UnimplementedError();
}
