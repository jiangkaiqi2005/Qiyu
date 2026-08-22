import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';

void main() {
  test('读取设置：configured/keySet/baseUrl/model，永不携带明文 Key', () async {
    final client = MockClient(
      (request) async => switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/stt' => _jsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://stt.example.com/v1',
          'model': 'whisper-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.configured, isTrue);
    expect(settings.keySet, isTrue);
    expect(settings.baseUrl, 'https://stt.example.com/v1');
    expect(settings.model, 'whisper-test');
    expect(settings.provider, SttServiceKind.openaiCompatible);
    expect(settings.wantsWavAudio, isFalse);
  });

  test('读取设置：豆包协议回填 provider 并标记需要 WAV 转换', () async {
    final client = MockClient(
      (request) async => switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/stt' => _jsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'volc_seed_asr',
          'baseUrl':
              'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
          'model': 'volc.seedasr.sauc.duration',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.provider, SttServiceKind.volcSeedAsr);
    expect(settings.wantsWavAudio, isTrue);
  });

  test('保存与忘记 Key 都带 CSRF 头且请求体形状正确', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/stt' => _jsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://stt.example.com/v1',
          'model': 'whisper-test',
        }, 200),
        '/api/provider/stt/key' => _jsonResponse({
          'configured': true,
          'keySet': false,
          'baseUrl': 'https://stt.example.com/v1',
          'model': 'whisper-test',
        }, 200),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final saved = await gateway.save(
      const SttSettingsDraft(
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-test',
        apiKey: 'stt-temporary-value',
      ),
    );
    expect(saved.keySet, isTrue);
    final saveRequest = requests.last;
    expect(saveRequest.method, 'PUT');
    expect(saveRequest.headers['x-qiyu-csrf'], 'csrf-1');
    expect(jsonDecode(saveRequest.body), {
      'provider': 'openai_compatible',
      'baseUrl': 'https://stt.example.com/v1',
      'model': 'whisper-test',
      'apiKey': 'stt-temporary-value',
    });

    final forgotten = await gateway.forgetApiKey();
    expect(forgotten.keySet, isFalse);
    final forgetRequest = requests.last;
    expect(forgetRequest.method, 'DELETE');
    expect(forgetRequest.url.path, '/api/provider/stt/key');
    expect(forgetRequest.headers['x-qiyu-csrf'], 'csrf-1');
  });

  test('连接测试复用聊天的测试结果形状并区分鉴权失败', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/provider/stt/test' => _jsonResponse({
          'ok': false,
          'status': 'authentication',
          'message': 'API Key 没有通过验证。',
        }, 200),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    const draft = SttSettingsDraft(
      baseUrl: 'https://new.example.com/v1',
      model: 'whisper-2',
      apiKey: 'new-test-value',
    );
    final result = await gateway.testConnection(draft);

    expect(result.status, ProviderTestStatus.authentication);
    expect(result.succeeded, isFalse);
    expect(jsonDecode(requests.last.body), draft.toJson());
  });

  test('聊天网关 transcribe：成功返回文本，失败抛出服务端人话', () async {
    final requests = <http.Request>[];
    var transcribeCalls = 0;
    final client = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/api/bootstrap' => _jsonResponse({'csrfToken': 'csrf-1'}, 200),
        '/api/chat/transcribe' => () {
          // 第一次成功，第二次服务端返回可重试失败。
          transcribeCalls += 1;
          return transcribeCalls == 1
              ? _jsonResponse({'text': '今天有点累'}, 200)
              : _jsonResponse({
                'code': 'stt_no_speech',
                'message': '没有识别到语音，可以再说一次。',
                'retryable': true,
              }, 400);
        }(),
        _ => http.Response('not found', 404),
      };
    });
    final gateway = HttpLocalChatGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    );

    final audio = Uint8List.fromList([1, 2, 3]);
    final text = await gateway.transcribe(audio: audio, mimeType: 'audio/webm');
    expect(text, '今天有点累');
    final sent = requests.last;
    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/chat/transcribe');
    expect(sent.headers['content-type'], 'audio/webm');
    expect(sent.headers['x-qiyu-csrf'], 'csrf-1');
    expect(sent.bodyBytes, audio);

    await expectLater(
      gateway.transcribe(audio: audio, mimeType: 'audio/webm'),
      throwsA(
        isA<LocalChatGatewayException>()
            .having(
              (error) => error.message,
              'message',
              '没有识别到语音，可以再说一次。',
            ),
      ),
    );
  });
}

http.Response _jsonResponse(Map<String, Object?> body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
