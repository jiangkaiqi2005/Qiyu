import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
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

    await tester.pumpWidget(QiyuApp(viewModel: viewModel));
    await tester.pumpAndSettle();

    expect(find.text('我回来了'), findsOneWidget);
    expect(find.text('嗯'), findsOneWidget);
    expect(find.text('本地规则回复'), findsOneWidget);
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
    await tester.pumpWidget(QiyuApp(viewModel: viewModel));
    await tester.pumpAndSettle();

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
      await tester.pumpWidget(QiyuApp(viewModel: viewModel));

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
    await tester.pumpWidget(QiyuApp(viewModel: viewModel));
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
  });

  testWidgets('shows a clear stopped state when the local host disappears', (
    tester,
  ) async {
    final viewModel = LocalChatViewModel(
      _FakeLocalChatGateway(),
      hostConnectionProbe: _FakeHostConnectionProbe([true, false]),
      autoStart: false,
    );
    await viewModel.initialize();
    await tester.pumpWidget(QiyuApp(viewModel: viewModel));

    expect(find.text('本机程序已停止'), findsNothing);

    await viewModel.checkHostNow();
    await tester.pump();

    expect(find.text('本机程序已停止'), findsOneWidget);
    expect(find.text('请重新启动栖语本机程序。'), findsOneWidget);
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
    await tester.pumpWidget(QiyuApp(viewModel: viewModel));

    await tester.enterText(find.byKey(const Key('chat-input')), '别丢掉这句');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(find.text('无法保存本地聊天记录。'), findsOneWidget);
    expect(viewModel.messages, isEmpty);
    final inputAfterFailure = tester.widget<TextField>(
      find.byKey(const Key('chat-input')),
    );
    expect(inputAfterFailure.controller!.text, '别丢掉这句');
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
    await tester.pumpWidget(QiyuApp(viewModel: viewModel));

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
    await tester.pumpWidget(QiyuApp(viewModel: viewModel));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('chat-input')), '别重复这句');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(gateway.sentRequestIds, ['interrupted-request']);
    expect(find.text('别重复这句'), findsOneWidget);
    expect(find.text('咋了'), findsOneWidget);
  });

  testWidgets('configures and tests all supported model providers', (
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
      ),
    );

    await tester.tap(find.byKey(const Key('open-provider-settings')));
    await tester.pumpAndSettle();

    expect(find.text('模型连接'), findsOneWidget);
    expect(find.text('OpenAI 兼容'), findsOneWidget);
    expect(find.text('Anthropic'), findsOneWidget);
    expect(find.text('Ollama'), findsOneWidget);
    expect(find.text('尚未保存 API Key'), findsOneWidget);
    expect(find.byKey(const Key('provider-api-key')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('provider-base-url')),
      'https://api.openai.com/v1',
    );
    await tester.enterText(
      find.byKey(const Key('provider-model')),
      'gpt-4.1-mini',
    );
    await tester.enterText(
      find.byKey(const Key('provider-api-key')),
      'ui-only-test-value',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-provider-settings')));
    await tester.pumpAndSettle();

    expect(settingsGateway.saved.single.apiKey, 'ui-only-test-value');
    expect(find.text('API Key 已安全保存在 Windows 凭据管理器'), findsOneWidget);
    final keyField = tester.widget<TextField>(
      find.byKey(const Key('provider-api-key')),
    );
    expect(keyField.controller!.text, isEmpty);

    await tester.enterText(
      find.byKey(const Key('provider-model')),
      'unsaved-test-model',
    );
    await tester.tap(find.byKey(const Key('test-provider-connection')));
    await tester.pumpAndSettle();
    expect(find.text('连接成功，栖语可以使用这个模型。'), findsOneWidget);
    expect(settingsGateway.tested.single.model, 'unsaved-test-model');
  });
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
