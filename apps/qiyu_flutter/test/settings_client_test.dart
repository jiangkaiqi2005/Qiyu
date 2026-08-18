import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';

void main() {
  group('HttpSettingsGateway', () {
    HttpSettingsGateway gatewayFor(
      List<http.Request> requests,
      http.Response Function(http.Request) respond,
    ) {
      final client = MockClient((request) async {
        requests.add(request);
        return respond(request);
      });
      return HttpSettingsGateway(
        client: client,
        baseUri: Uri.parse('http://127.0.0.1:5173/'),
      );
    }

    test('reads experience preferences', () async {
      final requests = <http.Request>[];
      final gateway = gatewayFor(requests, (request) => switch (
        request.url.path
      ) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/preferences' => _jsonResponse({'developerMode': true}, 200),
        _ => http.Response('not found', 404),
      });

      final preferences = await gateway.readPreferences();

      expect(preferences.developerMode, isTrue);
      expect(requests.last.method, 'GET');
    });

    test('saves developer mode with CSRF header', () async {
      final requests = <http.Request>[];
      final gateway = gatewayFor(requests, (request) => switch (
        request.url.path
      ) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/preferences' => _jsonResponse({'developerMode': true}, 200),
        _ => http.Response('not found', 404),
      });

      final preferences = await gateway.savePreferences(developerMode: true);

      expect(preferences.developerMode, isTrue);
      final save = requests.last;
      expect(save.method, 'PUT');
      expect(save.headers['x-qiyu-csrf'], 'csrf-1');
      expect(jsonDecode(save.body), {'developerMode': true});
    });

    test('reads the memory controls overview', () async {
      final requests = <http.Request>[];
      final gateway = gatewayFor(requests, (request) => switch (
        request.url.path
      ) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/memory/controls' => _jsonResponse({
          'readable': true,
          'frozen': [
            {'id': 1, 'origin': 'chat', 'summary': '一段冻结的记忆'},
          ],
          'banned': [
            {'id': 2, 'origin': 'chat', 'summary': '一段禁提的往事'},
          ],
          'deletedCount': 3,
        }, 200),
        _ => http.Response('not found', 404),
      });

      final overview = await gateway.readMemoryControls();

      expect(overview.readable, isTrue);
      expect(overview.frozen.single.summary, '一段冻结的记忆');
      expect(overview.banned.single.summary, '一段禁提的往事');
      expect(overview.deletedCount, 3);
    });

    test('clear preview exposes data location and counts', () async {
      final requests = <http.Request>[];
      final gateway = gatewayFor(requests, (request) => switch (
        request.url.path
      ) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/data/clear-preview' => _jsonResponse({
          'memoryDirectory': 'C:/qiyu/memories',
          'sessionCount': 4,
          'episodeDayCount': 9,
          'frozenCount': 1,
          'bannedCount': 2,
          'deletedCount': 0,
          'snapshotCount': 1,
          'providerConfigured': true,
          'keySet': true,
        }, 200),
        _ => http.Response('not found', 404),
      });

      final preview = await gateway.readClearPreview();

      expect(preview.memoryDirectory, 'C:/qiyu/memories');
      expect(preview.sessionCount, 4);
      expect(preview.episodeDayCount, 9);
      expect(preview.snapshotCount, 1);
      expect(preview.providerConfigured, isTrue);
      expect(preview.keySet, isTrue);
    });

    test('clear data sends an explicit confirmation', () async {
      final requests = <http.Request>[];
      final gateway = gatewayFor(requests, (request) => switch (
        request.url.path
      ) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/data/clear' => _jsonResponse({'cleared': true}, 200),
        _ => http.Response('not found', 404),
      });

      await gateway.clearData();

      final clear = requests.last;
      expect(clear.method, 'POST');
      expect(clear.headers['x-qiyu-csrf'], 'csrf-1');
      expect(jsonDecode(clear.body), {'confirm': true});
    });

    test('parses the developer diagnostics snapshot', () async {
      final requests = <http.Request>[];
      final gateway = gatewayFor(requests, (request) => switch (
        request.url.path
      ) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/dev/diagnostics' => _jsonResponse({
          'generatedAt': '2026-08-19T14:00:00.000Z',
          'memoryDirectory': 'C:/qiyu/memories',
          'recentRequests': [
            {
              'at': '2026-08-19T13:59:00.000Z',
              'source': 'chat',
              'result': 'fallback',
              'replySource': 'local',
              'fallbackReason': 'model_timeout',
            },
          ],
          'finalization': {
            'today': '2026-08-19',
            'todayFinalized': false,
            'pendingDays': 2,
            'unreadableDays': 0,
          },
          'dream': {
            'lastSuccessAt': '2026-08-11T16:00:00.000Z',
            'daysSinceLastSuccess': 8,
            'pending': false,
            'minIntervalDays': 7,
            'intervalSatisfied': true,
            'providerConfigured': true,
            'eligible': true,
          },
          'fileHealth': {'episodeDays': 9},
        }, 200),
        _ => http.Response('not found', 404),
      });

      final snapshot = await gateway.readDiagnostics();

      expect(snapshot.memoryDirectory, 'C:/qiyu/memories');
      expect(snapshot.recentRequests.single.source, 'chat');
      expect(snapshot.recentRequests.single.result, 'fallback');
      expect(snapshot.recentRequests.single.fallbackReason, 'model_timeout');
      expect(snapshot.finalization!.pendingDays, 2);
      expect(snapshot.dream!.eligible, isTrue);
      expect(snapshot.fileHealth['episodeDays'], 9);
    });

    test('surfaces a readable error when the host rejects a request', () async {
      final gateway = gatewayFor(<http.Request>[], (request) => switch (
        request.url.path
      ) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/data/clear' => _jsonResponse({
          'code': 'invalid_request',
          'message': '清除本机数据需要明确确认。',
          'retryable': false,
        }, 400),
        _ => http.Response('not found', 404),
      });

      await expectLater(
        gateway.clearData(),
        throwsA(
          isA<SettingsException>().having(
            (error) => error.message,
            'message',
            '清除本机数据需要明确确认。',
          ),
        ),
      );
    });
  });
}

http.Response _jsonResponse(Map<String, Object?> body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
