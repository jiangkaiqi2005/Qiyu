import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

void main() {
  test(
    'bootstraps CSRF, restores a session, and sends through the local API',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return switch (request.url.path) {
          '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
          '/api/chat/session' => _jsonResponse({
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
        };
      });
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
      expect(
        requests.where((request) => request.url.path == '/api/bootstrap'),
        hasLength(1),
      );
      final sendRequest = requests.last;
      expect(sendRequest.headers['x-qiyu-csrf'], 'csrf-1');
      expect(jsonDecode(sendRequest.body), {
        'requestId': 'new-1',
        'text': '在吗',
        'sessionId': 'session-1',
      });
    },
  );

  test('surfaces the local API error message', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/bootstrap') {
        return _jsonResponse({'csrfToken': 'csrf-1'}, 200);
      }
      return _jsonResponse({'message': '无法保存本地聊天记录，请检查磁盘空间和目录权限。'}, 500);
    });
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
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/chat/speak' => http.Response.bytes(
          [1, 2, 3],
          200,
          headers: const {'content-type': 'audio/mpeg'},
        ),
        _ => _jsonResponse({'message': 'not found'}, 404),
      };
    });
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
    expect(sent.headers['x-qiyu-csrf'], 'csrf-1');
    expect(jsonDecode(sent.body), {
      'requestId': 'r1',
      'deliveryIndex': 1,
      'sessionId': 's1',
    });
  });

  test('speak：服务端错误回人话异常', () async {
    final client = MockClient((request) async {
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/chat/speak' => _jsonResponse({
          'code': 'tts_turn_not_found',
          'message': '找不到这句话，请刷新后重试。',
          'retryable': false,
        }, 400),
        _ => _jsonResponse({'message': 'not found'}, 404),
      };
    });
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
}

http.Response _streamResponse(List<Map<String, Object?>> events) {
  final body = '${events.map(jsonEncode).join('\n')}\n';
  return http.Response.bytes(
    utf8.encode(body),
    200,
    headers: const {'content-type': 'application/x-ndjson; charset=utf-8'},
  );
}

http.Response _jsonResponse(Map<String, Object?> body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
