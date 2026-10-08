import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  const config = EmbeddingConfig(
    baseUrl: 'https://embedding.example.com/v1',
    model: 'text-embedding-test',
  );

  OpenAiEmbeddingGateway gateway(_StubEmbeddingHttp http) =>
      OpenAiEmbeddingGateway(http);

  test('请求形状：POST 拼接 embeddings 端点、Bearer 鉴权、model+input 载荷', () async {
    final http = _StubEmbeddingHttp(
      responseBody: jsonEncode({
        'data': [
          {'index': 0, 'embedding': [0.25, 0.5, 0.25]},
        ],
      }),
    );

    final vectors = await gateway(http).embed(
      config: config,
      apiKey: ' test-key ',
      inputs: ['一条输入'],
    );

    expect(http.lastUri!.toString(), 'https://embedding.example.com/v1/embeddings');
    expect(http.lastHeaders!['authorization'], 'Bearer test-key');
    expect(http.lastHeaders!['content-type'], 'application/json');
    final body = jsonDecode(utf8.decode(http.lastBody!)) as Map<String, Object?>;
    expect(body['model'], 'text-embedding-test');
    expect(body['input'], ['一条输入']);
    // 出网预算用 embedding 自己的 10 秒时限，不是聊天或语音的。
    expect(http.lastTimeout, embeddingRequestTimeout);
    expect(vectors.single, orderedCloseTo([0.25, 0.5, 0.25]));
  });

  test('多条输入按响应条目的 index 落位，缺 index 按出现顺序', () async {
    final indexed = _StubEmbeddingHttp(
      responseBody: jsonEncode({
        'data': [
          {'index': 1, 'embedding': [0.2, 0.2]},
          {'index': 0, 'embedding': [0.1, 0.1]},
        ],
      }),
    );
    final vectors = await gateway(indexed).embed(
      config: config,
      apiKey: 'k',
      inputs: ['第一条', '第二条'],
    );
    expect(vectors[0], orderedCloseTo([0.1, 0.1]));
    expect(vectors[1], orderedCloseTo([0.2, 0.2]));

    final unindexed = _StubEmbeddingHttp(
      responseBody: jsonEncode({
        'data': [
          {'embedding': [0.3, 0.3]},
          {'embedding': [0.4, 0.4]},
        ],
      }),
    );
    final vectors2 = await gateway(unindexed).embed(
      config: config,
      apiKey: 'k',
      inputs: ['第一条', '第二条'],
    );
    expect(vectors2[0], orderedCloseTo([0.3, 0.3]));
    expect(vectors2[1], orderedCloseTo([0.4, 0.4]));
  });

  test('维度不一致、embedding 缺失与非列表响应均不可发布', () async {
    final ragged = _StubEmbeddingHttp(
      responseBody: jsonEncode({
        'data': [
          {'index': 0, 'embedding': [0.1, 0.2]},
          {'index': 1, 'embedding': [0.1, 0.2, 0.3]},
        ],
      }),
    );
    await expectLater(
      gateway(ragged).embed(config: config, apiKey: 'k', inputs: ['a', 'b']),
      throwsA(
        isA<EmbeddingGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.incompatibleResponse,
        ),
      ),
    );

    final missing = _StubEmbeddingHttp(
      responseBody: jsonEncode({
        'data': [
          {'index': 0},
        ],
      }),
    );
    await expectLater(
      gateway(missing).embed(config: config, apiKey: 'k', inputs: ['a']),
      throwsA(
        isA<EmbeddingGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.incompatibleResponse,
        ),
      ),
    );

    final notList = _StubEmbeddingHttp(responseBody: '{"data": 3}');
    await expectLater(
      gateway(notList).embed(config: config, apiKey: 'k', inputs: ['a']),
      throwsA(
        isA<EmbeddingGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.contentParsing,
        ),
      ),
    );
  });

  test('非 2xx 按共享分类映射；鉴权失败文案带记忆召回服务标签', () async {
    final unauthorized = _StubEmbeddingHttp(
      statusCode: 401,
      responseBody: '{"error":"secret upstream detail"}',
    );
    await expectLater(
      gateway(unauthorized).embed(config: config, apiKey: 'k', inputs: ['a']),
      throwsA(
        isA<EmbeddingGatewayException>()
            .having(
              (error) => error.kind,
              'kind',
              ModelFailureKind.authentication,
            )
            .having(
              (error) => error.message,
              'message',
              'API Key 未通过记忆召回服务验证。',
            ),
      ),
    );
    // 异常 message 已被上一断言锁定为固定文案：上游响应原文
    // （"secret upstream detail"）不会出现在异常里。
  });

  test('出网前校验：内网地址拒绝且文案按本域服务名，Key 前置拦截', () async {
    final http = _StubEmbeddingHttp(responseBody: '{}');
    const localConfig = EmbeddingConfig(
      baseUrl: 'http://localhost:9999/v1',
      model: 'm',
    );
    await expectLater(
      gateway(http).embed(config: localConfig, apiKey: 'k', inputs: ['a']),
      throwsA(
        isA<EmbeddingGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.provider)
            .having(
              (error) => error.message,
              'message',
              '记忆召回服务地址不允许指向本机或内网。',
            ),
      ),
    );
    expect(http.postCalls, 0);

    await expectLater(
      gateway(http).embed(config: config, apiKey: '  ', inputs: ['a']),
      throwsA(
        isA<EmbeddingGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.authentication)
            .having(
              (error) => error.message,
              'message',
              '还没有保存记忆召回服务的 API Key。',
            ),
      ),
    );
    expect(http.postCalls, 0);
  });
}

Matcher orderedCloseTo(List<num> expected) => _OrderedCloseTo(expected);

final class _OrderedCloseTo extends Matcher {
  _OrderedCloseTo(this.expected);

  final List<num> expected;

  @override
  bool matches(Object? item, Map<Object?, Object?> matchState) =>
      item is Float32List &&
      item.length == expected.length &&
      List<bool>.generate(
        item.length,
        (i) => (item[i] - expected[i]).abs() < 1e-6,
      ).every((ok) => ok);

  @override
  Description describe(Description description) =>
      description.add('a Float32List close to $expected');
}

/// 桩出网 HTTP：记录最后一次请求，响应可编排。
final class _StubEmbeddingHttp implements ProviderHttpClient {
  _StubEmbeddingHttp({this.statusCode = 200, required this.responseBody});

  final int statusCode;
  final String responseBody;
  int postCalls = 0;
  Uri? lastUri;
  List<int>? lastBody;
  Map<String, String>? lastHeaders;
  Duration? lastTimeout;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    postCalls += 1;
    lastUri = uri;
    lastBody = body;
    lastHeaders = headers;
    lastTimeout = timeout;
    return ProviderHttpResponse(
      statusCode: statusCode,
      body: Stream.value(responseBody),
    );
  }
}
