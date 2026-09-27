import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';

import 'support/host_transport.dart';

void main() {
  test('读取设置：configured/keySet/baseUrl/model，永不携带明文 Key', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
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
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
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

  test('读取设置：千问协议回填 provider 并标记需要 WAV 转换', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'qwen_asr',
          'baseUrl':
              'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
          'model': 'qwen3-asr-flash',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.provider, SttServiceKind.qwenAsr);
    expect(settings.wantsWavAudio, isTrue);
  });

  test('读取设置：自定义协议回填旋钮且录音原样上送（不转 WAV）', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'custom',
          'baseUrl': 'https://stt.example.com/v1/audio/transcriptions',
          'model': 'whisper-test',
          'authHeader': 'X-Api-Key',
          'responseShape': 'sse',
          'responseField': 'result.text',
          'extraParams': {'speaker': 'zh'},
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.provider, SttServiceKind.custom);
    expect(settings.authHeader, 'X-Api-Key');
    expect(settings.responseShape, SttResponseShape.sse);
    expect(settings.responseField, 'result.text');
    expect(settings.extraParams, {'speaker': 'zh'});
    expect(settings.wantsWavAudio, isFalse);
  });

  test('读取设置：自定义段缺省旋钮按缺省形态读回', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'custom',
          'baseUrl': 'https://stt.example.com/v1/audio/transcriptions',
          'model': 'whisper-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
    );

    final settings = await HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).read();

    expect(settings.provider, SttServiceKind.custom);
    expect(settings.authHeader, isNull);
    expect(settings.responseShape, SttResponseShape.jsonPath);
    expect(settings.responseField, isNull);
    expect(settings.extraParams, isNull);
  });

  test('未知 provider 值按缺省协议呈现（旧版 Host 响应防御）', () async {
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
          'configured': true,
          'keySet': false,
          'provider': 'some_future_protocol',
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

    expect(settings.provider, SttServiceKind.openaiCompatible);
    expect(settings.wantsWavAudio, isFalse);
  });

  test('千问草稿保存：请求体带 qwen_asr wire 名与端点原值', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'qwen_asr',
          'baseUrl': qwenAsrDefaultEndpoint,
          'model': qwenAsrDefaultModel,
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );

    await HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).save(
      const SttSettingsDraft(
        provider: SttServiceKind.qwenAsr,
        baseUrl: qwenAsrDefaultEndpoint,
        model: qwenAsrDefaultModel,
        apiKey: 'qwen-temporary-value',
      ),
    );

    expect(jsonDecode(requests.last.body), {
      'provider': 'qwen_asr',
      'baseUrl': qwenAsrDefaultEndpoint,
      'model': qwenAsrDefaultModel,
      'apiKey': 'qwen-temporary-value',
    });
  });

  test('自定义草稿保存：请求体带 custom wire 名、旋钮与高级参数', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'provider': 'custom',
          'baseUrl': 'https://stt.example.com/v1/audio/transcriptions',
          'model': 'whisper-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );

    await HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).save(
      const SttSettingsDraft(
        provider: SttServiceKind.custom,
        baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
        model: 'whisper-test',
        apiKey: 'custom-temporary-value',
        authHeader: 'X-Api-Key',
        responseShape: SttResponseShape.sse,
        responseField: 'result.text',
        extraParams: {'speaker': 'zh'},
      ),
    );

    expect(jsonDecode(requests.last.body), {
      'provider': 'custom',
      'baseUrl': 'https://stt.example.com/v1/audio/transcriptions',
      'model': 'whisper-test',
      'apiKey': 'custom-temporary-value',
      'authHeader': 'X-Api-Key',
      'responseShape': 'sse',
      'responseField': 'result.text',
      'extraParams': {'speaker': 'zh'},
    });
  });

  test('非自定义草稿保存：请求体不带自定义旋钮', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://stt.example.com/v1',
          'model': 'whisper-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );

    await HttpSttSettingsGateway(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:5173/'),
    ).save(
      const SttSettingsDraft(
        provider: SttServiceKind.openaiCompatible,
        baseUrl: 'https://stt.example.com/v1',
        model: 'whisper-test',
        apiKey: 'stt-temporary-value',
      ),
    );

    expect(jsonDecode(requests.last.body), {
      'provider': 'openai_compatible',
      'baseUrl': 'https://stt.example.com/v1',
      'model': 'whisper-test',
      'apiKey': 'stt-temporary-value',
    });
  });

  test('保存与忘记 Key 都带 CSRF 头且请求体形状正确', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'baseUrl': 'https://stt.example.com/v1',
          'model': 'whisper-test',
        }, 200),
        '/api/provider/stt/key' => hostJsonResponse({
          'configured': true,
          'keySet': false,
          'baseUrl': 'https://stt.example.com/v1',
          'model': 'whisper-test',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
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
    expectCsrfHeader(saveRequest);
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
    expectCsrfHeader(forgetRequest);
  });

  test('连接测试复用聊天的测试结果形状并区分鉴权失败', () async {
    final requests = <http.Request>[];
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/stt/test' => hostJsonResponse({
          'ok': false,
          'status': 'authentication',
          'message': 'API Key 没有通过验证。',
        }, 200),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
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
    final client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/chat/transcribe' => () {
          // 第一次成功，第二次服务端返回可重试失败。
          transcribeCalls += 1;
          return transcribeCalls == 1
              ? hostJsonResponse({'text': '今天有点累'}, 200)
              : hostJsonResponse({
                  'code': 'stt_no_speech',
                  'message': '没有识别到语音，可以再说一次。',
                  'retryable': true,
                }, 400);
        }(),
        _ => http.Response('not found', 404),
      },
      requests: requests,
    );
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
    expectCsrfHeader(sent);
    expect(sent.bodyBytes, audio);

    await expectLater(
      gateway.transcribe(audio: audio, mimeType: 'audio/webm'),
      throwsA(
        isA<LocalChatGatewayException>().having(
          (error) => error.message,
          'message',
          '没有识别到语音，可以再说一次。',
        ).having((error) => error.code, 'code', 'stt_no_speech'),
      ),
    );
  });
}
