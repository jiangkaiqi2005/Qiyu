import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

void main() {
  testWidgets('restores the latest local session without duplicate messages', (
    tester,
  ) async {
    final gateway = _FakeLocalChatGateway(
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
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStart: false,
    );
    await viewModel.initialize();

    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);

    expect(find.text('我回来了'), findsOneWidget);
    expect(find.text('嗯'), findsOneWidget);
    expect(find.text('本地规则回复'), findsOneWidget);

    await _returnToHome(tester);
  });

  testWidgets('renders Qiyu replies as markdown but keeps user input plain', (
    tester,
  ) async {
    final gateway = _FakeLocalChatGateway(
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
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStart: false,
    );
    await viewModel.initialize();

    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);

    expect(find.text('**用户输入不当 Markdown 解析**'), findsOneWidget);
    expect(find.text('先**躺好**，慢慢说'), findsNothing);
    expect(find.text('先躺好，慢慢说'), findsOneWidget);

    await _returnToHome(tester);
  });

  testWidgets('sends non-empty text and renders user and local Qiyu replies', (
    tester,
  ) async {
    final gateway = _FakeLocalChatGateway();
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStart: false,
      requestIdFactory: () => 'new-request',
    );
    await viewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);

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
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: _FakeHostConnectionProbe([true]),
        autoStart: false,
        requestIdFactory: () => 'stream-request',
      );
      await viewModel.initialize();
      await tester.pumpWidget(
        QiyuApp(
          viewModel: viewModel,
          onboardingViewModel: await _completedOnboardingViewModel(),
        ),
      );
      await _enterChatFromHome(tester);

      await tester.enterText(find.byKey(const Key('chat-input')), '还醒着');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      gateway.add(
        const LocalChatDeliveryEvent(
          kind: LocalChatEventKind.accepted,
          requestId: 'stream-request',
          sessionId: 'session-1',
        ),
      );
      gateway.add(
        const LocalChatDeliveryEvent(
          kind: LocalChatEventKind.waiting,
          requestId: 'stream-request',
        ),
      );
      await tester.pump();

      expect(find.text('栖语在想…'), findsOneWidget);
      expect(find.byKey(const Key('chat-stop')), findsOneWidget);
      gateway.add(
        const LocalChatDeliveryEvent(
          kind: LocalChatEventKind.delta,
          requestId: 'stream-request',
          text: '还没',
        ),
      );
      await tester.pump();
      expect(find.text('还没'), findsOneWidget);

      gateway.add(
        const LocalChatDeliveryEvent(
          kind: LocalChatEventKind.delta,
          requestId: 'stream-request',
          text: '睡？',
        ),
      );
      gateway.add(
        const LocalChatDeliveryEvent(
          kind: LocalChatEventKind.message,
          requestId: 'stream-request',
          messages: ['还没睡？'],
        ),
      );
      gateway.add(
        const LocalChatDeliveryEvent(
          kind: LocalChatEventKind.state,
          requestId: 'stream-request',
          source: ReplySource.llm,
        ),
      );
      gateway.add(
        const LocalChatDeliveryEvent(
          kind: LocalChatEventKind.done,
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
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStart: false,
      requestIdFactory: () => 'cancel-request',
    );
    await viewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);
    await tester.enterText(find.byKey(const Key('chat-input')), '先别说');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    gateway.add(
      const LocalChatDeliveryEvent(
        kind: LocalChatEventKind.accepted,
        requestId: 'cancel-request',
        sessionId: 'session-1',
      ),
    );
    gateway.add(
      const LocalChatDeliveryEvent(
        kind: LocalChatEventKind.waiting,
        requestId: 'cancel-request',
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-stop')));
    await tester.pump();
    expect(gateway.cancelledRequestIds, ['cancel-request']);
    gateway.add(
      const LocalChatDeliveryEvent(
        kind: LocalChatEventKind.cancelled,
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
      _FakeLocalChatGateway(),
      hostConnectionProbe: _FakeHostConnectionProbe([true, false, true]),
      autoStart: false,
    );
    await viewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);

    expect(find.text('本机程序已停止'), findsNothing);

    await viewModel.checkHostNow();
    await tester.pump();

    expect(find.text('本机程序已停止'), findsOneWidget);
    expect(find.text('请重新启动栖语本机程序。'), findsOneWidget);

    await viewModel.checkHostNow();
    await tester.pumpAndSettle();
    await _returnToHome(tester);
  });

  testWidgets('shows storage errors without presenting an unsaved exchange', (
    tester,
  ) async {
    final gateway = _FakeLocalChatGateway(
      sendError: const LocalChatGatewayException('无法保存本地聊天记录。'),
      failuresRemaining: 1,
    );
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStart: false,
    );
    await viewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);

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
    final gateway = _FakeLocalChatGateway(
      sendError: const LocalChatGatewayException('第一次写入失败。'),
      failuresRemaining: 1,
    );
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStart: false,
      requestIdFactory: () => 'retry-${nextId++}',
    );
    await viewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);

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
    final gateway = _FakeLocalChatGateway(
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
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStart: false,
      requestIdFactory: () => 'new-request',
    );
    await viewModel.initialize();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: viewModel,
        onboardingViewModel: await _completedOnboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);

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
      _FakeLocalChatGateway(),
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
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
        onboardingViewModel: await _completedOnboardingViewModel(),
        settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
      ),
    );
    await _enterChatFromHome(tester);

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
    // 设置页唯一的纵向滚动区（TextField 内部的横向滚动条不算）。
    final settingsScrollable = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
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
    expect(find.text('API Key 已安全保存在 Windows 凭据管理器'), findsOneWidget);
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
      find.byTooltip('返回聊天'),
      -160,
      scrollable: settingsScrollable,
      maxScrolls: 20,
    );
    await tester.ensureVisible(find.byTooltip('返回聊天'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回聊天'));
    await tester.pumpAndSettle();
    await _returnToHome(tester);
  });

  testWidgets(
    'settings back works after selecting only a provider from home',
    (tester) async {
      final chatViewModel = LocalChatViewModel(
        _FakeLocalChatGateway(),
        hostConnectionProbe: _FakeHostConnectionProbe([true]),
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
      await tester.tap(find.byTooltip('返回聊天'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-go-chat')), findsOneWidget);
    },
  );

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
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: _FakeHostConnectionProbe([true]),
        autoStart: false,
        requestIdFactory: () => 'scroll-request',
      );
      await viewModel.initialize();
      await tester.pumpWidget(
        QiyuApp(
          viewModel: viewModel,
          onboardingViewModel: await _completedOnboardingViewModel(),
        ),
      );
      await _enterChatFromHome(tester);

      // 恢复后粘在会话尾部：最新一轮可见，最早一轮在视口外。
      expect(find.textContaining('回复第 23 条'), findsOneWidget);
      expect(find.textContaining('用户消息第 0 条'), findsNothing);

      // 发送并进入等待态后，用户上滑回读历史。
      await tester.enterText(find.byKey(const Key('chat-input')), '再说一句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      gateway.add(
        LocalChatDeliveryEvent(
          kind: LocalChatEventKind.accepted,
          requestId: 'scroll-request',
          sessionId: 'session-1',
        ),
      );
      gateway.add(
        LocalChatDeliveryEvent(
          kind: LocalChatEventKind.waiting,
          requestId: 'scroll-request',
        ),
      );
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 6000));
      await tester.pumpAndSettle();
      expect(find.textContaining('用户消息第 0 条'), findsOneWidget);

      // 流式增量到达时不打断回读：仍停留在顶部。
      gateway.add(
        LocalChatDeliveryEvent(
          kind: LocalChatEventKind.delta,
          requestId: 'scroll-request',
          text: '慢慢说，',
        ),
      );
      await tester.pump();
      gateway.add(
        LocalChatDeliveryEvent(
          kind: LocalChatEventKind.delta,
          requestId: 'scroll-request',
          text: '我在听。',
        ),
      );
      await tester.pump();
      expect(find.textContaining('用户消息第 0 条'), findsOneWidget);

      // 手动滑回底部后重新粘滞，跟随后续增量。
      await tester.drag(find.byType(ListView), const Offset(0, -8000));
      await tester.pump();
      await tester.pump();
      gateway.add(
        LocalChatDeliveryEvent(
          kind: LocalChatEventKind.delta,
          requestId: 'scroll-request',
          text: '你继续。',
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('chat-streaming-reply')), findsOneWidget);
      expect(find.textContaining('慢慢说，我在听。你继续。'), findsOneWidget);

      gateway.add(
        LocalChatDeliveryEvent(
          kind: LocalChatEventKind.message,
          requestId: 'scroll-request',
          messages: const ['慢慢说，我在听。你继续。'],
        ),
      );
      gateway.add(
        LocalChatDeliveryEvent(
          kind: LocalChatEventKind.state,
          requestId: 'scroll-request',
          source: ReplySource.llm,
        ),
      );
      gateway.add(
        LocalChatDeliveryEvent(
          kind: LocalChatEventKind.done,
          requestId: 'scroll-request',
        ),
      );
      await gateway.close();
      await tester.pumpAndSettle();
      expect(find.textContaining('慢慢说，我在听。你继续。'), findsOneWidget);
    },
  );
}

final class _FakeLocalChatGateway implements StreamingLocalChatGateway {
  _FakeLocalChatGateway({
    this.restored = const LocalChatSnapshot(
      sessionId: 'session-1',
      messages: [],
    ),
    this.sendError,
    this.failuresRemaining = 0,
  });

  final LocalChatSnapshot restored;
  final List<String> sentTexts = [];
  final List<String> sentRequestIds = [];
  final Object? sendError;
  int failuresRemaining;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async => restored;

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    sentTexts.add(text);
    sentRequestIds.add(requestId);
    if (sendError case final error? when failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw error;
    }
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: restored.sessionId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: requestId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      text: '咋了',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      messages: const ['咋了'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      source: ReplySource.local,
      fallbackReason: FallbackReason.noLlmConfig,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
    );
  }
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
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) => _controller.stream;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async => restored;
}

final class _FakeHostConnectionProbe implements HostConnectionProbe {
  _FakeHostConnectionProbe(this._results);

  final List<bool> _results;
  var _index = 0;

  @override
  Future<bool> isHostAvailable() async {
    final result = _results[_index];
    if (_index < _results.length - 1) {
      _index += 1;
    }
    return result;
  }
}

Future<OnboardingViewModel> _completedOnboardingViewModel() async {
  final viewModel = OnboardingViewModel(
    _FakeOnboardingGateway(completed: true),
    _FixedProviderSettingsGateway(),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}

Future<void> _enterChatFromHome(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('home-go-chat')));
  await tester.pumpAndSettle();
}

Future<void> _returnToHome(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('go-home')));
  await tester.pumpAndSettle();
}

final class _FakeOnboardingGateway implements OnboardingGateway {
  _FakeOnboardingGateway({required this.completed});

  bool completed;

  @override
  Future<OnboardingState> read() async =>
      OnboardingState(completed: completed);

  @override
  Future<void> complete() async {
    completed = true;
  }
}

final class _FixedProviderSettingsGateway implements ProviderSettingsGateway {
  @override
  Future<ProviderSettings> read() async =>
      const ProviderSettings(configured: false, keySet: false);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
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

final class _FakeSettingsGateway implements SettingsGateway {
  bool developerMode = false;
  int clearCalls = 0;

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
        frozen: [],
        banned: [],
        deletedCount: 0,
      );

  @override
  Future<ClearPreview> readClearPreview() async => const ClearPreview(
    memoryDirectory: 'C:/qiyu-test/memories',
    sessionCount: 0,
    episodeDayCount: 0,
    frozenCount: 0,
    bannedCount: 0,
    deletedCount: 0,
    snapshotCount: 0,
    providerConfigured: false,
    keySet: false,
  );

  @override
  Future<void> clearData() async {
    clearCalls += 1;
  }

  @override
  Future<DiagnosticsSnapshot> readDiagnostics() async => DiagnosticsSnapshot(
    generatedAt: DateTime(2026, 8, 19),
    memoryDirectory: 'C:/qiyu-test/memories',
    recentRequests: const [],
    finalization: const FinalizationHealth(
      today: '2026-08-19',
      todayFinalized: false,
      pendingDays: 0,
      unreadableDays: 0,
    ),
    dream: const DreamHealth(),
    fileHealth: const {},
  );
}
