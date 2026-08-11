import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
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
}

final class _FakeLocalChatGateway implements LocalChatGateway {
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
  Future<LocalChatExchange> send({
    required String requestId,
    required String text,
    String? sessionId,
  }) async {
    sentTexts.add(text);
    sentRequestIds.add(requestId);
    if (sendError case final error? when failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw error;
    }
    return LocalChatExchange(
      sessionId: restored.sessionId,
      requestId: requestId,
      messages: const ['咋了'],
      source: ReplySource.local,
      fallbackReason: FallbackReason.noLlmConfig,
    );
  }
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
