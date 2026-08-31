import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'support/host_transport.dart';

void main() {
  test(
    'bootstraps CSRF, restores a session, and sends through the local API',
    () async {
      final requests = <http.Request>[];
      final client = hostTransportClient(
        (request) => switch (request.url.path) {
          '/api/chat/session' => hostJsonResponse({
            'sessionId': 'session-1',
            'turns': [
              {
                'requestId': 'old-1',
                'speaker': 'user',
                'text': '旧消息',
                'at': '2026-08-11T12:00:00Z',
              },
            ],
          }, 200),
          '/api/chat' => _streamResponse([
            {
              'event': 'accepted',
              'requestId': 'new-1',
              'sessionId': 'session-1',
            },
            {
              'event': 'waiting',
              'requestId': 'new-1',
              'sessionId': 'session-1',
            },
            {'event': 'delta', 'requestId': 'new-1', 'text': '嗯？'},
            {
              'event': 'message',
              'requestId': 'new-1',
              'messages': ['嗯？'],
            },
            {
              'event': 'state',
              'requestId': 'new-1',
              'source': 'local',
              'fallbackReason': 'no_llm_config',
            },
            {'event': 'done', 'requestId': 'new-1'},
          ]),
          _ => http.Response('not found', 404),
        },
        requests: requests,
      );
      final gateway = HttpLocalChatGateway(
        client: client,
        baseUri: Uri.parse('http://127.0.0.1:5173/'),
      );

      final restored = await gateway.restore(sessionId: 'session-1');
      final exchange = await gateway.send(
        requestId: 'new-1',
        text: '在吗',
        sessionId: restored.sessionId,
      );

      expect(restored.messages.single.text, '旧消息');
      expect(exchange.source, ReplySource.local);
      expectBootstrapRequestedOnce(requests);
      final sendRequest = requests.last;
      expectCsrfHeader(sendRequest);
      expect(jsonDecode(sendRequest.body), {
        'requestId': 'new-1',
        'text': '在吗',
        'sessionId': 'session-1',
      });
    },
  );

  test('surfaces the local API error message', () async {
    final client = hostTransportClient(
      (request) =>
          hostJsonResponse({'message': '无法保存本地聊天记录，请检查磁盘空间和目录权限。'}, 500),
    );
    final gateway = HttpLocalChatGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    await expectLater(
      gateway.restore(),
      throwsA(
        isA<LocalChatGatewayException>().having(
          (error) => error.message,
          'message',
          contains('无法保存'),
        ),
      ),
    );
  });

  test('speak：带 CSRF 的朗读请求与二进制音频响应', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/chat/speak' => http.Response.bytes(
          [1, 2, 3],
          200,
          headers: const {'content-type': 'audio/mpeg'},
        ),
        _ => hostJsonResponse({'message': 'not found'}, 404),
      },
      requests: requests,
    );
    final gateway = HttpLocalChatGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final audio = await gateway.speak(
      requestId: 'r1',
      deliveryIndex: 1,
      sessionId: 's1',
    );
    expect(audio, [1, 2, 3]);
    final sent = requests.last;
    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/chat/speak');
    expectCsrfHeader(sent);
  });

  test('speak：服务端错误回人话异常', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/chat/speak' => hostJsonResponse({
          'code': 'tts_turn_not_found',
          'message': '找不到这句话，请刷新后重试。',
          'retryable': false,
        }, 400),
        _ => hostJsonResponse({'message': 'not found'}, 404),
      },
    );
    final gateway = HttpLocalChatGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    await expectLater(
      gateway.speak(requestId: 'r1', deliveryIndex: 0),
      throwsA(
        isA<LocalChatGatewayException>().having(
          (error) => error.message,
          'message',
          '找不到这句话，请刷新后重试。',
        ),
      ),
    );
  });

  test('speak：按 spec 发送 requestId 与 turnIndex 定位符', () async {
    late Map<String, Object?> payload;
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/chat/speak' => () {
          payload = (jsonDecode(request.body) as Map).cast<String, Object?>();
          return http.Response.bytes([1, 2, 3], 200);
        }(),
        _ => hostJsonResponse({'message': 'not found'}, 404),
      },
    );
    final gateway = HttpLocalChatGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    expect(await gateway.speak(requestId: 'r1', deliveryIndex: 2), [1, 2, 3]);
    expect(payload, {'requestId': 'r1', 'turnIndex': 2});
  });
}

http.Response _streamResponse(List<Map<String, Object?>> events) {
  final body = '${events.map(jsonEncode).join('\n')}\n';
  return http.Response.bytes(
    utf8.encode(body),
    200,
    headers: const {'content-type': 'application/x-ndjson; charset=utf-8'},
  );
}
