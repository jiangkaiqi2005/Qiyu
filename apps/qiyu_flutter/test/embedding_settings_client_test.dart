import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/features/settings/embedding_settings_client.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';

import 'support/host_transport.dart';

void main() {
  test('读取只回 configured/keySet 与地址模型，不存在明文 Key 字段', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/embedding' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://embedding.example.com/v1',
          'model': 'text-embedding-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpEmbeddingSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.configured, isTrue);
    expect(settings.keySet, isTrue);
    expect(settings.baseUrl, 'https://embedding.example.com/v1');
    expect(settings.model, 'text-embedding-test');
  });

  test('保存、连接测试与忘记 Key 使用固定接口和 CSRF；空白保存不带 apiKey', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/embedding' => hostJsonResponse({
          'configured': true,
          'keySet': true,
        }, 200),
        '/api/provider/embedding/test' => hostJsonResponse({
          'ok': true,
          'status': 'success',
          'message': '连接成功，记忆召回服务可以使用。',
        }, 200),
        '/api/provider/embedding/key' => hostJsonResponse({
          'configured': true,
          'keySet': false,
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
    final gateway = HttpEmbeddingSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    await gateway.save(
      const EmbeddingSettingsDraft(
        baseUrl: 'https://embedding.example.com/v1',
        model: 'text-embedding-test',
        apiKey: 'temporary-key',
      ),
    );
    final saveWithKey = requests.last;
    expect(saveWithKey.method, 'PUT');
    expect(saveWithKey.url.path, '/api/provider/embedding');
    expectCsrfHeader(saveWithKey);
    expect(
      jsonDecode(saveWithKey.body),
      {
        'baseUrl': 'https://embedding.example.com/v1',
        'model': 'text-embedding-test',
        'apiKey': 'temporary-key',
      },
    );

    // 留空 Key 的保存不发送 apiKey 字段：沿用与否由 Host 凭据作用域裁定。
    await gateway.save(
      const EmbeddingSettingsDraft(
        baseUrl: 'https://embedding.example.com/v1',
        model: 'text-embedding-test',
      ),
    );
    final saveWithoutKey = jsonDecode(requests.last.body) as Map<String, Object?>;
    expect(saveWithoutKey.containsKey('apiKey'), isFalse);

    final result = await gateway.testConnection(
      const EmbeddingSettingsDraft(
        baseUrl: 'https://embedding.example.com/v1',
        model: 'text-embedding-test',
      ),
    );
    expect(result, isA<ProviderTestResult>());
    final testRequest = requests.last;
    expect(testRequest.method, 'POST');
    expect(testRequest.url.path, '/api/provider/embedding/test');
    expectCsrfHeader(testRequest);

    final forgotten = await gateway.forgetApiKey();
    expect(forgotten.keySet, isFalse);
    final forgetRequest = requests.last;
    expect(forgetRequest.method, 'DELETE');
    expect(forgetRequest.url.path, '/api/provider/embedding/key');
    expectCsrfHeader(forgetRequest);
  });

  test('ViewModel 把测试失败转换成人话错误并区分成功结果', () async {
    final viewModel = EmbeddingSettingsViewModel(
      _FailingEmbeddingSettingsGateway(),
      autoStart: false,
    );
    await viewModel.initialize();

    await viewModel.testConnection(
      const EmbeddingSettingsDraft(
        baseUrl: 'https://embedding.example.com/v1',
        model: 'text-embedding-test',
      ),
    );

    expect(viewModel.testResult, isNull);
    expect(viewModel.testing, isFalse);
    expect(viewModel.errorMessage, '记忆召回设置暂时不可用，请稍后重试。');

    await viewModel.save(
      const EmbeddingSettingsDraft(
        baseUrl: 'https://embedding.example.com/v1',
        model: 'text-embedding-test',
      ),
    );
    // 保存失败保留原状态（initialize 读到的未配置快照），错误位人话。
    expect(viewModel.settings?.keySet, isFalse);
    expect(viewModel.settings?.configured, isFalse);
    expect(viewModel.errorMessage, '记忆召回设置暂时不可用，请稍后重试。');
  });
}

final class _FailingEmbeddingSettingsGateway
    implements EmbeddingSettingsGateway {
  @override
  Future<EmbeddingSettings> read() async =>
      const EmbeddingSettings(configured: false, keySet: false);

  @override
  Future<EmbeddingSettings> save(EmbeddingSettingsDraft draft) =>
      throw StateError('raw backend details');

  @override
  Future<EmbeddingSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(EmbeddingSettingsDraft draft) =>
      throw StateError('raw backend details');
}
