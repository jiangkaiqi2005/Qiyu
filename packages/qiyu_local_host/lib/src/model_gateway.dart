import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'cleartext_policy.dart';
import 'provider_config.dart';
import 'web_search.dart';

enum ModelMessageRole { system, user, assistant }

final class ModelMessage {
  const ModelMessage(this.role, this.content);

  final ModelMessageRole role;
  final String content;
}

enum ModelFailureKind {
  dns,
  tls,
  timeout,
  authentication,
  network,
  modelNotFound,
  rateLimited,
  incompatibleResponse,
  contentParsing,
  provider,
  internal,
}

final class ModelGatewayException implements Exception {
  const ModelGatewayException({
    required this.kind,
    required this.message,
    this._serviceError,
  });

  final ModelFailureKind kind;
  final String message;
  final ServiceErrorCategory? _serviceError;
  ServiceErrorCategory? get serviceError =>
      _serviceError ?? serviceErrorForModelFailure(kind);

  @override
  String toString() => message;
}

abstract interface class ModelGateway {
  /// [maxTokens] 缺省用全局回复上限（聊天护栏）；理解类调用输出的是
  /// 长结构 JSON，必须按调用显式给足预算，否则截断后解析必失败。
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  });
}

abstract interface class StreamingModelGateway implements ModelGateway {
  Stream<ModelStreamEvent> stream({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  });
}

abstract interface class WebSearchStreamingModelGateway {
  Stream<ModelStreamEvent> streamWithWebSearch({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    required String webSearchApiKey,
    required WebSearchClient webSearchClient,
    Future<void>? whenCancelled,
    int? maxTokens,
  });
}

final class ProviderHttpResponse {
  const ProviderHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Stream<String> body;
}

/// 二进制响应形态：响应体不经 utf8 解码（语音合成返回音频字节，
/// 文本解码会破坏二进制数据）。
final class ProviderBytesHttpResponse {
  const ProviderBytesHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final Stream<List<int>> body;

  /// 响应头（小写键，仅透出诊断需要的键）：语音合成网关用它记录
  /// 官方建议的 X-Tt-Logid（只进本机 stderr，不透出浏览器）。
  final Map<String, String> headers;
}

/// 二进制响应出网调用（语音合成等），保留原始音频字节。
abstract interface class ProviderBytesHttpClient {
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  });
}

abstract interface class ProviderHttpClient {
  /// 文本响应统一入口；请求体保持原始字节，兼容 JSON 与音频上传。
  /// [whenCancelled] 覆盖建立与读取，取消后释放连接和响应订阅。
  /// [budget] 在 UTF-8 解码前限制响应，并使 [timeout] 覆盖整个请求。
  /// 不带预算时保留连接、响应头与文本读取各阶段原有的超时语义。
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  });
}

/// 聊天／理解模型响应的字节预算：在解码、分行与聚合之前按原始字节
/// 限制响应，防止无换行大帧、超大响应或超大错误响应占满内存。预算
/// 按调用范围生效——只施加于模型 HTTP 请求，语音二进制与搜索通道
/// 不传预算，不受影响。
final class ProviderResponseBudget {
  const ProviderResponseBudget({
    required this.maxFrameBytes,
    required this.maxResponseBytes,
    required this.maxErrorBodyBytes,
  });

  /// 单帧（一行，行终止符不计）最大字节数。
  final int maxFrameBytes;

  /// 单个 2xx 响应体最大总字节数。
  final int maxResponseBytes;

  /// 非 2xx 错误响应体最大总字节数。
  final int maxErrorBodyBytes;
}

final class ProviderRequestCancelled implements Exception {
  const ProviderRequestCancelled();
}

/// 出网 HttpClient 的创建工厂（代理入口，ticket 08）：入参为本请求
/// 解析出的代理规则（未启用代理或目标不宜走代理时为 null）。缺省
/// 忽略规则直接 `HttpClient()`；测试注入假件观察代理决策（findProxy
/// 与连接目标），不真连。
typedef ProviderHttpClientFactory = HttpClient Function(
  ProxyRules? proxyRules,
);

final class DartIoProviderHttpClient
    implements ProviderHttpClient, ProviderBytesHttpClient {
  const DartIoProviderHttpClient({
    this.httpClientFactory = defaultHttpClientFactory,
    this.proxyRulesSource,
  });

  /// 生产缺省工厂：不设 findProxy，所有目标直连。
  static HttpClient defaultHttpClientFactory(ProxyRules? proxyRules) =>
      HttpClient();

  /// 每次请求创建出网 HttpClient 时调用的工厂。
  final ProviderHttpClientFactory httpClientFactory;

  /// 代理规则来源（缺省 null＝本客户端永远直连）：每次请求解析一次
  /// 最新配置，保存代理设置后下一条请求即生效，无缓存失真。规则是
  /// 可选注入——语音直连网关（豆包 volc）与搜索客户端装配本类时
  /// 不传来源，即使 provider.json 里存了代理也绝不走代理。
  final Future<ProxyRules?> Function()? proxyRulesSource;

  /// 本请求的代理规则：未装配来源、目标主机是本机／私有网段（局域网
  /// Ollama 等直连目标经外部代理不可达且不该出外网）时恒为 null。
  Future<ProxyRules?> _proxyRulesFor(Uri uri) async {
    final source = proxyRulesSource;
    if (source == null || isPrivateOrLoopbackHost(uri.host)) {
      return null;
    }
    return source();
  }

  Future<HttpClient> _createClient(Uri uri, Duration timeout) async {
    final proxyRules = await _proxyRulesFor(uri);
    final client = httpClientFactory(proxyRules);
    client.connectionTimeout = timeout;
    if (proxyRules != null) {
      client.findProxy = (uri) => proxyRules.findProxyFor(uri);
    }
    return client;
  }

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    final client = await _createClient(uri, timeout);
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.add(body);
      final response = await request.close().timeout(timeout);
      return ProviderBytesHttpResponse(
        statusCode: response.statusCode,
        body: _readBytesResponse(response, client, timeout),
        headers: {'x-tt-logid': ?response.headers.value('x-tt-logid')},
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    HttpClient? client;
    var abandoned = false;
    var cancelled = false;
    // 模型期限包括代理配置、连接、响应头和消费；无预算保留分步超时。
    final watch = budget == null ? null : (Stopwatch()..start());
    final cancellation = whenCancelled?.then<Never>((_) {
      cancelled = true;
      client?.close(force: true);
      throw const ProviderRequestCancelled();
    });
    Future<T> cancellable<T>(Future<T> pending) => cancellation == null
        ? pending
        : Future.any<T>([pending, cancellation]);
    try {
      final creating = _createClient(uri, timeout).then((created) {
        client = created;
        // 超时或取消后才完成的配置读取仍要释放新建客户端。
        if (abandoned || cancelled) {
          created.close(force: true);
        }
        return created;
      });
      final activeClient = await cancellable(
        watch == null
            ? creating
            : creating.timeout(_overallRemaining(timeout, watch)),
      );
      final request = await cancellable(
        activeClient.postUrl(uri),
      ).timeout(_overallRemaining(timeout, watch));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.add(body);
      final response = await cancellable(
        request.close(),
      ).timeout(_overallRemaining(timeout, watch));
      return ProviderHttpResponse(
        statusCode: response.statusCode,
        body: _cancelResponse(
          budget == null
              ? _readResponse(response, activeClient, timeout)
              : _readBoundedResponse(
                  response, activeClient, timeout, budget, watch!,
                ),
          whenCancelled,
          activeClient,
        ),
      );
    } catch (_) {
      abandoned = true;
      client?.close(force: true);
      if (cancelled) {
        throw const ProviderRequestCancelled();
      }
      rethrow;
    }
  }
}

/// 只从已分类的故障种类推导公开类别；未知 Provider 故障不猜测文本。
ServiceErrorCategory? serviceErrorForModelFailure(ModelFailureKind? kind) =>
    switch (kind) {
      ModelFailureKind.authentication => ServiceErrorCategory.authentication,
      ModelFailureKind.modelNotFound => ServiceErrorCategory.modelNotFound,
      ModelFailureKind.rateLimited => ServiceErrorCategory.rateLimited,
      ModelFailureKind.dns || ModelFailureKind.tls ||
      ModelFailureKind.timeout || ModelFailureKind.network =>
        ServiceErrorCategory.network,
      _ => null,
    };

/// 取消显式结束消费，不依赖 HttpClient.close 是否会为静默流派发事件。
Stream<String> _cancelResponse(
  Stream<String> body,
  Future<void>? whenCancelled,
  HttpClient client,
) {
  if (whenCancelled == null) {
    return body;
  }
  late final StreamController<String> controller;
  StreamSubscription<String>? subscription;
  var finished = false;
  void finish([Object? error, StackTrace? stackTrace]) {
    if (finished) {
      return;
    }
    finished = true;
    client.close(force: true);
    subscription?.cancel();
    if (error != null) {
      controller.addError(error, stackTrace);
    }
    controller.close();
  }

  controller = StreamController<String>(
    onListen: () {
      if (finished) {
        return;
      }
      subscription = body.listen(
        controller.add,
        onError: finish,
        onDone: finish,
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () {
      finished = true;
      client.close(force: true);
      return subscription?.cancel();
    },
  );
  whenCancelled.then((_) => finish(const ProviderRequestCancelled()));
  return controller.stream;
}

/// 整体期限的剩余等待时间：未计时（无预算调用）返回完整期限；已
/// 到期返回零，让 [Future.timeout] 立即失败。
Duration _overallRemaining(Duration timeout, Stopwatch? watch) {
  if (watch == null) {
    return timeout;
  }
  final remaining = timeout - watch.elapsed;
  return remaining.isNegative ? Duration.zero : remaining;
}

/// 带预算的模型响应读取：在解码与分行之前按原始字节限制（2xx 用
/// 响应总量上限，非 2xx 用错误体上限；单帧按行终止符之间的字节计），
/// 并施加从请求开始计时的整体期限。
///
/// 每次最多放行到一个行终止符，等待消费方处理后再检查后续字节。
/// 协议层因此能在原生完成行处取消读取，不受同一传输块尾部影响。
/// 期限直接压在原始响应流上，静默或暂停时也会关闭连接；所有退出
/// 路径都取消期限与响应订阅，不等待 HTTP EOF。
Stream<String> _readBoundedResponse(
  HttpClientResponse response,
  HttpClient client,
  Duration timeout,
  ProviderResponseBudget budget,
  Stopwatch watch,
) {
  final maxTotal = response.statusCode < 200 || response.statusCode >= 300
      ? budget.maxErrorBodyBytes
      : budget.maxResponseBytes;
  var totalBytes = 0;
  var frameBytes = 0;
  late final StreamController<List<int>> controller;
  StreamSubscription<List<int>>? subscription;
  Timer? deadline;
  List<int>? pendingChunk;
  var pendingOffset = 0;
  var sourcePaused = false;
  var terminated = false;

  // 终态收尾：取消期限定时器并强制关闭连接（重复调用无副作用）。
  void terminate() {
    terminated = true;
    pendingChunk = null;
    deadline?.cancel();
    client.close(force: true);
  }

  void fail(Object error, [StackTrace? stackTrace]) {
    if (terminated) {
      return;
    }
    terminate();
    subscription?.cancel();
    controller.addError(error, stackTrace);
    controller.close();
  }

  void pauseSource() {
    if (!sourcePaused) {
      sourcePaused = true;
      subscription?.pause();
    }
  }

  void pump() {
    if (terminated || controller.isPaused) {
      return;
    }
    if (watch.elapsed >= timeout) {
      fail(TimeoutException('整体期限已到', timeout));
      return;
    }
    final chunk = pendingChunk;
    if (chunk == null) {
      if (sourcePaused) {
        sourcePaused = false;
        subscription?.resume();
      }
      return;
    }
    final start = pendingOffset;
    while (pendingOffset < chunk.length) {
      final byte = chunk[pendingOffset++];
      totalBytes++;
      final terminator = byte == 0x0D || byte == 0x0A;
      frameBytes = terminator ? 0 : frameBytes + 1;
      if (totalBytes > maxTotal || frameBytes > budget.maxFrameBytes) {
        fail(
          const ModelGatewayException(
            kind: ModelFailureKind.incompatibleResponse,
            message: '模型服务返回了不兼容的响应格式。',
          ),
        );
        return;
      }
      if (terminator) {
        break;
      }
    }
    final end = pendingOffset;
    if (end == chunk.length) {
      pendingChunk = null;
    }
    controller.add(
      start == 0 && end == chunk.length ? chunk : chunk.sublist(start, end),
    );
    // add 的异步投递先于下一次 pump；若消费方暂停或在终态取消，
    // 下一次不会继续扫描。源订阅也保持暂停，避免积压后续传输块。
    scheduleMicrotask(pump);
  }

  controller = StreamController<List<int>>(
    onListen: () {
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        fail(TimeoutException('整体期限已到', timeout));
        return;
      }
      deadline = Timer(remaining, () {
        fail(TimeoutException('整体期限已到', timeout));
      });
      subscription = response.listen(
        (chunk) {
          if (terminated) {
            return;
          }
          pauseSource();
          pendingChunk = chunk;
          pendingOffset = 0;
          pump();
        },
        onError: fail,
        onDone: () {
          if (terminated) {
            return;
          }
          terminate();
          controller.close();
        },
      );
    },
    onPause: pauseSource,
    onResume: () => scheduleMicrotask(pump),
    onCancel: () {
      terminate();
      return subscription?.cancel();
    },
  );
  return controller.stream.transform(utf8.decoder);
}

Stream<String> _readResponse(
  HttpClientResponse response,
  HttpClient client,
  Duration timeout,
) async* {
  try {
    yield* response.transform(utf8.decoder).timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

Stream<List<int>> _readBytesResponse(
  HttpClientResponse response,
  HttpClient client,
  Duration timeout,
) async* {
  try {
    yield* response.timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

enum ModelStreamEventKind { delta, done, failure }

final class ModelStreamEvent {
  const ModelStreamEvent.delta(String this.text)
    : kind = ModelStreamEventKind.delta,
      _serviceError = null,
      failure = null,
      message = null;

  const ModelStreamEvent.done()
    : kind = ModelStreamEventKind.done,
      _serviceError = null,
      text = null,
      failure = null,
      message = null;

  const ModelStreamEvent.failure(
    ModelFailureKind this.failure,
    String this.message, {
    this._serviceError,
  }) : kind = ModelStreamEventKind.failure,
      text = null;

  final ModelStreamEventKind kind;
  final ServiceErrorCategory? _serviceError;
  ServiceErrorCategory? get serviceError =>
      _serviceError ?? serviceErrorForModelFailure(failure);
  final String? text;
  final ModelFailureKind? failure;
  final String? message;
}

final class ProviderModelGateway
    implements StreamingModelGateway, WebSearchStreamingModelGateway {
  const ProviderModelGateway(
    this.httpClient, {
    ProviderHttpClient? proxyHttpClient,
    void Function(String message)? diagnosticsSink,
  }) :
       // ignore: prefer_initializing_formals
       _proxyHttpClient = proxyHttpClient,
       // ignore: prefer_initializing_formals
       _diagnosticsSink = diagnosticsSink;

  final ProviderHttpClient httpClient;

  /// OpenAI 兼容／Anthropic 出站的代理通道（ticket 08）：代理作用于
  /// 模型网关的 HTTP 客户端，直连客户端与代理客户端在这里分叉。缺省
  /// null＝未装配代理通道，全部直连（行为与历史版本一致）。Ollama 是
  /// 局域网／本机直连，恒走 [httpClient]，见 [_outboundFor]。
  final ProviderHttpClient? _proxyHttpClient;
  final void Function(String message)? _diagnosticsSink;

  /// 本请求的出网客户端：代理只服务受限的海外云端协议（OpenAI 兼容
  /// 与 Anthropic）；Ollama 目标是本机／局域网服务，走代理不可达也不
  /// 该出外网。豆包语音直连网关（volc）不经过本类，结构上不受影响。
  ProviderHttpClient _outboundFor(ProviderKind kind) => switch (kind) {
    ProviderKind.ollama => httpClient,
    ProviderKind.openAiCompatible ||
    ProviderKind.anthropic => _proxyHttpClient ?? httpClient,
  };

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) async {
    final buffer = StringBuffer();
    await for (final event in stream(
      config: config,
      apiKey: apiKey,
      messages: messages,
      maxTokens: maxTokens,
    )) {
      if (event.kind == ModelStreamEventKind.delta) {
        buffer.write(event.text);
      } else if (event.kind == ModelStreamEventKind.failure) {
        throw ModelGatewayException(
          kind: event.failure!,
          message: event.message!,
          serviceError: event.serviceError,
        );
      }
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的内容无法解析。',
      );
    }
    return text;
  }

  @override
  Stream<ModelStreamEvent> stream({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) async* {
    config.validate();
    final protocol = _providerProtocol(config.kind);
    if (protocol.requiresApiKey && (apiKey == null || apiKey.trim().isEmpty)) {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.authentication,
        '还没有保存 API Key。',
      );
      return;
    }

    final request = protocol.buildRequest(
      config,
      apiKey,
      messages,
      maxTokens ?? _maxModelReplyTokens,
    );
    // 明文 HTTP 默认拒绝（ticket 08）：应用层允许列表只放行用户显式
    // 配置的本机／私有网段目标，公网目标一律要求 HTTPS。这是 dart:io
    // 出站唯一生效的放行口（平台明文策略不管辖 dart:io）。
    final cleartextRefusal = chatCleartextRefusalReason(request.uri);
    if (cleartextRefusal != null) {
      yield ModelStreamEvent.failure(
        ModelFailureKind.network,
        cleartextRefusal,
      );
      return;
    }
    final outbound = _outboundFor(config.kind);
    final chatTimeout = Duration(seconds: config.timeoutSeconds);
    final encodedBody = utf8.encode(jsonEncode(request.body));
    ProviderHttpResponse response;
    try {
      response = await outbound.post(
        uri: request.uri,
        headers: request.headers,
        body: encodedBody,
        timeout: chatTimeout,
        budget: _chatResponseBudget,
      );
    } on TimeoutException {
      _diagnosticsSink?.call('model connection timeout');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.timeout,
        '连接模型服务超时。',
      );
      return;
    } on HandshakeException {
      _diagnosticsSink?.call('model connection tls error');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.tls,
        '模型服务的 TLS 安全连接失败。',
      );
      return;
    } on SocketException catch (error) {
      final failure = _socketFailure(error);
      _diagnosticsSink?.call('model connection socket error [${failure.kind}]');
      yield ModelStreamEvent.failure(
        failure.kind, failure.message, serviceError: failure.serviceError,
      );
      return;
    } on HttpException {
      _diagnosticsSink?.call('model connection http error');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.network,
        '模型服务连接中断。',
      );
      return;
    } on ModelGatewayException catch (error) {
      _diagnosticsSink?.call('model gateway error [${error.kind}] ${error.message}');
      yield ModelStreamEvent.failure(
        error.kind, error.message, serviceError: error.serviceError,
      );
      return;
    } on Object catch (error) {
      _diagnosticsSink?.call('model connection unexpected error [$error]');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.internal,
        '本机程序内部出错。',
      );
      return;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String body;
      try {
        body = await response.body.join();
      } on TimeoutException {
        _diagnosticsSink?.call('model response error body timeout');
        yield const ModelStreamEvent.failure(
          ModelFailureKind.timeout,
          '模型服务响应超时。',
        );
        return;
      } on ModelGatewayException catch (error) {
        // 错误体读取超出预算（如超过错误体字节上限）时按其失败类别
        // 降级，不透出错误体内容。
        _diagnosticsSink?.call(
          'model response error body failure [${error.kind}]',
        );
        yield ModelStreamEvent.failure(
        error.kind, error.message, serviceError: error.serviceError,
      );
        return;
      } on Object catch (error) {
        _diagnosticsSink?.call('model response error body read error [$error]');
        yield const ModelStreamEvent.failure(
          ModelFailureKind.network,
          '模型服务连接中断。',
        );
        return;
      }
      final failure = _statusFailure(response.statusCode, body);
      _diagnosticsSink?.call('model response status error [${failure.kind}] status=${response.statusCode}');
      yield ModelStreamEvent.failure(
        failure.kind, failure.message, serviceError: failure.serviceError,
      );
      return;
    }
    var emittedText = false;
    try {
      await for (final line in response.body.transform(const LineSplitter())) {
        final event = protocol.readEvent(line);
        if (event == null) {
          continue;
        }
        if (event.delta.isNotEmpty) {
          emittedText = true;
          yield ModelStreamEvent.delta(event.delta);
        }
        if (event.done) {
          if (!emittedText) {
            _diagnosticsSink?.call('model stream finished without visible text');
            yield const ModelStreamEvent.failure(
              ModelFailureKind.contentParsing,
              '模型服务返回的内容无法解析。',
            );
          } else {
            yield const ModelStreamEvent.done();
          }
          return;
        }
      }
    } on TimeoutException {
      _diagnosticsSink?.call('model stream response timeout');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.timeout,
        '模型服务响应超时。',
      );
      return;
    } on FormatException catch (error) {
      _diagnosticsSink?.call('model stream format error [$error]');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.incompatibleResponse,
        '模型服务返回了不兼容的响应格式。',
      );
      return;
    } on ModelGatewayException catch (error) {
      _diagnosticsSink?.call('model gateway error [${error.kind}] ${error.message}');
      yield ModelStreamEvent.failure(
        error.kind, error.message, serviceError: error.serviceError,
      );
      return;
    } on Object catch (error) {
      _diagnosticsSink?.call('model stream unexpected error [$error]');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.internal,
        '本机程序内部出错。',
      );
      return;
    }
    if (!emittedText) {
      _diagnosticsSink?.call('model stream eof without visible text');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.contentParsing,
        '模型服务返回的内容无法解析。',
      );
      return;
    }
    _diagnosticsSink?.call('model stream interrupted before completion');
    yield const ModelStreamEvent.failure(
      ModelFailureKind.network,
      '模型服务连接在回复完成前中断。',
    );
  }

  @override
  Stream<ModelStreamEvent> streamWithWebSearch({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    required String webSearchApiKey,
    required WebSearchClient webSearchClient,
    Future<void>? whenCancelled,
    int? maxTokens,
  }) async* {
    if (config.kind != ProviderKind.anthropic) {
      yield* stream(
        config: config,
        apiKey: apiKey,
        messages: messages,
        maxTokens: maxTokens,
      );
      return;
    }
    config.validate();
    if (apiKey == null || apiKey.trim().isEmpty) {
      yield const ModelStreamEvent.failure(
        ModelFailureKind.authentication,
        '还没有保存 API Key。',
      );
      return;
    }
    final protocol = const _AnthropicProtocol();
    final request = protocol.buildRequest(
      config,
      apiKey,
      messages,
      maxTokens ?? _maxModelReplyTokens,
    );
    // 与普通流式同律：明文公网目标在出网前拒绝（ticket 08）。
    final cleartextRefusal = chatCleartextRefusalReason(request.uri);
    if (cleartextRefusal != null) {
      yield ModelStreamEvent.failure(
        ModelFailureKind.network,
        cleartextRefusal,
      );
      return;
    }
    // 联网搜索是 Anthropic 协议的模型调用，与普通流式共用代理分叉。
    final outbound = _outboundFor(config.kind);
    final firstBody = <String, Object?>{
      ...request.body,
      'tools': const [
        {
          'name': 'web_search',
          'description': '搜索当前互联网信息。',
          'input_schema': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
            },
            'required': ['query'],
            'additionalProperties': false,
          },
        },
      ],
      'tool_choice': const {'type': 'auto'},
    };
    try {
      final first = await _readAnthropicTurn(
        outbound: outbound,
        request: request,
        body: firstBody,
        timeout: Duration(seconds: config.timeoutSeconds),
        whenCancelled: whenCancelled,
      );
      if (first.toolUses.isEmpty) {
        if (first.text.trim().isEmpty) {
          throw const ModelGatewayException(
            kind: ModelFailureKind.contentParsing,
            message: '模型服务返回的内容无法解析。',
          );
        }
        yield ModelStreamEvent.delta(first.text);
        yield const ModelStreamEvent.done();
        return;
      }
      // 同一响应可能携带多个并行工具调用：先整体校验全部调用（名称与
      // 输入 schema），任何一个不合法都失败关闭，不执行任何搜索。
      final validated = [
        for (final toolUse in first.toolUses) _validatedWebSearchCall(toolUse),
      ];
      // 串行执行各次搜索，复用现有超时与取消信号；单个搜索失败只生成
      // 对应 id 的 is_error 结果，不中断其余调用。id、query、结果内容与
      // 错误标记合并在同一条记录里，后续不再按下标平行配对。
      final calls =
          <({String id, String query, String content, bool isError})>[];
      for (final call in validated) {
        String content;
        var isError = false;
        try {
          final results = await webSearchClient.search(
            apiKey: webSearchApiKey,
            query: call.query,
            whenCancelled: whenCancelled,
          );
          content = jsonEncode([
            for (final result in results) result.toJson(),
          ]);
        } on ProviderRequestCancelled {
          rethrow;
        } on Object {
          isError = true;
          content = '这次联网搜索失败，无法取得可靠结果。';
        }
        calls.add((
          id: call.id,
          query: call.query,
          content: content,
          isError: isError,
        ));
      }
      final secondMessages = <Object?>[
        ...request.body['messages']! as List<Object?>,
        {
          'role': 'assistant',
          'content': [
            for (final call in calls)
              {
                'type': 'tool_use',
                'id': call.id,
                'name': 'web_search',
                'input': {'query': call.query},
              },
          ],
        },
        {
          'role': 'user',
          'content': [
            for (final call in calls)
              {
                'type': 'tool_result',
                'tool_use_id': call.id,
                'content': call.content,
                if (call.isError) 'is_error': true,
              },
          ],
        },
      ];
      final second = await _readAnthropicTurn(
        outbound: outbound,
        request: request,
        body: {...request.body, 'messages': secondMessages},
        timeout: Duration(seconds: config.timeoutSeconds),
        whenCancelled: whenCancelled,
      );
      if (second.toolUses.isNotEmpty || second.text.trim().isEmpty) {
        throw const ModelGatewayException(
          kind: ModelFailureKind.incompatibleResponse,
          message: '模型服务返回了不兼容的响应格式。',
        );
      }
      yield ModelStreamEvent.delta(second.text);
      yield const ModelStreamEvent.done();
    } on ProviderRequestCancelled {
      return;
    } on TimeoutException catch (error) {
      _diagnosticsSink?.call('web search timeout [$error]');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.timeout,
        '模型服务响应超时。',
      );
    } on HandshakeException catch (error) {
      _diagnosticsSink?.call('web search tls error [$error]');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.tls,
        '模型服务的 TLS 安全连接失败。',
      );
    } on SocketException catch (error) {
      _diagnosticsSink?.call('web search socket error [$error]');
      final failure = _socketFailure(error);
      yield ModelStreamEvent.failure(
        failure.kind, failure.message, serviceError: failure.serviceError,
      );
    } on HttpException catch (error) {
      _diagnosticsSink?.call('web search http error [$error]');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.network,
        '模型服务连接中断。',
      );
    } on ModelGatewayException catch (error) {
      _diagnosticsSink?.call(
        'web search model error [${error.kind}] ${error.message}',
      );
      yield ModelStreamEvent.failure(
        error.kind, error.message, serviceError: error.serviceError,
      );
    } on Object catch (error) {
      _diagnosticsSink?.call('web search unexpected error [$error]');
      yield const ModelStreamEvent.failure(
        ModelFailureKind.internal,
        '本机程序内部出错。',
      );
    }
  }

  /// 校验单个工具调用的名称与输入 schema（`{query: string}` 单键），
  /// 返回脱敏后的搜索词；未知工具报 incompatibleResponse 失败关闭；
  /// 参数 JSON 无法解码时由外层兜底为 incompatibleResponse，可解码
  /// 但结构不符或脱敏后为空的输入才报 contentParsing。
  ({String id, String query}) _validatedWebSearchCall(
    _AnthropicToolUse toolUse,
  ) {
    if (toolUse.name != 'web_search') {
      throw const ModelGatewayException(
        kind: ModelFailureKind.incompatibleResponse,
        message: '模型服务请求了不支持的工具。',
      );
    }
    final Object? decodedInput;
    try {
      decodedInput = jsonDecode(toolUse.inputJson);
    } on FormatException {
      throw const ModelGatewayException(
        kind: ModelFailureKind.incompatibleResponse,
        message: '模型服务返回了不兼容的响应格式。',
      );
    }
    if (decodedInput is! Map<String, Object?> ||
        decodedInput.length != 1 ||
        decodedInput['query'] is! String) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的搜索参数无法解析。',
      );
    }
    final safeQuery = sanitizeWebSearchQuery(decodedInput['query']! as String);
    if (safeQuery.isEmpty) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的搜索参数无法解析。',
      );
    }
    return (id: toolUse.id, query: safeQuery);
  }

  Future<_AnthropicTurn> _readAnthropicTurn({
    required ProviderHttpClient outbound,
    required _ProviderRequest request,
    required Map<String, Object?> body,
    required Duration timeout,
    Future<void>? whenCancelled,
  }) async {
    var cancelled = false;
    whenCancelled?.then((_) => cancelled = true);
    // 每次工具模型请求有独立预算与整体期限；搜索请求不带模型预算。
    final pendingResponse = outbound.post(
      uri: request.uri,
      headers: request.headers,
      body: utf8.encode(jsonEncode(body)),
      timeout: timeout,
      budget: _chatResponseBudget,
      whenCancelled: whenCancelled,
    );
    final response = await pendingResponse;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String responseBody;
      try {
        responseBody = await response.body.join();
      } on Object {
        if (cancelled) {
          throw const ProviderRequestCancelled();
        }
        rethrow;
      }
      if (cancelled) {
        throw const ProviderRequestCancelled();
      }
      throw _statusFailure(response.statusCode, responseBody);
    }
    final text = StringBuffer();
    // 同一 turn 可包含多个工具块：每个 content_block 一组独立缓冲，参数
    // 增量按 index 归位；个别兼容服务省略 index 时退化为追加到最近开始
    // 的工具块，绝不跨块拼接不同工具的增量，thinking 与可见文本不进任何
    // 工具缓冲。
    final toolBuffers = <_AnthropicToolBuffer>[];
    final toolBuffersByIndex = <int, _AnthropicToolBuffer>{};
    _AnthropicToolBuffer? latestToolBuffer;
    var stopped = false;
    try {
      await for (final line in response.body.transform(const LineSplitter())) {
        if (cancelled) {
          throw const ProviderRequestCancelled();
        }
        final event = _readAnthropicEvent(line);
        if (event == null) {
          continue;
        }
        text.write(event.delta);
        if (event.toolName != null) {
          final buffer = _AnthropicToolBuffer(
            id: event.toolId,
            name: event.toolName!,
          );
          toolBuffers.add(buffer);
          final blockIndex = event.blockIndex;
          if (blockIndex != null) {
            toolBuffersByIndex[blockIndex] = buffer;
          }
          latestToolBuffer = buffer;
          buffer.input.write(event.toolInputDelta);
        } else if (event.toolInputDelta.isNotEmpty) {
          final buffer = event.blockIndex == null
              ? latestToolBuffer
              : toolBuffersByIndex[event.blockIndex];
          buffer?.input.write(event.toolInputDelta);
        }
        if (event.done) {
          stopped = true;
          break;
        }
      }
    } on Object {
      if (cancelled) {
        throw const ProviderRequestCancelled();
      }
      rethrow;
    }
    if (cancelled) {
      throw const ProviderRequestCancelled();
    }
    if (!stopped) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.network,
        message: '模型服务连接在回复完成前中断。',
      );
    }
    final toolUses = <_AnthropicToolUse>[
      for (final buffer in toolBuffers)
        if (buffer.id != null)
          _AnthropicToolUse(
            id: buffer.id!,
            name: buffer.name,
            inputJson: buffer.input.toString(),
          ),
    ];
    return _AnthropicTurn(text: text.toString(), toolUses: toolUses);
  }
}

final class _AnthropicToolUse {
  const _AnthropicToolUse({
    required this.id,
    required this.name,
    required this.inputJson,
  });

  final String id;
  final String name;
  final String inputJson;
}

/// 单个工具内容块的流式参数缓冲：id/name 来自 content_block_start，
/// input 累加属于同一块的 input_json_delta。
final class _AnthropicToolBuffer {
  _AnthropicToolBuffer({required this.id, required this.name});

  final String? id;
  final String name;

  final input = StringBuffer();
}

final class _AnthropicTurn {
  const _AnthropicTurn({required this.text, required this.toolUses});

  final String text;
  final List<_AnthropicToolUse> toolUses;
}

typedef _ProviderRequest = ({
  Uri uri,
  Map<String, String> headers,
  Map<String, Object?> body,
});

abstract interface class _ProviderProtocol {
  bool get requiresApiKey;

  /// [maxTokens] 已在 gateway 层解析过默认值；是否写入请求体由各
  /// 协议自定（Ollama 历来不设输出上限，见其实现）。
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
    int maxTokens,
  );

  _ProviderStreamPart? readEvent(String line);
}

typedef _ProviderStreamPart = ({String delta, bool done});

typedef _AnthropicStreamPart = ({
  String delta,
  bool done,
  int? blockIndex,
  String? toolId,
  String? toolName,
  String toolInputDelta,
});

/// 发给 Provider 的输出上限，各协议保持一致，防止失控的账单与超长候选。
const _maxModelReplyTokens = 512;

/// 聊天与理解模型响应的传输预算（ticket 08）：单帧（一行）1 MiB、
/// 单个 2xx 响应 16 MiB、错误响应 64 KiB，在解码、分行与聚合之前按
/// 原始字节生效。只施加于模型 HTTP 请求；语音二进制与搜索通道走同
/// 客户端的普通方法，不受影响。
const _chatResponseBudget = ProviderResponseBudget(
  maxFrameBytes: 1 * 1024 * 1024,
  maxResponseBytes: 16 * 1024 * 1024,
  maxErrorBodyBytes: 64 * 1024,
);

_ProviderProtocol _providerProtocol(ProviderKind kind) => switch (kind) {
  ProviderKind.openAiCompatible => const _OpenAiCompatibleProtocol(),
  ProviderKind.anthropic => const _AnthropicProtocol(),
  ProviderKind.ollama => const _OllamaProtocol(),
};

final class _OpenAiCompatibleProtocol implements _ProviderProtocol {
  const _OpenAiCompatibleProtocol();

  @override
  bool get requiresApiKey => true;

  @override
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
    int maxTokens,
  ) => (
    uri: appendProviderEndpoint(config.baseUrl, 'chat/completions'),
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer ${apiKey!.trim()}',
    },
    body: {
      'model': config.model.trim(),
      'messages': messages.map(_messageJson).toList(),
      'temperature': config.temperature,
      'max_tokens': maxTokens,
      'stream': true,
    },
  );

  @override
  _ProviderStreamPart? readEvent(String line) {
    final data = _sseData(line);
    if (data == null) {
      if (line.trim().isNotEmpty && !line.trim().startsWith(':')) {
        throw const FormatException('invalid SSE line');
      }
      return null;
    }
    if (data == '[DONE]') {
      return (delta: '', done: true);
    }
    final payload = jsonDecode(data) as Map<String, Object?>;
    try {
      final choices = payload['choices']! as List<Object?>;
      final choice = choices.first! as Map<String, Object?>;
      final delta = choice['delta'] as Map<String, Object?>?;
      final content = delta?['content'];
      final text = content is String
          ? content
          : content is List<Object?>
          ? content
                .map(
                  (part) =>
                      (part! as Map<String, Object?>)['text'] as String? ?? '',
                )
                .join()
          : '';
      return (delta: text, done: choice['finish_reason'] != null);
    } on Object {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的内容无法解析。',
      );
    }
  }
}

final class _AnthropicProtocol implements _ProviderProtocol {
  const _AnthropicProtocol();

  @override
  bool get requiresApiKey => true;

  @override
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
    int maxTokens,
  ) => (
    uri: _anthropicMessagesEndpoint(config.baseUrl),
    headers: {
      'content-type': 'application/json',
      if (_usesArkAgentPlan(config.baseUrl))
        'authorization': 'Bearer ${apiKey!.trim()}'
      else
        'x-api-key': apiKey!.trim(),
      'anthropic-version': '2023-06-01',
    },
    body: {
      'model': config.model.trim(),
      'system': messages
          .where((message) => message.role == ModelMessageRole.system)
          .map((message) => message.content)
          .join('\n'),
      'messages': messages
          .where((message) => message.role != ModelMessageRole.system)
          .map(_messageJson)
          .toList(),
      'temperature': config.temperature,
      'max_tokens': maxTokens,
      'stream': true,
    },
  );

  @override
  _ProviderStreamPart? readEvent(String line) {
    final event = _readAnthropicEvent(line);
    return event == null ? null : (delta: event.delta, done: event.done);
  }
}

_AnthropicStreamPart? _readAnthropicEvent(String line) {
  final data = _sseData(line);
  if (data == null) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty &&
        !trimmed.startsWith('event:') &&
        !trimmed.startsWith(':')) {
      throw const FormatException('invalid SSE line');
    }
    return null;
  }
  final payload = jsonDecode(data) as Map<String, Object?>;
  switch (payload['type']) {
    case 'error':
      throw const ModelGatewayException(
        kind: ModelFailureKind.provider,
        message: '模型服务返回了错误。',
      );
    case 'message_stop':
      return (
        delta: '',
        done: true,
        blockIndex: null,
        toolId: null,
        toolName: null,
        toolInputDelta: '',
      );
    case 'content_block_start':
      final block = payload['content_block'];
      if (block is Map<String, Object?> && block['type'] == 'tool_use') {
        final input = block['input'];
        return (
          delta: '',
          done: false,
          blockIndex: _contentBlockIndex(payload),
          toolId: block['id'] as String?,
          toolName: block['name'] as String?,
          toolInputDelta: input is Map && input.isNotEmpty
              ? jsonEncode(input)
              : '',
        );
      }
      return null;
    case 'content_block_delta':
      final delta = payload['delta'];
      if (delta is! Map<String, Object?>) {
        throw const ModelGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '模型服务返回的内容无法解析。',
        );
      }
      return (
        delta: delta['type'] == 'input_json_delta'
            ? ''
            : delta['text'] as String? ?? '',
        done: false,
        blockIndex: _contentBlockIndex(payload),
        toolId: null,
        toolName: null,
        toolInputDelta: delta['type'] == 'input_json_delta'
            ? delta['partial_json'] as String? ?? ''
            : '',
      );
    default:
      return null;
  }
}

/// Anthropic SSE 的内容块序号：个别兼容服务可能省略 index，此时返回
/// null，由累计方退化为「追加到最近开始的工具块」。
int? _contentBlockIndex(Map<String, Object?> payload) {
  final index = payload['index'];
  return index is int ? index : null;
}

bool _usesArkAgentPlan(String baseUrl) {
  final uri = Uri.parse(baseUrl.trim());
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  return uri.host.toLowerCase() == 'ark.cn-beijing.volces.com' &&
      (path == '/api/plan' || path.startsWith('/api/plan/'));
}

final class _OllamaProtocol implements _ProviderProtocol {
  const _OllamaProtocol();

  @override
  bool get requiresApiKey => false;

  @override
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
    int maxTokens,
  ) {
    // Ollama 历来不设输出上限，这里同样不设（num_predict），保持原状。
    final headers = <String, String>{'content-type': 'application/json'};
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      headers['authorization'] = 'Bearer ${apiKey.trim()}';
    }
    return (
      uri: appendProviderEndpoint(config.baseUrl, 'api/chat', ollama: true),
      headers: headers,
      body: {
        'model': config.model.trim(),
        'messages': messages.map(_messageJson).toList(),
        'options': {'temperature': config.temperature},
        'stream': true,
      },
    );
  }

  @override
  _ProviderStreamPart? readEvent(String line) {
    if (line.trim().isEmpty) {
      return null;
    }
    final payload = jsonDecode(line) as Map<String, Object?>;
    final message = payload['message'] as Map<String, Object?>?;
    return (
      delta: message?['content'] as String? ?? '',
      done: payload['done'] == true,
    );
  }
}

String? _sseData(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('data:')) {
    return null;
  }
  return trimmed.substring(5).trim();
}

Map<String, String> _messageJson(ModelMessage message) => {
  'role': message.role.name,
  'content': message.content,
};

/// 把服务地址与端点后缀拼接成完整请求地址：已以该端点结尾的地址原样
/// 使用（用户可能直接填了完整端点）。聊天与语音转写共用。
Uri appendProviderEndpoint(
  String baseUrl,
  String suffix, {
  bool ollama = false,
}) {
  final base = normalizeProviderBaseUri(baseUrl);
  final normalizedPath = base.path;
  if (normalizedPath.endsWith('/$suffix')) {
    return base;
  }
  if (ollama && normalizedPath.endsWith('/api')) {
    return base.replace(path: '$normalizedPath/chat');
  }
  final path = normalizedPath.isEmpty ? '/$suffix' : '$normalizedPath/$suffix';
  return base.replace(path: path);
}

Uri _anthropicMessagesEndpoint(String baseUrl) {
  final base = normalizeProviderBaseUri(baseUrl);
  final normalizedPath = base.path;
  if (normalizedPath.endsWith('/messages')) {
    return base;
  }
  if (normalizedPath.endsWith('/v1')) {
    return base.replace(path: '$normalizedPath/messages');
  }
  final path = normalizedPath.isEmpty
      ? '/v1/messages'
      : '$normalizedPath/v1/messages';
  return base.replace(path: path);
}

ModelGatewayException _statusFailure(int statusCode, String body) =>
    providerStatusFailure(statusCode, body, serviceLabel: '模型服务');

/// 出网 HTTP 非 2xx 的统一分类（带服务名文案）。聊天模型与语音转写
/// 共用同一套错误分类，供连接测试与失败提示使用。
ModelGatewayException providerStatusFailure(
  int statusCode,
  String body, {
  required String serviceLabel,
}) {
  if (statusCode == HttpStatus.unauthorized ||
      statusCode == HttpStatus.forbidden) {
    return ModelGatewayException(
      kind: ModelFailureKind.authentication,
      message: 'API Key 未通过$serviceLabel验证。',
    );
  }
  if (statusCode == HttpStatus.tooManyRequests) {
    return ModelGatewayException(
      kind: ModelFailureKind.rateLimited,
      message: '$serviceLabel请求过于频繁。',
    );
  }
  final lowerBody = body.toLowerCase();
  final missingModelMessage = lowerBody.contains('model') &&
      (lowerBody.contains('not found') ||
          lowerBody.contains('does not exist') ||
          lowerBody.contains('unknown model') ||
          lowerBody.contains('no such model'));
  if (statusCode >= 400 && statusCode < 500 &&
      (_hasMissingModelCode(body) || missingModelMessage)) {
    return const ModelGatewayException(
      kind: ModelFailureKind.modelNotFound,
      message: '模型名称不存在或当前账号不可用。',
    );
  }
  return ModelGatewayException(
    kind: ModelFailureKind.provider,
    message: '$serviceLabel拒绝了这次请求。',
    serviceError: statusCode >= 400 && statusCode < 500
        ? ServiceErrorCategory.client
        : statusCode >= 500 && statusCode < 600
        ? ServiceErrorCategory.server
        : null,
  );
}

bool _hasMissingModelCode(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) return false;
    final error = decoded['error'];
    return error is Map<String, Object?> && error['code'] == 'model_not_found';
  } on FormatException {
    return false;
  }
}

ModelGatewayException _socketFailure(SocketException error) =>
    providerSocketFailure(error, serviceLabel: '模型服务');

/// Socket 异常的统一分类（带服务名文案）：域名解析失败与一般网络故障
/// 分开报告。聊天模型与语音转写共用。
ModelGatewayException providerSocketFailure(
  SocketException error, {
  required String serviceLabel,
}) {
  final message = error.message.toLowerCase();
  final code = error.osError?.errorCode;
  if (message.contains('failed host lookup') || code == 11001) {
    return ModelGatewayException(
      kind: ModelFailureKind.dns,
      message: '找不到$serviceLabel域名。',
    );
  }
  return ModelGatewayException(
    kind: ModelFailureKind.network,
    message: '无法连接$serviceLabel。',
  );
}
