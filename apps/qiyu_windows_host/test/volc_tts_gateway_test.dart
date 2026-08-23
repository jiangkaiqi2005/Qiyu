import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  const config = TtsConfig(
    provider: TtsProviderKind.volcTts,
    baseUrl: 'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    model: 'seed-tts-2.0',
  );

  ProviderBytesHttpResponse lines(List<Map<String, Object?>> rows) {
    final text = rows.map((row) => jsonEncode(row)).join('\n');
    return ProviderBytesHttpResponse(
      statusCode: 200,
      body: Stream.value(utf8.encode(text)),
    );
  }

  test('请求形状：完整端点原样使用、鉴权头、req_params 字段', () async {
    final client = _RecordingBytesHttpClient(
      response: lines([
        {
          'code': 0,
          'data': base64Encode([1, 2]),
        },
        {
          'code': 0,
          'data': base64Encode([3]),
        },
        {'code': 20000000},
      ]),
    );

    final audio = await TtsModelGateway(
      client,
    ).synthesize(config: config, apiKey: 'ark-test-key', text: '晚安。');

    expect(audio, [1, 2, 3]);
    expect(
      client.uri.toString(),
      'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    );
    expect(client.headers['X-Api-Key'], 'ark-test-key');
    expect(client.headers['X-Api-Resource-Id'], 'seed-tts-2.0');
    expect(client.headers['X-Control-Require-Usage-Tokens-Return'], '*');
    expect(client.headers['content-type'], 'application/json');
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    final reqParams = body['req_params']! as Map<String, Object?>;
    expect(reqParams['text'], '晚安。');
    // 没填音色用官方示例缺省音色；没调语速不传 speed_ratio。
    expect(reqParams['speaker'], VolcTtsGateway.defaultSpeaker);
    expect(reqParams.containsKey('speed_ratio'), isFalse);
    expect(reqParams['audio_params'], {'format': 'mp3', 'sample_rate': 24000});
  });

  test('自定义音色与语速原样上送；结束码行后忽略多余内容', () async {
    final client = _RecordingBytesHttpClient(
      response: lines([
        {
          'code': 0,
          'data': base64Encode([9]),
        },
        {'code': 20000000},
        // 官方协议以结束码收束；防御性忽略其后出现的任何行。
        {
          'code': 0,
          'data': base64Encode([8]),
        },
      ]),
    );

    final audio = await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        voice: 'zh_female_gaolengyujie_uranus_bigtts',
        speed: 0.8,
      ),
      apiKey: 'ark-test-key',
      text: '嗯。',
    );

    expect(audio, [9]);
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    final reqParams = body['req_params']! as Map<String, Object?>;
    expect(reqParams['speaker'], 'zh_female_gaolengyujie_uranus_bigtts');
    expect(reqParams['speed_ratio'], 0.8);
  });

  test('行内 code>0 按服务拒绝拒绝，不透出原始行', () async {
    final client = _RecordingBytesHttpClient(
      response: lines([
        {
          'code': 0,
          'data': base64Encode([1]),
        },
        {'code': 45000002, 'message': 'internal quota secret detail'},
      ]),
    );

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'ark-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.provider)
            .having((error) => error.message, 'message', '语音合成服务拒绝了这次请求。'),
      ),
    );
  });

  test('没等到结束码断流按音频不完整拒绝；空音频拒绝', () async {
    final truncated = _RecordingBytesHttpClient(
      response: lines([
        {
          'code': 0,
          'data': base64Encode([1]),
        },
      ]),
    );
    await expectLater(
      TtsModelGateway(
        truncated,
      ).synthesize(config: config, apiKey: 'ark-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.message,
          'message',
          '语音合成服务返回的音频不完整。',
        ),
      ),
    );

    final silent = _RecordingBytesHttpClient(
      response: lines([
        {'code': 0},
        {'code': 20000000},
      ]),
    );
    await expectLater(
      TtsModelGateway(
        silent,
      ).synthesize(config: config, apiKey: 'ark-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.message,
          'message',
          '语音合成服务没有返回音频。',
        ),
      ),
    );
  });

  test('非 JSON 行按解析失败拒绝；HTTP 401 按鉴权失败分类', () async {
    final broken = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value(utf8.encode('not-json\n')),
      ),
    );
    await expectLater(
      TtsModelGateway(
        broken,
      ).synthesize(config: config, apiKey: 'ark-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.message,
          'message',
          '语音合成服务返回的内容无法解析。',
        ),
      ),
    );

    final unauthorized = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: HttpStatus.unauthorized,
        body: Stream.value(utf8.encode('{"code":401}')),
      ),
    );
    await expectLater(
      TtsModelGateway(
        unauthorized,
      ).synthesize(config: config, apiKey: 'ark-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.authentication,
        ),
      ),
    );
  });

  test('脏 Key 前置拦截人话文案，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'ark-test-key\u200B', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.message,
          'message',
          'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
        ),
      ),
    );
    expect(client.called, isFalse);
  });
}

final class _RecordingBytesHttpClient implements ProviderBytesHttpClient {
  _RecordingBytesHttpClient({this.response});

  final ProviderBytesHttpResponse? response;
  bool called = false;
  late Uri uri;
  late Map<String, String> headers;
  late List<int> bytesBody;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    called = true;
    this.uri = uri;
    this.headers = headers;
    bytesBody = body;
    return response!;
  }
}
