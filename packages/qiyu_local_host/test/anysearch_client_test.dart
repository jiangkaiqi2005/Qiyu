import 'dart:async';
import 'dart:convert';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  test('固定 JSON-RPC 端点、Bearer 与五条结果上限，搜索词先脱敏', () async {
    final http = _FakeHttpClient(
      ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'qiyu-web-search',
            'result': {
              'results': [
                for (var index = 0; index < 7; index += 1)
                  {
                    'title': '结果 $index',
                    'url': 'https://example.com/$index',
                    'snippet': '摘要 $index',
                  },
              ],
            },
          }),
        ),
      ),
    );

    final cancelled = Completer<void>();
    final results = await AnySearchClient(http).search(
      apiKey: 'any-secret',
      query: '天气 Bearer abcdefghijklmnop 验证码 123456',
      whenCancelled: cancelled.future,
    );

    expect(http.uri.toString(), anySearchEndpoint);
    expect(http.timeout, const Duration(seconds: 20));
    expect(http.budget, isNull);
    expect(http.whenCancelled, same(cancelled.future));
    expect(http.headers['authorization'], 'Bearer any-secret');
    expect(http.headers['X-Anysearch-Client'], anySearchClientName);
    expect(http.json['method'], 'tools/call');
    final arguments =
        ((http.json['params']! as Map<String, Object?>)['arguments']!
            as Map<String, Object?>);
    expect(arguments['max_results'], 5);
    expect(arguments, isNot(contains('limit')));
    expect(arguments['query'], isNot(contains('abcdefghijklmnop')));
    expect(arguments['query'], isNot(contains('123456')));
    expect(results, hasLength(5));
  });

  test('JSON-RPC error 只映射为允许列表错误', () async {
    final http = _FakeHttpClient(
      ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          '{"jsonrpc":"2.0","error":{"message":"secret raw error"}}',
        ),
      ),
    );

    await expectLater(
      AnySearchClient(http).search(apiKey: 'any-secret', query: '新闻'),
      throwsA(
        isA<ModelGatewayException>()
            .having(
              (error) => error.message,
              'safe error',
              isNot(contains('secret raw error')),
            )
            .having(
              (error) => error.message,
              'key',
              isNot(contains('any-secret')),
            ),
      ),
    );
  });

  test('解析官方 MCP Markdown 搜索结果并保留部分有效条目', () async {
    final http = _FakeHttpClient(
      ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'qiyu-web-search',
            'result': {
              'content': [
                {
                  'type': 'text',
                  'text': '''
## Search Results

### 1. [北京天气预报](https://example.com/weather)
- **URL**: https://example.com/weather
- **Snippet**: 今天有雨，最高温度 28℃。

### 2. 只有标题的部分结果
仍然可以作为摘要交给模型。

### 3.

这行畸形内容不能独立成为结果。
''',
                },
              ],
            },
          }),
        ),
      ),
    );

    final results = await AnySearchClient(
      http,
    ).search(apiKey: 'any-secret', query: '北京天气');

    expect(results, hasLength(2));
    expect(results.first.title, '北京天气预报');
    expect(results.first.url, 'https://example.com/weather');
    expect(results.first.snippet, '今天有雨，最高温度 28℃。');
    expect(results[1].title, '只有标题的部分结果');
    expect(results[1].url, isEmpty);
    expect(results[1].snippet, '仍然可以作为摘要交给模型。');
  });

  test('Markdown 结果遵守条数、字段与总长度上限', () async {
    final longText = List.filled(1600, '长').join();
    final markdown = StringBuffer('## Search Results\n');
    for (var index = 0; index < 7; index += 1) {
      markdown
        ..writeln('### ${index + 1}. [$longText](https://example.com/$index)')
        ..writeln('- **URL**: https://example.com/$index')
        ..writeln('- **Snippet**: $longText');
    }
    final http = _FakeHttpClient(
      ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'jsonrpc': '2.0',
            'result': {
              'content': [
                {'type': 'text', 'text': markdown.toString()},
              ],
            },
          }),
        ),
      ),
    );

    final results = await AnySearchClient(
      http,
    ).search(apiKey: 'any-secret', query: '长结果');

    expect(results.length, lessThanOrEqualTo(5));
    expect(results, isNotEmpty);
    expect(results.first.title.runes.length, 160);
    expect(results.first.url.runes.length, lessThanOrEqualTo(800));
    expect(results.first.snippet.runes.length, 1200);
    expect(
      results.fold<int>(
        0,
        (sum, result) =>
            sum +
            result.title.runes.length +
            result.url.runes.length +
            result.snippet.runes.length,
      ),
      lessThanOrEqualTo(6000),
    );
  });

  test('空或完全畸形的 Markdown 结果按安全解析失败处理', () async {
    final http = _FakeHttpClient(
      ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'jsonrpc': '2.0',
            'result': {
              'content': [
                {'type': 'text', 'text': '## Search Results\n普通散文，没有条目'},
              ],
            },
          }),
        ),
      ),
    );

    await expectLater(
      AnySearchClient(http).search(apiKey: 'any-secret', query: '空结果'),
      throwsA(
        isA<ModelGatewayException>().having(
          (error) => error.kind,
          'kind',
          ModelFailureKind.contentParsing,
        ),
      ),
    );
  });

  test('裸 AnySearch Key 在出网搜索词中统一脱敏', () async {
    const secret = 'as_sk_abcdefghijklmnopqrstuvwxyz123456';
    final http = _FakeHttpClient(
      ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'jsonrpc': '2.0',
            'result': {
              'results': [
                {'title': '天气', 'url': 'https://example.com', 'snippet': '晴'},
              ],
            },
          }),
        ),
      ),
    );

    await AnySearchClient(
      http,
    ).search(apiKey: 'any-secret', query: '查询 $secret 今天的天气');

    final arguments =
        ((http.json['params']! as Map<String, Object?>)['arguments']!
            as Map<String, Object?>);
    expect(arguments['query'], contains('[已脱敏]'));
    expect(arguments['query'], isNot(contains(secret)));
  });
}

final class _FakeHttpClient implements ProviderHttpClient {
  _FakeHttpClient(this.response);

  final ProviderHttpResponse response;
  late Duration timeout;
  ProviderResponseBudget? budget;
  Future<void>? whenCancelled;
  late Uri uri;
  late Map<String, String> headers;
  late Map<String, Object?> json;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    this.timeout = timeout;
    this.budget = budget;
    this.whenCancelled = whenCancelled;
    this.uri = uri;
    this.headers = headers;
    json = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    return response;
  }
}
