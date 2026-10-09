import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

/// 流式合成网关的录制型用例（票二）：录制型 HTTP 客户端返回分块 PCM
/// 响应（含中途断流），断言块顺序、块上采样率、请求形状与失败分类。
/// 只测外部可观察行为：块序列与异常，不测内部缓冲。
void main() {
  ProviderBytesHttpResponse bytesResponse(
    List<List<int>> chunks, {
    int statusCode = 200,
    Map<String, String> headers = const {},
  }) => ProviderBytesHttpResponse(
    statusCode: statusCode,
    body: Stream.fromIterable(chunks),
    headers: headers,
  );

  ProviderBytesHttpResponse textResponse(
    String text, {
    int statusCode = 200,
  }) => bytesResponse([utf8.encode(text)], statusCode: statusCode);

  group('豆包流式合成', () {
    const config = TtsConfig(
      provider: TtsProviderKind.volcTts,
      baseUrl:
          'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
      model: 'seed-tts-2.0',
    );

    test('逐行 JSON 的 base64 块按序转出，请求带 PCM 格式', () async {
      final client = _RecordingBytesHttpClient(
        response: textResponse(
          [
            jsonEncode({'code': 0, 'data': base64Encode([1, 2])}),
            jsonEncode({'code': 0, 'data': base64Encode([3])}),
            jsonEncode({'code': 20000000, 'usage': const {}}),
          ].join('\n'),
        ),
      );

      final chunks = await TtsModelGateway(client)
          .synthesizeStream(config: config, apiKey: 'ark-test-key', text: '晚安。')
          .toList();

      expect(chunks.map((chunk) => chunk.bytes), [
        [1, 2],
        [3],
      ]);
      // 块上带协商采样率：播放端按它初始化，不猜。
      expect(chunks.every((chunk) => chunk.sampleRate == 24000), isTrue);
      final body =
          jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
      final reqParams = body['req_params']! as Map<String, Object?>;
      // 流式推荐 pcm：官方明示禁 wav（流式会重复 header）。
      expect(reqParams['audio_params'], {
        'format': 'pcm',
        'sample_rate': 24000,
      });
      expect(reqParams['text'], '晚安。');
      expect(client.headers['X-Api-Key'], 'ark-test-key');
    });

    test('没等到结束码的中途断流按音频不完整拒绝', () async {
      final client = _RecordingBytesHttpClient(
        response: textResponse(
          jsonEncode({'code': 0, 'data': base64Encode([1, 2])}),
        ),
      );

      await expectLater(
        TtsModelGateway(client)
            .synthesizeStream(config: config, apiKey: 'ark-test-key', text: '晚安。')
            .toList(),
        throwsA(
          isA<TtsGatewayException>()
              .having((error) => error.kind, 'kind', ModelFailureKind.contentParsing)
              .having((error) => error.message, 'message', '语音合成服务返回的音频不完整。'),
        ),
      );
    });

    test('行内 code>0 按服务拒绝拒绝，不透出原始行', () async {
      final client = _RecordingBytesHttpClient(
        response: textResponse(
          [
            jsonEncode({'code': 0, 'data': base64Encode([1])}),
            jsonEncode({'code': 45000002, 'message': 'internal quota secret detail'}),
          ].join('\n'),
        ),
      );

      await expectLater(
        TtsModelGateway(client)
            .synthesizeStream(config: config, apiKey: 'ark-test-key', text: '晚安。')
            .toList(),
        throwsA(
          isA<TtsGatewayException>()
              .having((error) => error.kind, 'kind', ModelFailureKind.provider)
              .having((error) => error.message, 'message', '语音合成服务拒绝了这次请求。'),
        ),
      );
    });

    test('非 2xx 与空音频按既有分类拒绝', () async {
      final unauthorized = _RecordingBytesHttpClient(
        response: textResponse('{"code":401}', statusCode: HttpStatus.unauthorized),
      );
      await expectLater(
        TtsModelGateway(unauthorized)
            .synthesizeStream(config: config, apiKey: 'ark-test-key', text: '晚安。')
            .toList(),
        throwsA(
          isA<TtsGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.authentication,
          ),
        ),
      );

      final silent = _RecordingBytesHttpClient(
        response: textResponse(
          [jsonEncode({'code': 0}), jsonEncode({'code': 20000000})].join('\n'),
        ),
      );
      await expectLater(
        TtsModelGateway(silent)
            .synthesizeStream(config: config, apiKey: 'ark-test-key', text: '晚安。')
            .toList(),
        throwsA(
          isA<TtsGatewayException>().having(
            (error) => error.message,
            'message',
            '语音合成服务没有返回音频。',
          ),
        ),
      );
    });
  });

  group('qwenTtsNormalizeWavChunk WAV 段解析与剥头', () {
    test('带 LIST 扩展块的 WAV 段按块遍历剥头（不按固定 44 字节）', () {
      final wav = BytesBuilder(copy: false);
      void tag(String value) => wav.add(ascii.encode(value));
      void u32(int value) => wav.add([
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ]);
      void chunk(String id, List<int> body) {
        tag(id);
        u32(body.length);
        wav.add(body);
        if (body.length.isOdd) wav.add([0]); // 2 字节对齐填充
      }

      tag('RIFF');
      u32(0xffffffff);
      tag('WAVE');
      chunk('fmt ', [
        1, 0, // PCM
        1, 0, // 单声道
        0x80, 0x3e, 0, 0, // 16000 Hz
        0, 0x7d, 0, 0, // 字节率
        2, 0, // blockAlign
        16, 0, // 位深
      ]);
      chunk('LIST', ascii.encode('INFOhello'));
      chunk('data', [1, 2, 3, 4]);

      final result = qwenTtsNormalizeWavChunk(wav.takeBytes());
      expect(result.pcm, [1, 2, 3, 4]);
      expect(result.sampleRate, 16000);
    });

    test('data 声明长度超过实际 body：截断按实际到达的字节转出', () async {
      // 流式分块边界任意：data 声明的总长可能跨块才到齐，本块只到前段。
      final wav = BytesBuilder(copy: false);
      void tag(String value) => wav.add(ascii.encode(value));
      void u32(int value) => wav.add([
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ]);
      void chunk(String id, List<int> body, {int? declared}) {
        tag(id);
        u32(declared ?? body.length);
        wav.add(body);
        if (body.length.isOdd) wav.add([0]); // 2 字节对齐填充
      }

      tag('RIFF');
      u32(0xffffffff); // 流式分块：总长未知，占位
      tag('WAVE');
      chunk('fmt ', [
        1, 0, // PCM
        1, 0, // 单声道
        0x80, 0x3e, 0, 0, // 16000 Hz
        0, 0x7d, 0, 0, // 字节率
        2, 0, // blockAlign
        16, 0, // 位深
      ]);
      // data 声明 100 字节、实际只到 4 字节：以实际到达为准。
      chunk('data', [1, 2, 3, 4], declared: 100);
      final result = qwenTtsNormalizeWavChunk(wav.takeBytes());
      expect(result.pcm, [1, 2, 3, 4]);
      expect(result.sampleRate, 16000);
    });

    test('只有容器头没有 data 的片段：返回空 pcm 并带回采样率', () {
      final wav = BytesBuilder(copy: false);
      void tag(String value) => wav.add(ascii.encode(value));
      void u32(int value) => wav.add([
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ]);
      void chunk(String id, List<int> body) {
        tag(id);
        u32(body.length);
        wav.add(body);
        if (body.length.isOdd) wav.add([0]);
      }

      tag('RIFF');
      u32(0xffffffff);
      tag('WAVE');
      chunk('fmt ', [
        1, 0,
        1, 0,
        0x80, 0x3e, 0, 0,
        0, 0x7d, 0, 0,
        2, 0,
        16, 0,
      ]);

      final result = qwenTtsNormalizeWavChunk(wav.takeBytes());
      expect(result.pcm, isEmpty);
      expect(result.sampleRate, 16000);
    });

    test('普通 WAV 头剥掉容器头只送裸 PCM，采样率读回头里', () {
      final wav = wrapPcmAsWav(
        Uint8List.fromList(const [1, 2, 3, 4]),
        sampleRate: 16000,
      );
      final result = qwenTtsNormalizeWavChunk(wav);
      expect(result.pcm, [1, 2, 3, 4]);
      expect(result.sampleRate, 16000);
    });

    test('非 WAV 裸 PCM 字节原样返回', () {
      final raw = Uint8List.fromList([1, 2, 3, 4]);
      final result = qwenTtsNormalizeWavChunk(raw);
      expect(result.pcm, [1, 2, 3, 4]);
      expect(result.sampleRate, isNull);
    });
  });

  group('OpenAI 兼容流式合成', () {
    const config = TtsConfig(
      baseUrl: 'https://tts.example.com/v1',
      model: 'tts-test',
    );

    test('chunked 传输：流式格式参数 + PCM，原始字节块按序转出', () async {
      final client = _RecordingBytesHttpClient(
        response: bytesResponse([
          [1, 2],
          [3, 4],
          // 空块跳过，不算音频。
          <int>[],
        ]),
      );

      final chunks = await TtsModelGateway(client)
          .synthesizeStream(config: config, apiKey: 'tts-test-key', text: '晚安。')
          .toList();

      expect(chunks.map((chunk) => chunk.bytes), [
        [1, 2],
        [3, 4],
      ]);
      expect(
        chunks.every((chunk) => chunk.sampleRate == OpenAiSpeechGateway.pcmSampleRate),
        isTrue,
      );
      final body =
          jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
      // 官方流式开关：chunked 原始音频字节（stream_format=audio）。
      expect(body['stream_format'], 'audio');
      expect(body['response_format'], 'pcm');
      expect(body['input'], '晚安。');
    });

    test('非 2xx 按错误分类上报', () async {
      final client = _RecordingBytesHttpClient(
        response: textResponse(
          '{"error":"rate limited"}',
          statusCode: HttpStatus.tooManyRequests,
        ),
      );

      await expectLater(
        TtsModelGateway(client)
            .synthesizeStream(config: config, apiKey: 'tts-test-key', text: '晚安。')
            .toList(),
        throwsA(
          isA<TtsGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.rateLimited,
          ),
        ),
      );
    });
  });

  group('自定义档流式合成', () {
    test('raw_bytes：chunked 原始字节块按序转出，请求带流式格式参数', () async {
      const config = TtsConfig(
        provider: TtsProviderKind.custom,
        baseUrl: 'https://custom.example.com/tts',
        model: 'custom-tts',
        responseShape: TtsResponseShape.rawBytes,
      );
      final client = _RecordingBytesHttpClient(
        response: bytesResponse([
          [1, 2],
          [3],
        ]),
      );

      final chunks = await TtsModelGateway(client)
          .synthesizeStream(config: config, apiKey: 'custom-key', text: '晚安。')
          .toList();

      expect(chunks.map((chunk) => chunk.bytes), [
        [1, 2],
        [3],
      ]);
      final body =
          jsonDecode(utf8.decode(client.bytesBody)) as Map<String, Object?>;
      expect(body['stream_format'], 'audio');
      expect(body['response_format'], 'pcm');
      expect(body['model'], 'custom-tts');
      expect(body['input'], {'text': '晚安。'});
      // 鉴权头缺省 Bearer。
      expect(client.headers['authorization'], 'Bearer custom-key');
    });

    test('json_field / json_lines：拿不到音频块，整响应当一块（E1）', () async {
      // 两种 JSON 信封形态的音频容器都由服务定义（可能是 mp3/wav），
      // 不能当 PCM 块送——按 E1 每句独立整段合成、按序播放。
      for (final shape in [
        TtsResponseShape.jsonField,
        TtsResponseShape.jsonLines,
      ]) {
        final config = TtsConfig(
          provider: TtsProviderKind.custom,
          baseUrl: 'https://custom.example.com/tts',
          model: 'custom-tts',
          responseShape: shape,
        );
        final client = _RecordingBytesHttpClient(
          response: textResponse(
            jsonEncode({'data': base64Encode([9, 9])}),
          ),
        );

        final chunks = await TtsModelGateway(client)
            .synthesizeStream(config: config, apiKey: 'custom-key', text: '晚安。')
            .toList();

        expect(chunks, hasLength(1));
        expect(chunks.single.bytes, [9, 9]);
        expect(chunks.single.sampleRate, isNull);
        expect(chunks.single.mimeType, voiceWholeContainerMime);
      }
    });

    test('raw_bytes 但用户把 response_format 覆盖成 mp3：按 E1 整响应当一块', () async {
      const config = TtsConfig(
        provider: TtsProviderKind.custom,
        baseUrl: 'https://custom.example.com/tts',
        model: 'custom-tts',
        responseShape: TtsResponseShape.rawBytes,
        extraParams: {'response_format': 'mp3'},
      );
      final client = _RecordingBytesHttpClient(
        response: bytesResponse([
          [1, 2],
          [3],
        ]),
      );

      final chunks = await TtsModelGateway(client)
          .synthesizeStream(config: config, apiKey: 'custom-key', text: '晚安。')
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.bytes, [1, 2, 3]);
      expect(chunks.single.sampleRate, isNull);
      expect(chunks.single.mimeType, voiceWholeContainerMime);
    });
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

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) async => throw UnimplementedError();
}
