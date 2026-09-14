import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';

import '../../../packages/qiyu_local_host/test/support/in_process_chat_host.dart';
import 'support/host_transport.dart';

void main() {
  test('真实 Host 普通回复与重放由 Flutter 网关完整解析', () async {
    final model = ScriptedModelGateway(
      streamScript: [const ScriptedStreamReply('在。')],
    );
    final host = await InProcessChatHost.start(modelGateway: model);
    addTearDown(host.dispose);
    final first = await host.sendChat(requestId: 'normal', text: '在吗');
    final events = await _parse(first);
    expect(
      events
          .where((e) => e.kind == ChatDeliveryEventKind.message)
          .single
          .messages,
      ['在。'],
    );
    expect(
      events.where((e) => e.kind == ChatDeliveryEventKind.state).single.source,
      ReplySource.llm,
    );
    final replay = await host.sendChat(
      requestId: 'normal',
      text: '在吗',
      sessionId: first.sessionId,
    );
    expect((await _parse(replay)).last.kind, ChatDeliveryEventKind.done);
    expect(model.streamCalls, hasLength(1));
  });

  test('真实 Host 本地降级与安全回复由 Flutter 网关完整解析', () async {
    final host = await InProcessChatHost.start();
    addTearDown(host.dispose);
    final local = await _parse(
      await host.sendChat(requestId: 'local', text: '在吗'),
    );
    expect(
      local.where((e) => e.kind == ChatDeliveryEventKind.state).single.source,
      ReplySource.local,
    );
    expect(
      local
          .where((e) => e.kind == ChatDeliveryEventKind.fallback)
          .single
          .fallbackReason,
      FallbackReason.noLlmConfig,
    );
    final safety = await _parse(
      await host.sendChat(requestId: 'safety', text: '我想自杀'),
    );
    expect(
      safety
          .where((e) => e.kind == ChatDeliveryEventKind.state)
          .single
          .fallbackReason,
      FallbackReason.safety,
    );
    expect(safety.last.kind, ChatDeliveryEventKind.done);
  });

  test('真实 Host 取消事件由 Flutter 网关解析且没有完成段', () async {
    final model = ScriptedModelGateway(
      streamScript: [const ScriptedLiveStream()],
    );
    final host = await InProcessChatHost.start(modelGateway: model);
    addTearDown(host.dispose);
    final pending = host.sendChat(requestId: 'cancel', text: '在吗');
    await model.awaitStreamOpened();
    expect(await host.cancelChat('cancel'), isTrue);
    final events = await _parse(await pending);
    expect(events.last.kind, ChatDeliveryEventKind.cancelled);
    expect(events.where((e) => e.kind == ChatDeliveryEventKind.done), isEmpty);
  });
}

Future<List<LocalChatDeliveryEvent>> _parse(ChatEventTrace trace) async {
  final gateway = HttpLocalChatGateway(
    client: hostTransportClient(
      (_) => http.Response(
        trace.body,
        trace.statusCode,
        headers: {'content-type': 'application/x-ndjson; charset=utf-8'},
      ),
    ),
    baseUri: Uri.parse('http://127.0.0.1:5173/'),
  );
  final events = await gateway
      .deliver(requestId: 'parser', text: '在吗')
      .toList();
  expect(
    events.map((e) => e.toJson()).toList(),
    trace.events.map((e) => e.toJson()).toList(),
  );
  return events;
}
