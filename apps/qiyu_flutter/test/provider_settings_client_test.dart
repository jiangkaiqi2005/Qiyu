import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';

void main() {
  test('saves Provider settings without ever receiving the API Key', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider' => _jsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'anthropic',
          'baseUrl': 'https://api.anthropic.com/v1',
          'model': 'claude-sonnet-4-5',
          'temperature': 0.6,
          'timeoutSeconds': 45,
        }, 200),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpProviderSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final settings = await gateway.save(
      const ProviderSettingsDraft(
        provider: ProviderKind.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
        model: 'claude-sonnet-4-5',
        temperature: 0.6,
        timeoutSeconds: 45,
        apiKey: 'temporary-test-value',
      ),
    );

    expect(settings.keySet, isTrue);
    expect(settings.toString(), isNot(contains('temporary-test-value')));
    final saveRequest = requests.last;
    expect(saveRequest.method, 'PUT');
    expect(saveRequest.headers['x-qiyu-csrf'], 'csrf-1');
    expect(jsonDecode(saveRequest.body), {
      'provider': 'anthropic',
      'baseUrl': 'https://api.anthropic.com/v1',
      'model': 'claude-sonnet-4-5',
      'temperature': 0.6,
      'timeoutSeconds': 45,
      'apiKey': 'temporary-test-value',
    });
  });

  test('distinguishes an authentication test result', () async {
    final client = MockClient((request) async {
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/test' => _jsonResponse({
          'ok': false,
          'status': 'authentication',
          'message': 'API Key 没有通过验证。',
        }, 200),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpProviderSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final result = await gateway.testConnection();

    expect(result.status, ProviderTestStatus.authentication);
    expect(result.succeeded, isFalse);
  });
}

http.Response _jsonResponse(Map<String, Object?> body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
