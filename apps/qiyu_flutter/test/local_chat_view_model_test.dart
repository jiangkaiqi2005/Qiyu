import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

void main() {
  test(
    'a submitted user message is visible before the host accepts it',
    () async {
      final gateway = _GatedGateway();
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: _AvailableProbe(),
        requestIdFactory: () => 'pending-request',
        autoStart: false,
      );
      addTearDown(() {
        gateway.release();
        viewModel.dispose();
      });

      final send = viewModel.send('这条先显示');
      await Future<void>.delayed(Duration.zero);

      expect(viewModel.messages, hasLength(1));
      expect(viewModel.messages.single.speaker, LocalChatSpeaker.user);
      expect(viewModel.messages.single.text, '这条先显示');

      gateway.release();
      expect(await send, isTrue);
    },
  );

  test(
    'a recall bubble 2 on the same stream is committed as a second message',
    () async {
      final gateway = _TwoBubbleGateway();
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: _AvailableProbe(),
        requestIdFactory: () => 'request-1',
        autoStart: false,
      );

      final sent = await viewModel.send('我上次说爬山的事');

      expect(sent, isTrue);
      final qiyuMessages = viewModel.messages
          .where((message) => message.speaker == LocalChatSpeaker.qiyu)
          .toList();
      expect(qiyuMessages, hasLength(2));
      expect(qiyuMessages.first.text, '一时没想起。');
      expect(qiyuMessages.last.text, '对了，你周末是要去爬山来着。');
      // 两段都属于同一用户轮。
      expect(qiyuMessages.map((message) => message.requestId), [
        'request-1',
        'request-1',
      ]);
      expect(viewModel.streamingText, isEmpty);
      viewModel.dispose();
    },
  );

  test('a single-bubble stream still commits exactly one message', () async {
    final gateway = _TwoBubbleGateway(withBubble2: false);
    final viewModel = LocalChatViewModel(
      gateway,
      hostConnectionProbe: _AvailableProbe(),
      requestIdFactory: () => 'request-2',
      autoStart: false,
    );

    final sent = await viewModel.send('在吗');

    expect(sent, isTrue);
    final qiyuMessages = viewModel.messages
        .where((message) => message.speaker == LocalChatSpeaker.qiyu)
        .toList();
    expect(qiyuMessages, hasLength(1));
    expect(qiyuMessages.single.text, '在。');
    viewModel.dispose();
  });
}

final class _TwoBubbleGateway implements StreamingLocalChatGateway {
  _TwoBubbleGateway({this.withBubble2 = true});

  final bool withBubble2;

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      sessionId: 'session-1',
      text: withBubble2 ? '一时没想起。' : '在。',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      sessionId: 'session-1',
      messages: [withBubble2 ? '一时没想起。' : '在。'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
      sessionId: 'session-1',
    );
    if (!withBubble2) {
      return;
    }
    // 轮内召回命中：同一 requestId 的第二段交付。
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      sessionId: 'session-1',
      text: '对了，你周末是要去爬山来着。',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      sessionId: 'session-1',
      messages: ['对了，你周末是要去爬山来着。'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
      sessionId: 'session-1',
    );
  }

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);
}

final class _GatedGateway implements StreamingLocalChatGateway {
  final _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    await _gate.future;
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      sessionId: 'session-1',
      messages: const ['看见了。'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      sessionId: 'session-1',
      source: ReplySource.llm,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
      sessionId: 'session-1',
    );
  }

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);
}

final class _AvailableProbe implements HostConnectionProbe {
  @override
  Future<bool> isHostAvailable() async => true;
}
