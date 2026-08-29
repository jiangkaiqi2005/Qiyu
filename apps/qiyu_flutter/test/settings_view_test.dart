import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_client.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_view_model.dart';

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

  testWidgets(
    'FocusNode 保护与编辑态草稿：获焦编辑中绝不被覆盖，且 tts-extra-params 为 multiline',
    (tester) async {
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
      expect(
        tester.widget<TextField>(extraField).focusNode?.hasFocus,
        isTrue,
      );

      // 重新触发组件树更新/重绘，草稿绝不被冲掉
      await tester.pump();
      expect(
        tester.widget<TextField>(extraField).controller!.text,
        '{"user_draft": 123}',
      );
    },
  );

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

/// 当前页自己的纵向滚动容器。
///
/// 必须排除导航壳的侧边栏/抽屉：那块 [Scrollable] 同样是纵向，且在树里排在页面
/// 内容之前，取「第一个纵向 Scrollable」会误命中它（`/settings` 挂上壳之后才有的
/// 问题）。生产侧正是为此在 `_NavPanel` 上留了 `nav-scroll` 键，这里按它摘出去。
///
/// 不能反过来按页内键（如 `settings-scroll`）锁死：设置页里再点进的开发者诊断页
/// 与隐私页是各自独立的路由、不挂壳，也就没有那个键，锁死会让这些页上的滚动
/// 断言取不到容器。
Finder _verticalScrollable() => find
    .byElementPredicate((element) {
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
    })
    .first;

final class _FakeSettingsGateway implements SettingsGateway {
  _FakeSettingsGateway({this.onCleared});

  bool developerMode = false;
  int clearCalls = 0;

  /// 清除成功时的回调：测试用它同步翻转初见网关状态。
  final void Function()? onCleared;

  @override
  Future<ExperiencePreferences> readPreferences() async =>
      ExperiencePreferences(developerMode: developerMode);

  @override
  Future<ExperiencePreferences> savePreferences({
    required bool developerMode,
  }) async {
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
  ) async => const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功，栖语可以使用这个模型。',
  );
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
