import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/features/baseline/background_status_client.dart';

import 'support/host_transport.dart';

void main() {
  test('读取后台失败状态：只含平实任务名、时刻、次数与是否已恢复', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/memory/cadence-status' => hostJsonResponse({
          'task': '日终归档',
          'failedAt': '2026-09-07T23:10:05.000',
          'count': 2,
          'recovered': false,
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );

    final status = await HttpBackgroundStatusGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    final statusRequest = requests.singleWhere(
      (request) => request.url.path == '/api/memory/cadence-status',
    );
    expect(statusRequest.method, 'GET');
    expect(status, isNotNull);
    expect(status!.task, '日终归档');
    expect(status.failedAt, DateTime(2026, 9, 7, 23, 10, 5));
    expect(status.count, 2);
    expect(status.recovered, isFalse);
  });

  test('无失败时宿主安静返回，解析为 null', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/memory/cadence-status' => hostJsonResponse({
          'task': null,
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final status = await HttpBackgroundStatusGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(status, isNull);
  });

  test('快照按值比较：重复取到相同状态不触发多余通知', () {
    final first = BackgroundFailureStatus.fromJson({
      'task': '梦境整理',
      'failedAt': '2026-09-07T22:00:00.000',
      'count': 1,
      'recovered': false,
    });
    final second = BackgroundFailureStatus.fromJson({
      'task': '梦境整理',
      'failedAt': '2026-09-07T22:00:00.000',
      'count': 1,
      'recovered': false,
    });

    expect(first, equals(second));
    expect(first.hashCode, second.hashCode);
  });
}
