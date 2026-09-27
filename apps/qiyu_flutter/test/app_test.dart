import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

import 'support/shared_fakes.dart';

void main() {
  testWidgets('窄视口主题槽位取窄屏字阶，宽视口取桌面档（窄屏字阶接线）', (tester) async {
    // 接线缝在 QiyuApp 的 builder：宽度判读与壳层抽屉共用
    // QiyuLayout.desktopBreakpoint 一道缝，主题按它重建。这里锁的是
    // 可观察结果——bodyMedium 槽位随视口宽度在 15/14 之间切换，防接线缝
    // 日后被人拆掉（testWidgets 逐槽位契约见 qiyu_theme_test.dart）。
    Future<void> pumpAt(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        QiyuApp(
          viewModel: LocalChatViewModel(
            FakeLocalChatGateway(),
            hostConnectionProbe: FakeHostConnectionProbe([true]),
            autoStart: false,
          ),
          onboardingViewModel: await _completedOnboardingViewModel(),
        ),
      );
      await tester.pump();
    }

    await pumpAt(const Size(1200, 800));
    expect(
      Theme.of(
        tester.element(find.byType(Scaffold).first),
      ).textTheme.bodyMedium!.fontSize,
      QiyuType.bodySize,
      reason: '宽视口（≥ 760）必须仍是桌面档正文 15',
    );

    await pumpAt(const Size(420, 900));
    expect(
      Theme.of(
        tester.element(find.byType(Scaffold).first),
      ).textTheme.bodyMedium!.fontSize,
      QiyuType.narrowBodySize,
      reason: '窄视口（< 760）必须切到窄屏档正文 14',
    );
  });
  testWidgets('默认聊天 ViewModel 复用应用级 TTS 设置网关', (tester) async {
    final ttsGateway = _RecordingTtsSettingsGateway();
    await tester.pumpWidget(
      QiyuApp(
        ttsSettingsGateway: ttsGateway,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await tester.pump();

    // 两次读都走同一注入实例（复用语义）：VM initialize 自带一次刷新，
    // 聊天页挂载补拉（go 换栈销毁重建路径的兜底）再来一次，幂等 GET。
    expect(ttsGateway.readCalls, 2);
  });

  testWidgets('restores the latest local session without duplicate messages', (
    tester,
  ) async {
    final gateway = FakeLocalChatGateway(
      restored: const LocalChatSnapshot(
        sessionId: 'session-1',
        messages: [
          LocalChatMessage(
            requestId: 'old-1',
            speaker: LocalChatSpeaker.user,
            text: '我回来了',
          ),
          LocalChatMessage(
            requestId: 'old-1',
            speaker: LocalChatSpeaker.qiyu,
            text: '嗯',
            source: ReplySource.local,
            fallbackReason: FallbackReason.noLlmConfig,
          ),
        ],
      ),
    );
    await _pumpChatApp(tester, gateway);

    expect(find.text('我回来了'), findsOneWidget);
    expect(find.text('嗯'), findsOneWidget);
    expect(find.text('本地规则回复'), findsOneWidget);

    await _returnToHome(tester);
  });

  testWidgets('历史含本地回复但最后一条是模型回复时不显示本地规则标识', (tester) async {
    final gateway = FakeLocalChatGateway(
      restored: const LocalChatSnapshot(
        sessionId: 'session-1',
        messages: [
          LocalChatMessage(
            requestId: 'old-1',
            speaker: LocalChatSpeaker.user,
            text: '我回来了',
          ),
          LocalChatMessage(
            requestId: 'old-1',
            speaker: LocalChatSpeaker.qiyu,
            text: '嗯',
            source: ReplySource.local,
            fallbackReason: FallbackReason.noLlmConfig,
          ),
          LocalChatMessage(
            requestId: 'old-2',
            speaker: LocalChatSpeaker.user,
            text: '后来呢',
          ),
          LocalChatMessage(
            requestId: 'old-2',
            speaker: LocalChatSpeaker.qiyu,
            text: '后来好多了',
            source: ReplySource.llm,
          ),
        ],
      ),
    );
    await _pumpChatApp(tester, gateway);

    expect(find.text('我回来了'), findsOneWidget);
    expect(find.text('后来好多了'), findsOneWidget);
    expect(find.text('本地规则回复'), findsNothing);

    await _returnToHome(tester);
  });

  testWidgets('同一会话内先本地降级后模型恢复正常则隐藏标识', (tester) async {
    final gateway = FakeLocalChatGateway(
      replySources: const [ReplySource.local, ReplySource.llm],
    );
    await _pumpChatApp(
      tester,
      gateway,
      requestIdFactory: () => 'fallback-request',
    );

    // 第一轮走本地规则降级：标识出现。
    await tester.enterText(find.byKey(const Key('chat-input')), '有点累');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(gateway.sentTexts, ['有点累']);
    expect(find.text('咋了'), findsOneWidget);
    expect(find.text('本地规则回复'), findsOneWidget);

    // 第二轮模型恢复正常：最近一次已完成回复来自模型，标识消失。
    await tester.enterText(find.byKey(const Key('chat-input')), '那继续说说');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(gateway.sentTexts, ['有点累', '那继续说说']);
    expect(find.text('咋了'), findsNWidgets(2));
    expect(find.text('本地规则回复'), findsNothing);

    await _returnToHome(tester);
  });

  testWidgets('renders Qiyu replies as markdown but keeps user input plain', (
    tester,
  ) async {
    final gateway = FakeLocalChatGateway(
      restored: const LocalChatSnapshot(
        sessionId: 'session-1',
        messages: [
          LocalChatMessage(
            requestId: 'old-1',
            speaker: LocalChatSpeaker.user,
            text: '**用户输入不当 Markdown 解析**',
          ),
          LocalChatMessage(
            requestId: 'old-1',
            speaker: LocalChatSpeaker.qiyu,
            text: '先**躺好**，慢慢说',
            source: ReplySource.llm,
          ),
        ],
      ),
    );
    await _pumpChatApp(tester, gateway);

    expect(find.text('**用户输入不当 Markdown 解析**'), findsOneWidget);
    expect(find.text('先**躺好**，慢慢说'), findsNothing);
    expect(find.text('先躺好，慢慢说'), findsOneWidget);

    await _returnToHome(tester);
  });

  testWidgets('sends non-empty text and renders user and local Qiyu replies', (
    tester,
  ) async {
    final gateway = FakeLocalChatGateway();
    await _pumpChatApp(
      tester,
      gateway,
      requestIdFactory: () => 'new-request',
    );

    await tester.enterText(find.byKey(const Key('chat-input')), '今天有点累');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(gateway.sentTexts, ['今天有点累']);
    expect(find.text('今天有点累'), findsOneWidget);
    expect(find.text('咋了'), findsOneWidget);
    expect(find.text('本地规则回复'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('chat-input')), '   ');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    expect(gateway.sentTexts, hasLength(1));

    await tester.pumpAndSettle();
    await _returnToHome(tester);
  });

  testWidgets(
    'shows waiting before validated streaming text and then commits once',
    (tester) async {
      final gateway = _StreamingFakeLocalChatGateway();
      final viewModel = await _pumpChatApp(
        tester,
        gateway,
        requestIdFactory: () => 'stream-request',
      );

      await tester.enterText(find.byKey(const Key('chat-input')), '还醒着');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      expect(find.text('还醒着'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-input')))
            .controller!
            .text,
        isEmpty,
      );
      gateway.add(
        const LocalChatDeliveryEvent.accepted(
          requestId: 'stream-request',
          sessionId: 'session-1',
        ),
      );
      gateway.add(
        const LocalChatDeliveryEvent.waiting(
          requestId: 'stream-request',
        ),
      );
      await tester.pump();

      expect(find.text('栖语在想…'), findsOneWidget);
      expect(find.byKey(const Key('chat-stop')), findsOneWidget);
      gateway.add(
        const LocalChatDeliveryEvent.delta(
          requestId: 'stream-request',
          text: '还没',
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('还没'), findsOneWidget);

      gateway.add(
        const LocalChatDeliveryEvent.delta(
          requestId: 'stream-request',
          text: '睡？',
        ),
      );
      gateway.add(
        const LocalChatDeliveryEvent.message(
          requestId: 'stream-request',
          messages: ['还没睡？'],
        ),
      );
      gateway.add(
        const LocalChatDeliveryEvent.state(
          requestId: 'stream-request',
          source: ReplySource.llm,
        ),
      );
      gateway.add(
        const LocalChatDeliveryEvent.done(
          requestId: 'stream-request',
        ),
      );
      await gateway.close();
      await tester.pumpAndSettle();

      expect(find.text('还没睡？'), findsOneWidget);
      expect(
        viewModel.messages.where(
          (message) => message.speaker == LocalChatSpeaker.qiyu,
        ),
        hasLength(1),
      );

      await _returnToHome(tester);
    },
  );

  testWidgets('stops an active streamed reply without committing it', (
    tester,
  ) async {
    final gateway = _StreamingFakeLocalChatGateway();
    final viewModel = await _pumpChatApp(
      tester,
      gateway,
      requestIdFactory: () => 'cancel-request',
    );
    await tester.enterText(find.byKey(const Key('chat-input')), '先别说');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    gateway.add(
      const LocalChatDeliveryEvent.accepted(
        requestId: 'cancel-request',
        sessionId: 'session-1',
      ),
    );
    gateway.add(
      const LocalChatDeliveryEvent.waiting(
        requestId: 'cancel-request',
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-stop')));
    await tester.pump();
    expect(gateway.cancelledRequestIds, ['cancel-request']);
    gateway.add(
      const LocalChatDeliveryEvent.cancelled(
        requestId: 'cancel-request',
      ),
    );
    await gateway.close();
    await tester.pumpAndSettle();

    expect(
      viewModel.messages.where(
        (message) => message.speaker == LocalChatSpeaker.qiyu,
      ),
      isEmpty,
    );

    await _returnToHome(tester);
  });

  testWidgets('shows a clear stopped state when the local host disappears', (
    tester,
  ) async {
    final viewModel = LocalChatViewModel(
      FakeLocalChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe([true, false, true]),
      autoStart: false,
    );
    await viewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await _settleMergedPage(tester);

    expect(find.text('栖语本机程序未在运行或已更新。'), findsNothing);

    await viewModel.checkHostNow();
    await tester.pump();

    expect(find.text('栖语本机程序未在运行或已更新。'), findsOneWidget);
    expect(find.text('请在电脑上重新启动栖语，然后刷新这个页面。'), findsOneWidget);

    await viewModel.checkHostNow();
    await tester.pumpAndSettle();
    await _returnToHome(tester);
  });

  testWidgets('shows storage errors without presenting an unsaved exchange', (
    tester,
  ) async {
    final gateway = FakeLocalChatGateway(
      sendError: const LocalChatGatewayException('无法保存本地聊天记录。'),
      failuresRemaining: 1,
    );
    final viewModel = await _pumpChatApp(tester, gateway);

    await tester.enterText(find.byKey(const Key('chat-input')), '别丢掉这句');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(find.text('无法保存本地聊天记录。'), findsOneWidget);
    expect(viewModel.messages, isEmpty);
    final inputAfterFailure = tester.widget<TextField>(
      find.byKey(const Key('chat-input')),
    );
    expect(inputAfterFailure.controller!.text, '别丢掉这句');

    await _returnToHome(tester);
  });

  testWidgets('retries a failed send with the same request id', (tester) async {
    var nextId = 0;
    final gateway = FakeLocalChatGateway(
      sendError: const LocalChatGatewayException('第一次写入失败。'),
      failuresRemaining: 1,
    );
    await _pumpChatApp(
      tester,
      gateway,
      requestIdFactory: () => 'retry-${nextId++}',
    );

    await tester.enterText(find.byKey(const Key('chat-input')), '别重复这句');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    final inputAfterFailure = tester.widget<TextField>(
      find.byKey(const Key('chat-input')),
    );
    expect(inputAfterFailure.controller!.text, '别重复这句');

    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(gateway.sentRequestIds, ['retry-0', 'retry-0']);
    expect(find.text('别重复这句'), findsOneWidget);
    expect(find.text('咋了'), findsOneWidget);

    await _returnToHome(tester);
  });

  testWidgets('resumes a persisted user-only turn after a reload', (
    tester,
  ) async {
    final gateway = FakeLocalChatGateway(
      restored: const LocalChatSnapshot(
        sessionId: 'session-1',
        messages: [
          LocalChatMessage(
            requestId: 'interrupted-request',
            speaker: LocalChatSpeaker.user,
            text: '别重复这句',
          ),
        ],
      ),
    );
    await _pumpChatApp(
      tester,
      gateway,
      requestIdFactory: () => 'new-request',
    );

    await tester.enterText(find.byKey(const Key('chat-input')), '别重复这句');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(gateway.sentRequestIds, ['interrupted-request']);
    expect(find.text('别重复这句'), findsOneWidget);
    expect(find.text('咋了'), findsOneWidget);

    await _returnToHome(tester);
  });

  testWidgets('selects a provider preset and its Anthropic-compatible route', (
    tester,
  ) async {
    final chatViewModel = LocalChatViewModel(
      FakeLocalChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe([true]),
      autoStart: false,
    );
    await chatViewModel.initialize();
    final settingsGateway = _FakeProviderSettingsGateway();
    final settingsViewModel = ProviderSettingsViewModel(
      settingsGateway,
      autoStart: false,
    );
    await settingsViewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: chatViewModel,
        providerSettingsViewModel: settingsViewModel,
        sttSettingsViewModel: SttSettingsViewModel(
          const _FixedSttSettingsGateway(),
          autoStart: false,
        ),
        onboardingViewModel: await _completedOnboardingViewModel(),
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
      ),
    );
    await _settleMergedPage(tester);

    await tester.tap(find.byKey(const Key('open-provider-settings')));
    await tester.pumpAndSettle();

    expect(find.text('模型连接'), findsOneWidget);
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('官方 API · OpenAI 兼容'), findsOneWidget);
    expect(find.text('gpt-4.1-mini'), findsOneWidget);
    expect(find.textContaining('协议与服务地址已自动配置'), findsOneWidget);

    await tester.tap(find.byKey(const Key('provider-preset')));
    await tester.pumpAndSettle();
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('阿里云百炼'), findsOneWidget);
    expect(find.text('火山方舟'), findsOneWidget);
    await tester.tap(find.text('DeepSeek').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('provider-connection')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按量付费 · Anthropic 兼容').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('provider-model-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('输入其他模型名称').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('provider-model')),
      'claude-compatible-model',
    );
    // 设置页变长了（ticket 23 新增本地数据/隐私/开发者区块）：
    // 用滚动到可见代替固定位移，避免依赖具体页面高度。
    // 设置页唯一的纵向滚动区（TextField 内部的横向滚动条不算）：桌面导航壳的
    // 侧边栏同样是纵向可滚容器，因此按这一页列表的 Key 取它自己的 Scrollable。
    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('settings-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('provider-api-key')),
      160,
      scrollable: settingsScrollable,
      maxScrolls: 20,
    );
    expect(find.text('尚未保存 API Key'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('provider-api-key')),
      'ui-only-test-value',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('save-provider-settings')),
      160,
      scrollable: settingsScrollable,
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byKey(const Key('save-provider-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-provider-settings')));
    await tester.pumpAndSettle();

    expect(settingsGateway.saved.single.apiKey, 'ui-only-test-value');
    expect(settingsGateway.saved.single.provider, ProviderKind.anthropic);
    expect(
      settingsGateway.saved.single.baseUrl,
      'https://api.deepseek.com/anthropic',
    );
    expect(settingsGateway.saved.single.model, 'claude-compatible-model');
    expect(find.text('API Key 已保存在本机 provider.json'), findsOneWidget);
    final keyField = tester.widget<TextField>(
      find.byKey(const Key('provider-api-key')),
    );
    expect(keyField.controller!.text, isEmpty);

    await tester.scrollUntilVisible(
      find.byKey(const Key('provider-model')),
      -160,
      scrollable: settingsScrollable,
      maxScrolls: 20,
    );
    await tester.enterText(
      find.byKey(const Key('provider-model')),
      'unsaved-test-model',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('test-provider-connection')),
      160,
      scrollable: settingsScrollable,
      maxScrolls: 20,
    );
    await tester.ensureVisible(
      find.byKey(const Key('test-provider-connection')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('test-provider-connection')));
    await tester.pumpAndSettle();
    expect(find.text('连接成功，栖语可以使用这个模型。'), findsOneWidget);
    expect(settingsGateway.tested.single.model, 'unsaved-test-model');

    await tester.scrollUntilVisible(
      find.byTooltip('返回上一页'),
      -160,
      scrollable: settingsScrollable,
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byTooltip('返回上一页'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回上一页'));
    await tester.pumpAndSettle();
    await _returnToHome(tester);
  });

  testWidgets('settings back works after selecting only a provider from home', (
    tester,
  ) async {
    final chatViewModel = LocalChatViewModel(
      FakeLocalChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe([true]),
      autoStart: false,
    );
    await chatViewModel.initialize();
    final settingsViewModel = ProviderSettingsViewModel(
      _FakeProviderSettingsGateway(),
      autoStart: false,
    );
    await settingsViewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: chatViewModel,
        providerSettingsViewModel: settingsViewModel,
        sttSettingsViewModel: SttSettingsViewModel(
          const _FixedSttSettingsGateway(),
          autoStart: false,
        ),
        onboardingViewModel: await _completedOnboardingViewModel(),
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-go-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('provider-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DeepSeek').last);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(700, 120));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回上一页'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-go-chat')), findsOneWidget);
  });

  testWidgets(
    'chat list restores at the bottom and streaming never yanks a reading user',
    (tester) async {
      final messages = <LocalChatMessage>[
        for (var index = 0; index < 24; index += 1) ...[
          LocalChatMessage(
            requestId: 'old-$index',
            speaker: LocalChatSpeaker.user,
            text: '用户消息第 $index 条，写得长一点以便产生足够的滚动高度',
          ),
          LocalChatMessage(
            requestId: 'old-$index',
            speaker: LocalChatSpeaker.qiyu,
            text: '栖语回复第 $index 条，同样写得长一点以便产生滚动高度',
            source: ReplySource.llm,
          ),
        ],
      ];
      final gateway = _RestoredStreamingGateway(
        restored: LocalChatSnapshot(sessionId: 'session-1', messages: messages),
      );
      await _pumpChatApp(
        tester,
        gateway,
        requestIdFactory: () => 'scroll-request',
      );

      // 恢复后粘在会话尾部：最新一轮可见，最早一轮在视口外。
      expect(find.textContaining('回复第 23 条'), findsOneWidget);
      expect(find.textContaining('用户消息第 0 条'), findsNothing);

      // 发送并进入等待态后，用户上滑回读历史。
      await tester.enterText(find.byKey(const Key('chat-input')), '再说一句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      gateway.add(
        LocalChatDeliveryEvent.accepted(
          requestId: 'scroll-request',
          sessionId: 'session-1',
        ),
      );
      gateway.add(
        LocalChatDeliveryEvent.waiting(
          requestId: 'scroll-request',
        ),
      );
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 6000));
      await tester.pumpAndSettle();
      expect(find.textContaining('用户消息第 0 条'), findsOneWidget);

      // 流式增量到达时不打断回读：仍停留在顶部。
      gateway.add(
        LocalChatDeliveryEvent.delta(
          requestId: 'scroll-request',
          text: '慢慢说，',
        ),
      );
      await tester.pump();
      gateway.add(
        LocalChatDeliveryEvent.delta(
          requestId: 'scroll-request',
          text: '我在听。',
        ),
      );
      await tester.pump();
      expect(find.textContaining('用户消息第 0 条'), findsOneWidget);

      // 手动滑回底部后重新粘滞，跟随后续增量。
      // 恢复的历史栖语气泡带重听小喇叭（+28px/条），列表比以往更高：
      // 明确滚到最新流式内容（回读后回到最新可见的语义不变）。
      gateway.add(
        LocalChatDeliveryEvent.delta(
          requestId: 'scroll-request',
          text: '你继续。',
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('chat-streaming-reply')),
        200,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('chat-streaming-reply')), findsOneWidget);
      expect(find.textContaining('慢慢说，我在听。你继续。'), findsOneWidget);

      gateway.add(
        LocalChatDeliveryEvent.message(
          requestId: 'scroll-request',
          messages: const ['慢慢说，我在听。你继续。'],
        ),
      );
      gateway.add(
        LocalChatDeliveryEvent.state(
          requestId: 'scroll-request',
          source: ReplySource.llm,
        ),
      );
      gateway.add(
        LocalChatDeliveryEvent.done(
          requestId: 'scroll-request',
        ),
      );
      await gateway.close();
      await tester.pumpAndSettle();
      expect(find.textContaining('慢慢说，我在听。你继续。'), findsOneWidget);
    },
  );
}

final class _RecordingTtsSettingsGateway implements TtsSettingsGateway {
  int readCalls = 0;

  @override
  Future<TtsSettings> read() async {
    readCalls += 1;
    return const TtsSettings(configured: true, keySet: true, autoSpeak: true);
  }

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

final class _StreamingFakeLocalChatGateway
    implements StreamingLocalChatGateway {
  final _controller = StreamController<LocalChatDeliveryEvent>();
  final List<String> cancelledRequestIds = [];

  void add(LocalChatDeliveryEvent event) => _controller.add(event);
  Future<void> close() => _controller.close();

  @override
  Future<bool> cancel(String requestId) async {
    cancelledRequestIds.add(requestId);
    return true;
  }

  @override
  Future<bool> stopVoice(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) => _controller.stream;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);
}

final class _RestoredStreamingGateway implements StreamingLocalChatGateway {
  _RestoredStreamingGateway({required this.restored});

  final LocalChatSnapshot restored;
  final _controller = StreamController<LocalChatDeliveryEvent>();

  void add(LocalChatDeliveryEvent event) => _controller.add(event);
  Future<void> close() => _controller.close();

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<bool> stopVoice(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) => _controller.stream;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async => restored;
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

/// 装配合一页聊天应用：LocalChatViewModel（探活恒真）→ initialize → pumpWidget
/// → _settleMergedPage；[requestIdFactory] 有无逐字透传给 ViewModel。
Future<LocalChatViewModel> _pumpChatApp(
  WidgetTester tester,
  StreamingLocalChatGateway gateway, {
  RequestIdFactory? requestIdFactory,
}) async {
  final viewModel = LocalChatViewModel(
    gateway,
    hostConnectionProbe: FakeHostConnectionProbe([true]),
    autoStart: false,
    requestIdFactory: requestIdFactory,
  );
  await viewModel.initialize();
  await tester.pumpWidget(
    QiyuApp(
      viewModel: viewModel,
      onboardingViewModel: await _completedOnboardingViewModel(),
    ),
  );
  await _settleMergedPage(tester);
  return viewModel;
}

/// 合一页（design-system §5）没有「从首页进对话」这一跳：`/` 与 `/chat` 渲染
/// 的是同一个页面，composer 就在眼前。这里做的只是推进到稳定态——`home-go-chat`
/// 在合一页之后是输入容器的定位键，点它不触发任何导航。
Future<void> _settleMergedPage(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('home-go-chat')));
  await tester.pumpAndSettle();
}

/// 回合一页：桌面已不设任何「回合一页」入口（2026-08-31 二次裁定），`go-home`
/// 键只保留在窄屏抽屉品牌槽上，所以这一步切到窄视口走抽屉完成同一动作：
/// 停播 + `go('/')` 的语义不变，最后钉住落点确实是合一页。
Future<void> _returnToHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pump();
  await tester.tap(find.byKey(const Key('nav-menu-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('go-home')));
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
  expect(
    router.routerDelegate.currentConfiguration.matches.last.matchedLocation,
    '/',
  );
}

final class _FakeProviderSettingsGateway implements ProviderSettingsGateway {
  ProviderSettings current = const ProviderSettings(
    configured: false,
    keySet: false,
  );
  final List<ProviderSettingsDraft> saved = [];
  final List<ProviderSettingsDraft> tested = [];

  @override
  Future<ProviderSettings> read() async => current;

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async {
    saved.add(draft);
    current = ProviderSettings(
      configured: true,
      keySet: draft.apiKey != null,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
      temperature: draft.temperature,
      timeoutSeconds: draft.timeoutSeconds,
    );
    return current;
  }

  @override
  Future<ProviderSettings> forgetApiKey() async {
    current = ProviderSettings(
      configured: current.configured,
      keySet: false,
      provider: current.provider,
      baseUrl: current.baseUrl,
      model: current.model,
      temperature: current.temperature,
      timeoutSeconds: current.timeoutSeconds,
    );
    return current;
  }

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) async {
    tested.add(draft);
    return const ProviderTestResult(
      succeeded: true,
      status: ProviderTestStatus.success,
      message: '连接成功，栖语可以使用这个模型。',
    );
  }
}

/// 设置网关替身：共享版之外补上本文件诊断快照的日终健康档位。
class _FakeSettingsGateway extends FakeSettingsGateway {
  _FakeSettingsGateway()
    : super(
        finalization: const FinalizationHealth(
          today: '2026-08-19',
          todayFinalized: false,
          pendingDays: 0,
          unreadableDays: 0,
        ),
        dream: const DreamHealth(),
      );
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
