import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  const config = TtsConfig(
    baseUrl: 'https://tts.example.com/v1',
    model: 'tts-test',
  );

  test('请求形状：端点拼接、鉴权头、model/input/voice/response_format', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1, 2, 3]),
      ),
    );

    final audio = await TtsModelGateway(
      client,
    ).synthesize(config: config, apiKey: ' tts-test-key ', text: '晚安。');

    // 音频格式统一 PCM（票二）：裸样本在 Host 本地包 WAV 头，现有整段
    // 播放器零改动。
    expect(audio, wrapPcmAsWav(
      Uint8List.fromList(const [1, 2, 3]),
      sampleRate: OpenAiSpeechGateway.pcmSampleRate,
    ));
    expect(client.uri.toString(), 'https://tts.example.com/v1/audio/speech');
    expect(client.headers['authorization'], 'Bearer tts-test-key');
    expect(client.headers['content-type'], 'application/json');
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'tts-test');
    expect(body['input'], '晚安。');
    expect(body['voice'], OpenAiSpeechGateway.defaultVoice);
    expect(body['response_format'], 'pcm');
    // 整段路径不送流式开关：一问一答拿完整响应。
    expect(body.containsKey('stream_format'), isFalse);
    expect(body.containsKey('speed'), isFalse);
  });

  test('自定义音色与语速原样上送；已写完整端点的地址原样使用', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([9]),
      ),
    );

    await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        baseUrl: 'https://tts.example.com/v1/audio/speech',
        model: 'tts-test',
        voice: 'nova',
        speed: 1.5,
      ),
      apiKey: 'tts-test-key',
      text: '嗯。',
    );

    expect(client.uri.toString(), 'https://tts.example.com/v1/audio/speech');
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['voice'], 'nova');
    expect(body['speed'], 1.5);
  });

  test('双语智能音色：英文文本在未配置音色时智能推荐 nova，手动覆盖优先', () async {
    _RecordingBytesHttpClient makeClient() => _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1, 2, 3]),
      ),
    );

    // 1. 未配置音色，英文文本 -> 自动推荐 nova
    final client1 = makeClient();
    await TtsModelGateway(client1).synthesize(
      config: config,
      apiKey: 'tts-test-key',
      text: 'Good night, have a restful sleep.',
    );
    var body =
        jsonDecode(utf8.decode(client1.bytesBody)) as Map<String, Object?>;
    expect(body['voice'], OpenAiSpeechGateway.defaultVoiceEn);
    expect(body['voice'], 'nova');

    // 2. 中文文本 -> 保持 alloy
    final client2 = makeClient();
    await TtsModelGateway(client2).synthesize(
      config: config,
      apiKey: 'tts-test-key',
      text: '晚安。',
    );
    body = jsonDecode(utf8.decode(client2.bytesBody)) as Map<String, Object?>;
    expect(body['voice'], OpenAiSpeechGateway.defaultVoice);
    expect(body['voice'], 'alloy');

    // 3. 手动配置音色时，即使是英文文本也尊重手动配置
    final client3 = makeClient();
    await TtsModelGateway(client3).synthesize(
      config: const TtsConfig(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
        voice: 'echo',
      ),
      apiKey: 'tts-test-key',
      text: 'Good night.',
    );
    body = jsonDecode(utf8.decode(client3.bytesBody)) as Map<String, Object?>;
    expect(body['voice'], 'echo');
  });

  test('缺 Key 直接按鉴权失败拒绝，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: '  ', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.authentication,
        ),
      ),
    );
    expect(client.called, isFalse);
  });

  test('Key 带零宽空格按粘贴事故拒绝，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'tts-test-key\u200B', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.provider)
            .having(
              (error) => error.message,
              'message',
              'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
            ),
      ),
    );
    expect(client.called, isFalse);
  });

  test('地址指向环回按 SSRF 拒绝，不出网', () async {
    final client = _RecordingBytesHttpClient();

    await expectLater(
      TtsModelGateway(client).synthesize(
        config: const TtsConfig(
          baseUrl: 'http://127.0.0.1:8080/v1',
          model: 'tts-test',
        ),
        apiKey: 'tts-test-key',
        text: '晚安。',
      ),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.provider)
            .having((error) => error.message, 'message', '语音服务地址不允许指向本机或内网。'),
      ),
    );
    expect(client.called, isFalse);
  });

  test('非 2xx 按错误分类上报：401 鉴权、404+model not found 模型不存在', () async {
    final unauthorized = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: HttpStatus.unauthorized,
        body: Stream.value(utf8.encode('{"error":"bad key"}')),
      ),
    );
    await expectLater(
      TtsModelGateway(
        unauthorized,
      ).synthesize(config: config, apiKey: 'tts-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.authentication,
        ),
      ),
    );

    final missingModel = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: HttpStatus.notFound,
        body: Stream.value(utf8.encode('{"error":"model not found"}')),
      ),
    );
    await expectLater(
      TtsModelGateway(
        missingModel,
      ).synthesize(config: config, apiKey: 'tts-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.modelNotFound,
        ),
      ),
    );
  });

  test('2xx 但音频为空按解析失败拒绝', () async {
    final client = _RecordingBytesHttpClient(
      response: const ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.empty(),
      ),
    );

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'tts-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>()
            .having(
              (error) => error.kind,
              'kind',
              ModelFailureKind.contentParsing,
            )
            .having((error) => error.message, 'message', '语音合成服务没有返回音频。'),
      ),
    );
  });

  test('出网超时按超时分类上报', () async {
    final client = _RecordingBytesHttpClient(error: TimeoutException('slow'));

    await expectLater(
      TtsModelGateway(
        client,
      ).synthesize(config: config, apiKey: 'tts-test-key', text: '晚安。'),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.timeout,
        ),
      ),
    );
  });

  test('OpenAI 协议 extraParams 展平合并入顶层请求体', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1, 2]),
      ),
    );

    final audio = await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-1',
        voice: 'alloy',
        extraParams: {
          'user': 'test-user',
          'custom_field': 123,
        },
      ),
      apiKey: 'tts-test-key',
      text: '你好。',
    );

    expect(audio, wrapPcmAsWav(
      Uint8List.fromList(const [1, 2]),
      sampleRate: OpenAiSpeechGateway.pcmSampleRate,
    ));
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['model'], 'tts-1');
    expect(body['input'], '你好。');
    expect(body['voice'], 'alloy');
    expect(body['user'], 'test-user');
    expect(body['custom_field'], 123);
  });

  test('WAV 头锁定：44 字节 RIFF、PCM16 单声道、协商采样率与数据长度', () {
    final wav = wrapPcmAsWav(
      Uint8List.fromList(const [1, 2, 3, 4]),
      sampleRate: 24000,
    );
    expect(wav, hasLength(44 + 4));
    expect(wav.sublist(0, 4), ascii.encode('RIFF'));
    // 块长度 = 36 + 数据长度。
    expect(
      ByteData.sublistView(Uint8List.fromList(wav), 4, 8).getUint32(0, Endian.little),
      40,
    );
    expect(wav.sublist(8, 12), ascii.encode('WAVE'));
    expect(wav.sublist(12, 16), ascii.encode('fmt '));
    final header = ByteData.sublistView(Uint8List.fromList(wav), 16, 36);
    expect(header.getUint32(0, Endian.little), 16); // fmt 块长度
    expect(header.getUint16(4, Endian.little), 1); // audioFormat = PCM
    expect(header.getUint16(6, Endian.little), 1); // 单声道
    expect(header.getUint32(8, Endian.little), 24000); // 采样率
    expect(header.getUint32(12, Endian.little), 48000); // 字节率
    expect(header.getUint16(16, Endian.little), 2); // 块对齐
    expect(header.getUint16(18, Endian.little), 16); // 位深
    expect(wav.sublist(36, 40), ascii.encode('data'));
    expect(
      ByteData.sublistView(Uint8List.fromList(wav), 40, 44).getUint32(0, Endian.little),
      4,
    );
    expect(wav.sublist(44), [1, 2, 3, 4]);
  });

  test('整段归一：非裸 PCM 的格式覆盖原样返回，不包 WAV 头', () {
    final raw = Uint8List.fromList(const [1, 2, 3]);
    // 压缩格式 / 多声道 / 别的位深：一律原样。
    for (final case_ in [
      (format: 'mp3', channels: 1, bits: 16),
      (format: 'ogg_opus', channels: 1, bits: 16),
      (format: 'pcm', channels: 2, bits: 16),
      (format: 'pcm', channels: 1, bits: 8),
      (format: null, channels: 1, bits: 16),
    ]) {
      expect(
        wholeResponseAudio(
          raw,
          format: case_.format,
          channels: case_.channels,
          bitsPerSample: case_.bits,
          sampleRate: 24000,
        ),
        case_.format == null ? isNot(same(raw)) : same(raw),
        reason: 'format=${case_.format} channels=${case_.channels} '
            'bits=${case_.bits}',
      );
    }
    // 裸 PCM 单声道 16-bit：包 WAV 头。
    expect(
      wholeResponseAudio(
        raw,
        format: 'pcm',
        channels: 1,
        bitsPerSample: 16,
        sampleRate: 24000,
      ),
      hasLength(44 + 3),
    );
  });

  test('用户在高级参数里覆盖 response_format：值优先且不包 WAV 头', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.value([1, 2, 3]),
      ),
    );

    final audio = await TtsModelGateway(client).synthesize(
      config: const TtsConfig(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-1',
        extraParams: {'response_format': 'mp3'},
      ),
      apiKey: 'tts-test-key',
      text: '晚安。',
    );

    // 用户显式写的格式优先于协议缺省 pcm，且原样返回（不包 WAV 头）。
    expect(audio, [1, 2, 3]);
    final body =
        jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
    expect(body['response_format'], 'mp3');
  });

  test('流式路径对 response_format 覆盖按 E1 整响应当一块', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          [1, 2],
          [3],
        ]),
      ),
    );

    final chunks = await TtsModelGateway(client)
        .synthesizeStream(
          config: const TtsConfig(
            baseUrl: 'https://tts.example.com/v1',
            model: 'tts-1',
            extraParams: {'response_format': 'mp3'},
          ),
          apiKey: 'tts-test-key',
          text: '晚安。',
        )
        .toList();

    expect(chunks, hasLength(1));
    expect(chunks.single.bytes, [1, 2, 3]);
    expect(chunks.single.sampleRate, isNull);
    expect(chunks.single.mimeType, voiceWholeContainerMime);
  });
}

final class _RecordingBytesHttpClient implements ProviderBytesHttpClient {
  _RecordingBytesHttpClient({this.response, this.error});

  final ProviderBytesHttpResponse? response;
  final Object? error;
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
    if (error case final failure?) {
      throw failure;
    }
    return response!;
  }

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) async => throw UnimplementedError();
}
