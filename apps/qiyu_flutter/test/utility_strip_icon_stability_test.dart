
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'support/shared_fakes.dart';

/// 回归回路（bug 诊断）：本地规则回复时聊天页工具条右上角的三枚图标
/// （朗读开关 / 历史 / 模型连接）整体左移，模型回复后复位。
///
/// 期望不变量：图标水平位置只由壳层布局决定，与最近一次回复来自本地
/// 规则还是模型无关。测试同一会话内先投递本地规则回复、再投递模型
/// 回复，分别量三枚图标的 left 坐标并断言相等；bug 存在时变红。
///
/// 另设侧边栏导航项（nav-history / nav-memory / nav-settings）作对照组：
/// 侧边栏是定宽 240px 的独立列，聊天内容不应挤动它。
void main() {
  testWidgets('本地规则回复出现时工具条三图标不位移，模型回复后也不位移', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ttsGateway = _ConfiguredTtsSettingsGateway();
    final gateway = FakeLocalChatGateway(
      replySources: const [ReplySource.local, ReplySource.llm],
    );
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      autoStart: false,
      ttsSettingsGateway: ttsGateway,
      requestIdFactory: () => 'strip-stability-request',
    );
    await viewModel.initialize();

    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        ttsSettingsGateway: ttsGateway,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await tester.pumpAndSettle();

    Future<double> leftOf(Key key) async {
      // 图标必须可见且唯一，量到的才是用户看到的位置。
      expect(find.byKey(key), findsOneWidget);
      return tester.getRect(find.byKey(key)).left;
    }

    // ── 第一轮：本地规则回复 ──────────────────────────────────────────
    await tester.enterText(find.byKey(const Key('chat-input')), '有点累');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(find.text('本地规则回复'), findsOneWidget);

    final localVoiceLeft = await leftOf(const Key('voice-output-toggle-on'));
    final localHistoryLeft = await leftOf(const Key('open-history'));
    final localSettingsLeft = await leftOf(const Key('open-provider-settings'));

    // ── 第二轮：模型（Provider 流式）回复 ─────────────────────────────
    await tester.enterText(find.byKey(const Key('chat-input')), '那继续说说');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(find.text('本地规则回复'), findsNothing);

    final modelVoiceLeft = await leftOf(const Key('voice-output-toggle-on'));
    final modelHistoryLeft = await leftOf(const Key('open-history'));
    final modelSettingsLeft = await leftOf(const Key('open-provider-settings'));

    // 不变量：三枚图标的水平位置在两种回复状态下完全一致。
    // 先全部量完再断言，红的时候能看到完整几何差。
    expect(
      modelVoiceLeft,
      moreOrLessEquals(localVoiceLeft, epsilon: 0.5),
      reason: '朗读开关图标在本地规则回复时 left=$localVoiceLeft，'
          '模型回复时 left=$modelVoiceLeft，位置不应随回复来源变化',
    );
    expect(
      modelHistoryLeft,
      moreOrLessEquals(localHistoryLeft, epsilon: 0.5),
      reason: '历史图标在本地规则回复时 left=$localHistoryLeft，'
          '模型回复时 left=$modelHistoryLeft，位置不应随回复来源变化',
    );
    expect(
      modelSettingsLeft,
      moreOrLessEquals(localSettingsLeft, epsilon: 0.5),
      reason: '模型连接图标在本地规则回复时 left=$localSettingsLeft，'
          '模型回复时 left=$modelSettingsLeft，位置不应随回复来源变化',
    );
  });

  testWidgets('对照组：侧边栏三项导航的位置不受回复来源影响', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final gateway = FakeLocalChatGateway(
      replySources: const [ReplySource.local, ReplySource.llm],
    );
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      autoStart: false,
      requestIdFactory: () => 'sidebar-stability-request',
    );
    await viewModel.initialize();

    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await tester.pumpAndSettle();

    double leftOfNav(String name) =>
        tester.getRect(find.byKey(Key('nav-$name'))).left;

    await tester.enterText(find.byKey(const Key('chat-input')), '有点累');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    final localPositions = [
      leftOfNav('history'),
      leftOfNav('memory'),
      leftOfNav('settings'),
    ];

    await tester.enterText(find.byKey(const Key('chat-input')), '那继续说说');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    final modelPositions = [
      leftOfNav('history'),
      leftOfNav('memory'),
      leftOfNav('settings'),
    ];

    for (var i = 0; i < localPositions.length; i += 1) {
      expect(
        modelPositions[i],
        moreOrLessEquals(localPositions[i], epsilon: 0.5),
        reason: '侧边栏导航项第 $i 项在本地规则回复时 left=${localPositions[i]}，'
            '模型回复时 left=${modelPositions[i]}，位置不应随回复来源变化',
      );
    }
  });
}

final class _ConfiguredTtsSettingsGateway implements TtsSettingsGateway {
  @override
  Future<TtsSettings> read() async =>
      const TtsSettings(configured: true, keySet: true, autoSpeak: true);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) => read();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) => read();

  @override
  Future<TtsSettings> forgetApiKey() => read();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      const TtsConnectionTest(succeeded: true, message: '连接成功。');
}

Future<OnboardingViewModel> _completedOnboardingViewModel() async {
  final viewModel = OnboardingViewModel(
    FakeOnboardingGateway(completed: true),
    FixedProviderSettingsGateway(),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}
