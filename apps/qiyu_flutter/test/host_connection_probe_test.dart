import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports the local host as available only for a successful health check', (
    ) async {
    final availableProbe = HttpHostConnectionProbe(
      client: MockClient((_) async => http.Response('{"status":"ok"}', 200)),
      healthUri: Uri.parse('http://127.0.0.1:54321/api/health'),
    );
    final stoppedProbe = HttpHostConnectionProbe(
      client: MockClient((_) async => http.Response('invalid session', 401)),
      healthUri: Uri.parse('http://127.0.0.1:54321/api/health'),
    );

    expect(await availableProbe.isHostAvailable(), isTrue);
    expect(await stoppedProbe.isHostAvailable(), isFalse);
  });

  test('reports the local host as stopped when the request fails', () async {
    final probe = HttpHostConnectionProbe(
      client: MockClient((_) async => throw Exception('connection closed')),
      healthUri: Uri.parse('http://127.0.0.1:54321/api/health'),
    );

    expect(await probe.isHostAvailable(), isFalse);
  });
}
