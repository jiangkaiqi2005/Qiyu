import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  test('统一文本请求等待响应头时可取消', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      received.complete();
      // 有意不发响应头，验证取消不会等待读取阶段或请求超时。
    });
    final cancel = Completer<void>();
    final pending = const DartIoProviderHttpClient().post(
      uri: Uri.parse('http://127.0.0.1:${server.port}/test'),
      headers: const {},
      body: const [],
      timeout: const Duration(seconds: 5),
      whenCancelled: cancel.future,
    );
    final checked = expectLater(
      pending, throwsA(isA<ProviderRequestCancelled>()),
    );
    await received.future.timeout(const Duration(seconds: 1));
    cancel.complete();
    await checked.timeout(const Duration(seconds: 1));
  });

  for (final cancelRequest in [true, false]) {
    test('统一文本请求等待代理配置时${cancelRequest ? '可取消' : '计入整体期限'}', () async {
      final transport = _ByteHttpClient([]);
      final resolving = Completer<void>();
      final rules = Completer<ProxyRules?>();
      final cancel = Completer<void>();
      final client = DartIoProviderHttpClient(
        httpClientFactory: (_) => transport,
        proxyRulesSource: () {
          resolving.complete();
          return rules.future;
        },
      );
      final pending = client.post(
        uri: Uri.parse('https://example.com/test'),
        headers: const {},
        body: const [],
        timeout: const Duration(milliseconds: 100),
        whenCancelled: cancel.future,
        budget: const ProviderResponseBudget(
          maxFrameBytes: 1024,
          maxResponseBytes: 1024,
          maxErrorBodyBytes: 1024,
        ),
      );
      final checked = expectLater(
        pending,
        throwsA(
          cancelRequest
              ? isA<ProviderRequestCancelled>()
              : isA<TimeoutException>(),
        ),
      );
      await resolving.future;
      if (cancelRequest) {
        cancel.complete();
      }
      try {
        await checked.timeout(const Duration(seconds: 1));
      } finally {
        rules.complete(null);
      }
      await Future<void>.delayed(Duration.zero);
      expect(transport.closed, isTrue);
      expect(transport.opened, isFalse);
    });
  }

  test('统一文本请求在静默读取时取消订阅并只报告一次取消', () async {
    for (final budget in <ProviderResponseBudget?>[
      null,
      const ProviderResponseBudget(
        maxFrameBytes: 1024 * 1024,
        maxResponseBytes: 16 * 1024 * 1024,
        maxErrorBodyBytes: 64 * 1024,
      ),
    ]) {
      final transport = _ByteHttpClient([]);
      final cancel = Completer<void>();
      final response = await transport.provider.post(
        uri: Uri.parse('http://127.0.0.1/test'),
        headers: const {},
        body: const [],
        timeout: const Duration(seconds: 5),
        whenCancelled: cancel.future,
        budget: budget,
      );
      final errors = <Object>[];
      final done = Completer<void>();
      final subscription = response.body.listen(
        (_) => fail('静默响应不应产生数据'),
        onError: errors.add,
        onDone: done.complete,
      );
      addTearDown(subscription.cancel);
      cancel.complete();
      await done.future.timeout(const Duration(seconds: 1));
      expect(errors, [isA<ProviderRequestCancelled>()]);
      expect(transport.closed && transport.response.cancelled, isTrue);
    }
  });

  for (final scenario in [
    (name: '无工具纯文本', useTool: false, firstOpen: true),
    (name: '工具结果后第二回合', useTool: true, firstOpen: false),
    (name: '工具调用前后两个回合', useTool: true, firstOpen: true),
  ]) {
    test('Anthropic 工具入口${scenario.name}在 HTTP 未 EOF 时完成', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Map<String, Object?>>[];
      server.listen((request) async {
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>,
        );
        final first = requests.length == 1;
        request.response.bufferOutput = false;
        request.response.add(
          utf8.encode(
            scenario.useTool && first ? _anthropicToolBody : _anthropicTextBody,
          ),
        );
        try {
          await request.response.flush();
          if (first && !scenario.firstOpen) {
            await request.response.close();
          }
        } on Object {
          // 原生结束后的客户端取消或测试清理会关闭连接。
        }
      });
      final search = _RecordingSearch();
      final events = await _searchEvents(
        const DartIoProviderHttpClient(),
        search,
        port: server.port,
      );
      _expectCompleted(events);
      expect(requests, hasLength(scenario.useTool ? 2 : 1));
      expect(search.queries, scenario.useTool ? ['今天天气'] : isEmpty);
      if (scenario.useTool) {
        final messages = requests.last['messages']! as List;
        expect((messages[messages.length - 2] as Map)['content'], [
          {
            'type': 'tool_use',
            'id': 'tool-1',
            'name': 'web_search',
            'input': {'query': '今天天气'},
          },
        ]);
        expect((messages.last as Map)['content'], [
          {'type': 'tool_result', 'tool_use_id': 'tool-1', 'content': '[]'},
        ]);
      }
    });
  }

  for (final round in ['纯文本', '工具首轮', '工具次轮']) {
    test('Anthropic 工具入口$round按终态前后顺序处理同块及分块异常', () async {
      for (final invalid in [
        [0xff, 0x0a],
        [...List<int>.filled(1024 * 1024 + 1, 0x78), 0x0a],
        utf8.encode(
          'data: {"type":"error","error":{"message":"synthetic-error"}}\n',
        ),
      ]) {
        for (final afterDone in [false, true]) {
          final terminal = utf8.encode(
            round == '工具首轮' ? _anthropicToolBody : _anthropicTextBody,
          );
          final chunks = afterDone ? [terminal, invalid] : [invalid, terminal];
          for (final layout in [
            chunks,
            [chunks.expand((bytes) => bytes).toList()],
          ]) {
            final target = _ByteHttpClient(layout);
            final transports = [
              if (round == '工具次轮')
                _ByteHttpClient([utf8.encode(_anthropicToolBody)]),
              target,
              if (round == '工具首轮')
                _ByteHttpClient([utf8.encode(_anthropicTextBody)]),
            ];
            var requests = 0;
            final search = _RecordingSearch();
            final events = await _searchEvents(
              DartIoProviderHttpClient(
                httpClientFactory: (_) => transports[requests++],
              ),
              search,
            );
            if (afterDone) {
              _expectCompleted(events);
            } else {
              expect(events.single.kind, ModelStreamEventKind.failure);
            }
            final searched = round == '工具次轮' || (round == '工具首轮' && afterDone);
            expect(search.queries, searched ? ['今天天气'] : isEmpty);
            expect(requests, searched ? 2 : 1);
            expect(
              transports
                  .take(requests)
                  .every(
                    (transport) =>
                        transport.closed && transport.response.cancelled,
                  ),
              isTrue,
            );
          }
        }
      }
    });
  }

  test('Anthropic 工具入口结束后仍校验工具参数再执行搜索', () async {
    final transport = _ByteHttpClient([
      utf8.encode(_anthropicToolBody.replaceAll('query', 'unknown')),
    ]);
    final search = _RecordingSearch();
    final events = await _searchEvents(transport.provider, search);
    expect(events.single.failure, ModelFailureKind.contentParsing);
    expect(search.queries, isEmpty);
    expect(transport.closed && transport.response.cancelled, isTrue);
  });

  for (final fixture in _nativeCompletions) {
    test('${fixture.name} 完整结束行在 HTTP 未 EOF 时完成', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        // 客户端在协议终态即关闭连接；请求体可能尚未送达，
        // 吞掉服务端读取错误，避免与断言无关的 HttpException。
        request.listen((_) {}, onError: (Object _) {});
        request.response.bufferOutput = false;
        request.response.add(utf8.encode(fixture.body));
        // 有意不 close：只有协议终态可以结束消费，flush 不保证 TCP 分块。
        unawaited(request.response.flush().catchError((Object _) {}));
      });

      final events = await _events(
        const DartIoProviderHttpClient(),
        fixture.kind,
        port: server.port,
      );
      _expectCompleted(events);
    });

    for (final tail in [
      (name: '超帧尾部', bytes: List<int>.filled(1024 * 1024 + 1, 0x78)),
      (name: '无效 UTF-8 尾部', bytes: [0xff, 0x0a]),
    ]) {
      test('${fixture.name} 终态之后${tail.name}同块或分块均不改变成功', () async {
        final prefix = utf8.encode(fixture.body);
        for (final chunks in [
          [prefix, tail.bytes],
          [
            [...prefix, ...tail.bytes],
          ],
        ]) {
          final transport = _ByteHttpClient(chunks);
          final events = await _events(transport.provider, fixture.kind);
          _expectCompleted(events);
          expect(transport.closed, isTrue);
          expect(transport.response.cancelled, isTrue);
        }
      });
    }

    for (final ending in ['\n', '\r', '\r\n']) {
      test(
        '${fixture.name} ${jsonEncode(ending)} 与 UTF-8 在任意字节断点均完成',
        () async {
          final bytes = utf8.encode(fixture.body.replaceAll('\n', ending));
          final layouts = [
            [bytes],
            bytes.map((byte) => [byte]).toList(),
            for (var cut = 1; cut < bytes.length; cut++)
              [bytes.sublist(0, cut), bytes.sublist(cut)],
          ];
          for (final chunks in layouts) {
            final transport = _ByteHttpClient(chunks);
            _expectCompleted(await _events(transport.provider, fixture.kind));
            expect(transport.closed && transport.response.cancelled, isTrue);
          }
        },
      );
    }

    for (final prefix in [
      (name: '超帧', bytes: [...List<int>.filled(1024 * 1024 + 1, 0x78), 0x0a]),
      (name: '无效 UTF-8', bytes: [0xff, 0x0a]),
      (
        name: '无效 JSON',
        bytes: utf8.encode(
          fixture.kind == ProviderKind.ollama ? '{\n' : 'data: {\n',
        ),
      ),
    ]) {
      test('${fixture.name} 终态前${prefix.name}同块或分块均失败并关闭资源', () async {
        final terminal = utf8.encode(fixture.body);
        for (final chunks in [
          [prefix.bytes, terminal],
          [
            [...prefix.bytes, ...terminal],
          ],
        ]) {
          final transport = _ByteHttpClient(chunks);
          final events = await _events(transport.provider, fixture.kind);
          expect(events.single.kind, ModelStreamEventKind.failure);
          expect(events.single.failure, ModelFailureKind.incompatibleResponse);
          expect(transport.closed && transport.response.cancelled, isTrue);
        }
      });
    }

    test('${fixture.name} 未闭合结束行且连接静默仍超时', () async {
      final transport = _ByteHttpClient([
        utf8.encode(fixture.body.substring(0, fixture.body.length - 1)),
      ]);
      final events = await _events(transport.provider, fixture.kind);
      expect(events.last.failure, ModelFailureKind.timeout);
      expect(
        events.map((event) => event.kind),
        isNot(contains(ModelStreamEventKind.done)),
      );
      expect(transport.closed && transport.response.cancelled, isTrue);
    });
  }

  test('16 MiB 内终态后的空行、越总量帧同块或分块不改变成功', () async {
    final prefix = _paddedCompletion(_responseLimit);
    for (final suffix in [
      [0x0a],
      utf8.encode(': tail\n'),
    ]) {
      for (final chunks in [
        [prefix, suffix],
        [
          [...prefix, ...suffix],
        ],
      ]) {
        final transport = _ByteHttpClient(chunks);
        _expectCompleted(
          await _events(transport.provider, ProviderKind.openAiCompatible),
        );
        expect(transport.closed && transport.response.cancelled, isTrue);
      }
    }
  });

  test('终态首个 LF 超过 16 MiB 时同块或分块均失败', () async {
    final bytes = _paddedCompletion(_responseLimit + 1);
    for (final chunks in [
      [bytes],
      [
        bytes.sublist(0, bytes.length - 1),
        [0x0a],
      ],
    ]) {
      final transport = _ByteHttpClient(chunks);
      final events = await _events(
        transport.provider,
        ProviderKind.openAiCompatible,
      );
      expect(events.single.kind, ModelStreamEventKind.failure);
      expect(events.single.failure, ModelFailureKind.incompatibleResponse);
      expect(transport.closed && transport.response.cancelled, isTrue);
    }
  });

  test('预算前缀 CRLF 两字节均计总量，帧不含换行符', () async {
    for (final maxTotal in [4, 3]) {
      final transport = _ByteHttpClient([
        utf8.encode('a\r'),
        utf8.encode('\nb'),
      ], keepOpen: false);
      final response = await transport.provider.post(
        uri: Uri.parse('http://127.0.0.1/test'),
        headers: const {},
        body: utf8.encode('{}'),
        timeout: const Duration(seconds: 1),
        budget: ProviderResponseBudget(
          maxFrameBytes: 1,
          maxResponseBytes: maxTotal,
          maxErrorBodyBytes: 4,
        ),
      );
      if (maxTotal == 4) {
        expect(await response.body.join(), 'a\r\nb');
      } else {
        await expectLater(
          response.body.join(),
          throwsA(isA<ModelGatewayException>()),
        );
      }
      expect(transport.closed && transport.response.cancelled, isTrue);
    }
  });

  test('无文本的原生结束仍失败', () async {
    for (final fixture in [
      (kind: ProviderKind.openAiCompatible, body: 'data: [DONE]\n'),
      (kind: ProviderKind.anthropic, body: 'data: {"type":"message_stop"}\n'),
      (kind: ProviderKind.ollama, body: '{"done":true}\n'),
    ]) {
      final transport = _ByteHttpClient([utf8.encode(fixture.body)]);
      final events = await _events(transport.provider, fixture.kind);
      expect(events.single.failure, ModelFailureKind.contentParsing);
      expect(transport.closed && transport.response.cancelled, isTrue);
    }
  });

  test('EOF 可闭合合法原生结束尾行，EOF 本身仍不能替代原生完成', () async {
    for (final fixture in _nativeCompletions) {
      final transport = _ByteHttpClient([
        utf8.encode(fixture.body.substring(0, fixture.body.length - 1)),
      ], keepOpen: false);
      _expectCompleted(await _events(transport.provider, fixture.kind));
      expect(transport.closed && transport.response.cancelled, isTrue);
    }
    final transport = _ByteHttpClient([
      utf8.encode(_openAiDelta),
    ], keepOpen: false);
    final events = await _events(
      transport.provider,
      ProviderKind.openAiCompatible,
    );
    expect(events.last.failure, ModelFailureKind.network);
    expect(transport.closed && transport.response.cancelled, isTrue);
  });

  test('有效文本后的原生错误先于结束标记时失败且不透出错误原文', () async {
    final transport = _ByteHttpClient([
      utf8.encode(
        'data: {"type":"content_block_delta","delta":{"text":"在。"}}\n'
        'data: {"type":"error","error":{"message":"synthetic-private-error"}}\n'
        'data: {"type":"message_stop"}\n',
      ),
    ]);
    final events = await _events(transport.provider, ProviderKind.anthropic);
    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.failure,
    ]);
    expect(events.last.failure, ModelFailureKind.provider);
    expect(events.last.message, isNot(contains('synthetic-private-error')));
    expect(transport.closed && transport.response.cancelled, isTrue);
  });

  test('上游错误前无合法终态则失败，终态之后不改写成功', () async {
    for (final completed in [false, true]) {
      final transport = _ByteHttpClient([
        utf8.encode(completed ? _nativeCompletions.first.body : _openAiDelta),
      ], error: const HttpException('synthetic-source-error'));
      final events = await _events(
        transport.provider,
        ProviderKind.openAiCompatible,
      );
      if (completed) {
        _expectCompleted(events);
      } else {
        expect(events.map((event) => event.kind), [
          ModelStreamEventKind.delta,
          ModelStreamEventKind.failure,
        ]);
      }
      expect(transport.closed && transport.response.cancelled, isTrue);
    }
  });

  test('非 2xx 正文里的结束字样不能绕过错误体预算', () async {
    final terminal = utf8.encode(_nativeCompletions.first.body);
    for (final size in [64 * 1024, 64 * 1024 + 1]) {
      final transport = _ByteHttpClient(
        [terminal, List<int>.filled(size - terminal.length, 0x20)],
        statusCode: 500,
        keepOpen: false,
      );
      final events = await _events(
        transport.provider,
        ProviderKind.openAiCompatible,
      );
      expect(
        events.single.failure,
        size == 64 * 1024
            ? ModelFailureKind.provider
            : ModelFailureKind.incompatibleResponse,
      );
      expect(transport.closed && transport.response.cancelled, isTrue);
    }
  });

  test('下游收到增量后取消时丢弃同块余下字节并关闭响应', () async {
    final transport = _ByteHttpClient([
      utf8.encode('$_openAiDelta${'x' * 2048}'),
    ]);
    final first = Completer<void>();
    final events = <ModelStreamEvent>[];
    late StreamSubscription<ModelStreamEvent> subscription;
    subscription = _stream(transport.provider, ProviderKind.openAiCompatible)
        .listen((event) {
          events.add(event);
          subscription.pause();
          first.complete();
        });
    await first.future.timeout(const Duration(seconds: 2));
    await subscription.cancel().timeout(const Duration(seconds: 2));
    expect(events.single.kind, ModelStreamEventKind.delta);
    expect(transport.closed && transport.response.cancelled, isTrue);
  });

  test('暂停与恢复保留同块终态，暂停超过整体期限仍关闭上游', () async {
    for (final expire in [false, true]) {
      final transport = _ByteHttpClient([
        utf8.encode('${_openAiDelta}data: [DONE]\n'),
      ]);
      final first = Completer<void>();
      final events = <ModelStreamEvent>[];
      final done = Completer<void>();
      late StreamSubscription<ModelStreamEvent> subscription;
      subscription = _stream(transport.provider, ProviderKind.openAiCompatible)
          .listen((event) {
            events.add(event);
            if (!first.isCompleted) {
              subscription.pause();
              first.complete();
            }
          }, onDone: done.complete);
      await first.future.timeout(const Duration(seconds: 2));
      if (expire) {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(transport.closed && transport.response.cancelled, isTrue);
      }
      subscription.resume();
      await done.future.timeout(const Duration(seconds: 2));
      if (expire) {
        expect(events.last.failure, ModelFailureKind.timeout);
      } else {
        _expectCompleted(events);
      }
      expect(transport.closed && transport.response.cancelled, isTrue);
    }
  });
}

const _openAiDelta = 'data: {"choices":[{"delta":{"content":"在。"}}]}\n';

const _anthropicTextBody =
    'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"在。"}}\n'
    'data: {"type":"message_stop"}\n';

const _anthropicToolBody =
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-1","name":"web_search","input":{}}}\n'
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":\\"今天"}}\n'
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"天气\\"}"}}\n'
    'data: {"type":"message_stop"}\n';

Future<List<ModelStreamEvent>> _searchEvents(
  ProviderHttpClient client,
  WebSearchClient search, {
  int port = 12345,
}) => ProviderModelGateway(client)
    .streamWithWebSearch(
      config: ProviderConfig(
        kind: ProviderKind.anthropic,
        baseUrl: 'http://127.0.0.1:$port/v1',
        model: 'synthetic',
        temperature: 0.6,
        timeoutSeconds: 1,
      ),
      apiKey: 'synthetic-key',
      messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
      webSearchApiKey: 'synthetic-search-key',
      webSearchClient: search,
      whenCancelled: Completer<void>().future,
    )
    .toList()
    .timeout(const Duration(seconds: 5));

final class _RecordingSearch implements WebSearchClient {
  final queries = <String>[];

  @override
  Future<List<WebSearchResult>> search({
    required String apiKey,
    required String query,
    Future<void>? whenCancelled,
  }) async {
    queries.add(query);
    return const [];
  }
}

const _responseLimit = 16 * 1024 * 1024;

List<int> _paddedCompletion(int totalBytes) {
  final terminal = utf8.encode(_nativeCompletions.first.body);
  final bytes = BytesBuilder(copy: false);
  var remaining = totalBytes - terminal.length;
  while (remaining > 0) {
    final length = remaining > 1024 * 1024 ? 1024 * 1024 : remaining;
    bytes.add(utf8.encode(':${'x' * (length - 2)}\n'));
    remaining -= length;
  }
  bytes.add(terminal);
  return bytes.takeBytes();
}

const _nativeCompletions = [
  (
    name: 'OpenAI finish_reason',
    kind: ProviderKind.openAiCompatible,
    body:
        'data: {"choices":[{"delta":{"content":"在。"},"finish_reason":"stop"}]}\n',
  ),
  (
    name: 'OpenAI 独立 DONE',
    kind: ProviderKind.openAiCompatible,
    body:
        'data: {"choices":[{"delta":{"content":"在。"}}]}\n'
        'data: [DONE]\n',
  ),
  (
    name: 'Anthropic message_stop',
    kind: ProviderKind.anthropic,
    body:
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"在。"}}\n'
        'data: {"type":"message_stop"}\n',
  ),
  (
    name: 'Ollama done',
    kind: ProviderKind.ollama,
    body: '{"message":{"role":"assistant","content":"在。"},"done":true}\n',
  ),
];

Future<List<ModelStreamEvent>> _events(
  ProviderHttpClient client,
  ProviderKind kind, {
  int port = 12345,
}) => _stream(
  client,
  kind,
  port: port,
).toList().timeout(const Duration(seconds: 5));

Stream<ModelStreamEvent> _stream(
  ProviderHttpClient client,
  ProviderKind kind, {
  int port = 12345,
}) => ProviderModelGateway(client).stream(
  config: ProviderConfig(
    kind: kind,
    baseUrl: 'http://127.0.0.1:$port/v1',
    model: 'synthetic',
    temperature: 0.6,
    timeoutSeconds: 1,
  ),
  apiKey: 'synthetic-key',
  messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
);

void _expectCompleted(List<ModelStreamEvent> events) {
  expect(events.map((event) => event.kind), [
    ModelStreamEventKind.delta,
    ModelStreamEventKind.done,
  ]);
  expect(events.first.text, '在。');
}

/// 通过公开 HttpClient 工厂固定接收块，避免将服务器 flush 当作 TCP 边界。
final class _ByteHttpClient implements HttpClient {
  _ByteHttpClient(
    List<List<int>> chunks, {
    bool keepOpen = true,
    int statusCode = 200,
    Object? error,
  }) : response = _ByteResponse(
         chunks,
         keepOpen: keepOpen,
         statusCode: statusCode,
         error: error,
       );

  final _ByteResponse response;
  bool closed = false;
  bool opened = false;
  @override
  Duration? connectionTimeout;

  DartIoProviderHttpClient get provider =>
      DartIoProviderHttpClient(httpClientFactory: (_) => this);

  @override
  Future<HttpClientRequest> postUrl(Uri uri) async {
    opened = true;
    return _ByteRequest(response);
  }

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ByteRequest implements HttpClientRequest {
  _ByteRequest(this.response);

  final _ByteResponse response;
  @override
  bool followRedirects = true;
  @override
  final HttpHeaders headers = _TestHeaders();

  @override
  void add(List<int> bytes) {}

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TestHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ByteResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _ByteResponse(
    List<List<int>> chunks, {
    required bool keepOpen,
    required this.statusCode,
    Object? error,
  }) {
    _body = StreamController<List<int>>(
      onListen: () {
        for (final chunk in chunks) {
          _body.add(chunk);
        }
        if (error != null) {
          _body.addError(error);
        }
        if (!keepOpen) {
          unawaited(_body.close());
        }
      },
      onCancel: () => cancelled = true,
    );
  }

  late final StreamController<List<int>> _body;
  bool cancelled = false;
  @override
  final int statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
