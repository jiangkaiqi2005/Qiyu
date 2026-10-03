import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';

import 'support/host_transport.dart';

void main() {
  test('启动偏好读取兼容旧快照且保存自动方式经原有受保护设置入口', () async {
    expect(
      ProviderSettings.fromJson({
        'configured': false,
        'keySet': false,
      }).callStartupMode,
      CallStartupMode.manual,
    );
    final requests = <http.Request>[];
    final gateway = HttpProviderSettingsGateway(
      client: hostTransportClient(
        (request) => hostJsonResponse({
          'configured': true,
          'keySet': false,
          'provider': 'qwen_omni_realtime',
          'callStartupMode': 'auto_on_chat_entry',
        }, 200),
        requests: requests,
      ),
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );
    final settings = await gateway.save(
      const ProviderSettingsDraft(
        provider: ProviderKind.qwenOmniRealtime,
        baseUrl: 'wss://dashscope.example.com/api-ws/v1/realtime',
        model: 'qwen3.8-omni-flash-realtime',
        temperature: 0.7,
        timeoutSeconds: 30,
        callStartupMode: CallStartupMode.autoOnChatEntry,
      ),
    );
    expect(settings.callStartupMode, CallStartupMode.autoOnChatEntry);
    expect(
      jsonDecode(requests.last.body),
      containsPair('callStartupMode', 'auto_on_chat_entry'),
    );
    expectCsrfHeader(requests.last);
  });

  test('saves Provider settings without ever receiving the API Key', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'anthropic',
          'baseUrl': 'https://api.anthropic.com/v1',
          'model': 'claude-sonnet-4-5',
          'temperature': 0.6,
          'timeoutSeconds': 45,
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
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
    expectCsrfHeader(saveRequest);
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
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/test' => hostJsonResponse({
          'ok': false,
          'status': 'authentication',
          'message': 'API Key 没有通过验证。',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
    final gateway = HttpProviderSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    const draft = ProviderSettingsDraft(
      provider: ProviderKind.openAiCompatible,
      baseUrl: 'https://new.example/v1',
      model: 'new-model',
      temperature: 0.4,
      timeoutSeconds: 20,
      apiKey: 'new-test-value',
    );
    final result = await gateway.testConnection(draft);

    expect(result.status, ProviderTestStatus.authentication);
    expect(result.succeeded, isFalse);
    expect(jsonDecode(requests.last.body), draft.toJson());
  });

  test('parses the model interface mismatch test status', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/test' => hostJsonResponse({
          'ok': false,
          'status': 'modelInterfaceMismatch',
          'message': '这个模型不能用当前服务地址调用，请更换模型或调整服务地址。',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );
    final gateway = HttpProviderSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    const draft = ProviderSettingsDraft(
      provider: ProviderKind.openAiCompatible,
      baseUrl: 'https://new.example/v1',
      model: 'new-model',
      temperature: 0.4,
      timeoutSeconds: 20,
      apiKey: 'new-test-value',
    );
    final result = await gateway.testConnection(draft);

    expect(result.status, ProviderTestStatus.modelInterfaceMismatch);
    expect(result.succeeded, isFalse);
    expect(result.message, '这个模型不能用当前服务地址调用，请更换模型或调整服务地址。');
  });
}
