import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';

import 'support/host_transport.dart';

void main() {
  test('读取设置：configured/keySet/音色/语速/开关，永不携带明文 Key', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
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
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
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
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'volc_tts',
          'baseUrl':
              'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
          'model': 'seed-tts-2.0',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
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

  test('传输方式（票三）：豆包档快照回显与草稿上送，缺省 http_chunk', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'volc_tts',
          'baseUrl':
              'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
          'model': 'seed-tts-2.0',
          'transport': 'ws_bidirection',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final settings = await gateway.read();
    expect(settings.transport, TtsTransport.wsBidirection);

    await gateway.save(
      const TtsSettingsDraft(
        provider: TtsServiceKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        apiKey: 'ark-test-value',
        transport: TtsTransport.wsBidirection,
      ),
    );
    expect(jsonDecode(requests.last.body)['transport'], 'ws_bidirection');

    // 非豆包档草稿不上送传输方式（Host 侧归一为缺省 HTTP 分块）。
    await gateway.save(
      const TtsSettingsDraft(
        provider: TtsServiceKind.qwenTts,
        baseUrl: qwenTtsDefaultEndpoint,
        model: qwenTtsDefaultModel,
        transport: TtsTransport.wsBidirection,
      ),
    );
    expect(
      jsonDecode(requests.last.body).containsKey('transport'),
      isFalse,
    );
  });

  test('传输方式缺省字段：不带的快照按 http_chunk 呈现', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'volc_tts',
          'baseUrl':
              'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
          'model': 'seed-tts-2.0',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.transport, TtsTransport.httpChunk);
  });

  test('千问协议：provider 往返一致，保存请求带 qwen_tts', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'qwen_tts',
          'baseUrl': qwenTtsDefaultEndpoint,
          'model': qwenTtsDefaultModel,
          'voice': 'Cherry',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final settings = await gateway.read();
    expect(settings.provider, TtsServiceKind.qwenTts);
    expect(settings.baseUrl, qwenTtsDefaultEndpoint);
    expect(settings.voice, 'Cherry');

    final saved = await gateway.save(
      const TtsSettingsDraft(
        provider: TtsServiceKind.qwenTts,
        baseUrl: qwenTtsDefaultEndpoint,
        model: qwenTtsDefaultModel,
        apiKey: 'sk-dashscope-test-value',
        voice: 'Nofish',
      ),
    );
    expect(saved.provider, TtsServiceKind.qwenTts);
    expect(jsonDecode(requests.last.body)['provider'], 'qwen_tts');
  });

  test('保存与忘记 Key 都带 CSRF 头且请求体形状正确', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
        }, 200),
        '/api/provider/tts/key' => hostJsonResponse({
          'configured': true,
          'keySet': false,
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
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
    expectCsrfHeader(saveRequest);
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
    expectCsrfHeader(forgetRequest);
  });

  test('连接测试：成功带回试听音频，失败只回文案', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts/test' => hostJsonResponse({
          'ok': true,
          'status': 'success',
          'message': '连接成功，点「听试听」可以听听栖语的声音。',
          'audioBase64': base64Encode([1, 2, 3]),
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
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

    final failedClient = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts/test' => hostJsonResponse({
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
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts/auto-speak' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
          'autoSpeak': false,
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final settings = await gateway.setAutoSpeak(false);
    expect(settings.autoSpeak, isFalse);
    final sent = requests.last;
    expect(sent.method, 'PUT');
    expect(sent.url.path, '/api/provider/tts/auto-speak');
    expectCsrfHeader(sent);
    expect(jsonDecode(sent.body), {'enabled': false});
  });

  test('extraParams：读取与保存往返正确，请求携带 JSON 对象', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'volc_tts',
          'baseUrl':
              'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
          'model': 'seed-tts-2.0',
          'extraParams': {
            'audio_params': {'sample_rate': 16000},
            'additions': {'explicit_dialect': 'sichuan'},
          },
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final read = await gateway.read();
    expect(read.extraParams, {
      'audio_params': {'sample_rate': 16000},
      'additions': {'explicit_dialect': 'sichuan'},
    });

    final saved = await gateway.save(
      const TtsSettingsDraft(
        provider: TtsServiceKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        extraParams: {
          'audio_params': {'sample_rate': 16000},
        },
      ),
    );
    expect(saved.extraParams, isNotNull);
    final saveBody = jsonDecode(requests.last.body) as Map<String, Object?>;
    expect(saveBody['extraParams'], {
      'audio_params': {'sample_rate': 16000},
    });
  });

  test('自定义协议：读取回显旋钮，保存请求带 custom 与三个旋钮', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'custom',
          'baseUrl': 'https://tts.example.com/v1/audio/speech',
          'model': 'tts-test',
          'authHeader': 'X-Api-Key',
          'responseShape': 'json_lines',
          'responseField': 'result.audio',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final settings = await gateway.read();
    expect(settings.provider, TtsServiceKind.custom);
    expect(settings.authHeader, 'X-Api-Key');
    expect(settings.responseShape, TtsResponseShape.jsonLines);
    expect(settings.responseField, 'result.audio');

    final saved = await gateway.save(
      const TtsSettingsDraft(
        provider: TtsServiceKind.custom,
        baseUrl: 'https://tts.example.com/v1/audio/speech',
        model: 'tts-test',
        apiKey: 'sk-custom-test-value',
        authHeader: 'Authorization: Bearer',
        responseShape: TtsResponseShape.jsonField,
        responseField: 'data',
      ),
    );
    expect(saved.provider, TtsServiceKind.custom);
    final saveBody = jsonDecode(requests.last.body) as Map<String, Object?>;
    expect(saveBody['provider'], 'custom');
    expect(saveBody['authHeader'], 'Authorization: Bearer');
    expect(saveBody['responseShape'], 'json_field');
    expect(saveBody['responseField'], 'data');
  });

  test('自定义协议缺省字段：不带旋钮的快照按缺省形态呈现', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': false,
          'provider': 'custom',
          'baseUrl': 'https://tts.example.com/v1/audio/speech',
          'model': 'tts-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    // 缺省行为等价于 Authorization: Bearer、裸音频字节形态与字段 data。
    expect(settings.authHeader, isNull);
    expect(settings.responseShape, TtsResponseShape.rawBytes);
    expect(settings.responseField, isNull);
  });

  test('非自定义档草稿不携带自定义旋钮', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://tts.example.com/v1',
          'model': 'tts-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
    final gateway = HttpTtsSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    await gateway.save(
      const TtsSettingsDraft(
        provider: TtsServiceKind.qwenTts,
        baseUrl: qwenTtsDefaultEndpoint,
        model: qwenTtsDefaultModel,
        authHeader: 'X-Api-Key',
        responseShape: TtsResponseShape.jsonField,
        responseField: 'result.audio',
      ),
    );

    final saveBody = jsonDecode(requests.last.body) as Map<String, Object?>;
    expect(saveBody.containsKey('authHeader'), isFalse);
    expect(saveBody.containsKey('responseShape'), isFalse);
    expect(saveBody.containsKey('responseField'), isFalse);
  });
}
