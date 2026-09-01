import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/features/history/history_client.dart';

import 'support/host_transport.dart';

void main() {
  test(
    'bootstraps CSRF, fetches grouped history, and deletes with headers',
    () async {
      final requests = <http.Request>[];
      final client = hostTransportClient(
        (request) => switch (request.url.path) {
          '/api/history' => hostJsonResponse({
            'latestSessionId': 'session-2',
            'days': [
              {
                'date': '2026-08-12',
                'sessions': [
                  {
                    'sessionId': 'session-2',
                    'segment': 1,
                    'startedAt': '2026-08-12T13:00:00Z',
                    'updatedAt': '2026-08-12T13:05:00Z',
                    'turnCount': 4,
                    'preview': '我到家了',
                  },
                ],
              },
              {
                'date': '2026-08-11',
                'sessions': [
                  {
                    'sessionId': 'session-1',
                    'segment': 1,
                    'startedAt': '2026-08-11T15:00:00Z',
                    'updatedAt': '2026-08-11T15:02:00Z',
                    'turnCount': 2,
                    'preview': '昨晚的话',
                  },
                ],
              },
            ],
            'unavailable': [
              {
                'name': '2026-08-10-001.md',
                'message': '这个会话文件暂时无法读取，不影响其他历史记录。',
              },
            ],
          }, 200),
          '/api/history/sessions/session-1' => hostJsonResponse({
            'deleted': true,
          }, 200),
          _ => http.Response('not found', 404),
        },
        requests: requests,
      );
      final gateway = HttpHistoryGateway(
        client: client,
        baseUri: Uri.parse('http://127.0.0.1:5173/'),
      );

      final listing = await gateway.fetchHistory();

      expect(listing.latestSessionId, 'session-2');
      expect(listing.days.map((day) => day.date), ['2026-08-12', '2026-08-11']);
      expect(listing.days.first.sessions.single.preview, '我到家了');
      expect(listing.days.first.sessions.single.turnCount, 4);
      expect(listing.days.last.sessions.single.sessionId, 'session-1');
      expect(listing.unavailable.single.name, '2026-08-10-001.md');

      await gateway.deleteSession('session-1');

      final deleteRequest = requests.last;
      expect(deleteRequest.method, 'DELETE');
      expect(deleteRequest.url.path, '/api/history/sessions/session-1');
      expectCsrfHeader(deleteRequest);
      expectBootstrapRequestedOnce(requests);
    },
  );

  test(
    'surfaces host error messages when deleting a missing session',
    () async {
      final client = hostTransportClient(
        (request) => hostJsonResponse({'message': '没有找到这段本地会话，可能已经被删除。'}, 404),
      );
      final gateway = HttpHistoryGateway(
        client: client,
        baseUri: Uri.parse('http://127.0.0.1:5173/'),
      );

      await expectLater(
        gateway.deleteSession('missing'),
        throwsA(
          isA<HistoryGatewayException>().having(
            (error) => error.message,
            'message',
            contains('已经被删除'),
          ),
        ),
      );
    },
  );
}
