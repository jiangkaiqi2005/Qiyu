import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_collapse_platform.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_client.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_view_model.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

void main() {
  testWidgets(
    'developer diagnostics entry only appears after developer mode is on',
    (tester) async {
      final settingsGateway = _FakeSettingsGateway();
      await tester.pumpWidget(
        await _app(
          settingsViewModel: SettingsViewModel(settingsGateway),
          providerGateway: _FixedProviderSettingsGateway(configured: false),
        ),
      );
      await _openSettings(tester);

      // 「体验与开发者选项」按 §8 默认收起，先点标题展开才有开关。
      await _expandSection(tester, 'developer');

      // 默认不打扰普通用户：诊断入口不存在。
      expect(find.byKey(const Key('settings-diagnostics')), findsNothing);
      expect(settingsGateway.developerMode, isFalse);

      // 打开开发者模式后入口出现。
      await tester.scrollUntilVisible(
        find.byKey(const Key('developer-mode-switch')),
        200,
        scrollable: _verticalScrollable(),
        maxScrolls: 20,
      );
      await tester.ensureVisible(
        find.byKey(const Key('developer-mode-switch')),
      );
      await tester.pumpAndSettle();
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

  testWidgets('memory controls overview lists frozen and banned entries', (
    tester,
  ) async {
    final settingsGateway = _FakeSettingsGateway();
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(settingsGateway),
        providerGateway: _FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-memory-controls')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(
      find.byKey(const Key('settings-memory-controls')),
    );
    await tester.pumpAndSettle();
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
    final onboardingGateway = _ClearableOnboardingGateway();
    // 清除落地的同时初见记录也被清除：重读状态后当次会话重走初见引导。
    final settingsGateway = _FakeSettingsGateway(
      onCleared: () => onboardingGateway.completed = false,
    );
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(settingsGateway),
        providerGateway: _FixedProviderSettingsGateway(configured: false),
        onboardingGateway: onboardingGateway,
      ),
    );
    await _openSettings(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-clear-data')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('settings-clear-data')));
    await tester.pumpAndSettle();
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
        providerGateway: _FixedProviderSettingsGateway(configured: false),
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('save-tts-settings')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 10,
    );
    await tester.ensureVisible(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('tts-provider')),
      -300,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('forget-tts-key')),
      -200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('forget-tts-key')));
    await tester.pumpAndSettle();
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
        providerGateway: _FixedProviderSettingsGateway(configured: false),
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('tts-advanced-params-tile')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 10,
    );
    await tester.ensureVisible(
      find.byKey(const Key('tts-advanced-params-tile')),
    );
    await tester.pumpAndSettle();
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

    // 修改 extraParams 并保存
    await tester.enterText(
      find.byKey(const Key('tts-extra-params')),
      '{"audio_params": {"sample_rate": 16000}}',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('save-tts-settings')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 10,
    );
    await tester.ensureVisible(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-tts-settings')));
    await tester.pumpAndSettle();

    expect(ttsGateway.savedDrafts.last.extraParams, {
      'audio_params': {'sample_rate': 16000},
    });
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

    await tester.scrollUntilVisible(
      find.byKey(const Key('forget-api-key')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('forget-api-key')));
    await tester.pumpAndSettle();
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
        providerGateway: _FixedProviderSettingsGateway(configured: false),
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('save-stt-settings')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 10,
    );
    await tester.ensureVisible(find.byKey(const Key('save-stt-settings')));
    await tester.pumpAndSettle();
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('stt-provider')),
      -300,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('forget-stt-key')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 10,
    );
    await tester.ensureVisible(find.byKey(const Key('forget-stt-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-stt-key')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stt-forget-key-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('stt-forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(sttGateway.forgetCalls, 1);
    expect(find.textContaining('尚未保存语音服务的 API Key'), findsOneWidget);
  });

  testWidgets('privacy page states the local-only boundaries', (tester) async {
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: _FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'privacy');

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-privacy')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('settings-privacy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-privacy')));
    await tester.pumpAndSettle();

    expect(find.text('隐私与边界'), findsWidgets);
    expect(find.textContaining('数据只保存在你的电脑上'), findsOneWidget);

    // 页面较长逐段滚动断言；危机输入绝不发给模型是必须讲清的边界。
    await tester.scrollUntilVisible(
      find.textContaining('何时调用你选择的模型服务'),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 20,
    );
    expect(find.textContaining('何时调用你选择的模型服务'), findsOneWidget);
    expect(find.textContaining('绝不发送给模型'), findsOneWidget);

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
        providerGateway: _FixedProviderSettingsGateway(configured: false),
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
        providerGateway: _FixedProviderSettingsGateway(configured: false),
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
        providerGateway: _FixedProviderSettingsGateway(configured: false),
        ttsGateway: ttsGateway,
      ),
    );
    await _openSettings(tester);
    await _expandSection(tester, 'tts');

    // 展开高级参数
    await tester.scrollUntilVisible(
      find.byKey(const Key('tts-advanced-params-tile')),
      200,
      scrollable: _verticalScrollable(),
      maxScrolls: 30,
    );
    await tester.ensureVisible(
      find.byKey(const Key('tts-advanced-params-tile')),
    );
    await tester.pumpAndSettle();
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
    // 整页层面的断言要七节同时在场（设置页是懒建的 ListView）。
    _useFullPageViewport(tester);
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: _FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);
    // 默认档只展开两节，其余五节的正文根本不在树上；这里要看的是七节的形态，
    // 所以先全部展开（折叠态自身的断言在折叠那几条用例里）。
    await _expandAllSections(tester);

    final scheme = Theme.of(
      tester.element(find.byKey(const Key('settings-scroll'))),
    ).colorScheme;

    // 七节各自成节，且每节都有一个可点的分节头——§8「分节标题本身就是导航」，
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
    // 次要字色、3px 字距（`.scratch/qiyu-prototype/index.html:229-230`）。
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
    // 整页层面的次序要七节同时在场。
    _useFullPageViewport(tester);
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: _FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);

    // 次序量的是**页面上的纵向位置**，不是「这一节的文本在场」：七节标题都在树
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
    // 整页层面的默认档要七节同时在场。
    _useFullPageViewport(tester);
    await tester.pumpWidget(
      await _app(
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        providerGateway: _FixedProviderSettingsGateway(configured: false),
      ),
    );
    await _openSettings(tester);

    // §8：默认展开「模型连接」「本地数据」，其余五节收起。
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
    // 存的就是「收起的节 id 集合」：默认收起的五节里去掉联网搜索（展开了）、
    // 再加上本地数据（收起了）；模型连接这一路没碰过。
    expect(store.readCollapsed(), {
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
        providerGateway: _FixedProviderSettingsGateway(configured: false),
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
/// 取值按页面现状。出入如实登记：§8／决策日志第一轮 #8／Spec Decision 15 把第三
/// 节写作「语音转写」，页面渲染的是「语音输入」（`provider_settings_view.dart`
/// 的 `_SttSection`），这条命名出入已上报、未裁定，本用例不替它作数。
const _sectionTitlesInOrder = <String, String>{
  'provider': '模型连接',
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
  WebSearchSettingsGateway? webSearchGateway,
}) async {
  final providerViewModel = ProviderSettingsViewModel(
    providerGateway,
    autoStart: false,
  );
  await providerViewModel.initialize();
  final onboardingViewModel = OnboardingViewModel(
    onboardingGateway ?? _CompletedOnboardingGateway(),
    _FixedProviderSettingsGateway(configured: true),
    autoStart: false,
  );
  await onboardingViewModel.initialize();
  return QiyuApp(
    viewModel: LocalChatViewModel(
      _UnusedChatGateway(),
      hostConnectionProbe: _FixedHostConnectionProbe(),
      autoStart: false,
    ),
    providerSettingsViewModel: providerViewModel,
    sttSettingsViewModel: SttSettingsViewModel(
      sttGateway ?? const _FixedSttSettingsGateway(),
      autoStart: false,
    ),
    ttsSettingsViewModel: TtsSettingsViewModel(
      ttsGateway ?? const _FixedTtsSettingsGateway(),
      autoStart: false,
    ),
    webSearchSettingsViewModel: WebSearchSettingsViewModel(
      webSearchGateway ?? const _FixedWebSearchSettingsGateway(),
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

/// 这一节当前是否展开。
///
/// 判据是「正文那块在不在树上」——收起时 [_SettingsPanel] 只不画正文，分节自身
/// 与它的标题都还在（标题就是唯一的导航入口）。不去看标题文本、也不去看指示符
/// 朝向，两者在两种状态下都没差别或不足以定位。
bool _isSectionExpanded(WidgetTester tester, String sectionId) => find
    .byKey(Key('settings-section-content-$sectionId'))
    .evaluate()
    .isNotEmpty;

/// 整页层面的断言要七节同时在场，而设置页是**懒建的 ListView**：默认 600 高的
/// 视口只建得出头两三节，「某一节的正文在不在树上」这类判据会因为它还没被建
/// 出来而误判成收起。宽度仍取 1200（内容列由 `settingsReadingMaxWidth` 限宽），
/// 只是把视口拉高，不改变任何布局档位。
void _useFullPageViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// §8 默认档里点名展开的两节；其余五节默认收起。
const _defaultExpandedSectionIds = <String>['provider', 'local_data'];

/// 点一次某一节的标题（不判当前状态，也不幂等）。
Future<void> _tapSectionHeader(WidgetTester tester, String sectionId) async {
  final header = find.byKey(Key('settings-section-header-$sectionId'));
  await tester.scrollUntilVisible(
    header,
    200,
    scrollable: _verticalScrollable(),
    maxScrolls: 20,
  );
  await tester.ensureVisible(header);
  await tester.pumpAndSettle();
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
    _FixedProviderSettingsGateway(configured: false),
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

/// 按 §8 顺序把七节全部展开，供整页层面的视觉断言使用。
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

final class _FakeSettingsGateway implements SettingsGateway {
  _FakeSettingsGateway({this.onCleared});

  bool developerMode = false;
  int clearCalls = 0;

  /// 主持久化链路（Host `/api` 那侧）被写了几次：分节折叠按 design-system §8
  /// 只准走本地 UI 存储，这个计数一次都不该动。
  int prefWrites = 0;

  /// 清除成功时的回调：测试用它同步翻转初见网关状态。
  final void Function()? onCleared;

  @override
  Future<ExperiencePreferences> readPreferences() async =>
      ExperiencePreferences(developerMode: developerMode);

  @override
  Future<ExperiencePreferences> savePreferences({
    required bool developerMode,
  }) async {
    prefWrites += 1;
    this.developerMode = developerMode;
    return ExperiencePreferences(developerMode: developerMode);
  }

  @override
  Future<MemoryControlsOverview> readMemoryControls() async =>
      const MemoryControlsOverview(
        readable: true,
        frozen: [
          MemoryControlRecord(id: 1, origin: 'chat', summary: '一段冻结的记忆'),
        ],
        banned: [
          MemoryControlRecord(id: 2, origin: 'chat', summary: '一段禁提的往事'),
        ],
        deletedCount: 3,
      );

  @override
  Future<ClearPreview> readClearPreview() async => const ClearPreview(
    memoryDirectory: 'C:/qiyu/memories',
    sessionCount: 4,
    episodeDayCount: 9,
    frozenCount: 1,
    bannedCount: 2,
    deletedCount: 0,
    snapshotCount: 1,
    providerConfigured: false,
    keySet: false,
  );

  @override
  Future<void> clearData() async {
    clearCalls += 1;
    onCleared?.call();
  }

  @override
  Future<DiagnosticsSnapshot> readDiagnostics() async => DiagnosticsSnapshot(
    generatedAt: DateTime.parse('2026-08-19T14:00:00.000Z'),
    memoryDirectory: 'C:/qiyu/memories',
    recentRequests: [
      RecentRequest(
        at: DateTime.parse('2026-08-19T13:59:00.000Z'),
        source: 'chat',
        result: 'fallback',
        replySource: 'local',
        fallbackReason: 'model_timeout',
      ),
    ],
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

final class _FixedProviderSettingsGateway implements ProviderSettingsGateway {
  _FixedProviderSettingsGateway({required this.configured});

  final bool configured;

  @override
  Future<ProviderSettings> read() async =>
      ProviderSettings(configured: configured, keySet: configured);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
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

final class _CompletedOnboardingGateway extends _ClearableOnboardingGateway {}

/// 初见状态可翻转：清除产品数据测试用它模拟初见记录被一并清除。
class _ClearableOnboardingGateway implements OnboardingGateway {
  bool completed = true;

  @override
  Future<OnboardingState> read() async => OnboardingState(completed: completed);

  @override
  Future<void> complete() async {
    completed = true;
  }
}

final class _FixedHostConnectionProbe implements HostConnectionProbe {
  @override
  Future<bool> isHostAvailable() async => true;
}

final class _UnusedChatGateway implements StreamingLocalChatGateway {
  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {}

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';
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
  _MutableSttSettingsGateway(this._settings);

  SttSettings _settings;
  final savedDrafts = <SttSettingsDraft>[];
  int testCalls = 0;
  int forgetCalls = 0;

  @override
  Future<SttSettings> read() async => _settings;

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async {
    savedDrafts.add(draft);
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
  _MutableTtsSettingsGateway(this._settings);

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
    return _settings = TtsSettings(
      configured: true,
      keySet: draft.apiKey != null || _settings.keySet,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
      voice: draft.voice,
      speed: draft.speed,
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
    return TtsConnectionTest(
      succeeded: true,
      message: '连接成功，点「听试听」可以听听栖语的声音。',
      audio: Uint8List.fromList([1, 2, 3]),
    );
  }
}
