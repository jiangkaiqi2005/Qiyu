import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 进程内真实 Host 会话帮助：起 [LocalAppHost]、兑换启动凭据拿会话
/// Cookie、从 bootstrap 取 CSRF，然后按生产形态走 `POST /api/chat`
/// 的 NDJSON 交付真路径。聊天测试不再经过聚合旁路，直接消费与浏览器
/// 一致的事件流，并对照落盘断言。
final class InProcessChatHost {
  InProcessChatHost._(
    this.rootDirectory,
    this.modelGateway,
    this.personaConstitution,
    this.clock,
    this.atomicWriter,
    this.deliveryPause,
    this.recallWindowWait,
    this.diagnosticsSink,
    this.idleCatchupPoller,
    this.zoneErrors,
  );

  /// 拥有 webRoot、memories 与 provider.json 的临时根目录。
  final Directory rootDirectory;

  /// 脚本化模型网关；未配置 Provider 的用例里为 null。
  final StreamingModelGateway? modelGateway;
  final String personaConstitution;
  final Clock? clock;
  final AtomicTextWriter? atomicWriter;
  final DeliveryPause? deliveryPause;
  final RecallWindowWait? recallWindowWait;
  final void Function(String message)? diagnosticsSink;

  /// 注入的空闲补办轮询定时器（测试用它断言宿主收尾取消）；null 时
  /// 宿主使用生产默认的周期定时器壳。
  final IdleCatchupPoller? idleCatchupPoller;

  late LocalAppHost _host;
  late String _cookie;
  late String _csrfToken;
  final HttpClient _client = HttpClient();

  /// Host 侧顶层异步错误留档：交付流中途异常（如落盘失败）会在服务
  /// 端留下未捕获错误；测试框架的错误区会让它们直接失败用例，因此
  /// Host 在守护区里启动，错误记到这里供中断类用例断言。
  final List<Object> zoneErrors;

  LocalAppHost get host => _host;
  Uri get origin => _host.origin;
  String get memoryDirectory =>
      '${rootDirectory.path}${Platform.pathSeparator}memories';

  /// 起一个进程内 Host：临时根目录、Web 根、记忆目录与（可选的）
  /// 脚本化 Provider 配置一次备齐；[seedMemory] 在 Host 启动前执行，
  /// 用来播种既有记忆材料。
  static Future<InProcessChatHost> start({
    Directory? rootDirectory,
    String personaConstitution = '测试人格宪法',
    StreamingModelGateway? modelGateway,
    bool configureProvider = true,
    Clock? clock,
    AtomicTextWriter? atomicWriter,
    DeliveryPause? deliveryPause,
    RecallWindowWait? recallWindowWait,
    void Function(String message)? diagnosticsSink,
    IdleCatchupPoller? idleCatchupPoller,
    FutureOr<void> Function(Directory memoryDirectory)? seedMemory,
  }) async {
    final root =
        rootDirectory ??
        await Directory.systemTemp.createTemp('qiyu-chat-host-test-');
    final webRoot = Directory('${root.path}${Platform.pathSeparator}web')
      ..createSync(recursive: true);
    final memoryDirectory = Directory(
      '${root.path}${Platform.pathSeparator}memories',
    )..createSync(recursive: true);
    File(
      '${webRoot.path}${Platform.pathSeparator}index.html',
    ).writeAsStringSync(
      '<!doctype html><title>栖语</title>'
      '<script src="flutter_bootstrap.js"></script>',
    );
    File(
      '${webRoot.path}${Platform.pathSeparator}flutter_bootstrap.js',
    ).writeAsStringSync('globalThis.qiyuLoaded = true;');
    if (seedMemory != null) {
      await seedMemory(memoryDirectory);
    }

    if (modelGateway != null && configureProvider) {
      await JsonProviderConfigRepository(
        filePath: '${root.path}${Platform.pathSeparator}provider.json',
      ).save(
        const ProviderConfig(
          kind: ProviderKind.openAiCompatible,
          baseUrl: 'https://scripted.invalid/v1',
          model: 'scripted-model',
          temperature: 0.6,
          timeoutSeconds: 25,
          apiKey: 'scripted-test-key',
        ),
      );
    }

    final instance = InProcessChatHost._(
      root,
      modelGateway,
      personaConstitution,
      clock,
      atomicWriter,
      deliveryPause,
      recallWindowWait,
      diagnosticsSink,
      idleCatchupPoller,
      <Object>[],
    );
    await instance._boot();
    final client = HttpClient();
    final session = await _login(instance.host, client);
    client.close(force: true);
    instance._cookie = session.cookie;
    instance._csrfToken = session.csrfToken;
    return instance;
  }

  /// 在守护错误区里启动/重启 Host：交付流中途异常会在服务端留下顶层
  /// 异步错误，测试框架的错误区会把它们直接放大成用例失败；收进
  /// [zoneErrors] 后由中断类用例自行断言。启动本身的失败仍经返回的
  /// Future 正常上抛。
  static Future<LocalAppHost> _startInGuardedZone(
    List<Object> zoneErrors,
    Future<LocalAppHost> Function() starter,
  ) {
    final started = runZonedGuarded<Future<LocalAppHost>>(starter, (
      error,
      stackTrace,
    ) {
      zoneErrors.add(error);
    });
    return started!;
  }

  /// 用同一套启动参数与同一目录重启 Host（刷新/重启幂等场景）；
  /// 会话 Cookie 与 CSRF 重新兑换，旧会话随重启失效。
  Future<void> restart() async {
    await _host.close();
    await _boot();
    final session = await _login(_host, _client);
    _cookie = session.cookie;
    _csrfToken = session.csrfToken;
  }

  /// 首次启动与重启共用的装配：按注入的网关与人格宪法建（可能为空的）
  /// Provider 设置服务，再在守护错误区里起 [LocalAppHost] 并赋给
  /// [_host]。provider.json 只在首次启动前预写一次，重启时由服务自行
  /// 从盘上读取；五个可选注入参数两路同律透传，[deliveryPause] 缺省
  /// 抹掉分段停顿。
  Future<void> _boot() async {
    _host = await _startInGuardedZone(
      zoneErrors,
      () => LocalAppHost.start(
        webRoot: '${rootDirectory.path}${Platform.pathSeparator}web',
        memoryDirectory: memoryDirectory,
        personaConstitution: personaConstitution,
        providerSettingsService: modelGateway == null
            ? null
            : ProviderSettingsService(
                // 此处为聊天设置自建仓储实例，与 Host 内部五服务共用的
                // 那个实例不同，读改写排队队列不共享；本装配只服务聊天
                // 管线用例，不承载跨段并发验证——跨段交错由
                // provider_config_transaction_test 的单实例用例覆盖。
                JsonProviderConfigRepository(
                  filePath:
                      '${rootDirectory.path}${Platform.pathSeparator}'
                      'provider.json',
                ),
                const _FileOnlySecretStore(),
                modelGateway!,
                ModelPromptBuilder(personaConstitution),
              ),
        clock: clock,
        atomicWriter: atomicWriter,
        // 缺省抹掉分段停顿：与迁移前测试同律，避免真路径测试空等；
        // 需要验证停顿本身时显式传入。
        deliveryPause: deliveryPause ?? (_) async {},
        recallWindowWait: recallWindowWait,
        diagnosticsSink: diagnosticsSink,
        idleCatchupPoller: idleCatchupPoller,
      ),
    );
  }

  static Future<_HostSession> _login(
    LocalAppHost host,
    HttpClient client,
  ) async {
    final start = await _send(client, host.launchUri, followRedirects: false);
    if (start.statusCode != HttpStatus.seeOther) {
      throw StateError('startup credential rejected: ${start.statusCode}');
    }
    final cookie = start.headers![HttpHeaders.setCookieHeader]!.single
        .split(';')
        .first;
    final bootstrap = await _send(
      client,
      host.origin.resolve('/api/bootstrap'),
      headers: {
        HttpHeaders.cookieHeader: cookie,
        HttpHeaders.refererHeader: host.origin.toString(),
      },
    );
    if (bootstrap.statusCode != HttpStatus.ok) {
      throw StateError('bootstrap rejected: ${bootstrap.statusCode}');
    }
    final bootstrapJson = jsonDecode(bootstrap.body) as Map<String, Object?>;
    return _HostSession(cookie, bootstrapJson['csrfToken']! as String);
  }

  Map<String, String> _readHeaders() => {
    HttpHeaders.cookieHeader: _cookie,
    HttpHeaders.refererHeader: _host.origin.toString(),
  };

  Map<String, String> _mutationHeaders() => {
    ..._readHeaders(),
    'origin': _host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
    'x-qiyu-csrf': _csrfToken,
    HttpHeaders.contentTypeHeader: 'application/json',
  };

  /// 完整消费一次聊天交付：发出请求，读完 NDJSON 事件流，返回状态码
  /// 与事件序列。非 200 时事件列表为空，[ChatEventTrace.jsonBody] 为
  /// 错误 JSON。
  Future<ChatEventTrace> sendChat({
    required String requestId,
    required String text,
    String? sessionId,
  }) async {
    final request = await _client.openUrl(
      'POST',
      _host.origin.resolve('/api/chat'),
    );
    _mutationHeaders().forEach(request.headers.set);
    request.add(
      utf8.encode(
        jsonEncode({
          'requestId': requestId,
          'text': text,
          'sessionId': ?sessionId,
        }),
      ),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return ChatEventTrace.parse(response.statusCode, body);
  }

  /// 打开一次聊天交付但不等待读完：取消与轮内查找窗口测试用它先观察
  /// 事件、再发 `/api/chat/cancel`。
  OpenChatStream openChat({
    required String requestId,
    required String text,
    String? sessionId,
  }) {
    final stream = OpenChatStream._();
    () async {
      try {
        final request = await _client.openUrl(
          'POST',
          _host.origin.resolve('/api/chat'),
        );
        _mutationHeaders().forEach(request.headers.set);
        request.add(
          utf8.encode(
            jsonEncode({
              'requestId': requestId,
              'text': text,
              'sessionId': ?sessionId,
            }),
          ),
        );
        final response = await request.close();
        stream._status.complete(response.statusCode);
        await for (final line
            in response
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (line.trim().isEmpty) {
            continue;
          }
          final json = jsonDecode(line) as Map<String, Object?>;
          stream._push(ChatDeliveryEvent.fromJson(json));
        }
        stream._finish();
      } on Object catch (error) {
        // 服务端把仓储层异常作为流错误向外传时，连接在交付中途断开；
        // 测试按「流异常终止 + 已收到的部分事件」断言。
        if (!stream._status.isCompleted) {
          stream._status.complete(HttpStatus.internalServerError);
        }
        stream._finish(error);
      }
    }();
    return stream;
  }

  /// `POST /api/chat/cancel`：与浏览器停止键同路径。
  Future<bool> cancelChat(String requestId) async {
    final response = await _postJson('/api/chat/cancel', {
      'requestId': requestId,
    });
    final json = jsonDecode(response.body) as Map<String, Object?>;
    return json['cancelled']! as bool;
  }

  /// `GET /api/chat/session`：读取 Host 落盘后的会话快照。
  Future<HttpResponse> readSession({String? sessionId}) {
    final query = sessionId == null ? '' : '?sessionId=$sessionId';
    return _get('/api/chat/session$query');
  }

  /// `GET /api/history`：历史列表。
  Future<HttpResponse> readHistory() => _get('/api/history');

  /// `DELETE /api/history/sessions/<id>`：删除会话。
  Future<HttpResponse> deleteSession(String sessionId) async {
    final request = await _client.openUrl(
      'DELETE',
      _host.origin.resolve('/api/history/sessions/$sessionId'),
    );
    _mutationHeaders().forEach(request.headers.set);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return HttpResponse(response.statusCode, body);
  }

  /// 以测试自己的时钟重开一个只读仓储视图，用于对照落盘。
  MarkdownMemoryRepository sessionReader() => MarkdownMemoryRepository(
    memoryDirectory: memoryDirectory,
    clock: clock,
    atomicWriter: atomicWriter,
  );

  /// 按会话 id 读回落盘会话：`sessionReader().openSession(sessionId:)`
  /// 的只读便捷形态，供对照落盘断言。
  Future<RawSession> storedSession(String sessionId) =>
      sessionReader().openSession(sessionId: sessionId);

  Future<HttpResponse> _get(String path) =>
      _send(_client, _host.origin.resolve(path), headers: _readHeaders());

  Future<HttpResponse> _postJson(String path, Map<String, Object?> body) async {
    final request = await _client.openUrl('POST', _host.origin.resolve(path));
    _mutationHeaders().forEach(request.headers.set);
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return HttpResponse(response.statusCode, responseBody);
  }

  /// 关闭 Host 但保留目录（供重启复用）；[dispose] 才删目录。
  Future<void> close() => _host.close();

  /// 手动拨动一次空闲补办轮询 tick（spec：轮询 tick 唯一新缝；测试
  /// 不启动真定时器，直接拨 tick 配假时钟）。补办排进后台任务链后
  /// 返回，等待落定用 [finalizePending] 或 [close]。
  Future<void> pollTick() => _host.memoryCadence.pollTick();

  /// 等待后台任务链（补归档、月压缩、Dream）排空。
  Future<void> finalizePending() => _host.memoryCadence.finalizePending();

  Future<void> dispose() async {
    _client.close(force: true);
    await _host.close();
    if (rootDirectory.existsSync()) {
      await rootDirectory.delete(recursive: true);
    }
  }

  static Future<HttpResponse> _send(
    HttpClient client,
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async {
    final request = await client.openUrl('GET', uri);
    request.followRedirects = followRedirects;
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return HttpResponse(response.statusCode, body, response.headers);
  }
}

/// 一次完整聊天交付的事件轨迹（含 HTTP 状态码与原始响应体）。
final class ChatEventTrace {
  ChatEventTrace._(this.statusCode, this.body, this.events);

  factory ChatEventTrace.parse(int statusCode, String body) {
    if (statusCode != HttpStatus.ok) {
      return ChatEventTrace._(statusCode, body, const []);
    }
    final events = body
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .map(
          (line) => ChatDeliveryEvent.fromJson(
            jsonDecode(line) as Map<String, Object?>,
          ),
        )
        .toList(growable: false);
    return ChatEventTrace._(statusCode, body, events);
  }

  final int statusCode;
  final String body;
  final List<ChatDeliveryEvent> events;

  ChatDeliveryEvent event(ChatDeliveryEventKind kind) =>
      events.singleWhere((event) => event.kind == kind);

  List<ChatDeliveryEvent> eventsOf(ChatDeliveryEventKind kind) =>
      events.where((event) => event.kind == kind).toList(growable: false);

  /// message 事件：单次交付恰好一条最终回复消息。
  ChatDeliveryEvent get message => event(ChatDeliveryEventKind.message);

  /// state 事件：单次交付的回复状态包。
  ChatDeliveryEvent get state => event(ChatDeliveryEventKind.state);

  /// accepted 事件里的会话标识。
  String get sessionId => event(ChatDeliveryEventKind.accepted).sessionId!;

  Map<String, Object?> get jsonBody => jsonDecode(body) as Map<String, Object?>;
}

/// 进行中的聊天交付流：边收事件边允许测试插入取消等操作。
final class OpenChatStream {
  OpenChatStream._();

  final List<ChatDeliveryEvent> received = [];
  final _status = Completer<int>();
  final _finished = Completer<void>();
  final _arrivals = StreamController<void>.broadcast();

  /// 流异常终止时的原因；正常交付完成为 null。
  Object? terminationError;

  Future<int> get statusCode => _status.future;
  Future<void> get done => _finished.future;

  /// 等待指定种类的交付事件出现（已收到的也算）。
  Future<void> waitFor(ChatDeliveryEventKind kind) async {
    while (true) {
      if (received.any((event) => event.kind == kind)) {
        return;
      }
      if (_finished.isCompleted) {
        return;
      }
      await _arrivals.stream.first;
    }
  }

  void _push(ChatDeliveryEvent event) {
    received.add(event);
    _arrivals.add(null);
  }

  void _finish([Object? error]) {
    terminationError = error;
    _arrivals.close();
    if (!_finished.isCompleted) {
      _finished.complete();
    }
  }
}

/// 简单 HTTP 响应（状态码 + 文本体）。
final class HttpResponse {
  const HttpResponse(this.statusCode, this.body, [this.headers]);

  final int statusCode;
  final String body;
  final HttpHeaders? headers;
}

final class _HostSession {
  const _HostSession(this.cookie, this.csrfToken);

  final String cookie;
  final String csrfToken;
}

/// Key 只从 provider.json 读：脚本化 Provider 的 Key 直接落文件，
/// 凭据库永空。
final class _FileOnlySecretStore implements SecretStore {
  const _FileOnlySecretStore();

  @override
  Future<void> deleteApiKey(String scope) async {}

  @override
  Future<String?> readApiKey(String scope) async => null;
}

/// 脚本化模型网关：聊天流（[stream]）与理解类小调用（[complete]）
/// 各自按脚本应答，消息序列分别留档供断言。
final class ScriptedModelGateway implements StreamingModelGateway {
  ScriptedModelGateway({
    List<ScriptedStream?> streamScript = const [],
    List<ScriptedCompletion?> completeScript = const [],
  }) : _streamScript = List.of(streamScript),
       _completeScript = List.of(completeScript);

  final List<ScriptedStream?> _streamScript;
  final List<ScriptedCompletion?> _completeScript;
  final List<List<ModelMessage>> streamCalls = [];
  final List<List<ModelMessage>> completeCalls = [];

  final StreamController<void> _arrivals = StreamController<void>.broadcast();

  var _streamIndex = 0;
  var _completeIndex = 0;

  /// 交互式流的控制器：取消类测试用它随时推增量。
  final StreamController<ModelStreamEvent> liveController =
      StreamController<ModelStreamEvent>();

  /// 等待服务端打开第 [call] 次聊天流（accepted/waiting 已在其前发出）。
  /// Host 的 NDJSON 响应整体缓冲，客户端看不到中途事件，取消类测试
  /// 靠服务端里程碑定位时机。
  Future<void> awaitStreamOpened({int call = 1}) =>
      _awaitMilestone(() => streamCalls.length >= call);

  /// 等待第 [count] 次理解类小调用到达（轮内查找的选择/组织）。
  Future<void> awaitCompleteCalls(int count) =>
      _awaitMilestone(() => completeCalls.length >= count);

  Future<void> _awaitMilestone(bool Function() reached) async {
    while (!reached()) {
      if (_arrivals.isClosed) {
        return;
      }
      await _arrivals.stream.first;
    }
  }

  @override
  Stream<ModelStreamEvent> stream({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) {
    streamCalls.add(messages);
    _arrivals.add(null);
    final scripted = _streamScript.isEmpty
        ? null
        : _streamScript[_streamIndex < _streamScript.length
              ? _streamIndex
              : _streamScript.length - 1];
    _streamIndex += 1;
    return switch (scripted) {
      null => Stream.fromIterable(const [ModelStreamEvent.done()]),
      ScriptedStreamReply(:final text) => Stream.fromIterable([
        ModelStreamEvent.delta(text),
        const ModelStreamEvent.done(),
      ]),
      ScriptedStreamFailure(:final kind) => Stream.value(
        ModelStreamEvent.failure(kind, '已脱敏的脚本故障'),
      ),
      ScriptedStreamEvents(:final events) => Stream.fromIterable(events),
      ScriptedLiveStream() => liveController.stream,
    };
  }

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) async {
    completeCalls.add(messages);
    _arrivals.add(null);
    final scripted = _completeScript.isEmpty
        ? null
        : _completeScript[_completeIndex < _completeScript.length
              ? _completeIndex
              : _completeScript.length - 1];
    _completeIndex += 1;
    return switch (scripted) {
      null => throw const ModelGatewayException(
        kind: ModelFailureKind.provider,
        message: '脚本未准备该调用',
      ),
      ScriptedCompletionReply(:final text) => text,
      ScriptedCompletionFailure(:final kind) => throw ModelGatewayException(
        kind: kind,
        message: '已脱敏的脚本故障',
      ),
      ScriptedGatedCompletion(:final gate, :final reply) => _awaitGate(
        gate,
        reply,
      ),
    };
  }

  Future<String> _awaitGate(Future<void> gate, String reply) async {
    await gate;
    return reply;
  }

  /// 最近一次聊天流调用收到的消息。
  List<ModelMessage>? get lastStreamMessages =>
      streamCalls.isEmpty ? null : streamCalls.last;
}

/// 聊天流脚本条目。
sealed class ScriptedStream {
  const ScriptedStream();
}

final class ScriptedStreamReply extends ScriptedStream {
  const ScriptedStreamReply(this.text);

  final String text;
}

final class ScriptedStreamFailure extends ScriptedStream {
  const ScriptedStreamFailure(this.kind);

  final ModelFailureKind kind;
}

final class ScriptedStreamEvents extends ScriptedStream {
  const ScriptedStreamEvents(this.events);

  final List<ModelStreamEvent> events;
}

/// 走 [ScriptedModelGateway.liveController] 的交互式流。
final class ScriptedLiveStream extends ScriptedStream {
  const ScriptedLiveStream();
}

/// 理解类小调用脚本条目。
sealed class ScriptedCompletion {
  const ScriptedCompletion();
}

final class ScriptedCompletionReply extends ScriptedCompletion {
  const ScriptedCompletionReply(this.text);

  final String text;
}

final class ScriptedCompletionFailure extends ScriptedCompletion {
  const ScriptedCompletionFailure(this.kind);

  final ModelFailureKind kind;
}

/// 等待 [gate] 完成才应答：把查找停在窗口中途。
final class ScriptedGatedCompletion extends ScriptedCompletion {
  const ScriptedGatedCompletion({required this.gate, required this.reply});

  final Future<void> gate;
  final String reply;
}
