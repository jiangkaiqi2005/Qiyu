import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/proxy_settings_client.dart';
import 'package:qiyu_flutter/features/settings/proxy_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_collapse_platform.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_client.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_client.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_view_model.dart';
import 'package:qiyu_flutter/features/shell/qiyu_strings.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

import 'support/shared_fakes.dart';

void main() {
  testWidgets('English mode translates settings without leaving the page', (tester) async {
    final locale = LocaleController();
    await tester.pumpWidget(await _app(
      settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
      providerGateway: FixedProviderSettingsGateway(configured: false),
      localeController: locale,
    ));
    await _openSettings(tester);
    expect(find.text('设置'), findsWidgets);
    final apiKey = find.byKey(const Key('provider-api-key'));
    await _reveal(tester, apiKey);
    await tester.enterText(apiKey, 'unsaved-key-draft');
    await _expandSection(tester, 'tts');
    expect(find.byKey(const Key('settings-section-content-tts')), findsOneWidget);

    locale.setLocale('en');
    await tester.pumpAndSettle();
    expect(find.byType(ProviderSettingsView), findsOneWidget);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Model connection'), findsOneWidget);
    expect(find.text('Provider'), findsOneWidget);
    expect(find.text('Official API · OpenAI compatible'), findsOneWidget);
    expect(find.text('设置'), findsNothing);
    expect(tester.widget<TextField>(apiKey).controller!.text, 'unsaved-key-draft');
    await _reveal(tester, find.byKey(const Key('settings-section-header-tts')));
    expect(find.text('Read aloud'), findsOneWidget);
    expect(find.byKey(const Key('settings-section-content-tts')), findsOneWidget);
  });

  testWidgets('English settings fit a 420px window', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(await _app(
      settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
      providerGateway: FixedProviderSettingsGateway(configured: false),
      localeController: LocaleController(initialLocale: 'en'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-go-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Model connection'), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final section in ['tts', 'stt', 'web_search']) {
      await _expandSection(tester, section);
      expect(tester.takeException(), isNull, reason: '$section overflowed');
    }
  });

  testWidgets('安卓后台中断挂起合成后按钮立即可重试，旧请求晚到不覆盖新试听', (tester) async {
    final oldRequest = Completer<TtsConnectionTest>();
    final gateway = _MutableTtsSettingsGateway(const TtsSettings(
      configured: true, keySet: true, baseUrl: 'https://tts.example.com', model: 'tts'))
      ..pendingTest = oldRequest;
    final player = _HoldingPreviewPlayer();
    await tester.pumpWidget(await _app(
      settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
      providerGateway: FixedProviderSettingsGateway(configured: false),
      ttsGateway: gateway, ttsPlayer: player,
    ));
    await _openSettings(tester);
    await _expandSection(tester, 'tts');
    final button = find.byKey(const Key('test-tts-connection'));
    await _reveal(tester, button);
    await tester.tap(button);
    await tester.pump();
    expect(gateway.testCalls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    gateway.pendingTest = null;
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(oldRequest.isCompleted, false);
    expect(gateway.testCalls, 2);
    expect(player.active, true);
    oldRequest.complete(const TtsConnectionTest(succeeded: false, message: '旧请求失败'));
    await tester.pumpAndSettle();
    expect(player.active, true);
    expect(find.text('旧请求失败'), findsNothing);
    expect(find.byKey(const Key('tts-replay-preview')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  for (final interruption in ['后台', '离页']) {
    testWidgets('安卓设置试听$interruption立即停止，恢复后安静，主动试听可用', (tester) async {
      final player = _HoldingPreviewPlayer();
      await tester.pumpWidget(await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        ttsGateway: _MutableTtsSettingsGateway(const TtsSettings(
          configured: true, keySet: true, baseUrl: 'https://tts.example.com', model: 'tts')),
        ttsPlayer: player,
      ));
      await _openSettings(tester);
      await _expandSection(tester, 'tts');
      final button = find.byKey(const Key('test-tts-connection'));
      await _reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(player.active, true);
      if (interruption == '后台') {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        expect(player.active, false);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      } else {
        GoRouter.of(tester.element(find.byType(ProviderSettingsView))).push('/history');
        await tester.pumpAndSettle();
        expect(player.active, false);
        GoRouter.of(tester.element(find.byType(Scaffold).first)).pop();
      }
      await tester.pumpAndSettle();
      expect(player.active, false);
      await _reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(player.active, true);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(player.active, false);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
  testWidgets(
    'developer diagnostics entry only appears after developer mode is on',
    (tester) async {
      final settingsGateway = _FakeSettingsGateway();
      await tester.pumpWidget(
        await _app(
          settingsViewModel: SettingsViewModel(settingsGateway),
          providerGateway: FixedProviderSettingsGateway(configured: false),
        ),
      );
      await _openSettings(tester);

      // 「体验与开发者选项」按 §8 默认收起，先点标题展开才有开关。
      await _expandSection(tester, 'developer');

      // 默认不打扰普通用户：诊断入口不存在。
      expect(find.byKey(const Key('settings-diagnostics')), findsNothing);
      expect(settingsGateway.developerMode, isFalse);

      // 打开开发者模式后入口出现。
      await _reveal(tester, find.byKey(const Key('developer-mode-switch')));
      await tester.tap(find.byKey(const Key('developer-mode-switch')));
      await tester.pumpAndSettle();

      expect(settingsGateway.developerMode, isTrue);
      expect(find.byKey(const Key('settings-diagnostics')), findsOneWidget);

      // 进入诊断页：最近请求、后台整理、Dream 资格与文件健康逐区呈现。
      await tester.ensureVisible(find.byKey(const Key('settings-diagnostics')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-diagnostics')));
      await tester.pumpAndSettle();
      expect(find.text('开发者诊断'), findsOneWidget);
      expect(find.textContaining('聊天'), findsWidgets);
      expect(find.textContaining('model_timeout'), findsOneWidget);
      expect(find.textContaining('已回退本地'), findsOneWidget);
      expect(find.textContaining('待补归档 2 天'), findsOneWidget);
      expect(find.textContaining('当前具备资格'), findsOneWidget);
      // 数据位置在页面底部：滚到可见再断言。
      await tester.scrollUntilVisible(
        find.textContaining('C:/qiyu/memories'),
        200,
        scrollable: _verticalScrollable(),
        maxScrolls: 20,
      );
      expect(find.textContaining('C:/qiyu/memories'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets('诊断页只把真故障标暗红，设计内回退走中性底', (tester) async {
    // 五枚按顺序铺开的最近请求：危险色的分档依据是**原因**，不是 result 本身。
    _useFullPageViewport(tester);
    final settingsGateway = _FakeSettingsGateway(
      recentRequests: [
        RecentRequest(
          at: DateTime.parse('2026-08-19T13:55:00.000Z'),
          source: 'chat',
          result: 'failed',
        ),
        RecentRequest(
          at: DateTime.parse('2026-08-19T13:56:00.000Z'),
          source: 'chat',
          result: 'fallback',
          replySource: 'local',
          fallbackReason: 'model_timeout',
        ),
        RecentRequest(
          at: DateTime.parse('2026-08-19T13:57:00.000Z'),
          source: 'chat',
          result: 'fallback',
          replySource: 'local',
          fallbackReason: 'safety',
        ),
        RecentRequest(
          at: DateTime.parse('2026-08-19T13:58:00.000Z'),
          source: 'chat',
          result: 'fallback',
          replySource: 'local',
          fallbackReason: 'no_llm_config',
        ),
        RecentRequest(
          at: DateTime.parse('2026-08-19T13:59:00.000Z'),
          source: 'chat',
          result: 'ok',
          replySource: 'local',
        ),
      ],
    )..developerMode = true;
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(settingsGateway),
        providerGateway: FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'developer');
    await tester.ensureVisible(find.byKey(const Key('settings-diagnostics')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-diagnostics')));
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.text('开发者诊断'))).colorScheme;
    // 读芯片实际拿到的底色：取带定位键那枚 Container 的 `decoration.color`，
    // 也就是 `_chip` 内部按 `emphasized` 选出的那一档，而不是调用方传进去的布尔
    // ——分档判据与配色两处任一漂移，这里都当场判红。
    Color fill(int index) {
      final container = tester.widget<Container>(
        find.byKey(Key('diagnostics-result-$index')),
      );
      return ((container.decoration!) as BoxDecoration).color!;
    }

    expect(fill(0), scheme.errorContainer, reason: '失败态必须看着就是没成（§1）');
    expect(fill(1), scheme.errorContainer, reason: '模型超时是模型侧没交付合格结果，属故障');
    // 这两类是**设计内**降级：危机输入的模型没回应时由本地热线话术兜底，
    // 未配模型时本机规则引擎就是产品形态。给它们暗红等于用危险色宣布
    // 「一切正常」为异常。
    expect(fill(2), scheme.surfaceContainerHighest, reason: 'safety 回退被误标故障');
    expect(
      fill(3),
      scheme.surfaceContainerHighest,
      reason: 'no_llm_config 回退被误标故障',
    );
    expect(fill(4), scheme.surfaceContainerHighest);
    // 防这条用例退化成一枚颜色自证：两档必须真是两个颜色。
    expect(scheme.errorContainer, isNot(scheme.surfaceContainerHighest));
  });

  testWidgets('memory controls overview lists frozen and banned entries', (
    tester,
  ) async {
    final settingsGateway = _FakeSettingsGateway();
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(settingsGateway),
        providerGateway: FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);

    await _reveal(tester, find.byKey(const Key('settings-memory-controls')));
    await tester.tap(find.byKey(const Key('settings-memory-controls')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('memory-controls-dialog')), findsOneWidget);
    expect(find.textContaining('已冻结（1）'), findsOneWidget);
    expect(find.textContaining('一段冻结的记忆'), findsOneWidget);
    expect(find.textContaining('已禁提（1）'), findsOneWidget);
    expect(find.textContaining('一段禁提的往事'), findsOneWidget);
    expect(find.textContaining('已删除范围：3 条'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-controls-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-controls-dialog')), findsNothing);
  });

  testWidgets('clearing product data previews impact and needs confirmation', (
    tester,
  ) async {
    final onboardingGateway = FakeOnboardingGateway(completed: true);
    // 清除落地的同时初见记录也被清除：重读状态后当次会话重走初见引导。
    final settingsGateway = _FakeSettingsGateway(
      onCleared: () => onboardingGateway.completed = false,
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(settingsGateway),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        onboardingGateway: onboardingGateway,
      ),
    );
    await _openSettings(tester);

    await _reveal(tester, find.byKey(const Key('settings-clear-data')));
    await tester.tap(find.byKey(const Key('settings-clear-data')));
    await tester.pumpAndSettle();

    // 影响逐条列清。
    expect(find.byKey(const Key('clear-data-dialog')), findsOneWidget);
    expect(find.textContaining('AnySearch API Key 会一并删除'), findsOneWidget);
    expect(find.textContaining('4 段会话'), findsOneWidget);
    expect(find.textContaining('9 天的整理记录'), findsOneWidget);
    expect(find.textContaining('冻结 1、禁提 2'), findsOneWidget);
    expect(find.textContaining('备份快照'), findsWidgets);

    // 取消不执行。
    await tester.tap(find.byKey(const Key('clear-data-cancel')));
    await tester.pumpAndSettle();
    expect(settingsGateway.clearCalls, 0);

    // 再次进入并确认后才真正清除，随后重走初见引导。
    await tester.tap(find.byKey(const Key('settings-clear-data')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear-data-confirm')));
    await tester.pumpAndSettle();
    expect(settingsGateway.clearCalls, 1);
    expect(find.byKey(const Key('first-meeting-greeting')), findsOneWidget);
  });

  testWidgets('TTS 设置区块：读写、音色语速、测试试听与忘记 Key', (tester) async {
    final ttsGateway = _MutableTtsSettingsGateway(
      const TtsSettings(
        configured: true,
        keySet: true,
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
        voice: 'nova',
        speed: 1.25,
      ),
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        ttsGateway: ttsGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'tts');

    // 已保存配置回填（含音色），Key 只显示已保存状态、绝不回显明文。
    await tester.scrollUntilVisible(
      find.byKey(const Key('tts-base-url')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 30,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-base-url')))
          .controller!
          .text,
      'https://tts.example.com/v1',
    );
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const Key('tts-voice-preset')),
          )
          .value,
      'nova',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-api-key')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.textContaining('语速：1.25'), findsOneWidget);

    // 保存：Key、音色、语速随表单提交，保存后 Key 输入框清空。
    await tester.enterText(
      find.byKey(const Key('tts-api-key')),
      'tts-new-secret-value',
    );
    await _reveal(
      tester,
      find.byKey(const Key('save-tts-settings')),
      maxScrolls: 10,
    );
    await tester.tap(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();
    expect(ttsGateway.savedDrafts, hasLength(1));
    expect(ttsGateway.savedDrafts.single.apiKey, 'tts-new-secret-value');
    expect(ttsGateway.savedDrafts.single.voice, 'nova');
    expect(ttsGateway.savedDrafts.single.speed, 1.25);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-api-key')))
          .controller!
          .text,
      isEmpty,
    );

    // 连接测试：widget 环境不能播放时明确区分「连接已通、试听失败」，
    // 不能同时留下绿色成功状态；仍保留「再听一次试听」恢复入口。
    await tester.ensureVisible(find.byKey(const Key('test-tts-connection')));
    await tester.tap(find.byKey(const Key('test-tts-connection')));
    await tester.pumpAndSettle();
    expect(ttsGateway.testCalls, 1);
    expect(find.textContaining('没能播放试听'), findsOneWidget);
    expect(find.textContaining('连接成功'), findsNothing);
    expect(find.byKey(const Key('tts-replay-preview')), findsOneWidget);

    // 切到豆包：地址与模型换成订阅专属缺省（完整端点 + Resource-Id）。
    await _reveal(tester, find.byKey(const Key('tts-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('豆包语音合成').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-base-url')))
          .controller!
          .text,
      'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-model')))
          .controller!
          .text,
      'seed-tts-2.0',
    );
    await tester.ensureVisible(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();
    expect(ttsGateway.savedDrafts.last.provider, TtsServiceKind.volcTts);

    // 忘记 Key 需要确认；确认后 keySet 归零。
    // 方向取负：`forget-tts-key` 在列表里位于上一步 ensureVisible 到的
    // `save-tts-settings` **之上**，必须往上滚才回得去。设置页挂上导航壳后内容列
    // 变窄（默认 800px 视口减去 240px 侧栏）、列表随之变长，之前向下滚能蒙对是
    // 因为整页还装得下、目标始终在缓存区内。
    await _reveal(tester, find.byKey(const Key('forget-tts-key')), delta: -200);
    await tester.tap(find.byKey(const Key('forget-tts-key')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tts-forget-key-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tts-forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(ttsGateway.forgetCalls, 1);
    expect(find.textContaining('尚未保存语音合成的 API Key'), findsOneWidget);
  });

  testWidgets('TTS 设置：支持选择方言音色、自定义音色与高级参数 extraParams', (tester) async {
    final ttsGateway = _MutableTtsSettingsGateway(
      const TtsSettings(
        configured: true,
        keySet: true,
        provider: TtsServiceKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        voice: 'zh_female_sichuan_uranus_bigtts',
        extraParams: {
          'additions': {'explicit_dialect': 'sichuan'},
        },
      ),
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        ttsGateway: ttsGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'tts');

    await tester.scrollUntilVisible(
      find.byKey(const Key('tts-voice-preset')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 30,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const Key('tts-voice-preset')),
          )
          .value,
      'zh_female_sichuan_uranus_bigtts',
    );

    // 展开高级参数面板，校验已回填 extraParams JSON
    await _reveal(
      tester,
      find.byKey(const Key('tts-advanced-params-tile')),
      maxScrolls: 10,
    );
    await tester.tap(find.byKey(const Key('tts-advanced-params-tile')));
    await tester.pumpAndSettle();

    final helpTextFinder = find.textContaining('配置豆包语音合成的深合并参数');
    expect(helpTextFinder, findsOneWidget);
    final helpTextWidget = tester.widget<Text>(helpTextFinder);
    expect(helpTextWidget.style?.fontFamily, 'Noto Serif SC');

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-extra-params')))
          .controller!
          .text,
      contains('"explicit_dialect": "sichuan"'),
    );
    final ttsExtraField = tester.widget<TextField>(
      find.byKey(const Key('tts-extra-params')),
    );
    expect(
      (ttsExtraField.decoration?.border as OutlineInputBorder?)?.borderRadius,
      QiyuRadii.smallBorder,
    );

    // 修改 extraParams 并保存
    await tester.enterText(
      find.byKey(const Key('tts-extra-params')),
      '{"audio_params": {"sample_rate": 16000}}',
    );
    await _reveal(
      tester,
      find.byKey(const Key('save-tts-settings')),
      maxScrolls: 10,
    );
    await tester.tap(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();

    expect(ttsGateway.savedDrafts.last.extraParams, {
      'audio_params': {'sample_rate': 16000},
    });
  });

  testWidgets('TTS 设置区块：千问档下拉、缺省回填、音色 ID 输入框、无语速滑条', (tester) async {
    final ttsGateway = _MutableTtsSettingsGateway(
      const TtsSettings(configured: false, keySet: false),
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        ttsGateway: ttsGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'tts');

    // 下拉出现「千问语音合成」，选中后地址、模型、音色落缺省值。
    await _reveal(tester, find.byKey(const Key('tts-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    expect(find.text('千问语音合成'), findsOneWidget);
    await tester.tap(find.text('千问语音合成').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-base-url')))
          .controller!
          .text,
      qwenTtsDefaultEndpoint,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-model')))
          .controller!
          .text,
      qwenTtsDefaultModel,
    );

    // 音色直给「音色 ID」输入框（无预设目录）：千问档没有音色下拉。
    await _reveal(tester, find.byKey(const Key('tts-voice')), maxScrolls: 10);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-voice')))
          .controller!
          .text,
      qwenTtsDefaultVoice,
    );
    expect(find.byKey(const Key('tts-voice-preset')), findsNothing);

    // 千问档不显示语速滑条（请求字段没有对应参数）。
    expect(find.byKey(const Key('tts-speed-slider')), findsNothing);
    expect(find.textContaining('语速：'), findsNothing);

    // 区块文案按千问档一句话说明（下拉按钮自身也显示「千问语音合成」，
    // 这里用具象文案锁定区块说明那一句）。
    expect(find.textContaining('千问语音合成，走阿里云百炼'), findsOneWidget);

    // 高级参数面板对千问档照常显示并参与保存（换 instruct 模型时传
    // instructions 这类字段）。
    await _reveal(
      tester,
      find.byKey(const Key('tts-advanced-params-tile')),
      maxScrolls: 10,
    );
    expect(find.byKey(const Key('tts-advanced-params-tile')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tts-advanced-params-tile')));
    await tester.pumpAndSettle();
    await _reveal(
      tester,
      find.byKey(const Key('tts-extra-params')),
      maxScrolls: 10,
    );
    await tester.enterText(
      find.byKey(const Key('tts-extra-params')),
      '{"instructions": "用温柔的语气"}',
    );

    // 保存往返：provider 以 qwen_tts wire 名上送，音色与 extraParams 随行。
    await _reveal(tester, find.byKey(const Key('tts-api-key')), maxScrolls: 10);
    await tester.enterText(find.byKey(const Key('tts-api-key')), 'sk-qwen');
    await _reveal(
      tester,
      find.byKey(const Key('save-tts-settings')),
      maxScrolls: 10,
    );
    await tester.tap(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();

    final draft = ttsGateway.savedDrafts.single;
    expect(draft.provider, TtsServiceKind.qwenTts);
    expect(draft.baseUrl, qwenTtsDefaultEndpoint);
    expect(draft.model, qwenTtsDefaultModel);
    expect(draft.voice, qwenTtsDefaultVoice);
    expect(draft.speed, isNull);
    expect(draft.extraParams, {'instructions': '用温柔的语气'});
    expect(draft.apiKey, 'sk-qwen');
  });

  testWidgets('TTS 设置区块：自定义档下拉、四件套露出、无语速滑条与音色框', (tester) async {
    final ttsGateway = _MutableTtsSettingsGateway(
      const TtsSettings(configured: false, keySet: false),
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        ttsGateway: ttsGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'tts');

    // 未选自定义档前，鉴权头/响应形态/字段名都不露出。
    expect(find.byKey(const Key('tts-auth-header')), findsNothing);
    expect(find.byKey(const Key('tts-response-shape')), findsNothing);
    expect(find.byKey(const Key('tts-response-field')), findsNothing);

    // 下拉出现「自定义合成服务」，选中后完整地址直填、旋钮露出。
    await _reveal(tester, find.byKey(const Key('tts-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    expect(find.text('自定义合成服务'), findsOneWidget);
    await tester.tap(find.text('自定义合成服务').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tts-auth-header')), findsOneWidget);
    expect(find.byKey(const Key('tts-response-shape')), findsOneWidget);
    expect(find.byKey(const Key('tts-response-field')), findsOneWidget);
    // 区块说明文案按自定义档一句话说明（下拉按钮自身也显示「自定义合成
    // 服务」，这里用具象文案锁定区块说明那一句）。
    expect(find.textContaining('POST 填写的完整地址'), findsOneWidget);
    // 自定义档地址与模型都等用户填：不做缺省回填。
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-base-url')))
          .controller!
          .text,
      isEmpty,
    );

    // 无语速滑条（请求字段没有对应参数），也没有音色位（Spec 只给四件套）。
    expect(find.byKey(const Key('tts-speed-slider')), findsNothing);
    expect(find.textContaining('语速：'), findsNothing);
    expect(find.byKey(const Key('tts-voice')), findsNothing);
    expect(find.byKey(const Key('tts-voice-preset')), findsNothing);

    // 响应形态下拉三种形态可切，字段名输入框与高级参数面板照常露出。
    await _reveal(tester, find.byKey(const Key('tts-response-shape')));
    await tester.tap(find.byKey(const Key('tts-response-shape')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JSON 字段').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tts-response-field')), findsOneWidget);
    await _reveal(tester, find.byKey(const Key('tts-advanced-params-tile')));
    expect(find.byKey(const Key('tts-advanced-params-tile')), findsOneWidget);

    // 切回千问档：自定义旋钮整体收回，语速滑条仍不显示，音色 ID 框回来。
    await _reveal(tester, find.byKey(const Key('tts-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('千问语音合成').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tts-auth-header')), findsNothing);
    expect(find.byKey(const Key('tts-response-shape')), findsNothing);
    expect(find.byKey(const Key('tts-response-field')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tts-base-url')))
          .controller!
          .text,
      qwenTtsDefaultEndpoint,
    );
    await _reveal(tester, find.byKey(const Key('tts-voice')), maxScrolls: 10);
    expect(find.byKey(const Key('tts-voice')), findsOneWidget);
    expect(find.byKey(const Key('tts-speed-slider')), findsNothing);

    // 再切回自定义档并保存：草稿带 custom wire 名与旋钮上送。
    await _reveal(tester, find.byKey(const Key('tts-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义合成服务').last);
    await tester.pumpAndSettle();
    await _reveal(tester, find.byKey(const Key('tts-base-url')));
    await tester.enterText(
      find.byKey(const Key('tts-base-url')),
      'https://tts.example.com/v1/audio/speech',
    );
    await tester.enterText(find.byKey(const Key('tts-model')), 'tts-test');
    await _reveal(tester, find.byKey(const Key('tts-auth-header')));
    await tester.enterText(find.byKey(const Key('tts-auth-header')), 'X-Api-Key');
    await _reveal(
      tester,
      find.byKey(const Key('save-tts-settings')),
      maxScrolls: 10,
    );
    await tester.enterText(find.byKey(const Key('tts-api-key')), 'sk-custom');
    await tester.tap(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();

    final draft = ttsGateway.savedDrafts.single;
    expect(draft.provider, TtsServiceKind.custom);
    expect(draft.baseUrl, 'https://tts.example.com/v1/audio/speech');
    expect(draft.model, 'tts-test');
    expect(draft.authHeader, 'X-Api-Key');
    // 缺省形态：裸音频字节（选中自定义档未动过形态下拉）。
    expect(draft.responseShape, TtsResponseShape.rawBytes);
    expect(draft.apiKey, 'sk-custom');
  });

  testWidgets('TTS 设置区块：自定义档鉴权头脏字符被主机按人话驳回时如实呈现', (tester) async {
    final ttsGateway = _MutableTtsSettingsGateway(
      const TtsSettings(configured: false, keySet: false),
      saveFailure: '鉴权头里混入了中文或看不见的字符，请重新填写。',
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        ttsGateway: ttsGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'tts');

    await _reveal(tester, find.byKey(const Key('tts-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义合成服务').last);
    await tester.pumpAndSettle();
    await _reveal(tester, find.byKey(const Key('tts-base-url')));
    await tester.enterText(
      find.byKey(const Key('tts-base-url')),
      'https://tts.example.com/v1/audio/speech',
    );
    await tester.enterText(find.byKey(const Key('tts-model')), 'tts-test');
    await _reveal(tester, find.byKey(const Key('tts-auth-header')));
    await tester.enterText(
      find.byKey(const Key('tts-auth-header')),
      'X-Api-Key\u200B',
    );
    await _reveal(
      tester,
      find.byKey(const Key('save-tts-settings')),
      maxScrolls: 10,
    );
    await tester.tap(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();

    expect(ttsGateway.savedDrafts.single.authHeader, 'X-Api-Key\u200B');
    expect(
      find.textContaining('鉴权头里混入了中文或看不见的字符'),
      findsOneWidget,
    );
  });

  testWidgets('forgetting the saved API key needs confirmation', (
    tester,
  ) async {
    final providerGateway = _MutableProviderSettingsGateway();
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: providerGateway,
      ),
    );
    await _openSettings(tester);

    await _reveal(tester, find.byKey(const Key('forget-api-key')));
    await tester.tap(find.byKey(const Key('forget-api-key')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('forget-key-dialog')), findsOneWidget);
    expect(find.textContaining('无法调用模型服务'), findsOneWidget);

    await tester.tap(find.byKey(const Key('forget-key-cancel')));
    await tester.pumpAndSettle();
    expect(providerGateway.forgetCalls, 0);

    await tester.tap(find.byKey(const Key('forget-api-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(providerGateway.forgetCalls, 1);
  });

  testWidgets('STT 设置区块：读写、Key 不回显、测试与忘记 Key', (tester) async {
    final sttGateway = _MutableSttSettingsGateway(
      const SttSettings(
        configured: true,
        keySet: true,
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-test',
      ),
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        sttGateway: sttGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'stt');

    // 已保存配置回填，Key 只显示已保存状态、绝不回显明文。
    await tester.scrollUntilVisible(
      find.byKey(const Key('stt-base-url')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 30,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stt-base-url')))
          .controller!
          .text,
      'https://stt.example.com/v1',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stt-api-key')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.textContaining('API Key 已保存在本机'), findsOneWidget);

    // 保存：新 Key 随表单提交，保存后输入框清空。
    await tester.enterText(
      find.byKey(const Key('stt-api-key')),
      'stt-new-secret-value',
    );
    await _reveal(
      tester,
      find.byKey(const Key('save-stt-settings')),
      maxScrolls: 10,
    );
    await tester.tap(find.byKey(const Key('save-stt-settings')));
    await tester.pumpAndSettle();
    expect(sttGateway.savedDrafts, hasLength(1));
    expect(
      sttGateway.savedDrafts.single.provider,
      SttServiceKind.openaiCompatible,
    );
    expect(sttGateway.savedDrafts.single.apiKey, 'stt-new-secret-value');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stt-api-key')))
          .controller!
          .text,
      isEmpty,
    );

    // 连接测试：结果以人话呈现。
    await tester.ensureVisible(find.byKey(const Key('test-stt-connection')));
    await tester.tap(find.byKey(const Key('test-stt-connection')));
    await tester.pumpAndSettle();
    expect(sttGateway.testCalls, 1);
    expect(find.textContaining('连接成功，语音输入可以使用'), findsOneWidget);

    // 切到豆包：下拉在区块顶部，测试按钮之后可能已经滚下去，向上找回。
    await _reveal(tester, find.byKey(const Key('stt-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('豆包流式语音识别').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stt-base-url')))
          .controller!
          .text,
      'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stt-model')))
          .controller!
          .text,
      'volc.seedasr.sauc.duration',
    );
    await tester.ensureVisible(find.byKey(const Key('save-stt-settings')));
    await tester.tap(find.byKey(const Key('save-stt-settings')));
    await tester.pumpAndSettle();
    expect(sttGateway.savedDrafts.last.provider, SttServiceKind.volcSeedAsr);
    expect(
      sttGateway.savedDrafts.last.baseUrl,
      'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    );

    // 忘记 Key：需要确认，确认后 keySet 归零。
    await _reveal(
      tester,
      find.byKey(const Key('forget-stt-key')),
      maxScrolls: 10,
    );
    await tester.tap(find.byKey(const Key('forget-stt-key')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stt-forget-key-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('stt-forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(sttGateway.forgetCalls, 1);
    expect(find.textContaining('尚未保存语音服务的 API Key'), findsOneWidget);
  });

  testWidgets('STT 设置区块：千问档下拉、缺省回填、区块文案与无高级参数面板', (tester) async {
    final sttGateway = _MutableSttSettingsGateway(
      const SttSettings(configured: false, keySet: false),
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        sttGateway: sttGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'stt');

    // 下拉出现「千问语音识别」，选中后地址与模型落缺省值。
    await _reveal(tester, find.byKey(const Key('stt-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    expect(find.text('千问语音识别'), findsOneWidget);
    await tester.tap(find.text('千问语音识别').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stt-base-url')))
          .controller!
          .text,
      qwenAsrDefaultEndpoint,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stt-model')))
          .controller!
          .text,
      qwenAsrDefaultModel,
    );
    // 千问档固定按千问话术说明，且不露出高级参数面板（识别侧无 extraParams）。
    expect(find.textContaining('千问语音识别，走阿里云百炼'), findsOneWidget);
    expect(find.text('高级参数'), findsNothing);

    // 保存后 provider 以 qwen_asr wire 名上送。
    await _reveal(
      tester,
      find.byKey(const Key('save-stt-settings')),
      maxScrolls: 10,
    );
    await tester.enterText(find.byKey(const Key('stt-api-key')), 'sk-qwen');
    await tester.tap(find.byKey(const Key('save-stt-settings')));
    await tester.pumpAndSettle();
    expect(sttGateway.savedDrafts.single.provider, SttServiceKind.qwenAsr);
    expect(sttGateway.savedDrafts.single.baseUrl, qwenAsrDefaultEndpoint);
    expect(sttGateway.savedDrafts.single.apiKey, 'sk-qwen');
  });

  testWidgets('STT 设置区块：千问档保存被主机按人话驳回时如实呈现', (tester) async {
    final sttGateway = _MutableSttSettingsGateway(
      const SttSettings(configured: false, keySet: false),
      saveFailure:
          '语音服务地址里混入了中文或看不见的字符，请重新复制粘贴。',
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        sttGateway: sttGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'stt');

    await _reveal(tester, find.byKey(const Key('stt-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('千问语音识别').last);
    await tester.pumpAndSettle();
    await _reveal(
      tester,
      find.byKey(const Key('save-stt-settings')),
      maxScrolls: 10,
    );
    await tester.tap(find.byKey(const Key('save-stt-settings')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('语音服务地址里混入了中文或看不见的字符'),
      findsOneWidget,
    );
  });

  testWidgets('STT 设置区块：自定义档下拉、旋钮露出条件与保存上送', (tester) async {
    final sttGateway = _MutableSttSettingsGateway(
      const SttSettings(configured: false, keySet: false),
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        sttGateway: sttGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'stt');

    // 未选自定义档前，鉴权头/响应形态/字段路径/高级参数都不露出。
    expect(find.byKey(const Key('stt-auth-header')), findsNothing);
    expect(find.byKey(const Key('stt-response-shape')), findsNothing);
    expect(find.byKey(const Key('stt-response-field')), findsNothing);
    expect(find.byKey(const Key('stt-advanced-params-tile')), findsNothing);

    // 下拉出现「自定义转写服务」，选中后完整地址直填、旋钮露出。
    await _reveal(tester, find.byKey(const Key('stt-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    expect(find.text('自定义转写服务'), findsOneWidget);
    await tester.tap(find.text('自定义转写服务').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('stt-auth-header')), findsOneWidget);
    expect(find.byKey(const Key('stt-response-shape')), findsOneWidget);
    expect(find.byKey(const Key('stt-response-field')), findsOneWidget);
    expect(find.byKey(const Key('stt-advanced-params-tile')), findsOneWidget);
    expect(find.textContaining('自定义转写服务'), findsWidgets);
    // 自定义档地址与模型都等用户填：不做缺省回填。
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stt-base-url')))
          .controller!
          .text,
      isEmpty,
    );

    // 响应形态切到 SSE 后字段路径输入框仍在（两个形态共用同一面板）。
    await _reveal(tester, find.byKey(const Key('stt-response-shape')));
    await tester.tap(find.byKey(const Key('stt-response-shape')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SSE 流式').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stt-response-field')), findsOneWidget);

    // 高级参数面板展开后有 JSON 输入框。
    await _reveal(tester, find.byKey(const Key('stt-advanced-params-tile')));
    await tester.tap(find.byKey(const Key('stt-advanced-params-tile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stt-extra-params')), findsOneWidget);

    // 切回千问档：自定义旋钮整体收回。
    await _reveal(tester, find.byKey(const Key('stt-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('千问语音识别').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stt-auth-header')), findsNothing);
    expect(find.byKey(const Key('stt-response-shape')), findsNothing);
    expect(find.byKey(const Key('stt-response-field')), findsNothing);
    expect(find.byKey(const Key('stt-advanced-params-tile')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stt-base-url')))
          .controller!
          .text,
      qwenAsrDefaultEndpoint,
    );

    // 再切回自定义档并保存：草稿带 custom wire 名与旋钮上送。
    await _reveal(tester, find.byKey(const Key('stt-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义转写服务').last);
    await tester.pumpAndSettle();
    await _reveal(tester, find.byKey(const Key('stt-base-url')));
    await tester.enterText(
      find.byKey(const Key('stt-base-url')),
      'https://stt.example.com/v1/audio/transcriptions',
    );
    await tester.enterText(find.byKey(const Key('stt-model')), 'whisper-test');
    await _reveal(tester, find.byKey(const Key('stt-auth-header')));
    await tester.enterText(
      find.byKey(const Key('stt-auth-header')),
      'X-Api-Key',
    );
    await _reveal(
      tester,
      find.byKey(const Key('save-stt-settings')),
      maxScrolls: 10,
    );
    await tester.enterText(find.byKey(const Key('stt-api-key')), 'sk-custom');
    await tester.tap(find.byKey(const Key('save-stt-settings')));
    await tester.pumpAndSettle();
    final draft = sttGateway.savedDrafts.single;
    expect(draft.provider, SttServiceKind.custom);
    expect(draft.baseUrl, 'https://stt.example.com/v1/audio/transcriptions');
    expect(draft.authHeader, 'X-Api-Key');
    expect(draft.responseShape, SttResponseShape.jsonPath);
    expect(draft.apiKey, 'sk-custom');
  });

  testWidgets('STT 设置区块：自定义档鉴权头脏字符被主机按人话驳回时如实呈现', (tester) async {
    final sttGateway = _MutableSttSettingsGateway(
      const SttSettings(configured: false, keySet: false),
      saveFailure: '鉴权头里混入了中文或看不见的字符，请重新填写。',
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        sttGateway: sttGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'stt');

    await _reveal(tester, find.byKey(const Key('stt-provider')), delta: -300);
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义转写服务').last);
    await tester.pumpAndSettle();
    await _reveal(tester, find.byKey(const Key('stt-base-url')));
    await tester.enterText(
      find.byKey(const Key('stt-base-url')),
      'https://stt.example.com/v1/audio/transcriptions',
    );
    await tester.enterText(find.byKey(const Key('stt-model')), 'whisper-test');
    await _reveal(tester, find.byKey(const Key('stt-auth-header')));
    await tester.enterText(
      find.byKey(const Key('stt-auth-header')),
      'X-Api-Key\u200B',
    );
    await _reveal(
      tester,
      find.byKey(const Key('save-stt-settings')),
      maxScrolls: 10,
    );
    await tester.tap(find.byKey(const Key('save-stt-settings')));
    await tester.pumpAndSettle();

    expect(sttGateway.savedDrafts.single.authHeader, 'X-Api-Key\u200B');
    expect(
      find.textContaining('鉴权头里混入了中文或看不见的字符'),
      findsOneWidget,
    );
  });

  testWidgets('privacy page states the local-only boundaries', (tester) async {
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'privacy');

    await _reveal(tester, find.byKey(const Key('settings-privacy')));
    await tester.tap(find.byKey(const Key('settings-privacy')));
    await tester.pumpAndSettle();

    expect(find.text('隐私与边界'), findsWidgets);
    expect(find.textContaining('数据只保存在你自己的设备上'), findsOneWidget);

    // 页面较长逐段滚动断言；危机倾诉如何被接住、热线如何给出，是必须
    // 讲清的边界。
    await tester.scrollUntilVisible(
      find.textContaining('何时调用你选择的模型服务'),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    expect(find.textContaining('何时调用你选择的模型服务'), findsOneWidget);
    expect(find.textContaining('心理援助热线 12356'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('永远不会被提升为记忆'),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    expect(find.textContaining('永远不会被提升为记忆'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('日志与诊断统一脱敏'),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    expect(find.textContaining('日志与诊断统一脱敏'), findsOneWidget);
  });

  testWidgets('联网搜索 Key 可保存、空白保留，重新进入不回显', (tester) async {
    final webSearchGateway = _MutableWebSearchSettingsGateway();
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        webSearchGateway: webSearchGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'web_search');

    final field = find.byKey(const Key('web-search-api-key'));
    await tester.scrollUntilVisible(
      field,
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    expect(find.text('联网搜索'), findsOneWidget);
    expect(find.text('ANYSEARCH_API_KEY'), findsOneWidget);

    await tester.enterText(field, 'temporary-anysearch-key');
    await tester.ensureVisible(
      find.byKey(const Key('save-web-search-settings')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-web-search-settings')));
    await tester.pumpAndSettle();
    expect(webSearchGateway.savedApiKeys, ['temporary-anysearch-key']);
    expect(tester.widget<TextField>(field).controller?.text, isEmpty);
    expect(find.textContaining('已保存在本机'), findsWidgets);

    await tester.enterText(field, '   ');
    await tester.ensureVisible(
      find.byKey(const Key('save-web-search-settings')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-web-search-settings')));
    await tester.pumpAndSettle();
    expect(webSearchGateway.savedApiKeys, ['temporary-anysearch-key', null]);

    final context = tester.element(find.byType(Scaffold).first);
    GoRouter.of(context).go('/');
    await tester.pumpAndSettle();
    await _openSettings(tester);
    // 重新进来是一枚新的页面 State，折叠状态回到 §8 默认档（此节收起）。
    await _expandSection(tester, 'web_search');
    await tester.scrollUntilVisible(
      field,
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    expect(tester.widget<TextField>(field).controller?.text, isEmpty);
  });

  testWidgets('联网搜索 Key 可忘记，保存失败只显示人话错误', (tester) async {
    final webSearchGateway = _MutableWebSearchSettingsGateway(
      keySet: true,
      failSave: true,
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        webSearchGateway: webSearchGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'web_search');

    final field = find.byKey(const Key('web-search-api-key'));
    await tester.scrollUntilVisible(
      field,
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.enterText(field, 'temporary-anysearch-key');
    await tester.ensureVisible(
      find.byKey(const Key('save-web-search-settings')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-web-search-settings')));
    await tester.pumpAndSettle();
    expect(find.text('联网搜索设置暂时不可用，请稍后重试。'), findsOneWidget);
    // 失败路径行为不变：只留错误横幅，不给保存成功的轻提示。
    expect(find.text('已保存到本机。'), findsNothing);
    expect(tester.widget<TextField>(field).controller?.text, isEmpty);
    expect(webSearchGateway.keySet, isTrue);
    expect(find.byKey(const Key('forget-web-search-key')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('forget-web-search-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-web-search-key')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('web-search-forget-key-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('web-search-forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(webSearchGateway.forgetCalls, 1);
    expect(find.byKey(const Key('forget-web-search-key')), findsNothing);
  });

  testWidgets('四域保存成功统一轻提示：保存后出现「已保存到本机」，五秒渐隐', (
    tester,
  ) async {
    final webSearchGateway = _MutableWebSearchSettingsGateway();
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        webSearchGateway: webSearchGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'web_search');

    final field = find.byKey(const Key('web-search-api-key'));
    await tester.scrollUntilVisible(
      field,
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.enterText(field, 'temporary-anysearch-key');
    await tester.ensureVisible(
      find.byKey(const Key('save-web-search-settings')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-web-search-settings')));
    await tester.pumpAndSettle();

    // 保存成功：统一轻提示立刻出现，四域共用同一句。
    expect(find.text('已保存到本机。'), findsOneWidget);

    // 五秒渐隐通道：走完既定节奏整条退场，不留挂起的计时器。
    await tester.pump(const Duration(milliseconds: 5500));
    await tester.pumpAndSettle();
    expect(find.text('已保存到本机。'), findsNothing);
  });

  testWidgets('FocusNode 保护与编辑态草稿：获焦编辑中绝不被覆盖，且 tts-extra-params 为 multiline', (
    tester,
  ) async {
    final ttsGateway = _MutableTtsSettingsGateway(
      const TtsSettings(
        configured: true,
        keySet: true,
        provider: TtsServiceKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        voice: 'zh_female_vv_uranus_bigtts',
        extraParams: {'old': 'val'},
      ),
    );

    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
        ttsGateway: ttsGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'tts');

    // 展开高级参数
    await _reveal(
      tester,
      find.byKey(const Key('tts-advanced-params-tile')),
      maxScrolls: 30,
    );
    await tester.tap(find.byKey(const Key('tts-advanced-params-tile')));
    await tester.pumpAndSettle();

    final extraField = find.byKey(const Key('tts-extra-params'));
    final textFieldWidget = tester.widget<TextField>(extraField);
    expect(textFieldWidget.keyboardType, TextInputType.multiline);
    expect(textFieldWidget.focusNode, isNotNull);

    // 用户正在获焦输入未保存的草稿
    await tester.enterText(extraField, '{"user_draft": 123}');
    await tester.pump();
    expect(tester.widget<TextField>(extraField).focusNode?.hasFocus, isTrue);

    // 重新触发组件树更新/重绘，草稿绝不被冲掉
    await tester.pump();
    expect(
      tester.widget<TextField>(extraField).controller!.text,
      '{"user_draft": 123}',
    );
  });

  testWidgets('设置页是阅读式：分节不带卡片底，标题是可点的次要色小字距分节头', (tester) async {
    // 整页层面的断言要八节同时在场（设置页是懒建的 ListView）。
    _useFullPageViewport(tester);
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);
    // 默认档只展开两节，其余六节的正文根本不在树上；这里要看的是八节的形态，
    // 所以先全部展开（折叠态自身的断言在折叠那几条用例里）。
    await _expandAllSections(tester);

    final scheme = Theme.of(
      tester.element(find.byKey(const Key('settings-scroll'))),
    ).colorScheme;

    // 八节各自成节，且每节都有一个可点的分节头——§8「分节标题本身就是导航」，
    // 所以既不做吸顶子导航，也不给某节换成别的入口。
    for (final id in _sectionIds) {
      expect(
        find.byKey(Key('settings-section-$id')),
        findsOneWidget,
        reason: id,
      );
      expect(
        find.byKey(Key('settings-section-header-$id')),
        findsOneWidget,
        reason: id,
      );
    }

    // 分节头的形态＝原型变体 B `.settings-flat .set-section h3`：13px、w400、
    // 次要字色、3px 字距（`docs/product/prototype/index.html:229-230`）。
    // 读渲染出来的那一份：悬停过渡由一条 `TweenAnimationBuilder` 插值后落到
    // `Text.style` 上，页面上真落的样式在 RichText 的 span 上，不看 widget 上写了什么。
    final headerStyle =
        (tester
                    .widget<RichText>(
                      find.descendant(
                        of: find.byKey(
                          const Key('settings-section-title-provider'),
                        ),
                        matching: find.byType(RichText),
                      ),
                    )
                    .text
                as TextSpan)
            .style!;
    expect(headerStyle.fontSize, QiyuType.secondarySize);
    expect(headerStyle.fontWeight, FontWeight.w400);
    expect(
      headerStyle.letterSpacing,
      QiyuType.sectionHeaderLetterSpacing,
      reason: '阅读式的「小字距」是这一处唯一的表意，丢了就退回普通小标题',
    );
    expect(headerStyle.color, QiyuColors.sectionHeader);
    // §1 三色纪律：分节标题不是强调位，不着紫也不着危险红。
    expect(headerStyle.color, isNot(QiyuColors.accentBright));
    expect(headerStyle.color, isNot(QiyuColors.danger));

    // 卡片形态要拆掉的那三样之一：分节之内不再有 surfaceContainer 底的 Material。
    expect(
      find.descendant(
        of: find.byKey(const Key('settings-scroll')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Material && widget.color == scheme.surfaceContainer,
        ),
      ),
      findsNothing,
      reason: '分节又变回带底色的卡片了（§8「分节不用卡片」）',
    );

    // 发丝分隔线：展开的非末节各画一条 1px `line` 底线，末节不画
    // （原型 `:227` 画线、`:228` `last-of-type` 不画）。
    for (final id in _sectionIds) {
      expect(
        find.descendant(
          of: find.byKey(Key('settings-section-$id')),
          matching: _bottomHairline,
        ),
        id == _sectionIds.last ? findsNothing : findsOneWidget,
        reason: '$id 的分隔线档位不对：只有末节不画，且不得画成一圈描边',
      );
    }
  });

  testWidgets('分节头悬停：标题与指示符在同一条过渡里，指示符不瞬变', (tester) async {
    await _pumpSettingsPage(tester, InMemorySettingsCollapseStore());

    final header = find.byKey(const Key('settings-section-header-provider'));
    // 读页面上真落的那两份颜色：标题取 span 前景，指示符取本节头里唯一那颗
    // Icon 的 color。
    Color titleColor() =>
        (tester
                    .widget<RichText>(
                      find.descendant(
                        of: find.byKey(
                          const Key('settings-section-title-provider'),
                        ),
                        matching: find.byType(RichText),
                      ),
                    )
                    .text
                as TextSpan)
            .style!
            .color!;
    Color caretColor() => tester
        .widget<Icon>(find.descendant(of: header, matching: find.byType(Icon)))
        .color!;

    expect(titleColor(), QiyuColors.sectionHeader);
    expect(caretColor(), QiyuColors.sectionHeaderCaret);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(header));
    // moveTo 只投递 hover 事件；onHover 的 setState 与过渡起程发生在这一帧，
    // 40ms 必须从起程之后开始算，否则读到的还是 t=0 的静置色。
    await tester.pump();
    // 160ms 档（`QiyuMotion.fast`）只推进 40ms：两档前景都该还在路上。
    await tester.pump(const Duration(milliseconds: 40));

    expect(titleColor(), isNot(QiyuColors.sectionHeader), reason: '标题没随悬停起程');
    expect(titleColor(), isNot(QiyuColors.sectionHeaderHover));
    expect(
      caretColor(),
      isNot(QiyuColors.sectionHeaderCaret),
      reason: '指示符没跟着走，还停在静置档',
    );
    expect(
      caretColor(),
      isNot(QiyuColors.sectionHeaderCaretHover),
      reason:
          '指示符一步跳到终值＝瞬变：原型的 transition 挂在 h3 上，'
          '指示符是它的 ::after 生成内容，本应与标题一起渐变',
    );

    await tester.pumpAndSettle();
    expect(titleColor(), QiyuColors.sectionHeaderHover);
    expect(caretColor(), QiyuColors.sectionHeaderCaretHover);
  });

  testWidgets('reduced-motion 档下分节头的悬停过渡压成零：一帧到位', (tester) async {
    await _pumpSettingsPage(
      tester,
      InMemorySettingsCollapseStore(),
      reduceMotion: true,
    );

    final header = find.byKey(const Key('settings-section-header-provider'));
    Color titleColor() =>
        (tester
                    .widget<RichText>(
                      find.descendant(
                        of: find.byKey(
                          const Key('settings-section-title-provider'),
                        ),
                        matching: find.byType(RichText),
                      ),
                    )
                    .text
                as TextSpan)
            .style!
            .color!;
    Color caretColor() => tester
        .widget<Icon>(find.descendant(of: header, matching: find.byType(Icon)))
        .color!;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(header));
    // 只走一帧、不 settle：时长没被压成零的话，两档前景会停在途中。
    await tester.pump();

    expect(
      titleColor(),
      QiyuColors.sectionHeaderHover,
      reason: '§9 要求 reduced-motion 下关闭全部过渡，这里还留着渐变',
    );
    expect(caretColor(), QiyuColors.sectionHeaderCaretHover);
  });

  testWidgets('分节顺序按 §8 定案序排列，且每一格排的确实是点名的那一节', (tester) async {
    // 整页层面的次序要八节同时在场。
    _useFullPageViewport(tester);
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);

    // 次序量的是**页面上的纵向位置**，不是「这一节的文本在场」：八节标题都在树
    // 上（§8 的默认档收起只藏正文，标题就是导航），比的是每一节的顶边一节比一节低。
    final headerTops = <String, double>{};
    for (final id in _sectionIds) {
      final header = find.byKey(Key('settings-section-header-$id'));
      expect(header, findsOneWidget, reason: id);
      // 排在这一格的必须是点名的那一节——id 与标题配错也要红。
      expect(
        find.descendant(
          of: header,
          matching: find.text(_sectionTitlesInOrder[id]!),
        ),
        findsOneWidget,
        reason: '$id 的标题不是 §8 序上这一格应有的那一节',
      );
      headerTops[id] = tester.getRect(header).top;
    }

    for (var i = 1; i < _sectionIds.length; i++) {
      final previous = _sectionIds[i - 1];
      final current = _sectionIds[i];
      expect(
        headerTops[current]!,
        greaterThan(headerTops[previous]!),
        reason: '§8 要 $previous 在 $current 之前，实测两节标题的先后不是这样',
      );
    }
  });

  testWidgets('折叠默认档：只展开模型连接与本地数据，收起的节里控件不在树上', (tester) async {
    // 整页层面的默认档要八节同时在场。
    _useFullPageViewport(tester);
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);

    // §8：默认展开「模型连接」「本地数据」，其余六节收起。
    for (final id in _sectionIds) {
      expect(
        _isSectionExpanded(tester, id),
        _defaultExpandedSectionIds.contains(id),
        reason: '$id 的默认档不对：design-system §8 只点名展开这两节',
      );
      // 标题永远在场——它就是那唯一的导航（§8 不做吸顶子导航）。
      expect(
        find.byKey(Key('settings-section-title-$id')),
        findsOneWidget,
        reason: id,
      );
    }

    // 收起不是「看不见」：节内控件整块不在树上（原型 `:235` `display: none`）。
    expect(find.byKey(const Key('web-search-api-key')), findsNothing);
    expect(find.byKey(const Key('stt-base-url')), findsNothing);
    expect(find.byKey(const Key('tts-base-url')), findsNothing);
    expect(find.byKey(const Key('settings-privacy')), findsNothing);
    expect(find.byKey(const Key('developer-mode-switch')), findsNothing);
    // 正向对照：默认展开的两节里，控件确实在。
    expect(find.byKey(const Key('provider-preset')), findsOneWidget);
    expect(find.byKey(const Key('settings-clear-data')), findsOneWidget);
  });

  testWidgets('折叠只写本地 UI 存储：点标题能收也能展，一次都不碰主持久化链路', (tester) async {
    final store = InMemorySettingsCollapseStore();
    final settingsGateway = await _pumpSettingsPage(
      tester,
      store,
      settingsGateway: _FakeSettingsGateway(),
    );

    // 收起的节能点开：正文与节内控件回到树上。
    await _expandSection(tester, 'web_search');
    expect(find.byKey(const Key('web-search-api-key')), findsOneWidget);
    expect(store.readCollapsed(), {
      'memory_recall',
      'tts',
      'stt',
      'privacy',
      'developer',
    }, reason: '展开没写进本地 UI 存储');

    // 默认展开的节能收回去，再点又能展开。
    expect(_isSectionExpanded(tester, 'local_data'), isTrue);
    await _tapSectionHeader(tester, 'local_data');
    expect(
      _isSectionExpanded(tester, 'local_data'),
      isFalse,
      reason: '点标题没把这一节收起来',
    );
    await _tapSectionHeader(tester, 'local_data');
    expect(
      _isSectionExpanded(tester, 'local_data'),
      isTrue,
      reason: '再点标题没能把这一节展开回来',
    );
    expect(store.readCollapsed(), {
      'memory_recall',
      'tts',
      'stt',
      'privacy',
      'developer',
    }, reason: '一收一展之后存储没跟着回到原样');

    // 折叠状态是 UI 状态：这一路点下来一次都没写 Host 那侧的偏好（§8）。
    expect(settingsGateway.prefWrites, 0, reason: '折叠状态漏进了主持久化链路');
  });

  testWidgets('同一份本地存储重建页面后，上次收起来的节还收着', (tester) async {
    final store = InMemorySettingsCollapseStore();
    await _pumpSettingsPage(tester, store);

    // 离开前把默认档反过来：收起「本地数据」、展开「联网搜索」。
    await _tapSectionHeader(tester, 'local_data');
    await _tapSectionHeader(tester, 'web_search');
    expect(_isSectionExpanded(tester, 'local_data'), isFalse);
    expect(_isSectionExpanded(tester, 'web_search'), isTrue);

    // 用同一份存储重建页面＝关掉设置页再进来（浏览器侧就是 localStorage）。
    // 这里靠的是 _pumpSettingsPage 每次都先卸再挂：不换成一枚新的页面 State，
    // 「还收着」就只是 State 原地留着，测不到存储那一路。
    await _pumpSettingsPage(tester, store);
    expect(
      _isSectionExpanded(tester, 'local_data'),
      isFalse,
      reason: '上次收起来的节下次进来又展开了（§8「上次收起来的下次进来还收着」）',
    );
    expect(
      _isSectionExpanded(tester, 'web_search'),
      isTrue,
      reason: '上次展开的节下次进来还开着',
    );
    // 存的就是「收起的节 id 集合」：默认收起的六节里去掉联网搜索（展开了）、
    // 再加上本地数据（收起了）；模型连接这一路没碰过。
    expect(store.readCollapsed(), {
      'memory_recall',
      'tts',
      'stt',
      'privacy',
      'developer',
      'local_data',
    });

    // 防白测：上一枚 State 与存储此刻内容相同，光看上面两组断言分不出
    // 「读了存储」还是「State 原地留着」。这里把存储改成与上一枚 State 明显
    // 分歧的一副样子，再重建一次——页面必须跟着存储走。
    store.writeCollapsed({'provider', 'developer'});
    await _pumpSettingsPage(tester, store);
    expect(
      _isSectionExpanded(tester, 'provider'),
      isFalse,
      reason: '新页面没重读存储，沿用了上一枚 State 的折叠集合',
    );
    expect(
      _isSectionExpanded(tester, 'local_data'),
      isTrue,
      reason: '存储里这一节没收起，重建后却还收着——沿用的是上一枚 State',
    );
  });

  testWidgets('存储里的陌生节 id 不采纳，回写时抹掉', (tester) async {
    final store = InMemorySettingsCollapseStore()
      ..writeCollapsed({'tts', 'renamed_section'});
    await _pumpSettingsPage(tester, store);

    // 认生的 id 不得把任何一节收起来：一节平白收起而用户找不回出口，
    // 比退回默认档更糟。
    expect(_isSectionExpanded(tester, 'tts'), isFalse);
    for (final id in _sectionIds.where((id) => id != 'tts')) {
      expect(_isSectionExpanded(tester, id), isTrue, reason: id);
    }

    // 任何一次折叠的回写都把陌生 id 洗掉，存储里只留名单内的节。
    await _tapSectionHeader(tester, 'privacy');
    expect(store.readCollapsed(), {'tts', 'privacy'});
  });

  testWidgets('收起只藏正文，不卸载分节：填了一半的输入框展开回来还在', (tester) async {
    await _pumpSettingsPage(tester, InMemorySettingsCollapseStore());
    await _expandSection(tester, 'web_search');

    // 一串从没保存过的草稿。
    final field = find.byKey(const Key('web-search-api-key'));
    await tester.enterText(field, 'sk-填到一半');
    await tester.pumpAndSettle();

    // 收起：正文整块不在树上（§8 的呈现），但分节自身与它的标题必须在——
    // 各节是持有 TextEditingController / FocusNode 的 StatefulWidget，把整节
    // 换成占位件就等于把用户填了一半的东西丢掉。
    await _tapSectionHeader(tester, 'web_search');
    expect(_isSectionExpanded(tester, 'web_search'), isFalse);
    expect(field, findsNothing);
    expect(
      find.byKey(const Key('settings-section-web_search')),
      findsOneWidget,
      reason: '折叠把分节自身也卸了：节内的输入态随 State 一起没了',
    );
    expect(
      find.byKey(const Key('settings-section-title-web_search')),
      findsOneWidget,
      reason: '收起后标题就是唯一的出口，它不在用户就再也打不开这一节了',
    );

    // 再展开：草稿还在那一格里。
    await _tapSectionHeader(tester, 'web_search');
    expect(
      tester.widget<TextField>(field).controller?.text,
      'sk-填到一半',
      reason: '折叠把用户填了一半的输入框状态弄丢了',
    );
  });

  testWidgets('状态文案不给成功着色：失败才是 danger，成功退回主题默认字色', (tester) async {
    final gateway = _MutableProviderSettingsGateway();
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: gateway,
      ),
    );
    await _openSettings(tester);

    // 结果行的作用域：整页只挂这一条被点名，行内恰好一颗图标 + 一段文字。
    // 不按「文字的祖先 Row」找——一段文字会被多层 Row 同时命中，图标就成了
    // 一组，测不出这一行自己的着色。
    final statusRow = find.byKey(const Key('settings-status-connection'));

    // 读页面上真正渲染的那一份：span 上的前景色，不看 widget 上写了什么。
    // 这一行里有两颗 RichText——Icon 也是按字形渲染的，所以得按文案挑出正文那颗。
    Color? foregroundOf(String message) {
      final spans = tester
          .widgetList<RichText>(
            find.descendant(of: statusRow, matching: find.byType(RichText)),
          )
          .where((w) => w.text.toPlainText() == message)
          .toList();
      expect(spans, hasLength(1), reason: '结果行里这段文字没能唯一定位');
      return spans.single.text.style?.color;
    }

    Icon statusIconOf() => tester.widget<Icon>(
      find.descendant(of: statusRow, matching: find.byType(Icon)),
    );

    // 「测试连接」在展开后的长节里落在视口之外：不先滚进可见区，tap 的坐标会打到
    // 别的东西上，结果文案根本不会出现。
    Future<void> runConnectionTest() async {
      final button = find.byKey(const Key('test-provider-connection'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    // 成功：§2 色板里没有绿色档，§1 的暗红又只住「破坏性操作」与「故障/失败态」
    // 两类，成功两样都不是——所以它不着色，前景完全交给页面默认字色。
    await runConnectionTest();
    const successMessage = '连接成功，栖语可以使用这个模型。';
    expect(
      foregroundOf(successMessage),
      isNot(const Color(0xFF91C7A7)),
      reason: '成功文案又穿回那枚色板外的绿了',
    );
    expect(
      foregroundOf(successMessage),
      DefaultTextStyle.of(
        tester.element(find.text(successMessage)),
      ).style.color,
      reason: '成功文案没走主题默认字色：它自带了前景色',
    );
    expect(statusIconOf().color, isNull);

    // 失败：故障/失败态是 §1 认可的两类危险之一，前景换成 danger
    // （本主题的 colorScheme.error 即 §2 的 danger）。
    gateway.testResult = const ProviderTestResult(
      succeeded: false,
      status: ProviderTestStatus.network,
      message: '连不上这个模型。',
    );
    await runConnectionTest();
    expect(foregroundOf('连不上这个模型。'), QiyuColors.danger);
    expect(statusIconOf().color, QiyuColors.danger);
  });

  testWidgets('窄屏页头让开三条杠：「设置」标题不被浮层压住', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: FixedProviderSettingsGateway(configured: false),
      ),
    );
    await tester.pumpAndSettle();

    // 窄屏没有常驻侧边栏：三条杠开抽屉，再由抽屉进设置。
    await tester.tap(find.byKey(const Key('nav-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-go-settings')));
    await tester.pumpAndSettle();

    final menu = tester.getRect(find.byKey(const Key('nav-menu-button')));
    expect(
      tester
          .getTopLeft(
            find.descendant(
              of: find.byType(ProviderSettingsView),
              matching: find.text('设置'),
            ),
          )
          .dx,
      greaterThanOrEqualTo(menu.right),
      reason: '「设置」标题的左边界不得落在三条杠的命中区里',
    );
  });
}

/// 页面上七个分节的 id，**按 design-system §8 固定的分节顺序**排列：末位
/// （体验与开发者选项）不画分隔线。字符串与 `provider_settings_view.dart` 的
/// `_SettingsSectionId` 一致——折叠状态在本地存储里存的就是这些 id。
const _sectionIds = <String>[
  'provider',
  'memory_recall',
  'tts',
  'stt',
  'web_search',
  'local_data',
  'privacy',
  'developer',
];

/// 定案序上每一格**应有的分节标题**：次序用例除了比纵向位置，还要核排在这个
/// 位置上的到底是哪一节——只挪顺序不改文案的漂移、以及 id 与标题配错，都挡得住。
///
/// 取值按页面现状。命名差一处已由 §8 登记：§8／决策日志第二轮 #8／Spec Decision
/// 15 按**机制**把第三节写作「语音转写」，页面渲染的是「语音输入」
/// （`provider_settings_view.dart` 的 `_SttSection`），§8 明写不声称页面上有
/// 「语音转写」四个字。本用例按页面文案取值，不替规范另立一种叫法。
const _sectionTitlesInOrder = <String, String>{
  'provider': '模型连接',
  'memory_recall': '记忆召回',
  'tts': '语音朗读',
  'stt': '语音输入',
  'web_search': '联网搜索',
  'local_data': '本地数据',
  'privacy': '隐私与边界',
  'developer': '体验与开发者选项',
};

/// 分节之间那条**只画底边**的 1px `line` 发丝线（原型 `:227`）。
///
/// 只认底边而不认「有任何描边」，是为了把重新长成卡片的可能挡回来：§8 要的是
/// 分隔线，不是盒子。
final _bottomHairline = find.byWidgetPredicate((widget) {
  if (widget is! DecoratedBox) {
    return false;
  }
  final decoration = widget.decoration;
  final border = decoration is BoxDecoration ? decoration.border : null;
  return border != null &&
      border.bottom.color == QiyuColors.line &&
      border.bottom.width == QiyuLine.hairline &&
      border.top == BorderSide.none;
});

Future<Widget> _app({
  required SettingsViewModel settingsViewModel,
  required ProviderSettingsGateway providerGateway,
  OnboardingGateway? onboardingGateway,
  SttSettingsGateway? sttGateway,
  TtsSettingsGateway? ttsGateway,
  VoicePlayerPlatform? ttsPlayer,
  WebSearchSettingsGateway? webSearchGateway,
  LocaleController? localeController,
}) async {
  final providerViewModel = ProviderSettingsViewModel(
    providerGateway,
    autoStart: false,
  );
  await providerViewModel.initialize();
  final onboardingViewModel = OnboardingViewModel(
    onboardingGateway ?? FakeOnboardingGateway(completed: true),
    FixedProviderSettingsGateway(configured: true),
    autoStart: false,
  );
  await onboardingViewModel.initialize();
  return QiyuApp(
    localeController: localeController,
    viewModel: LocalChatViewModel(
      FakeLocalChatGateway.silent(),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      autoStart: false,
    ),
    providerSettingsViewModel: providerViewModel,
    sttSettingsViewModel: SttSettingsViewModel(
      sttGateway ?? const _FixedSttSettingsGateway(),
      autoStart: false,
    ),
    ttsSettingsViewModel: TtsSettingsViewModel(
      ttsGateway ?? const _FixedTtsSettingsGateway(),
      playerPlatform: ttsPlayer,
      autoStart: false,
    ),
    webSearchSettingsViewModel: WebSearchSettingsViewModel(
      webSearchGateway ?? const _FixedWebSearchSettingsGateway(),
      autoStart: false,
    ),
    embeddingSettingsViewModel: EmbeddingSettingsViewModel(
      const _FixedEmbeddingSettingsGateway(),
      autoStart: false,
    ),
    proxySettingsViewModel: ProxySettingsViewModel(
      const _FixedProxySettingsGateway(),
      autoStart: false,
    ),
    onboardingViewModel: onboardingViewModel,
    settingsViewModel: settingsViewModel,
  );
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.pumpAndSettle();
  // 全局 GoRouter 跨用例保留栈：先强制回到首页再进入设置。
  final context = tester.element(find.byType(Scaffold).first);
  GoRouter.of(context).go('/');
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('home-go-settings')));
  await tester.pumpAndSettle();
}

/// 滚动到 [finder] 可见并定格：scrollUntilVisible → ensureVisible → pumpAndSettle
/// 三连。滚动参数逐字透传：[delta] 是每次滚动的距离（默认 200，个别用例
/// -300/-200），[maxScrolls] 是最多滚动次数（默认 20，个别用例 30/10）。
Future<void> _reveal(
  WidgetTester tester,
  Finder finder, {
  double delta = 200,
  int maxScrolls = 20,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: _verticalScrollable(),
    maxScrolls: maxScrolls,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// 这一节当前是否展开。
///
/// 判据是「正文那块在不在树上」——收起时 [_SettingsPanel] 只不画正文，分节自身
/// 与它的标题都还在（标题就是唯一的导航入口）。不去看标题文本、也不去看指示符
/// 朝向，两者在两种状态下都没差别或不足以定位。
bool _isSectionExpanded(WidgetTester tester, String sectionId) => find
    .byKey(Key('settings-section-content-$sectionId'))
    .evaluate()
    .isNotEmpty;

/// 整页层面的断言要八节同时在场，而设置页是**懒建的 ListView**：默认 600 高的
/// 视口只建得出头两三节，「某一节的正文在不在树上」这类判据会因为它还没被建
/// 出来而误判成收起。宽度仍取 1200（内容列由 `pageReadingMaxWidth` 限宽），
/// 只是把视口拉高，不改变任何布局档位。
void _useFullPageViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// §8 默认档里点名展开的两节；其余六节默认收起。
const _defaultExpandedSectionIds = <String>['provider', 'local_data'];

/// 点一次某一节的标题（不判当前状态，也不幂等）。
Future<void> _tapSectionHeader(WidgetTester tester, String sectionId) async {
  final header = find.byKey(Key('settings-section-header-$sectionId'));
  await _reveal(tester, header);
  await tester.tap(header);
  await tester.pumpAndSettle();
}

/// 直接 pump 设置页本体并注入折叠存储；返回本页用的设置网关，供用例核写入次数。
///
/// 为什么不走路由：`/settings` 那条 GoRoute 与它的 builder 签名是行为不变量
/// （Spec 实现决策 18），不能为了把 store 递进去而改路由表；这里按 widget 注入
/// 的既有路子（同 `ProviderSettingsView` 的 `backupPlatform`）直接挂页面本体。
///
/// 每次调用都**先把页面整棵摘下再挂**：`pumpWidget` 给的是同类型、同 key 的
/// widget 时会复用 Element，`initState` 不重跑，折叠集合就原地留在 State 里——
/// 那样第二次「重建页面」根本没读过存储，持久化的断言会白测。先挂一枚空树，
/// 才等价于浏览器里离开设置页再进来拿到一枚新的页面 State。
Future<_FakeSettingsGateway> _pumpSettingsPage(
  WidgetTester tester,
  SettingsCollapseStore store, {
  _FakeSettingsGateway? settingsGateway,
  bool reduceMotion = false,
}) async {
  _useFullPageViewport(tester);
  await tester.pumpWidget(Container(key: UniqueKey()));
  await tester.pumpAndSettle();
  final providerViewModel = ProviderSettingsViewModel(
    FixedProviderSettingsGateway(configured: false),
    autoStart: false,
  );
  await providerViewModel.initialize();
  final gateway = settingsGateway ?? _FakeSettingsGateway();
  final settingsViewModel = SettingsViewModel(gateway);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: providerViewModel),
        ChangeNotifierProvider.value(
          value: SttSettingsViewModel(
            const _FixedSttSettingsGateway(),
            autoStart: false,
          ),
        ),
        ChangeNotifierProvider.value(
          value: TtsSettingsViewModel(
            const _FixedTtsSettingsGateway(),
            autoStart: false,
          ),
        ),
        ChangeNotifierProvider.value(
          value: WebSearchSettingsViewModel(
            const _FixedWebSearchSettingsGateway(),
            autoStart: false,
          ),
        ),
        ChangeNotifierProvider.value(
          value: EmbeddingSettingsViewModel(
            const _FixedEmbeddingSettingsGateway(),
            autoStart: false,
          ),
        ),
        ChangeNotifierProvider.value(
          value: ProxySettingsViewModel(
            const _FixedProxySettingsGateway(),
            autoStart: false,
          ),
        ),
        ChangeNotifierProvider.value(value: settingsViewModel),
      ],
      child: MaterialApp(
        home: ProviderSettingsView(collapseStore: store),
        // `qiyuReducedMotion()` 读的是 `MediaQuery.disableAnimationsOf`（Web
        // 引擎把 `prefers-reduced-motion` 映射到这个特性位），测试侧同从这一位
        // 进；画法与 `qiyu_shell_test.dart` 一致——套在 MaterialApp.builder 上，
        // 保住框架自己那份 MediaQuery 的尺寸信息。
        builder: reduceMotion
            ? (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child ?? const SizedBox.shrink(),
              )
            : null,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gateway;
}

/// 展开某一节（幂等）：§8 的默认档只展开「模型连接」「本地数据」，其余五节
/// 的节内控件根本不在树上，任何要动它们的用例都得先把那一节展开。
Future<void> _expandSection(WidgetTester tester, String sectionId) async {
  if (_isSectionExpanded(tester, sectionId)) {
    return;
  }
  await _tapSectionHeader(tester, sectionId);
  expect(_isSectionExpanded(tester, sectionId), isTrue, reason: sectionId);
}

/// 按 §8 顺序把八节全部展开，供整页层面的视觉断言使用。
Future<void> _expandAllSections(WidgetTester tester) async {
  for (final id in _sectionIds) {
    await _expandSection(tester, id);
  }
}

/// 当前页自己的纵向滚动容器。
///
/// 必须排除导航壳的侧边栏/抽屉：那块 [Scrollable] 同样是纵向，且在树里排在页面
/// 内容之前，取「第一个纵向 Scrollable」会误命中它（`/settings` 挂上壳之后才有的
/// 问题）。生产侧正是为此在 `_NavPanel` 上留了 `nav-scroll` 键，这里按它摘出去。
///
/// 不能反过来按页内键（如 `settings-scroll`）锁死：设置页里再点进的开发者诊断页
/// 与隐私页是各自独立的路由、不挂壳，也就没有那个键，锁死会让这些页上的滚动
/// 断言取不到容器。
Finder _verticalScrollable() => find.byElementPredicate((element) {
  final widget = element.widget;
  if (widget is! Scrollable || widget.axisDirection != AxisDirection.down) {
    return false;
  }
  var insideNavPanel = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget.key == const Key('nav-scroll')) {
      insideNavPanel = true;
    }
    return true;
  });
  return !insideNavPanel;
}).first;

/// 诊断页默认供的那一枚：模型超时（真故障），既有入口用例按它断文案。
List<RecentRequest> _defaultDiagnosticsRequests() => [
  RecentRequest(
    at: DateTime.parse('2026-08-19T13:59:00.000Z'),
    source: 'chat',
    result: 'fallback',
    replySource: 'local',
    fallbackReason: 'model_timeout',
  ),
];

/// 设置网关替身：在共享版之上换成本页的富档位——记忆控制/清数据预览
/// 带真实计数，诊断快照按分档用例的需要给「最近请求」（缺省一枚模型
/// 超时），时间戳与文件健康取本文件固化的那组。
class _FakeSettingsGateway extends FakeSettingsGateway {
  _FakeSettingsGateway({super.onCleared, List<RecentRequest>? recentRequests})
    : super(
        recentRequests: recentRequests ?? _defaultDiagnosticsRequests(),
        memoryControls: const MemoryControlsOverview(
          readable: true,
          frozen: [
            MemoryControlRecord(id: 1, origin: 'chat', summary: '一段冻结的记忆'),
          ],
          banned: [
            MemoryControlRecord(id: 2, origin: 'chat', summary: '一段禁提的往事'),
          ],
          deletedCount: 3,
        ),
        clearPreview: const ClearPreview(
          memoryDirectory: 'C:/qiyu/memories',
          sessionCount: 4,
          episodeDayCount: 9,
          frozenCount: 1,
          bannedCount: 2,
          deletedCount: 0,
          snapshotCount: 1,
          providerConfigured: false,
          keySet: false,
        ),
        generatedAt: DateTime.parse('2026-08-19T14:00:00.000Z'),
        memoryDirectory: 'C:/qiyu/memories',
        finalization: const FinalizationHealth(
          today: '2026-08-19',
          todayFinalized: false,
          pendingDays: 2,
          unreadableDays: 0,
        ),
        dream: DreamHealth(
          lastSuccessAt: DateTime.parse('2026-08-11T16:00:00.000Z'),
          daysSinceLastSuccess: 8,
          pending: false,
          minIntervalDays: 3,
          intervalSatisfied: true,
          providerConfigured: true,
          eligible: true,
        ),
        fileHealth: const {
          'sessionsReadable': 4,
          'sessionsUnavailable': 0,
          'episodeDays': 9,
          'episodeUnfinalized': 2,
          'episodeUnreadable': 0,
        },
      );
}

final class _MutableProviderSettingsGateway implements ProviderSettingsGateway {
  var keySet = true;
  int forgetCalls = 0;

  /// 连接测试的回执：默认成功（既有「忘记 Key」用例只走保存与忘记，不读它）；
  /// 要核成功/失败两态的着色纪律时用这一处切换。
  ProviderTestResult testResult = const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功，栖语可以使用这个模型。',
  );

  @override
  Future<ProviderSettings> read() async => ProviderSettings(
    configured: true,
    keySet: keySet,
    provider: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.example.com/v1',
    model: 'chat-model',
    temperature: 0.7,
    timeoutSeconds: 60,
  );

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async => read();

  @override
  Future<ProviderSettings> forgetApiKey() async {
    forgetCalls += 1;
    keySet = false;
    return read();
  }

  @override
  Future<ProviderTestResult> testConnection(
    ProviderSettingsDraft draft,
  ) async => testResult;
}

final class _FixedWebSearchSettingsGateway implements WebSearchSettingsGateway {
  const _FixedWebSearchSettingsGateway();

  @override
  Future<WebSearchSettings> read() async =>
      const WebSearchSettings(configured: false, keySet: false);

  @override
  Future<WebSearchSettings> save(WebSearchSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<WebSearchSettings> forgetApiKey() => throw UnimplementedError();
}

final class _FixedEmbeddingSettingsGateway implements EmbeddingSettingsGateway {
  const _FixedEmbeddingSettingsGateway();

  @override
  Future<EmbeddingSettings> read() async =>
      const EmbeddingSettings(configured: false, keySet: false, enabled: false);

  @override
  Future<EmbeddingSettings> save(EmbeddingSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<EmbeddingSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(EmbeddingSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<EmbeddingSettings> enable() => throw UnimplementedError();

  @override
  Future<EmbeddingSettings> disable() => throw UnimplementedError();

  @override
  Future<EmbeddingSettings> rebuild() => throw UnimplementedError();
}

final class _FixedProxySettingsGateway implements ProxySettingsGateway {
  const _FixedProxySettingsGateway();

  @override
  Future<ProxySettings> read() async => const ProxySettings(
    configured: false,
    enabled: false,
    host: '',
    port: 0,
  );

  @override
  Future<ProxySettings> save(ProxySettingsDraft draft) =>
      throw UnimplementedError();
}

final class _MutableWebSearchSettingsGateway
    implements WebSearchSettingsGateway {
  _MutableWebSearchSettingsGateway({
    this.keySet = false,
    this.failSave = false,
  });

  bool keySet;
  final bool failSave;
  final List<String?> savedApiKeys = [];
  int forgetCalls = 0;

  @override
  Future<WebSearchSettings> read() async =>
      WebSearchSettings(configured: keySet, keySet: keySet);

  @override
  Future<WebSearchSettings> save(WebSearchSettingsDraft draft) async {
    savedApiKeys.add(draft.apiKey);
    if (failSave) {
      throw StateError('raw backend details');
    }
    if (draft.apiKey != null) {
      keySet = true;
    }
    return read();
  }

  @override
  Future<WebSearchSettings> forgetApiKey() async {
    forgetCalls += 1;
    keySet = false;
    return read();
  }
}

final class _FixedSttSettingsGateway implements SttSettingsGateway {
  const _FixedSttSettingsGateway();

  @override
  Future<SttSettings> read() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async => SttSettings(
    configured: true,
    keySet: draft.apiKey != null,
    baseUrl: draft.baseUrl,
    model: draft.model,
  );

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

/// 可变 STT 设置网关：记录保存草稿、测试与忘记 Key 的调用。
final class _MutableSttSettingsGateway implements SttSettingsGateway {
  _MutableSttSettingsGateway(this._settings, {this.saveFailure});

  SttSettings _settings;
  final String? saveFailure;
  final savedDrafts = <SttSettingsDraft>[];
  int testCalls = 0;
  int forgetCalls = 0;

  @override
  Future<SttSettings> read() async => _settings;

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async {
    savedDrafts.add(draft);
    if (saveFailure case final message?) {
      throw ProviderSettingsGatewayException(message);
    }
    return _settings = SttSettings(
      configured: true,
      keySet: draft.apiKey != null || _settings.keySet,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
    );
  }

  @override
  Future<SttSettings> forgetApiKey() async {
    forgetCalls += 1;
    return _settings = SttSettings(
      configured: true,
      keySet: false,
      baseUrl: _settings.baseUrl,
      model: _settings.model,
    );
  }

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async {
    testCalls += 1;
    return const ProviderTestResult(
      succeeded: true,
      status: ProviderTestStatus.success,
      message: '连接成功，语音输入可以使用。',
    );
  }
}

final class _HoldingPreviewPlayer implements VoicePlayerPlatform {
  _PreviewPlayback? current;
  bool get active => current != null && !current!.completed.isCompleted;
  @override
  bool get supported => true;
  @override
  double getInitialVolume() => 1;
  @override
  void saveVolume(double volume) {}
  @override
  Future<VoicePlayback?> play(Uint8List bytes, {required String mimeType, double volume = 1}) async => current = _PreviewPlayback();
}

final class _PreviewPlayback implements VoicePlayback {
  final completed = Completer<void>();
  @override
  Future<void> get done => completed.future;
  @override
  void stop() { if (!completed.isCompleted) completed.complete(); }
  @override
  void setVolume(double volume) {}
}

final class _FixedTtsSettingsGateway implements TtsSettingsGateway {
  const _FixedTtsSettingsGateway();

  @override
  Future<TtsSettings> read() async =>
      const TtsSettings(configured: false, keySet: false);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async => TtsSettings(
    configured: true,
    keySet: draft.apiKey != null,
    baseUrl: draft.baseUrl,
    model: draft.model,
    voice: draft.voice,
    speed: draft.speed,
  );

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> forgetApiKey() async =>
      const TtsSettings(configured: false, keySet: false);

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      const TtsConnectionTest(succeeded: false, message: '还没有保存语音合成服务配置。');
}

final class _MutableTtsSettingsGateway implements TtsSettingsGateway {
  Completer<TtsConnectionTest>? pendingTest;
  _MutableTtsSettingsGateway(this._settings, {this.saveFailure});

  /// 非空时保存按主机驳回失败（人话文案由 Host 侧给出，这里只透传）。
  final String? saveFailure;

  TtsSettings _settings;
  final savedDrafts = <TtsSettingsDraft>[];
  int testCalls = 0;
  int forgetCalls = 0;
  final autoSpeakWrites = <bool>[];

  @override
  Future<TtsSettings> read() async => _settings;

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async {
    autoSpeakWrites.add(enabled);
    return _settings;
  }

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async {
    savedDrafts.add(draft);
    if (saveFailure case final message?) {
      throw ProviderSettingsGatewayException(message);
    }
    return _settings = TtsSettings(
      configured: true,
      keySet: draft.apiKey != null || _settings.keySet,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
      voice: draft.voice,
      speed: draft.speed,
      authHeader: draft.authHeader,
      responseShape: draft.responseShape ?? TtsResponseShape.rawBytes,
      responseField: draft.responseField,
      extraParams: draft.extraParams,
    );
  }

  @override
  Future<TtsSettings> forgetApiKey() async {
    forgetCalls += 1;
    return _settings = TtsSettings(
      configured: true,
      keySet: false,
      baseUrl: _settings.baseUrl,
      model: _settings.model,
      voice: _settings.voice,
      speed: _settings.speed,
    );
  }

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async {
    testCalls += 1;
    if (pendingTest != null) return pendingTest!.future;
    return TtsConnectionTest(
      succeeded: true,
      message: '连接成功，点「听试听」可以听听栖语的声音。',
      audio: Uint8List.fromList([1, 2, 3]),
    );
  }
}
