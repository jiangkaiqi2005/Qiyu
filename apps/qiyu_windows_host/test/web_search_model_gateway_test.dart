import 'dart:async';
import 'dart:convert';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('Anthropic 拼接流式 tool_use 并只执行一次搜索与两次模型请求', () async {
    final http = _SequencedHttpClient([
      _sse([
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'tool_use',
            'id': 'tool-1',
            'name': 'web_search',
            'input': <String, Object?>{},
          },
        },
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'input_json_delta', 'partial_json': '{"query":"今'},
        },
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'input_json_delta', 'partial_json': '天天气"}'},
        },
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
        },
        {'type': 'message_stop'},
      ]),
      _sse([
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': '今天会下雨，带伞。'},
        },
        {'type': 'message_stop'},
      ]),
    ]);
    final search = _FakeWebSearchClient();
    final events = await ProviderModelGateway(http)
        .streamWithWebSearch(
          config: _anthropicConfig,
          apiKey: 'provider-secret',
          messages: const [
            ModelMessage(ModelMessageRole.system, 'system'),
            ModelMessage(ModelMessageRole.user, '今天天气？'),
          ],
          webSearchApiKey: 'any-secret',
          webSearchClient: search,
        )
        .toList();

    expect(http.bodies, hasLength(2));
    expect(http.bodies.first['tools'], hasLength(1));
    expect(
      ((http.bodies.first['tools']! as List).single as Map)['name'],
      'web_search',
    );
    expect(http.bodies[1], isNot(contains('tools')));
    expect(http.bodies[1], isNot(contains('tool_choice')));
    expect(search.queries, ['今天天气']);
    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(events.first.text, '今天会下雨，带伞。');
  });

  test('第二轮再次发工具调用时受控失败且不会再次搜索', () async {
    final toolTurn = _sse([
      {
        'type': 'content_block_start',
        'content_block': {
          'type': 'tool_use',
          'id': 'tool-1',
          'name': 'web_search',
          'input': {'query': '新闻'},
        },
      },
      {'type': 'message_stop'},
    ]);
    final http = _SequencedHttpClient([toolTurn, toolTurn]);
    final search = _FakeWebSearchClient();

    final events = await ProviderModelGateway(http)
        .streamWithWebSearch(
          config: _anthropicConfig,
          apiKey: 'provider-secret',
          messages: const [ModelMessage(ModelMessageRole.user, '新闻')],
          webSearchApiKey: 'any-secret',
          webSearchClient: search,
        )
        .toList();

    expect(search.queries, ['新闻']);
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.incompatibleResponse);
  });

  test('未知工具、畸形 JSON、提前 EOF 与 Anthropic 原生错误均安全关闭', () async {
    final scenarios =
        <
          ({
            String name,
            ProviderHttpResponse response,
            ModelFailureKind failure,
          })
        >[
          (
            name: 'unknown-tool',
            response: _sse([
              {
                'type': 'content_block_start',
                'content_block': {
                  'type': 'tool_use',
                  'id': 'tool-unknown',
                  'name': 'get_local_time',
                  'input': <String, Object?>{},
                },
              },
              {'type': 'message_stop'},
            ]),
            failure: ModelFailureKind.incompatibleResponse,
          ),
          (
            name: 'malformed-json',
            response: _sse([
              {
                'type': 'content_block_start',
                'content_block': {
                  'type': 'tool_use',
                  'id': 'tool-malformed',
                  'name': 'web_search',
                  'input': <String, Object?>{},
                },
              },
              {
                'type': 'content_block_delta',
                'delta': {
                  'type': 'input_json_delta',
                  'partial_json': '{"query":',
                },
              },
              {'type': 'message_stop'},
            ]),
            failure: ModelFailureKind.incompatibleResponse,
          ),
          (
            name: 'early-eof',
            response: ProviderHttpResponse(
              statusCode: 200,
              body: Stream.value(
                'data: ${jsonEncode({
                  'type': 'content_block_start',
                  'content_block': {
                    'type': 'tool_use',
                    'id': 'tool-eof',
                    'name': 'web_search',
                    'input': {'query': '新闻'},
                  },
                })}\n\n',
              ),
            ),
            failure: ModelFailureKind.network,
          ),
          (
            name: 'native-error',
            response: _sse([
              {
                'type': 'error',
                'error': {'message': 'Authorization: Bearer must-not-leak'},
              },
            ]),
            failure: ModelFailureKind.provider,
          ),
        ];

    for (final scenario in scenarios) {
      final http = _SequencedHttpClient([scenario.response]);
      final search = _FakeWebSearchClient();
      final events = await ProviderModelGateway(http)
          .streamWithWebSearch(
            config: _anthropicConfig,
            apiKey: 'provider-secret',
            messages: const [ModelMessage(ModelMessageRole.user, '新闻')],
            webSearchApiKey: 'any-secret',
            webSearchClient: search,
          )
          .toList();

      expect(events, hasLength(1), reason: scenario.name);
      expect(events.single.kind, ModelStreamEventKind.failure);
      expect(events.single.failure, scenario.failure, reason: scenario.name);
      expect(events.single.message, isNot(contains('must-not-leak')));
      expect(search.queries, isEmpty, reason: scenario.name);
      expect(http.bodies, hasLength(1), reason: scenario.name);
    }
  });

  test('第一轮模型、AnySearch 与第二轮模型三阶段均可取消', () async {
    for (final stage in _CancellationStage.values) {
      final http = _CancellableRoundTripHttpClient(stage);
      final cancelled = Completer<void>();
      final eventsFuture = ProviderModelGateway(http)
          .streamWithWebSearch(
            config: _anthropicConfig,
            apiKey: 'provider-secret',
            messages: const [ModelMessage(ModelMessageRole.user, '新闻')],
            webSearchApiKey: 'any-secret',
            webSearchClient: AnySearchClient(http),
            whenCancelled: cancelled.future,
          )
          .toList();

      await http.blockedRequestStarted.future;
      cancelled.complete();

      expect(await eventsFuture, isEmpty, reason: stage.name);
      expect(http.blockedRequestCancelled, isTrue, reason: stage.name);
      expect(
        http.providerCalls,
        stage == _CancellationStage.secondProvider ? 2 : 1,
        reason: stage.name,
      );
      expect(
        http.searchCalls,
        stage == _CancellationStage.firstProvider ? 0 : 1,
        reason: stage.name,
      );
    }
  });

  test('AnySearch 鉴权、限流、超时、空结果与不兼容响应均完成第二轮回复', () async {
    final scenarios =
        <({String name, ProviderHttpResponse? response, Object? error})>[
          (
            name: 'authentication',
            response: ProviderHttpResponse(
              statusCode: 401,
              body: Stream.value('{"error":"bad any-secret"}'),
            ),
            error: null,
          ),
          (
            name: 'rate-limit',
            response: ProviderHttpResponse(
              statusCode: 429,
              body: Stream.value('{"error":"slow down"}'),
            ),
            error: null,
          ),
          (name: 'timeout', response: null, error: TimeoutException('slow')),
          (
            name: 'empty-results',
            response: ProviderHttpResponse(
              statusCode: 200,
              body: Stream.value(
                '{"jsonrpc":"2.0","id":"qiyu-web-search",'
                '"result":{"content":[]}}',
              ),
            ),
            error: null,
          ),
          (
            name: 'incompatible-response',
            response: ProviderHttpResponse(
              statusCode: 200,
              body: Stream.value('<html>not json</html>'),
            ),
            error: null,
          ),
        ];

    for (final scenario in scenarios) {
      final http = _FailingSearchRoundTripHttpClient(
        searchResponse: scenario.response,
        searchError: scenario.error,
      );
      final events = await ProviderModelGateway(http)
          .streamWithWebSearch(
            config: _anthropicConfig,
            apiKey: 'provider-secret',
            messages: const [ModelMessage(ModelMessageRole.user, '新闻')],
            webSearchApiKey: 'any-secret',
            webSearchClient: AnySearchClient(http),
          )
          .toList();

      expect(events.map((event) => event.kind), [
        ModelStreamEventKind.delta,
        ModelStreamEventKind.done,
      ], reason: scenario.name);
      expect(events.first.text, '这次没搜到可靠信息。', reason: scenario.name);
      expect(http.providerBodies, hasLength(2), reason: scenario.name);
      expect(http.searchCalls, 1, reason: scenario.name);
      final messages = http.providerBodies.last['messages']! as List<Object?>;
      final toolResultMessage = messages.last as Map<String, Object?>;
      final toolResult =
          (toolResultMessage['content']! as List<Object?>).single
              as Map<String, Object?>;
      expect(toolResult['type'], 'tool_result', reason: scenario.name);
      expect(toolResult['is_error'], isTrue, reason: scenario.name);
      expect(
        toolResult['content'],
        '这次联网搜索失败，无法取得可靠结果。',
        reason: scenario.name,
      );
      expect(
        jsonEncode(http.providerBodies.last),
        isNot(contains('any-secret')),
      );
      expect(
        jsonEncode(http.providerBodies.last),
        isNot(contains('slow down')),
      );
    }
  });
}

const _anthropicConfig = ProviderConfig(
  kind: ProviderKind.anthropic,
  baseUrl: 'https://api.example.com/v1',
  model: 'deepseek-v4-flash',
  temperature: 0.6,
  timeoutSeconds: 25,
);

ProviderHttpResponse _sse(List<Map<String, Object?>> payloads) =>
    ProviderHttpResponse(
      statusCode: 200,
      body: Stream.fromIterable([
        for (final payload in payloads) 'data: ${jsonEncode(payload)}\n\n',
      ]),
    );

final class _SequencedHttpClient implements ProviderHttpClient {
  _SequencedHttpClient(this.responses);

  final List<ProviderHttpResponse> responses;
  final bodies = <Map<String, Object?>>[];

  @override
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) async {
    bodies.add(jsonDecode(body) as Map<String, Object?>);
    return responses[bodies.length - 1];
  }

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) => throw UnimplementedError();
}

final class _FakeWebSearchClient implements WebSearchClient {
  final queries = <String>[];

  @override
  Future<List<WebSearchResult>> search({
    required String apiKey,
    required String query,
    Future<void>? whenCancelled,
  }) async {
    queries.add(query);
    return const [
      WebSearchResult(
        title: '天气',
        url: 'https://example.com/weather',
        snippet: '今天有雨',
      ),
    ];
  }
}

enum _CancellationStage { firstProvider, anySearch, secondProvider }

final class _CancellableRoundTripHttpClient
    implements CancellableProviderHttpClient {
  _CancellableRoundTripHttpClient(this.stage);

  final _CancellationStage stage;
  final blockedRequestStarted = Completer<void>();
  var blockedRequestCancelled = false;
  var providerCalls = 0;
  var searchCalls = 0;

  @override
  Future<ProviderHttpResponse> postStreamCancellable({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    required Future<void> whenCancelled,
  }) async {
    providerCalls += 1;
    final blocksHere =
        (stage == _CancellationStage.firstProvider && providerCalls == 1) ||
        (stage == _CancellationStage.secondProvider && providerCalls == 2);
    if (blocksHere) {
      blockedRequestStarted.complete();
      await whenCancelled;
      blockedRequestCancelled = true;
      throw const ProviderRequestCancelled();
    }
    if (providerCalls == 2) {
      return _sse([
        {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': '搜索完成。'},
        },
        {'type': 'message_stop'},
      ]);
    }
    return _toolUseResponse();
  }

  @override
  Future<ProviderHttpResponse> postCancellable({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    required Future<void> whenCancelled,
  }) async {
    searchCalls += 1;
    if (stage == _CancellationStage.anySearch) {
      blockedRequestStarted.complete();
      await whenCancelled;
      blockedRequestCancelled = true;
      throw const ProviderRequestCancelled();
    }
    return _successfulSearchResponse();
  }

  @override
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) => throw UnimplementedError();

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) => throw UnimplementedError();
}

final class _FailingSearchRoundTripHttpClient implements ProviderHttpClient {
  _FailingSearchRoundTripHttpClient({
    required this.searchResponse,
    required this.searchError,
  });

  final ProviderHttpResponse? searchResponse;
  final Object? searchError;
  final providerBodies = <Map<String, Object?>>[];
  var searchCalls = 0;

  @override
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) async {
    providerBodies.add(jsonDecode(body) as Map<String, Object?>);
    if (providerBodies.length == 1) {
      return _toolUseResponse();
    }
    return _sse([
      {
        'type': 'content_block_delta',
        'delta': {'type': 'text_delta', 'text': '这次没搜到可靠信息。'},
      },
      {'type': 'message_stop'},
    ]);
  }

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    searchCalls += 1;
    if (searchError case final error?) {
      throw error;
    }
    return searchResponse!;
  }
}

ProviderHttpResponse _toolUseResponse() => _sse([
  {
    'type': 'content_block_start',
    'content_block': {
      'type': 'tool_use',
      'id': 'tool-1',
      'name': 'web_search',
      'input': {'query': '新闻'},
    },
  },
  {'type': 'message_stop'},
]);

ProviderHttpResponse _successfulSearchResponse() => ProviderHttpResponse(
  statusCode: 200,
  body: Stream.value(
    '{"jsonrpc":"2.0","id":"qiyu-web-search",'
    '"result":{"results":[{"title":"新闻","url":"https://example.com",'
    '"snippet":"内容"}]}}',
  ),
);
