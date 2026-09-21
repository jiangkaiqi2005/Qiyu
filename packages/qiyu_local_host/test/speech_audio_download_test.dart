import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  test('公网地址下载成功返回完整音频字节，超时预算与合成请求同级', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        // 分块流：验证读完全量字节再返回，不停在第一块。
        body: Stream.fromIterable([
          [1, 2, 3],
          [4, 5],
        ]),
      ),
    );

    final audio = await downloadSpeechAudioBytes(
      httpClient: client,
      url: 'https://oss.example.com/audio/qiyu.mp3?Expires=1893456000&Signature=abc',
    );

    expect(audio, [1, 2, 3, 4, 5]);
    expect(client.called, isTrue);
    expect(
      client.uri.toString(),
      'https://oss.example.com/audio/qiyu.mp3?Expires=1893456000&Signature=abc',
    );
    expect(client.timeout, ttsRequestTimeout);
    // 钉住数值：常量若被改成非 60 秒，这里失败（下载与合成请求同级预算）。
    expect(ttsRequestTimeout, const Duration(seconds: 60));
  });

  test('地址指向本机或内网字面量时被拒，话术与语音出网拒绝一致且不出网', () async {
    const refused = '语音服务地址不允许指向本机或内网。';
    final urls = [
      'http://127.0.0.1:8080/audio.mp3',
      'http://localhost/audio.mp3',
      'http://192.168.1.5/audio.mp3',
      'http://10.0.0.9/audio.mp3',
      'http://[::1]/audio.mp3',
    ];
    for (final url in urls) {
      final client = _RecordingBytesHttpClient();
      await expectLater(
        downloadSpeechAudioBytes(httpClient: client, url: url),
        throwsA(
          isA<TtsGatewayException>()
              .having((error) => error.kind, 'kind', ModelFailureKind.provider)
              .having((error) => error.message, 'message', refused),
        ),
      );
      expect(client.called, isFalse, reason: url);
    }
  });

  test('下载超时按超时分类报错', () async {
    final client = _RecordingBytesHttpClient(error: TimeoutException('slow'));

    await expectLater(
      downloadSpeechAudioBytes(
        httpClient: client,
        url: 'https://oss.example.com/audio/qiyu.mp3',
      ),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.timeout)
            .having((error) => error.message, 'message', '连接语音合成服务超时。'),
      ),
    );
  });

  test('音频字节读取中超时按响应超时分类报错', () async {
    final client = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.fromFuture(
          Future.delayed(const Duration(milliseconds: 10)).then(
            (_) => throw TimeoutException('slow body'),
          ),
        ),
      ),
    );

    await expectLater(
      downloadSpeechAudioBytes(
        httpClient: client,
        url: 'https://oss.example.com/audio/qiyu.mp3',
      ),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.timeout)
            .having((error) => error.message, 'message', '语音合成服务响应超时。'),
      ),
    );
  });

  test('HTTP 非 2xx 落进现有状态码分类：401 鉴权、429 限流、404/500 服务拒绝', () async {
    final unauthorized = _RecordingBytesHttpClient(
      response: ProviderBytesHttpResponse(
        statusCode: HttpStatus.unauthorized,
        body: Stream.value(utf8.encode('{"error":"bad key"}')),
      ),
    );
    await expectLater(
      downloadSpeechAudioBytes(
        httpClient: unauthorized,
        url: 'https://oss.example.com/audio/qiyu.mp3',
      ),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.authentication,
        ),
      ),
    );

    final rateLimited = _RecordingBytesHttpClient(
      response: const ProviderBytesHttpResponse(
        statusCode: HttpStatus.tooManyRequests,
        body: Stream.empty(),
      ),
    );
    await expectLater(
      downloadSpeechAudioBytes(
        httpClient: rateLimited,
        url: 'https://oss.example.com/audio/qiyu.mp3',
      ),
      throwsA(
        isA<TtsGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.rateLimited,
        ),
      ),
    );

    final statuses = [HttpStatus.notFound, HttpStatus.internalServerError];
    for (final status in statuses) {
      final rejected = _RecordingBytesHttpClient(
        response: ProviderBytesHttpResponse(
          statusCode: status,
          body: Stream.value(utf8.encode('denied')),
        ),
      );
      await expectLater(
        downloadSpeechAudioBytes(
          httpClient: rejected,
          url: 'https://oss.example.com/audio/qiyu.mp3',
        ),
        throwsA(
          isA<TtsGatewayException>()
              .having((error) => error.kind, 'kind', ModelFailureKind.provider)
              .having((error) => error.message, 'message', '语音合成服务拒绝了这次请求。'),
        ),
      );
    }
  });

  test('网络失败按网络分类报错', () async {
    final socket = _RecordingBytesHttpClient(
      error: const SocketException('connection failed'),
    );
    await expectLater(
      downloadSpeechAudioBytes(
        httpClient: socket,
        url: 'https://oss.example.com/audio/qiyu.mp3',
      ),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.network)
            .having((error) => error.message, 'message', '无法连接语音合成服务。'),
      ),
    );

    final interrupted = _RecordingBytesHttpClient(
      error: const HttpException('connection reset'),
    );
    await expectLater(
      downloadSpeechAudioBytes(
        httpClient: interrupted,
        url: 'https://oss.example.com/audio/qiyu.mp3',
      ),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.network)
            .having((error) => error.message, 'message', '语音合成服务连接中断。'),
      ),
    );
  });

  test('空响应按内容解析失败拒绝', () async {
    final client = _RecordingBytesHttpClient(
      response: const ProviderBytesHttpResponse(
        statusCode: 200,
        body: Stream.empty(),
      ),
    );

    await expectLater(
      downloadSpeechAudioBytes(
        httpClient: client,
        url: 'https://oss.example.com/audio/qiyu.mp3',
      ),
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

  test('地址缺失或无法解析按内容解析失败拒绝，不出网', () async {
    for (final url in [
      null,
      '',
      '   ',
      'not-a-url',
      'example.com/audio.mp3',
      'ftp://oss.example.com/audio/qiyu.mp3',
    ]) {
      final client = _RecordingBytesHttpClient();
      await expectLater(
        downloadSpeechAudioBytes(httpClient: client, url: url),
        throwsA(
          isA<TtsGatewayException>()
              .having(
                (error) => error.kind,
                'kind',
                ModelFailureKind.contentParsing,
              )
              .having(
                (error) => error.message,
                'message',
                '语音合成服务没有返回有效的音频地址。',
              ),
        ),
      );
      expect(client.called, isFalse, reason: '$url');
    }
  });

  test('未分类异常按内部错误上报', () async {
    final client = _RecordingBytesHttpClient(error: Exception('boom'));

    await expectLater(
      downloadSpeechAudioBytes(
        httpClient: client,
        url: 'https://oss.example.com/audio/qiyu.mp3',
      ),
      throwsA(
        isA<TtsGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.internal)
            .having((error) => error.message, 'message', '本机程序内部出错。'),
      ),
    );
  });
}

final class _RecordingBytesHttpClient implements ProviderBytesHttpClient {
  _RecordingBytesHttpClient({this.response, this.error});

  final ProviderBytesHttpResponse? response;
  final Object? error;
  bool called = false;
  late Uri uri;
  late Duration timeout;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async => throw UnimplementedError();

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) async {
    called = true;
    this.uri = uri;
    this.timeout = timeout;
    if (error case final failure?) {
      throw failure;
    }
    return response!;
  }
}
