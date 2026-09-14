import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

/// 聊天／理解模型调用的传输预算测试：单帧、单响应与错误响应的字节
/// 上限，以及覆盖连接与响应消费的整体期限。测试经 Provider HTTP 接缝
/// 注入真实 [DartIoProviderHttpClient]，对本地回环服务器观察字节层
/// 行为；语音与搜索通道用同客户端的既有方法验证不受预算影响。
void main() {
  const messages = [
    ModelMessage(ModelMessageRole.system, '你是栖语。'),
    ModelMessage(ModelMessageRole.user, '在吗'),
  ];

  test('无换行大帧在读满单帧预算时就被拒绝，不等到响应结束', () async {
    final server = await _startServer((request) async {
      // 2 MiB 无换行数据后保持连接：旧实现会把整段缓冲进 LineSplitter，
      // 等待更多数据；预算实现应在读满单帧上限时立即失败。
      request.response.add(utf8.encode('x' * (2 * _mib)));
      await request.response.flush();
    });
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events.last.kind, ModelStreamEventKind.failure);
    expect(events.last.failure, ModelFailureKind.incompatibleResponse);
    expect(events.map((event) => event.kind), isNot(contains(ModelStreamEventKind.done)));
  });

  test('OpenAI 持续无效帧不能刷新整体期限', () async {
    final server = await _startServer(
      (request) => _dripLines(request, ': keep-alive\n\n'),
    );
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port, timeoutSeconds: 1), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.timeout);
  });

  test('Anthropic 持续无效帧不能刷新整体期限', () async {
    final server = await _startServer((request) => _dripLines(request, ': ping\n\n'));
    final events = await ProviderModelGateway(const DartIoProviderHttpClient())
        .stream(
          config: _anthropicConfig(server.port, timeoutSeconds: 1),
          apiKey: 'test-key',
          messages: messages,
        )
        .toList()
        .timeout(_eventWaitLimit);

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.timeout);
  });

  test('Ollama 持续空行不能刷新整体期限', () async {
    final server = await _startServer((request) => _dripLines(request, '\n'));
    final events = await ProviderModelGateway(const DartIoProviderHttpClient())
        .stream(
          config: _ollamaConfig(server.port, timeoutSeconds: 1),
          apiKey: null,
          messages: messages,
        )
        .toList()
        .timeout(_eventWaitLimit);

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.timeout);
  });

  test('错误响应体超过 64 KiB 上限按不兼容响应降级', () async {
    final server = await _startServer((request) async {
      request.response.statusCode = 500;
      request.response.add(utf8.encode('e' * (_errorBodyLimit + 1)));
      await request.response.close();
    });
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.incompatibleResponse);
  });

  test('错误响应体恰好 64 KiB 仍按状态码分类', () async {
    final server = await _startServer((request) async {
      request.response.statusCode = 500;
      request.response.add(utf8.encode('e' * _errorBodyLimit));
      await request.response.close();
    });
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.provider);
    expect(events.single.message, '模型服务拒绝了这次请求。');
  });

  test('单帧超一字节即拒绝且不产出增量', () async {
    final frameBytes = _openAiStopFrame(_frameLimit + 1);
    final server = await _startServer((request) async {
      request.response.add(utf8.encode('$frameBytes\n\n'));
      await request.response.close();
    });
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(
      events.map((event) => event.kind),
      isNot(contains(ModelStreamEventKind.delta)),
    );
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.incompatibleResponse);
  });

  test('单帧恰好 1 MiB 正常交付', () async {
    final frame = _openAiStopFrame(_frameLimit);
    final server = await _startServer((request) async {
      request.response.add(utf8.encode('$frame\n\n'));
      await request.response.close();
    });
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(events.first.text, 'a' * (_frameLimit - _frameOverhead));
  });

  test('单响应超一字节即拒绝且不以完成标记收尾', () async {
    final body = _exactSizeOpenAiBody(_responseLimit + 1);
    final server = await _startServer((request) async {
      request.response.add(body);
      await request.response.close();
    });
    final diagnostics = <String>[];
    final events = await ProviderModelGateway(
      const DartIoProviderHttpClient(),
      diagnosticsSink: diagnostics.add,
    )
        .stream(config: _openAiConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(
      events.map((event) => event.kind),
      isNot(contains(ModelStreamEventKind.done)),
    );
    expect(events.last.kind, ModelStreamEventKind.failure);
    expect(events.last.failure, ModelFailureKind.incompatibleResponse);
  });

  test('单响应恰好 16 MiB 正常交付', () async {
    final body = _exactSizeOpenAiBody(_responseLimit);
    final server = await _startServer((request) async {
      request.response.add(body);
      await request.response.close();
    });
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events.last.kind, ModelStreamEventKind.done);
    expect(
      events.map((event) => event.kind),
      isNot(contains(ModelStreamEventKind.failure)),
    );
  });

  test('Anthropic 在预算通道正常终止', () async {
    final server = await _startServer((request) async {
      request.response.add(
        utf8.encode(
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"在。"}}\n\n'
          'data: {"type":"message_stop"}\n\n',
        ),
      );
      await request.response.close();
    });
    final events = await ProviderModelGateway(const DartIoProviderHttpClient())
        .stream(config: _anthropicConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(events.first.text, '在。');
  });

  test('Ollama 在预算通道正常终止', () async {
    final server = await _startServer((request) async {
      request.response.add(
        utf8.encode(
          '{"message":{"role":"assistant","content":"嗯"},"done":false}\n'
          '{"message":{"role":"assistant","content":"。"},"done":true}\n',
        ),
      );
      await request.response.close();
    });
    final events = await ProviderModelGateway(const DartIoProviderHttpClient())
        .stream(config: _ollamaConfig(server.port), apiKey: null, messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(events.where((event) => event.kind == ModelStreamEventKind.delta)
        .map((event) => event.text)
        .join(), '嗯。');
    expect(events.last.kind, ModelStreamEventKind.done);
  });

  test('预算通道内提前 EOF 不视为完成（OpenAI）', () async {
    final server = await _startServer((request) async {
      request.response.add(
        utf8.encode('data: {"choices":[{"delta":{"content":"半句"}}]}\n\n'),
      );
      await request.response.close();
    });
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events.last.kind, ModelStreamEventKind.failure);
    expect(events.last.failure, ModelFailureKind.network);
    expect(events.map((event) => event.kind), isNot(contains(ModelStreamEventKind.done)));
  });

  test('预算通道内提前 EOF 不视为完成（Anthropic）', () async {
    final server = await _startServer((request) async {
      request.response.add(
        utf8.encode(
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"半句"}}\n\n',
        ),
      );
      await request.response.close();
    });
    final events = await ProviderModelGateway(const DartIoProviderHttpClient())
        .stream(config: _anthropicConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events.last.kind, ModelStreamEventKind.failure);
    expect(events.map((event) => event.kind), isNot(contains(ModelStreamEventKind.done)));
  });

  test('预算通道内提前 EOF 不视为完成（Ollama）', () async {
    final server = await _startServer((request) async {
      request.response.add(
        utf8.encode('{"message":{"role":"assistant","content":"半句"},"done":false}\n'),
      );
      await request.response.close();
    });
    final events = await ProviderModelGateway(const DartIoProviderHttpClient())
        .stream(config: _ollamaConfig(server.port), apiKey: null, messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events.last.kind, ModelStreamEventKind.failure);
    expect(events.last.failure, ModelFailureKind.network);
    expect(events.map((event) => event.kind), isNot(contains(ModelStreamEventKind.done)));
  });

  test('预算通道内原生错误事件仍安全失败且不回传原文', () async {
    final server = await _startServer((request) async {
      request.response.add(
        utf8.encode(
          'data: {"type":"error","error":{"message":"Authorization: Bearer leaked-token"}}\n\n',
        ),
      );
      await request.response.close();
    });
    final events = await ProviderModelGateway(const DartIoProviderHttpClient())
        .stream(config: _anthropicConfig(server.port), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.provider);
    expect(events.single.message, isNot(contains('leaked-token')));
  });

  test('整体期限覆盖连接阶段', () async {
    final server = await _startServer((request) async {
      // 接受连接但不响应：整体期限应覆盖到连接建立与响应等待。
    });
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port, timeoutSeconds: 1), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.timeout);
  });

  test('响应头后完全静默时整体期限仍终结流', () async {
    final server = await _startServer((request) async {
      // 只发出响应头，之后零字节静默：期限到点必须终结流并按超时
      // 降级，不能因源静默而滞留（旧实现以空闲超时终结静默源）。
      await request.response.flush();
    });
    final events = await _openAiGateway()
        .stream(config: _openAiConfig(server.port, timeoutSeconds: 1), apiKey: 'test-key', messages: messages)
        .toList()
        .timeout(_eventWaitLimit);

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.timeout);
  });

  test('联网搜索分支持续无效帧不能刷新整体期限', () async {
    final server = await _startServer((request) => _dripLines(request, ': ping\n\n'));
    final events = await ProviderModelGateway(const DartIoProviderHttpClient())
        .streamWithWebSearch(
          config: _anthropicConfig(server.port, timeoutSeconds: 1),
          apiKey: 'test-key',
          messages: messages,
          webSearchApiKey: 'search-key',
          webSearchClient: _FakeWebSearchClient(),
        )
        .toList()
        .timeout(_eventWaitLimit);

    expect(events, hasLength(1));
    expect(events.single.kind, ModelStreamEventKind.failure);
    expect(events.single.failure, ModelFailureKind.timeout);
  });

  test('联网搜索分支在预算通道正常往返', () async {
    var requests = 0;
    final server = await _startServer((request) async {
      requests++;
      request.response.add(
        utf8.encode(
          requests == 1
              ? 'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-1","name":"web_search","input":{}}}\n\n'
                  'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":\\"今天\\"}"}}\n\n'
                  'data: {"type":"message_stop"}\n\n'
              : 'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"今天会下雨，带伞。"}}\n\n'
                  'data: {"type":"message_stop"}\n\n',
        ),
      );
      await request.response.close();
    });
    final events = await ProviderModelGateway(const DartIoProviderHttpClient())
        .streamWithWebSearch(
          config: _anthropicConfig(server.port),
          apiKey: 'test-key',
          messages: messages,
          webSearchApiKey: 'search-key',
          webSearchClient: _FakeWebSearchClient(),
        )
        .toList()
        .timeout(_eventWaitLimit);

    expect(requests, 2);
    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(events.first.text, '今天会下雨，带伞。');
  });

  test('语音转写路径不施加聊天预算', () async {
    final server = await _startServer((request) async {
      // 2 MiB 无换行文本：远超聊天单帧预算，语音转写（post）路径必须
      // 原样读回，不被预算误伤。
      request.response.add(utf8.encode('x' * (2 * _mib)));
      await request.response.close();
    });
    final response = await const DartIoProviderHttpClient().post(
      uri: Uri.parse('http://127.0.0.1:${server.port}/v1/audio/transcriptions'),
      headers: const {'content-type': 'application/octet-stream'},
      body: utf8.encode('audio'),
      timeout: const Duration(seconds: 25),
    );

    expect(response.statusCode, 200);
    expect((await response.body.join()).length, 2 * _mib);
  });

  test('预算通道取消时关闭底层连接', () async {
    final server = await _startServer((request) async {
      request.response.add(
        utf8.encode('data: {"choices":[{"delta":{"content":"嗯"}}]}\n\n'),
      );
      await request.response.flush();
      // 持续发送直到连接被客户端强制关闭。
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        request.response.add(utf8.encode(': keep-alive\n\n'));
        await request.response.flush();
      }
    });
    final cancel = Completer<void>();
    final response = await const DartIoProviderHttpClient()
        .postStreamBoundedCancellable(
          uri: Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions'),
          headers: const {'content-type': 'application/json'},
          body: '{"model":"chat-model"}',
          timeout: const Duration(seconds: 25),
          budget: const ProviderResponseBudget(
            maxFrameBytes: _frameLimit,
            maxResponseBytes: _responseLimit,
            maxErrorBodyBytes: _errorBodyLimit,
          ),
          whenCancelled: cancel.future,
        );
    final firstChunk = Completer<void>();
    late final StreamSubscription<String> subscription;
    subscription = response.body.listen(
      (_) {
        if (!firstChunk.isCompleted) {
          firstChunk.complete();
          cancel.complete();
        }
      },
      onError: (Object error) {},
      onDone: () {},
      cancelOnError: false,
    );
    await firstChunk.future.timeout(_eventWaitLimit);

    // 服务器仍在持续发送：取消后流必须立刻终止（连接被强制关闭），
    // 否则会继续收到 keep-alive 事件。只断言在宽限内终止，不压具体
    // 时延，避免慢环境抖动误报。
    await cancel.future;
    final terminated = Completer<void>();
    subscription.onData((_) {});
    subscription.onError((Object _) {
      if (!terminated.isCompleted) {
        terminated.complete();
      }
    });
    subscription.onDone(() {
      if (!terminated.isCompleted) {
        terminated.complete();
      }
    });
    await terminated.future.timeout(const Duration(seconds: 5));
    await subscription.cancel();
  });
}

/// 红灯等待上限：预算路径应在毫秒级到秒级给出结果，超时即视为旧实现
/// 在整段缓冲或被持续事件拖住。
const _eventWaitLimit = Duration(seconds: 8);

const _mib = 1024 * 1024;

const _frameLimit = 1 * 1024 * 1024;

const _responseLimit = 16 * 1024 * 1024;

const _errorBodyLimit = 64 * 1024;

const _openAiDeltaPrefix = 'data: {"choices":[{"delta":{"content":"';

const _openAiStopFrameTail = '"},"finish_reason":"stop"}]}';

const _openAiMidFrameTail = '"}}]}';

final _frameOverhead = _openAiDeltaPrefix.length + _openAiStopFrameTail.length;

/// 单帧上限恰好对齐的 OpenAI 完成行（不含行终止符）。
String _openAiStopFrame(int frameBytes) =>
    '$_openAiDeltaPrefix${'a' * (frameBytes - _frameOverhead)}$_openAiStopFrameTail';

/// 构造总字节数恰为 [totalBytes] 的 OpenAI SSE 字节流：先行填满中间
/// 行（每行帧不超 1 MiB），末行携带完成标记。用于总量上限的精确边界。
List<int> _exactSizeOpenAiBody(int totalBytes) {
  // 总量边界落在首个 LF：它使完成行成立，后续空行已在协议终态之后。
  final minStopLineBytes = _openAiDeltaPrefix.length + _openAiStopFrameTail.length + 1;
  final maxMidContent = _frameLimit - _openAiDeltaPrefix.length - _openAiMidFrameTail.length;
  final maxStopContent = _frameLimit - _frameOverhead;
  final builder = BytesBuilder(copy: false);
  var remaining = totalBytes;
  while (remaining - minStopLineBytes > maxStopContent) {
    final line = '$_openAiDeltaPrefix${'a' * maxMidContent}$_openAiMidFrameTail\n\n';
    builder.add(utf8.encode(line));
    remaining -= line.length;
  }
  final stopContent = remaining - minStopLineBytes;
  if (stopContent < 0) {
    throw ArgumentError('总字节数过小，无法容纳完成行');
  }
  builder.add(utf8.encode('$_openAiDeltaPrefix${'a' * stopContent}$_openAiStopFrameTail\n'));
  final bytes = builder.takeBytes();
  if (bytes.length != totalBytes) {
    throw StateError('构造字节数偏差：${bytes.length} != $totalBytes');
  }
  return bytes;
}

/// 起本地回环服务器并注册清理：handler 内的写入在客户端断开后会抛，
/// 由这里统一吞掉，不影响测试断言。响应须关掉输出缓冲：dart:io 服务
/// 器默认把正文攒到响应关闭才发出，不模拟真实 Provider 的流式行为；
/// 请求体同时持续消费，保持与真实服务一致。
Future<HttpServer> _startServer(
  FutureOr<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) {
    request.response.bufferOutput = false;
    request.listen(
      (_) {},
      onDone: () {},
      onError: (_) {},
      cancelOnError: false,
    );
    () async {
      try {
        await handler(request);
      } catch (_) {
        // 客户端提前断开或测试清理时写响应失败，属预期。
      }
    }();
  });
  return server;
}

/// 按固定间隔持续发送同一行（无效但被协议忽略的事件），用于验证整体
/// 期限不被持续事件刷新。永不返回；服务器关闭时写入抛出退出。
Future<void> _dripLines(HttpRequest request, String line) async {
  const interval = Duration(milliseconds: 100);
  final bytes = utf8.encode(line);
  while (true) {
    request.response.add(bytes);
    await request.response.flush();
    await Future<void>.delayed(interval);
  }
}

ProviderModelGateway _openAiGateway() =>
    const ProviderModelGateway(DartIoProviderHttpClient());

ProviderConfig _openAiConfig(int port, {int timeoutSeconds = 25}) =>
    ProviderConfig(
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'http://127.0.0.1:$port/v1',
      model: 'chat-model',
      temperature: 0.6,
      timeoutSeconds: timeoutSeconds,
    );

ProviderConfig _anthropicConfig(int port, {int timeoutSeconds = 25}) =>
    ProviderConfig(
      kind: ProviderKind.anthropic,
      baseUrl: 'http://127.0.0.1:$port/v1',
      model: 'chat-model',
      temperature: 0.6,
      timeoutSeconds: timeoutSeconds,
    );

ProviderConfig _ollamaConfig(int port, {int timeoutSeconds = 25}) =>
    ProviderConfig(
      kind: ProviderKind.ollama,
      baseUrl: 'http://127.0.0.1:$port',
      model: 'chat-model',
      temperature: 0.6,
      timeoutSeconds: timeoutSeconds,
    );

final class _FakeWebSearchClient implements WebSearchClient {
  const _FakeWebSearchClient();

  @override
  Future<List<WebSearchResult>> search({
    required String apiKey,
    required String query,
    Future<void>? whenCancelled,
  }) async => const [
    WebSearchResult(
      title: '天气',
      url: 'https://weather.example.com/today',
      snippet: '今天有雨。',
    ),
  ];
}
