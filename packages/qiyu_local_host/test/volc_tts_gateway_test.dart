import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
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

  test('自定义通用音色与语速转入 audio_params.speech_rate；结束码行后忽略多余内容', () async {
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
    expect(reqParams.containsKey('speed_ratio'), isFalse);
    expect(reqParams['audio_params'], {
      'format': 'mp3',
      'sample_rate': 24000,
      'speech_rate': -20,
    });
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

  test('extraParams 智能深合并：audio_params 深度合并、additions 序列化为 JSON 字符串且方言音色映射为基础音色', () async {
    final client = _RecordingBytesHttpClient(
      response: lines([
        {
          'code': 0,
          'data': base64Encode([1, 2, 3]),
        },
        {'code': 20000000},
      ]),
    );

    final audio = await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        voice: 'zh_female_sichuan_uranus_bigtts',
        extraParams: {
          'audio_params': {'sample_rate': 16000, 'channel': 1},
          'additions': {'explicit_dialect': 'sichuan'},
          'custom_field': 'custom_value',
        },
      ),
      apiKey: 'ark-test-key',
      text: '你好呀。',
    );

    expect(audio, [1, 2, 3]);
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    final reqParams = body['req_params']! as Map<String, Object?>;
    expect(reqParams['text'], '你好呀。');
    // 方言音色自动映射为基础音色 zh_female_vv_uranus_bigtts
    expect(reqParams['speaker'], VolcTtsGateway.defaultSpeaker);
    // audio_params 保留 format: mp3 并合并 sample_rate 与 channel
    expect(reqParams['audio_params'], {
      'format': 'mp3',
      'sample_rate': 16000,
      'channel': 1,
    });
    // 火山 Go 服务端 additions 字段类型必须是 string
    expect(reqParams['additions'], isA<String>());
    expect(jsonDecode(reqParams['additions']! as String), {
      'explicit_dialect': 'sichuan',
    });
    expect(reqParams['custom_field'], 'custom_value');
  });

  test('方言预设映射：四川话、粤语、东北话、河南话、陕西话等自动注入 additions 且 speaker 设为灿灿', () async {
    final dialectCases = <String, String>{
      'zh_female_sichuan_uranus_bigtts': 'sichuan',
      'zh_female_cantonese_uranus_bigtts': 'guangdong',
      'zh_female_dongbei_uranus_bigtts': 'dongbei',
      'zh_female_henan_uranus_bigtts': 'henan',
      'zh_female_shanxi_uranus_bigtts': 'shaanxi',
      'zh_female_tianjin_uranus_bigtts': 'tianjin',
      'zh_female_shandong_uranus_bigtts': 'shandong',
      'zh_female_minnan_uranus_bigtts': 'minnan',
      'zh_female_wanwanxiaohe_moon_bigtts': 'taiwan',
    };

    for (final entry in dialectCases.entries) {
      final client = _RecordingBytesHttpClient(
        response: lines([
          {
            'code': 0,
            'data': base64Encode([1]),
          },
          {'code': 20000000},
        ]),
      );

      await TtsModelGateway(client).synthesize(
        config: TtsConfig(
          provider: TtsProviderKind.volcTts,
          baseUrl:
              'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
          model: 'seed-tts-2.0',
          voice: entry.key,
        ),
        apiKey: 'ark-test-key',
        text: '测试方言',
      );

      final body =
          jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
      final reqParams = body['req_params']! as Map<String, Object?>;
      expect(
        reqParams['speaker'],
        VolcTtsGateway.defaultSpeaker,
        reason: '方言音色 ${entry.key} 必须映射为基础通用音色',
      );
      expect(
        reqParams['additions'],
        isA<String>(),
        reason: 'additions 必须是 JSON 字符串',
      );
      expect(
        jsonDecode(reqParams['additions']! as String),
        {'explicit_dialect': entry.value},
        reason: '${entry.key} 对应的方言代码应为 ${entry.value}',
      );
    }
  });

  test('通用音色保留原 speaker 且无 additions；若 extraParams 自带 additions 字符串则保持字符串', () async {
    final client = _RecordingBytesHttpClient(
      response: lines([
        {
          'code': 0,
          'data': base64Encode([1]),
        },
        {'code': 20000000},
      ]),
    );

    await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        voice: 'zh_female_gaolengyujie_uranus_bigtts',
        extraParams: {
          'additions': '{"explicit_dialect":"sichuan","custom_key":123}',
        },
      ),
      apiKey: 'ark-test-key',
      text: '你好',
    );

    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    final reqParams = body['req_params']! as Map<String, Object?>;
    expect(reqParams['speaker'], 'zh_female_gaolengyujie_uranus_bigtts');
    expect(reqParams['additions'], '{"explicit_dialect":"sichuan","custom_key":123}');
  });

  test('语速转换边界：1.0x -> 0, 1.5x -> 50, 2.0x -> 100, 0.5x -> -50', () async {
    final speedCases = <double, int>{
      1.0: 0,
      1.5: 50,
      2.0: 100,
      0.5: -50,
      0.8: -20,
      1.25: 25,
    };

    for (final entry in speedCases.entries) {
      final client = _RecordingBytesHttpClient(
        response: lines([
          {
            'code': 0,
            'data': base64Encode([1]),
          },
          {'code': 20000000},
        ]),
      );

      await TtsModelGateway(client).synthesize(
        config: TtsConfig(
          provider: TtsProviderKind.volcTts,
          baseUrl:
              'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
          model: 'seed-tts-2.0',
          speed: entry.key,
        ),
        apiKey: 'ark-test-key',
        text: '测试语速',
      );

      final body =
          jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
      final reqParams = body['req_params']! as Map<String, Object?>;
      expect(reqParams.containsKey('speed_ratio'), isFalse);
      final audioParams = reqParams['audio_params']! as Map<String, Object?>;
      expect(
        audioParams['speech_rate'],
        entry.value,
        reason: 'speed ${entry.key} 应换算为 speech_rate ${entry.value}',
      );
    }
  });

  test('x-tt-logid 响应头打入诊断日志；空白音色降级为默认音色', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        headers: {'x-tt-logid': 'logid-test-12345'},
        body: Stream.value(
          utf8.encode(
            '{"code":0,"data":"${base64Encode([1])}"}\n{"code":20000000}\n',
          ),
        ),
      ),
    );

    final audio = await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        voice: '   ',
      ),
      apiKey: 'ark-test-key',
      text: '测试日志',
    );

    expect(audio, [1]);
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    final reqParams = body['req_params']! as Map<String, Object?>;
    expect(reqParams['speaker'], VolcTtsGateway.defaultSpeaker);
    expect(reqParams.containsKey('additions'), isFalse);
  });

  test('additions 处理：Map 形式合并方言并序列化为 JSON 字符串，非空字符串直接保留', () async {
    // 1. Map 形式 additions + 方言音色合并 explicit_dialect
    final client1 = _RecordingBytesHttpClient(
      response: lines([
        {
          'code': 0,
          'data': base64Encode([1]),
        },
        {'code': 20000000},
      ]),
    );
    await TtsModelGateway(client1).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        voice: 'zh_female_sichuan_uranus_bigtts',
        extraParams: {
          'additions': {'custom_flag': true},
          'audio_params': 'not-a-map',
        },
      ),
      apiKey: 'ark-test-key',
      text: '测试',
    );
    final body1 =
        jsonDecode(utf8.decode(client1.bytesBody)) as Map<String, Object?>;
    final reqParams1 = body1['req_params']! as Map<String, Object?>;
    final additions1 = jsonDecode(
      reqParams1['additions']! as String,
    ) as Map<String, Object?>;
    expect(additions1['custom_flag'], isTrue);
    expect(additions1['explicit_dialect'], 'sichuan');

    // 2. 非空字符串形式 additions 直接保留
    final client2 = _RecordingBytesHttpClient(
      response: lines([
        {
          'code': 0,
          'data': base64Encode([1]),
        },
        {'code': 20000000},
      ]),
    );
    await TtsModelGateway(client2).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        extraParams: {'additions': '{"custom_flag":true}'},
      ),
      apiKey: 'ark-test-key',
      text: '测试',
    );
    final body2 =
        jsonDecode(utf8.decode(client2.bytesBody)) as Map<String, Object?>;
    final reqParams2 = body2['req_params']! as Map<String, Object?>;
    expect(reqParams2['additions'], '{"custom_flag":true}');
  });

  test('自定义音色不匹配预设方言时不误劫持，保留原 speaker 且无 additions', () async {
    final client = _RecordingBytesHttpClient(
      response: lines([
        {
          'code': 0,
          'data': base64Encode([1]),
        },
        {'code': 20000000},
      ]),
    );

    await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        provider: TtsProviderKind.volcTts,
        baseUrl:
            'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
        model: 'seed-tts-2.0',
        voice: 'custom_sichuan_voice',
      ),
      apiKey: 'ark-test-key',
      text: '自定义音色测试',
    );

    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    final reqParams = body['req_params']! as Map<String, Object?>;
    expect(reqParams['speaker'], 'custom_sichuan_voice');
    expect(reqParams.containsKey('additions'), isFalse);
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
