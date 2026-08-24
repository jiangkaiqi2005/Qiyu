import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_client.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_view_model.dart';

void main() {
  test('读取只消费 configured/keySet，不存在明文 Key 字段', () async {
    final client = MockClient(
      (request) async => switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/web-search' => _jsonResponse({
          'configured': true,
          'keySet': true,
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpWebSearchSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.configured, isTrue);
    expect(settings.keySet, isTrue);
  });

  test('保存与忘记 Key 使用固定接口和 CSRF，空白保存不发送 apiKey', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/web-search' => _jsonResponse({
          'configured': true,
          'keySet': true,
        }, 200),
        '/api/provider/web-search/key' => _jsonResponse({
          'configured': false,
          'keySet': false,
        }, 200),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpWebSearchSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    await gateway.save(const WebSearchSettingsDraft(apiKey: 'temporary-key'));
    final saveWithKey = requests.last;
    expect(saveWithKey.method, 'PUT');
    expect(saveWithKey.url.path, '/api/provider/web-search');
    expect(saveWithKey.headers['x-qiyu-csrf'], 'csrf-1');
    expect(jsonDecode(saveWithKey.body), {'apiKey': 'temporary-key'});

    await gateway.save(const WebSearchSettingsDraft());
    expect(jsonDecode(requests.last.body), <String, Object?>{});

    final forgotten = await gateway.forgetApiKey();
    expect(forgotten.configured, isFalse);
    final forgetRequest = requests.last;
    expect(forgetRequest.method, 'DELETE');
    expect(forgetRequest.url.path, '/api/provider/web-search/key');
    expect(forgetRequest.headers['x-qiyu-csrf'], 'csrf-1');
  });

  test('ViewModel 把保存失败转换成人话错误并保留原状态', () async {
    final viewModel = WebSearchSettingsViewModel(
      _FailingWebSearchSettingsGateway(),
      autoStart: false,
    );
    await viewModel.initialize();

    final saved = await viewModel.save(
      const WebSearchSettingsDraft(apiKey: 'temporary-key'),
    );

    expect(saved, isFalse);
    expect(viewModel.settings?.keySet, isFalse);
    expect(viewModel.errorMessage, '联网搜索设置暂时不可用，请稍后重试。');
  });
}

final class _FailingWebSearchSettingsGateway
    implements WebSearchSettingsGateway {
  @override
  Future<WebSearchSettings> read() async =>
      const WebSearchSettings(configured: false, keySet: false);

  @override
  Future<WebSearchSettings> save(WebSearchSettingsDraft draft) =>
      throw StateError('raw backend details');

  @override
  Future<WebSearchSettings> forgetApiKey() => throw UnimplementedError();
}

http.Response _jsonResponse(Map<String, Object?> body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
