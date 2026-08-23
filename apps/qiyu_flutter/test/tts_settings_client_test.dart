import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';

void main() {
  test('读取设置：configured/keySet/音色/语速/开关，永不携带明文 Key', () async {
    final client = MockClient(
      (request) async => switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/tts' => _jsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'openai_compatible',
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
          'voice': 'nova',
          'speed': 1.25,
          'autoSpeak': false,
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.configured, isTrue);
    expect(settings.keySet, isTrue);
    expect(settings.baseUrl, 'https://tts.example.com/v1');
    expect(settings.model, 'tts-test');
    expect(settings.provider, TtsServiceKind.openAiCompatible);
    expect(settings.voice, 'nova');
    expect(settings.speed, 1.25);
    expect(settings.autoSpeak, isFalse);
  });

  test('缺省字段：不带 voice/speed/autoSpeak 的快照按默认呈现', () async {
    final client = MockClient(
      (request) async => switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/tts' => _jsonResponse({
          'configured': true,
          'keySet': false,
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.voice, isNull);
    expect(settings.speed, isNull);
    expect(settings.autoSpeak, isTrue);
  });

  test('豆包协议：provider 往返一致，保存请求带 volc_tts', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/tts' => _jsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'volc_tts',
          'baseUrl':
              'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
          'model': 'seed-tts-2.0',
        }, 200),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final settings = await gateway.read();
    expect(settings.provider, TtsServiceKind.volcTts);

    final saved = await gateway.save(
      const TtsSettingsDraft(
        provider: TtsServiceKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        apiKey: 'ark-test-value',
      ),
    );
    expect(saved.provider, TtsServiceKind.volcTts);
    expect(jsonDecode(requests.last.body)['provider'], 'volc_tts');
  });

  test('保存与忘记 Key 都带 CSRF 头且请求体形状正确', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/tts' => _jsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
        }, 200),
        '/api/provider/tts/key' => _jsonResponse({
          'configured': true,
          'keySet': false,
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
        }, 200),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final saved = await gateway.save(
      const TtsSettingsDraft(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
        apiKey: 'tts-temporary-value',
        voice: 'nova',
        speed: 1.5,
      ),
    );
    expect(saved.keySet, isTrue);
    final saveRequest = requests.last;
    expect(saveRequest.method, 'PUT');
    expect(saveRequest.headers['x-qiyu-csrf'], 'csrf-1');
    expect(jsonDecode(saveRequest.body), {
      'provider': 'openai_compatible',
      'baseUrl': 'https://tts.example.com/v1',
      'model': 'tts-test',
      'apiKey': 'tts-temporary-value',
      'voice': 'nova',
      'speed': 1.5,
    });

    final forgotten = await gateway.forgetApiKey();
    expect(forgotten.keySet, isFalse);
    final forgetRequest = requests.last;
    expect(forgetRequest.method, 'DELETE');
    expect(forgetRequest.url.path, '/api/provider/tts/key');
    expect(forgetRequest.headers['x-qiyu-csrf'], 'csrf-1');
  });

  test('连接测试：成功带回试听音频，失败只回文案', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/tts/test' => _jsonResponse({
          'ok': true,
          'status': 'success',
          'message': '连接成功，点「听试听」可以听听栖语的声音。',
          'audioBase64': base64Encode([1, 2, 3]),
        }, 200),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    const draft = TtsSettingsDraft(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
      apiKey: 'new-test-value',
    );
    final result = await gateway.testConnection(draft);

    expect(result.succeeded, isTrue);
    expect(result.audio, [1, 2, 3]);
    expect(jsonDecode(requests.last.body), draft.toJson());

    final failedClient = MockClient(
      (request) async => switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/tts/test' => _jsonResponse({
          'ok': false,
          'status': 'authentication',
          'message': 'API Key 没有通过验证。',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );
    final failed = await HttpTtsSettingsGateway(
      client: failedClient,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).testConnection(draft);
    expect(failed.succeeded, isFalse);
    expect(failed.audio, isNull);
    expect(failed.message, 'API Key 没有通过验证。');
  });

  test('setAutoSpeak：独立端点、带 CSRF、只传 enabled', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/tts/auto-speak' => _jsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
          'autoSpeak': false,
        }, 200),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final settings = await gateway.setAutoSpeak(false);
    expect(settings.autoSpeak, isFalse);
    final sent = requests.last;
    expect(sent.method, 'PUT');
    expect(sent.url.path, '/api/provider/tts/auto-speak');
    expect(sent.headers['x-qiyu-csrf'], 'csrf-1');
    expect(jsonDecode(sent.body), {'enabled': false});
  });
}

http.Response _jsonResponse(Map<String, Object?> body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
