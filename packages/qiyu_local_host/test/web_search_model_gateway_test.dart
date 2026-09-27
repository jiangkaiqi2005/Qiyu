import 'dart:async';
import 'dart:convert';

import 'package:qiyu_local_host/qiyu_local_host.dart';
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

  test('首轮纯文本响应不触发搜索且只发一次模型请求', () async {
    final http = _SequencedHttpClient([
      _sse([
        {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': '今晚早点休息。'},
        },
        {'type': 'message_stop'},
      ]),
    ]);
    final search = _FakeWebSearchClient();
    final events = await ProviderModelGateway(http)
        .streamWithWebSearch(
          config: _anthropicConfig,
          apiKey: 'provider-secret',
          messages: const [ModelMessage(ModelMessageRole.user, '随便聊聊')],
          webSearchApiKey: 'any-secret',
          webSearchClient: search,
        )
        .toList();

    expect(http.bodies, hasLength(1));
    expect(http.bodies.single['tools'], hasLength(1));
    expect(search.queries, isEmpty);
    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(events.first.text, '今晚早点休息。');
  });

  test('同一轮两个并行 web_search 各自解析、分别搜索并按 id 一一回传结果', () async {
    final http = _SequencedHttpClient([
      _sse([
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'thinking', 'thinking': ''},
        },
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': '需要先查一下'},
        },
        {
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'text', 'text': ''},
        },
        {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'text_delta', 'text': '我查一下。'},
        },
        {
          'type': 'content_block_start',
          'index': 2,
          'content_block': {
            'type': 'tool_use',
            'id': 'tool-a',
            'name': 'web_search',
            'input': <String, Object?>{},
          },
        },
        {
          'type': 'content_block_delta',
          'index': 2,
          'delta': {'type': 'input_json_delta', 'partial_json': '{"query":"今'},
        },
        {
          'type': 'content_block_delta',
          'index': 2,
          'delta': {'type': 'input_json_delta', 'partial_json': '天天气"}'},
        },
        {
          'type': 'content_block_start',
          'index': 3,
          'content_block': {
            'type': 'tool_use',
            'id': 'tool-b',
            'name': 'web_search',
            'input': <String, Object?>{},
          },
        },
        {
          'type': 'content_block_delta',
          'index': 3,
          'delta': {'type': 'input_json_delta', 'partial_json': '{"query":"新'},
        },
        {
          'type': 'content_block_delta',
          'index': 3,
          'delta': {'type': 'input_json_delta', 'partial_json': '闻头条"}'},
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
          'delta': {'type': 'text_delta', 'text': '今天有雨，记得带伞。'},
        },
        {'type': 'message_stop'},
      ]),
    ]);
    final search = _FakeWebSearchClient();
    final events = await ProviderModelGateway(http)
        .streamWithWebSearch(
          config: _anthropicConfig,
          apiKey: 'provider-secret',
          messages: const [ModelMessage(ModelMessageRole.user, '今天有什么新闻？')],
          webSearchApiKey: 'any-secret',
          webSearchClient: search,
        )
        .toList();

    // thinking 与首轮可见文本不得混入任何工具参数。
    expect(search.queries, ['今天天气', '新闻头条']);
    expect(http.bodies, hasLength(2));
    expect(http.bodies[1], isNot(contains('tools')));
    expect(http.bodies[1], isNot(contains('tool_choice')));
    final messages = http.bodies[1]['messages']! as List<Object?>;
    final assistant = messages[messages.length - 2] as Map<String, Object?>;
    expect(assistant['role'], 'assistant');
    final toolUses = assistant['content']! as List<Object?>;
    expect(toolUses, hasLength(2));
    expect((toolUses[0]! as Map)['type'], 'tool_use');
    expect((toolUses[0]! as Map)['id'], 'tool-a');
    expect((toolUses[0]! as Map)['name'], 'web_search');
    expect((toolUses[0]! as Map)['input'], {'query': '今天天气'});
    expect((toolUses[1]! as Map)['id'], 'tool-b');
    expect((toolUses[1]! as Map)['name'], 'web_search');
    expect((toolUses[1]! as Map)['input'], {'query': '新闻头条'});
    final toolResultMessage = messages.last as Map<String, Object?>;
    expect(toolResultMessage['role'], 'user');
    final toolResults = toolResultMessage['content']! as List<Object?>;
    expect(toolResults, hasLength(2));
    expect((toolResults[0]! as Map)['type'], 'tool_result');
    expect((toolResults[0]! as Map)['tool_use_id'], 'tool-a');
    expect((toolResults[0]! as Map)['is_error'], isNull);
    expect(
      jsonDecode((toolResults[0]! as Map)['content']! as String),
      isA<List<Object?>>().having(
        (results) => (results.single as Map)['title'],
        'single.title',
        '天气',
      ),
    );
    expect((toolResults[1]! as Map)['tool_use_id'], 'tool-b');
    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    // 首轮可见文本不交付，只交付第二轮最终回复而非 failure。
    expect(events.first.text, '今天有雨，记得带伞。');
  });

  test('两个并行搜索中单个失败只生成对应 is_error 结果且其余照常', () async {
    final http = _SequencedHttpClient([
      _sse([
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'tool_use',
            'id': 'tool-a',
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
          'type': 'content_block_start',
          'index': 1,
          'content_block': {
            'type': 'tool_use',
            'id': 'tool-b',
            'name': 'web_search',
            'input': <String, Object?>{},
          },
        },
        {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'input_json_delta', 'partial_json': '{"query":"新'},
        },
        {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'input_json_delta', 'partial_json': '闻头条"}'},
        },
        {'type': 'message_stop'},
      ]),
      _sse([
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': '天气有雨，头条也看过了。'},
        },
        {'type': 'message_stop'},
      ]),
    ]);
    final search = _FailingSecondQueryWebSearchClient();
    final events = await ProviderModelGateway(http)
        .streamWithWebSearch(
          config: _anthropicConfig,
          apiKey: 'provider-secret',
          messages: const [ModelMessage(ModelMessageRole.user, '今天有什么新闻？')],
          webSearchApiKey: 'any-secret',
          webSearchClient: search,
        )
        .toList();

    // 两次搜索都发起。
    expect(search.queries, ['今天天气', '新闻头条']);
    expect(http.bodies, hasLength(2));
    final messages = http.bodies[1]['messages']! as List<Object?>;
    final assistant = messages[messages.length - 2] as Map<String, Object?>;
    final toolUses = assistant['content']! as List<Object?>;
    expect(toolUses, hasLength(2));
    expect((toolUses[0]! as Map)['id'], 'tool-a');
    expect((toolUses[1]! as Map)['id'], 'tool-b');
    final toolResultMessage = messages.last as Map<String, Object?>;
    expect(toolResultMessage['role'], 'user');
    final toolResults = toolResultMessage['content']! as List<Object?>;
    expect(toolResults, hasLength(2));
    // 成功的调用：内容校验到结果字段。
    expect((toolResults[0]! as Map)['tool_use_id'], 'tool-a');
    expect((toolResults[0]! as Map)['is_error'], isNull);
    expect(
      jsonDecode((toolResults[0]! as Map)['content']! as String),
      isA<List<Object?>>().having(
        (results) => (results.single as Map)['url'],
        'single.url',
        'https://example.com/weather',
      ),
    );
    // 失败的调用：is_error 且只有脱敏文案。
    expect((toolResults[1]! as Map)['tool_use_id'], 'tool-b');
    expect((toolResults[1]! as Map)['is_error'], isTrue);
    expect(
      (toolResults[1]! as Map)['content'],
      '这次联网搜索失败，无法取得可靠结果。',
    );
    expect(
      jsonEncode(http.bodies[1]),
      isNot(contains('slow')),
    );
    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(events.first.text, '天气有雨，头条也看过了。');
  });

  test('兼容服务省略 index 时参数增量仍累计到唯一工具块并正常交付', () async {
    final http = _SequencedHttpClient([
      _sse([
        {
          'type': 'content_block_start',
          'content_block': {
            'type': 'tool_use',
            'id': 'tool-1',
            'name': 'web_search',
            'input': <String, Object?>{},
          },
        },
        {
          'type': 'content_block_delta',
          'delta': {'type': 'input_json_delta', 'partial_json': '{"query":"今'},
        },
        {
          'type': 'content_block_delta',
          'delta': {'type': 'input_json_delta', 'partial_json': '天天气"}'},
        },
        {'type': 'message_stop'},
      ]),
      _sse([
        {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': '今天会下雨，记得带伞。'},
        },
        {'type': 'message_stop'},
      ]),
    ]);
    final search = _FakeWebSearchClient();
    final events = await ProviderModelGateway(http)
        .streamWithWebSearch(
          config: _anthropicConfig,
          apiKey: 'provider-secret',
          messages: const [ModelMessage(ModelMessageRole.user, '今天天气？')],
          webSearchApiKey: 'any-secret',
          webSearchClient: search,
        )
        .toList();

    expect(search.queries, ['今天天气']);
    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(events.first.text, '今天会下雨，记得带伞。');
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

  test('streamWithWebSearch records diagnostic and preserves internal failure on unexpected error', () async {
    final diagnostics = <String>[];
    final http = _ThrowingHttpClient(StateError('unexpected crash'));
    final gateway = ProviderModelGateway(http, diagnosticsSink: diagnostics.add);
    final events = await gateway
        .streamWithWebSearch(
          config: _anthropicConfig,
          apiKey: 'provider-secret',
          messages: const [ModelMessage(ModelMessageRole.user, '新闻')],
          webSearchApiKey: 'any-secret',
          webSearchClient: _FakeWebSearchClient(),
        )
        .toList();

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.internal);
    expect(events.single.message, '本机程序内部出错。');
    expect(diagnostics, hasLength(1));
    expect(diagnostics.single, contains('unexpected crash'));
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
      expect(http.cancellationSignals, everyElement(same(cancelled.future)));
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

  test('多个并行搜索中途停止会取消剩余搜索且不再发起第二轮请求', () async {
    final http = _ParallelSearchCancelHttpClient();
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

    await http.blockedSearchStarted.future;
    cancelled.complete();

    expect(await eventsFuture, isEmpty);
    expect(http.blockedSearchCancelled, isTrue);
    expect(http.searchCalls, 2);
    expect(http.providerCalls, 1);
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
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    bodies.add(jsonDecode(utf8.decode(body)) as Map<String, Object?>);
    return responses[bodies.length - 1];
  }
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

/// 第二个查询抛错的假搜索客户端：验证单个搜索失败不中断其余调用。
final class _FailingSecondQueryWebSearchClient implements WebSearchClient {
  final queries = <String>[];

  @override
  Future<List<WebSearchResult>> search({
    required String apiKey,
    required String query,
    Future<void>? whenCancelled,
  }) async {
    queries.add(query);
    if (query == '新闻头条') {
      throw TimeoutException('slow');
    }
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

final class _CancellableRoundTripHttpClient implements ProviderHttpClient {
  _CancellableRoundTripHttpClient(this.stage);

  final _CancellationStage stage;
  final blockedRequestStarted = Completer<void>();
  var blockedRequestCancelled = false;
  final cancellationSignals = <Future<void>?>[];
  var providerCalls = 0;
  var searchCalls = 0;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    cancellationSignals.add(whenCancelled);
    if (uri.toString() == anySearchEndpoint) {
      searchCalls += 1;
      if (stage == _CancellationStage.anySearch) {
        blockedRequestStarted.complete();
        await whenCancelled;
        blockedRequestCancelled = true;
        throw const ProviderRequestCancelled();
      }
      return _successfulSearchResponse();
    }
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
}

/// 第一轮返回两个并行 web_search 调用；第一次搜索成功、第二次阻塞等待
/// 取消信号，用来验证取消覆盖全部未完成搜索与第二轮模型请求。
final class _ParallelSearchCancelHttpClient implements ProviderHttpClient {
  final blockedSearchStarted = Completer<void>();
  var blockedSearchCancelled = false;
  var providerCalls = 0;
  var searchCalls = 0;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    if (uri.toString() == anySearchEndpoint) {
      searchCalls += 1;
      if (searchCalls == 1) {
        return _successfulSearchResponse();
      }
      blockedSearchStarted.complete();
      await whenCancelled;
      blockedSearchCancelled = true;
      throw const ProviderRequestCancelled();
    }
    providerCalls += 1;
    return _sse([
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {
          'type': 'tool_use',
          'id': 'tool-a',
          'name': 'web_search',
          'input': {'query': '今天天气'},
        },
      },
      {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'tool_use',
          'id': 'tool-b',
          'name': 'web_search',
          'input': {'query': '新闻头条'},
        },
      },
      {'type': 'message_stop'},
    ]);
  }
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
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    if (uri.toString() == anySearchEndpoint) {
      searchCalls += 1;
      if (searchError case final error?) {
        throw error;
      }
      return searchResponse!;
    }
    providerBodies.add(jsonDecode(utf8.decode(body)) as Map<String, Object?>);
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

final class _ThrowingHttpClient implements ProviderHttpClient {
  const _ThrowingHttpClient(this.error);

  final Object error;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) => throw error;
}
