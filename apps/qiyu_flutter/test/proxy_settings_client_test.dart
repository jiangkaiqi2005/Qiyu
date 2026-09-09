import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/features/settings/proxy_settings_client.dart';

import 'support/host_transport.dart';

void main() {
  test('读取消费 configured/enabled/host/port，代理配置原样回显', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/proxy' => hostJsonResponse({
          'configured': true,
          'enabled': true,
          'host': '192.168.1.2',
          'port': 7890,
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpProxySettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.configured, isTrue);
    expect(settings.enabled, isTrue);
    expect(settings.host, '192.168.1.2');
    expect(settings.port, 7890);
  });

  test('保存走 PUT 加 CSRF，地址端口原样上送', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/proxy' => hostJsonResponse({
          'configured': true,
          'enabled': true,
          'host': 'proxy.example.com',
          'port': 1080,
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
    final gateway = HttpProxySettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final saved = await gateway.save(
      const ProxySettingsDraft(enabled: true, host: 'proxy.example.com', port: 1080),
    );

    final request = requests.last;
    expect(request.method, 'PUT');
    expect(request.url.path, '/api/provider/proxy');
    expectCsrfHeader(request);
    expect(jsonDecode(request.body), {
      'enabled': true,
      'host': 'proxy.example.com',
      'port': 1080,
    });
    expect(saved.enabled, isTrue);
  });

  test('服务端校验错误透出人话 message', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/proxy' => hostJsonResponse({
          'code': 'invalid_provider_config',
          'message': '请填写代理地址。',
          'retryable': false,
        }, 400),
        _ => http.Response('not found', 404),
      },
    );
    final gateway = HttpProxySettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    await expectLater(
      gateway.save(const ProxySettingsDraft(enabled: true, host: '', port: 7890)),
      throwsA(
        isA<ProxySettingsGatewayException>().having(
          (error) => error.message,
          'message',
          '请填写代理地址。',
        ),
      ),
    );
  });
}
