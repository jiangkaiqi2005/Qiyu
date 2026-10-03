import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/chat_memory_test_module.dart';

/// T03 验证矩阵（票面验证与完成）：注入 Provider 连接、时钟与存储，
/// 覆盖正常、打断、失败、缺失转录、晚到回忆、新轮抢占、旧包、重连
/// 期间结束、重复事件、热层更新、禁提与晚安。事件形状全部取自 T01
/// 原型实测（2026-10-02 真实凭据，见 prototype-results.md）。

const _omniConfig = ProviderConfig(
  kind: ProviderKind.qwenOmniRealtime,
  baseUrl: 'wss://dashscope.example.com/api-ws/v1/realtime',
  model: 'qwen3.8-omni-flash-realtime',
  temperature: 0.7,
  timeoutSeconds: 1,
);

DateTime _fixedClock() => DateTime(2026, 10, 2, 22, 30);

// ---------------------------------------------------------------------------
// 可注入的脚本化连接（连接按队列发放，供重连与后台查找选择小调用共用）
// ---------------------------------------------------------------------------

final class _ScriptedCallConnection implements ProviderWebSocketConnection {
  // sync 广播：add 同步投递，测试时序不依赖微任务调度窗口。
  final _incoming = StreamController<String>.broadcast(sync: true);
  final sentFrames = <Map<String, Object?>>[];
  bool closed = false;


  /// 客户端帧脚本应答器。
  void Function(Map<String, Object?> frame)? onClientFrame;

  @override
  Stream<List<int>> get messages => const Stream<List<int>>.empty();

  @override
  Stream<String> get textMessages => _incoming.stream;

  @override
  void send(List<int> bytes) {}

  @override
  void sendText(String text) {
    final frame = jsonDecode(text) as Map<String, Object?>;
    sentFrames.add(frame);
    onClientFrame?.call(frame);
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    // 投递期间的关闭（错误帧同步收口）排到微任务，避开 sync 重入。
    if (_delivering > 0) {
      scheduleMicrotask(_incoming.close);
      return;
    }
    await _incoming.close();
  }

  int _delivering = 0;

  /// 服务端帧下发。sync 广播在投递期间禁止重入 add——服务的续答会在
  /// 事件回调里发新帧，应答器随之重入，这里把重入帧排到微任务延后。
  void server(Map<String, Object?> event) {
    _add(jsonEncode(event));
  }

  void _add(String payload) {
    if (_delivering > 0) {
      scheduleMicrotask(() => _add(payload));
      return;
    }
    _delivering += 1;
    try {
      _incoming.add(payload);
    } finally {
      _delivering -= 1;
    }
  }

  List<Map<String, Object?>> framesOfType(String type) =>
      sentFrames.where((frame) => frame['type'] == type).toList();
}

/// 连接队列：第 n 次 connect 发放第 n 条脚本连接（重连与后台查找的
/// 选择小调用共用同一条队列，发放顺序即脚本顺序）。
final class _ScriptedCallConnector implements ProviderWebSocketConnector {
  final queue = <_ScriptedCallConnection>[];
  int connectCount = 0;

  _ScriptedCallConnection enqueue() {
    final connection = _ScriptedCallConnection();
    queue.add(connection);
    return connection;
  }

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async {
    final index = connectCount;
    connectCount += 1;
    return queue[index];
  }
}

/// 标准脚本应答：session.update 一律回 session.updated；response.create
/// 按脚本队列逐个下发；conversation.item.create 只留痕不应答。
void _respondWithScript(
  _ScriptedCallConnection connection,
  List<List<Map<String, Object?>>> replies,
) {
  var next = 0;
  connection.onClientFrame = (frame) {
    switch (frame['type']) {
      case 'session.update':
        connection.server({'type': 'session.updated', 'session': {}});
      case 'response.create':
        if (next < replies.length) {
          for (final event in replies[next]) {
            connection.server(event);
          }
          next += 1;
        }
    }
  };
}

/// 后台查找选择小调用的脚本连接（纯文字轮）：唯一一次 response.create
/// 回一段隐藏块文本。
void _respondSelection(_ScriptedCallConnection connection, String replyText) {
  var answered = false;
  connection.onClientFrame = (frame) {
    switch (frame['type']) {
      case 'session.update':
        connection.server({'type': 'session.updated', 'session': {}});
      case 'response.create':
        if (!answered) {
          answered = true;
          connection
            ..server(_responseCreated('sel-1'))
            ..server(_textDelta('sel-1', replyText))
            ..server(_responseDone('sel-1', 'completed'));
        }
    }
  };
}

// 事件脚本形状（T01 原型实测 wire 形状）。
Map<String, Object?> _responseCreated(String id) =>
    {'type': 'response.created', 'response': {'id': id}};

Map<String, Object?> _transcriptDelta(String id, String text) =>
    {
      'type': 'response.audio_transcript.delta',
      'response_id': id,
      'delta': text,
    };

Map<String, Object?> _textDelta(String id, String text) =>
    {'type': 'response.text.delta', 'response_id': id, 'delta': text};

Map<String, Object?> _audioDelta(String id, List<int> bytes) =>
    {
      'type': 'response.audio.delta',
      'response_id': id,
      'delta': base64Encode(bytes),
    };

Map<String, Object?> _responseDone(String id, String status) =>
    {'type': 'response.done', 'response': {'id': id, 'status': status}};

Map<String, Object?> _functionCallItem(String itemId, String callId, String name) =>
    {
      'type': 'conversation.item.created',
      'item': {
        'type': 'function_call',
        'id': itemId,
        'call_id': callId,
        'name': name,
      },
    };

Map<String, Object?> _argsDone(String id, String itemId, String args) =>
    {
      'type': 'response.function_call_arguments.done',
      'response_id': id,
      'item_id': itemId,
      'arguments': args,
    };

/// 一次语音输入（VAD 开→停 + 完整输入转录）。
void _speak(_ScriptedCallConnection connection, String text) {
  connection
    ..server({'type': 'input_audio_buffer.speech_started'})
    ..server({'type': 'input_audio_buffer.speech_stopped'})
    ..server({
      'type': 'conversation.item.input_audio_transcription.completed',
      'transcript': text,
    });
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

final class _Harness {
  _Harness({
    List<List<Map<String, Object?>>> callReplies = const [],
    EpisodeMemoryPipeline? pipeline,
    MemoryCadence? cadence,
  }) {
    connection = connector.enqueue();
    _respondWithScript(connection, callReplies);
    // 写项目内目录而非全局 TEMP：Windows 实时扫描对 %TEMP% 的新建
    // 小文件延迟大且间歇，测试期 IO 停顿曾达 30 秒。
    memoryDirectory =
        '${Directory.current.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}qiyu_omni_call_test_'
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    configRepo = _MemoryProviderConfigRepository()
      ..config = _omniConfig.withApiKey('key-omni');
    providerSettings = ProviderSettingsService(
      configRepo,
      _MemorySecretStore(),
      _FakeModelGateway(),
      ModelPromptBuilder('你是栖语。'),
      omniRealtimeGateway: QwenOmniRealtimeGateway(
        connector,
        diagnosticsSink: diagnostics.add,
      ),
    );
    effectivePipeline = pipeline ??
        EpisodeMemoryPipeline(
          memoryDirectory: memoryDirectory,
          clock: _fixedClock,
        );
    final effectiveCadence = cadence ??
        // 缺省带真实日终归档服务（晚安测试观察 finalized）；月压缩与
        // Dream 不注入，相关调度缺省空转。
        MemoryCadence(
          dailyFinalization: DailyFinalizationService(
            memoryDirectory: memoryDirectory,
            episodePipeline: effectivePipeline,
            clock: _fixedClock,
          ),
          clock: _fixedClock,
        );
    memoryModule = buildChatMemoryModule(
      memoryDirectory: memoryDirectory,
      clock: _fixedClock,
      episodePipeline: effectivePipeline,
      memoryCadence: effectiveCadence,
      recallModelClient: providerSettings,
      // 别名扩展不接（未配置时执行器静默退回无别名，既有语义）：
      // 控制动作的模型别名调用会另开脚本连接，干扰通话脚本序列。
    );
    final innerRepository = MarkdownMemoryRepository(
      memoryDirectory: memoryDirectory,
      clock: _fixedClock,
    );
    repository = _LoggingRepository(innerRepository, diagnostics);
    callService = OmniRealtimeCallService(
      gateway: QwenOmniRealtimeGateway(connector, diagnosticsSink: diagnostics.add),
      providerSettings: providerSettings,
      repository: repository,
      memory: memoryModule,
      actionExecutor: HiddenActionExecutor(
        memory: memoryModule,

        diagnosticsSink: diagnostics.add,
      ),
      modelPromptBuilder: ModelPromptBuilder('你是栖语。'),
      clock: _fixedClock,
      diagnosticsSink: diagnostics.add,
      reconnectWait: (delay) {
        final wait = Completer<void>();
        reconnectWaits.add(wait);
        return wait.future;
      },
    );
  }

  final connector = _ScriptedCallConnector();
  final reconnectWaits = <Completer<void>>[];
  final frontEvents = <Map<String, Object?>>[];
  final diagnostics = <String>[];
  late final String memoryDirectory;
  late final _ScriptedCallConnection connection;
  late final _MemoryProviderConfigRepository configRepo;
  late final ProviderSettingsService providerSettings;
  late final EpisodeMemoryPipeline effectivePipeline;
  late final ChatMemoryModule memoryModule;
  late final MemoryRepository repository;
  late final OmniRealtimeCallService callService;

  Future<void> start() async {
    // 预热本机存储（建目录 + 建当日首段）：服务首查 openSession 命中
    // 既有段直接返回，绕开「并发测试进程同刻建段」的 Windows 写盘
    // 争用窗口。
    await repository.openSession();
    await callService.startCall(send: frontEvents.add);
    // 每个测试结束时收掉仍在跑的通话服务：残留的看门狗计时器与
    // fire-and-forget 任务不得泄漏进下一个测试的时序。
    addTearDown(callService.stopCall);
    await until(
      () => phases().contains('active'),
      label: '通话进入 active',
    );
  }

  void sendFront(Map<String, Object?> frame) {
    unawaited(callService.handleFrontFrame(frame));
  }

  List<String> phases() => [
    for (final event in frontEvents)
      if (event['type'] == 'state') event['phase']! as String,
  ];

  Future<RawSession> turnsOnDisk() => repository.openSession();
}


String _itemText(Map<String, Object?> frame) {
  final item = frame['item']! as Map<String, Object?>;
  final content = (item['content']! as List).cast<Map<String, Object?>>().first;
  return content['text']! as String;
}

/// 仓储日志代理：每个调用落时间线，定位间歇挂死的 IO 步骤。
final class _LoggingRepository implements MemoryRepository {
  _LoggingRepository(this._inner, this.log);
  final MemoryRepository _inner;
  final List<String> log;
  String _stamp(String label) {
    final line =
        '${DateTime.now().millisecondsSinceEpoch % 100000} $label';
    log.add(line);
    return line;
  }

  @override
  Future<void> initialize() {
    log.add(_stamp('repo.init begin'));
    return _inner.initialize().then((_) => log.add(_stamp('repo.init done')));
  }

  @override
  Future<RawSession> openSession({String? sessionId}) {
    log.add(_stamp('repo.open begin id=$sessionId'));
    return _inner.openSession(sessionId: sessionId).then((session) {
      log.add(_stamp('repo.open done ${session.id}'));
      return session;
    });
  }

  @override
  Future<RawSession> createSession() {
    log.add(_stamp('repo.create begin'));
    return _inner.createSession().then((session) {
      log.add(_stamp('repo.create done ${session.id}'));
      return session;
    });
  }

  @override
  Future<RawSession> appendTurn(RawSession session, RawSessionTurn turn) {
    log.add(_stamp('repo.append begin ${turn.speaker.name}'));
    return _inner.appendTurn(session, turn).then((updated) {
      log.add(_stamp('repo.append done'));
      return updated;
    });
  }

  @override
  Future<HistoryListing> readHistory() => _inner.readHistory();

  @override
  Future<void> deleteSession(String sessionId) => _inner.deleteSession(sessionId);
}
final class _MemoryProviderConfigRepository implements ProviderConfigRepository {
  ProviderConfig? config;

  @override
  Future<ProviderConfig?> load() async => config;

  @override
  Future<void> save(ProviderConfig config) async {
    this.config = config;
  }

  @override
  Future<T> runTransaction<T>(Future<T> Function() action) => action();
}

final class _MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> deleteApiKey(String scope) async => values.remove(scope);

  @override
  Future<String?> readApiKey(String scope) async => values[scope];
}

final class _FakeModelGateway implements ModelGateway {
  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) => Future.value('不该用我');
}

/// 轮询等待（Host 侧大量异步落盘，微任务泵不足，用短间隔真等待）。
Future<void> until(
  FutureOr<bool> Function() condition, {
  required String label,
  String? debug,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时：$label${debug == null ? '' : '\n$debug'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('正常轮与记录（T03:14–15）', () {
    test('语音轮完整走通：转录与回复成对落盘，事件与音频即时交付', () async {
      final harness = _Harness();
      await harness.start();

      // 完整提示词与工具随建连下发（T01 §9.7 实测形状）。
      final update = harness.connection.framesOfType('session.update').single;
      final session = update['session']! as Map<String, Object?>;
      expect(session['instructions'], contains(omniRealtimeActionsDirective));
      expect((session['tools']! as List).length, 11);
      expect(session['voice'], qwenOmniRealtimeDefaultVoice);

      _speak(harness.connection, '在吗');
      // 语音轮回复由服务端 VAD 自动触发（客户端无 response.create），
      // 测试作为服务端直接下发回复事件。
      harness.connection
        ..server(_responseCreated('resp-1'))
        ..server(_transcriptDelta('resp-1', '在。'))
        ..server(_audioDelta('resp-1', [1, 2, 3, 4]))
        ..server(_responseDone('resp-1', 'completed'));
      await until(
        () => harness.frontEvents.any(
          (event) =>
              event['type'] == 'replyDone' && event['turnId'] == 'voice-1',
        ),
        label: '语音轮回复收束',
        debug:
            'front=${harness.frontEvents}\ndiag=${harness.diagnostics}\n'
            'connClosed=${harness.connection.closed} '
            'connects=${harness.connector.connectCount} '
            'phases=${harness.phases()} '

      );

      // 事件序列：状态 → 语音事件 → 回复增量 → 音频 → 收束。
      final types = harness.frontEvents.map((event) => event['type']).toList();
      expect(types, contains('speechStarted'));
      expect(types, contains('speechStopped'));
      expect(types, contains('replyDelta'));
      expect(types, contains('audio'));
      final replyDone = harness.frontEvents
          .where((event) => event['type'] == 'replyDone')
          .single;
      expect(replyDone['status'], 'completed');
      expect(replyDone['incomplete'], false);

      // Markdown 会话成对落盘：用户转录 + 回复 transcript。
      final snapshot = await harness.turnsOnDisk();
      expect(snapshot.turns, hasLength(2));
      expect(snapshot.turns[0].speaker, Speaker.user);
      expect(snapshot.turns[0].text, '在吗');
      expect(snapshot.turns[1].speaker, Speaker.qiyu);
      expect(snapshot.turns[1].text, '在。');
      expect(snapshot.turns[1].source, ReplySource.llm);
      expect(snapshot.turns[1].mode, 'omni-realtime');
      // 音频只在事件里流转，不落盘（spec:58）。
      final sessionDir = Directory(
        '${harness.memoryDirectory}${Platform.pathSeparator}sessions',
      );
      if (sessionDir.existsSync()) {
        await for (final file in sessionDir.list()) {
          if (file is File) {
            expect(file.readAsStringSync(), isNot(contains('AAECAwQ=')));
          }
        }
      }
    });

    test('通话中打字进同一会话，requestId 幂等不重复送模型', () async {
      final harness = _Harness(
        callReplies: [
          [
            _responseCreated('resp-1'),
            _transcriptDelta('resp-1', '在。'),
            _responseDone('resp-1', 'completed'),
          ],
        ],
      );
      await harness.start();

      harness.sendFront({
        'type': 'text',
        'requestId': 'type-1',
        'text': '还在吗',
      });
      await until(
        () => harness.connection.framesOfType('response.create').isNotEmpty,
        label: '打字轮建响应',
      );
      await until(
        () => harness.frontEvents.any((event) => event['type'] == 'replyDone'),
        label: '打字轮收束',
      );

      // 打字 item 带时刻前缀（与聊天装配同律）。
      final item = harness.connection.framesOfType('conversation.item.create').single;
      final content = _itemText(item);
      expect(content, contains('还在吗'));
      expect(content, contains('[2026-10-02 22:30]'));

      final creates = harness.connection.framesOfType('response.create').length;
      // 重复 requestId：不开新轮、不再送模型。
      harness.sendFront({
        'type': 'text',
        'requestId': 'type-1',
        'text': '还在吗',
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(harness.connection.framesOfType('response.create').length, creates);

      final snapshot = await harness.turnsOnDisk();
      expect(
        snapshot.turns.where((turn) => turn.requestId == 'type-1'),
        hasLength(2),
      );
    });
  });

  group('打断、失败与如实标识（T03:15）', () {
    test('打断保留已显示前缀并标记未完成', () async {
      final harness = _Harness();
      await harness.start();

      _speak(harness.connection, '讲个故事');
      // 播放中被打断：同毫秒 cancelled 终态（T01 §8.3 实测形状）。
      harness.connection
        ..server(_responseCreated('resp-1'))
        ..server(_transcriptDelta('resp-1', '从前有座山，'))
        ..server(_responseDone('resp-1', 'cancelled'));

      await until(
        () => harness.frontEvents.any((event) => event['type'] == 'replyDone'),
        label: '打断收束',
      );
      final replyDone = harness.frontEvents
          .where((event) => event['type'] == 'replyDone')
          .single;
      expect(replyDone['status'], 'cancelled');
      expect(replyDone['incomplete'], true);

      final snapshot = await harness.turnsOnDisk();
      expect(snapshot.turns[0].text, '讲个故事');
      // 前缀如实落盘，不冒充完整回复（spec:20）。
      expect(snapshot.turns[1].text, '从前有座山，');
    });

    test('语音转录缺失时用标识落盘，不编原话', () async {
      final harness = _Harness();
      await harness.start();

      // 只开口与判停，转录事件缺失（服务端转写失败的如实形态）。
      harness.connection
        ..server({'type': 'input_audio_buffer.speech_started'})
        ..server({'type': 'input_audio_buffer.speech_stopped'})
        ..server(_responseCreated('resp-1'))
        ..server(_transcriptDelta('resp-1', '嗯。'))
        ..server(_responseDone('resp-1', 'completed'));
      await until(
        () => harness.frontEvents.any((event) => event['type'] == 'replyDone'),
        label: '无转录轮收束',
      );

      final snapshot = await harness.turnsOnDisk();
      expect(snapshot.turns[0].text, omniMissingTranscriptMarker);
    });

    test('音频已播出而回复转录缺失时同样标识', () async {
      final harness = _Harness();
      await harness.start();

      _speak(harness.connection, '嗯');
      harness.connection
        ..server(_responseCreated('resp-1'))
        ..server(_audioDelta('resp-1', [9, 9, 9, 9]))
        ..server(_responseDone('resp-1', 'completed'));

      await until(
        () => harness.frontEvents.any((event) => event['type'] == 'replyDone'),
        label: '无转录回复收束',
      );
      final snapshot = await harness.turnsOnDisk();
      expect(snapshot.turns[1].text, omniMissingReplyTranscriptMarker);
    });

    test('重复 response.done 与迟到旧事件不重复落盘、不复活回复', () async {
      final harness = _Harness();
      await harness.start();

      _speak(harness.connection, '在吗');
      harness.connection
        ..server(_responseCreated('resp-1'))
        ..server(_transcriptDelta('resp-1', '在。'))
        ..server(_responseDone('resp-1', 'completed'));
      await until(
        () => harness.frontEvents.any((event) => event['type'] == 'replyDone'),
        label: '首轮收束',
      );
      final doneCount = harness.frontEvents
          .where((event) => event['type'] == 'replyDone')
          .length;

      // 旧回复的重复终态与迟到增量（T02:15 旧事件隔离的服务侧复验）。
      harness.connection
        ..server(_transcriptDelta('resp-1', '又来了'))
        ..server(_responseDone('resp-1', 'completed'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        harness.frontEvents
            .where((event) => event['type'] == 'replyDone')
            .length,
        doneCount,
      );
      final snapshot = await harness.turnsOnDisk();
      expect(
        snapshot.turns.where((turn) => turn.text.contains('又来了')),
        isEmpty,
      );
    });
  });

  group('晚一拍回忆（T03:13，T01 §9 实测时序）', () {
    test('静默工具轮回填检索结果并请求续答，参数零发声', () async {
      // 选择小调用经选中 Provider 的纯文字轮（队列第 2 条连接）。
      final selection = _ScriptedCallConnection();
      _respondSelection(
        selection,
        '<qiyu-actions>[{"action":"memory_recall","query":"梧桐里",'
        '"dates":["2026-10-02"]}]</qiyu-actions>',
      );
      final harness = _Harness(
        callReplies: [
          // 第一轮：记录住址（day 文件随后可被检索）。
          [
            _responseCreated('resp-1'),
            _functionCallItem('item-1', 'call-1', 'memory_signal'),
            _argsDone(
              'resp-1',
              'item-1',
              jsonEncode({'summary': '用户住在梧桐里', 'evidence': '我住在梧桐里'}),
            ),
            _responseDone('resp-1', 'completed'),
          ],
          // 静默工具轮后的续答：确认记录。
          [
            _responseCreated('resp-1b'),
            _transcriptDelta('resp-1b', '好，记下了。'),
            _responseDone('resp-1b', 'completed'),
          ],
          // 第二轮主回复：静默调用 memory_recall。
          [
            _responseCreated('resp-2'),
            _functionCallItem('item-2', 'call-2', 'memory_recall'),
            _argsDone('resp-2', 'item-2', jsonEncode({'query': '梧桐里'})),
            _responseDone('resp-2', 'completed'),
          ],
          // 回填后的续答。
          [
            _responseCreated('resp-3'),
            _transcriptDelta('resp-3', '记得，你住在梧桐里。'),
            _responseDone('resp-3', 'completed'),
          ],
        ],
      );
      harness.connector.queue.insert(1, selection);
      await harness.start();

      // 第一轮：文字记录住址。
      harness.sendFront({
        'type': 'text',
        'requestId': 'type-1',
        'text': '我住在梧桐里，记一下',
      });
      await until(
        () => harness.frontEvents.any(
          (event) =>
              event['type'] == 'replyDone' && event['status'] == 'completed',
        ),
        label: '记录轮收束',
      );
      // 轮次收束后 episode 落盘（索引由查找按需重建）。
      await until(
        () async {
          final day = await harness.effectivePipeline.readDay('2026-10-02');
          return day.entries.isNotEmpty;
        },
        label: 'episode 写入',
      );

      // 第二轮：问旧事 → 静默调用 memory_recall → 回填 → 续答。
      harness.sendFront({
        'type': 'text',
        'requestId': 'type-2',
        'text': '我上次说我住哪儿来着',
      });
      await until(
        () => harness.frontEvents.any(
          (event) =>
              event['type'] == 'replyDelta' &&
              (event['text']! as String).contains('梧桐里'),
        ),
        label: '回忆续答增量',
      );

      // 回填帧：found 且证据压缩进入工具输出。
      final backfill = harness.connection.framesOfType('conversation.item.create')
          .map((frame) => frame['item']! as Map<String, Object?>)
          .firstWhere(
            (item) =>
                item['type'] == 'function_call_output' &&
                item['call_id'] == 'call-2',
          );
      final payload =
          jsonDecode(backfill['output']! as String) as Map<String, Object?>;
      expect(payload['found'], true);
      expect(payload['context'], contains('梧桐里'));

      // 工具参数零发声（T01 §9.2）：可见增量里没有 JSON。
      for (final event in harness.frontEvents) {
        if (event['type'] == 'replyDelta') {
          expect(event['text'], isNot(contains('{"')));
        }
      }
    });

    test('用户新轮抢占后，旧检索只回填不续答，不唤醒旧语音', () async {
      // 挂起的选择调用：session.update 照常回，response.create 等放行。
      final gate = Completer<void>();
      final selection = _ScriptedCallConnection();
      selection.onClientFrame = (frame) {
        if (frame['type'] == 'session.update') {
          selection.server({'type': 'session.updated', 'session': {}});
        }
      };
      unawaited(
        gate.future.then((_) {
          selection
            ..server(_responseCreated('sel-1'))
            ..server(_textDelta('sel-1',
                '<qiyu-actions>[{"action":"memory_recall","query":"梧桐里"}]</qiyu-actions>'))
            ..server(_responseDone('sel-1', 'completed'));
        }),
      );
      final harness = _Harness(
        callReplies: [
          // 种子轮：先记下住址（查找需要索引命中才能走到选择调用）。
          [
            _responseCreated('resp-0'),
            _functionCallItem('item-0', 'call-0', 'memory_signal'),
            _argsDone('resp-0', 'item-0',
                jsonEncode({'summary': '用户住在梧桐里', 'evidence': '我住在梧桐里'})),
            _responseDone('resp-0', 'completed'),
          ],
          [
            _responseCreated('resp-0b'),
            _transcriptDelta('resp-0b', '好，记下了。'),
            _responseDone('resp-0b', 'completed'),
          ],
          // 查找轮主回复：静默调用 memory_recall。
          [
            _responseCreated('resp-1'),
            _functionCallItem('item-1', 'call-1', 'memory_recall'),
            _argsDone('resp-1', 'item-1', jsonEncode({'query': '梧桐里'})),
            _responseDone('resp-1', 'completed'),
          ],
          // 抢占轮的回复。
          [
            _responseCreated('resp-2'),
            _transcriptDelta('resp-2', '先说你刚问的事。'),
            _responseDone('resp-2', 'completed'),
          ],
        ],
      );
      harness.connector.queue.insert(1, selection);
      await harness.start();

      harness.sendFront({
        'type': 'text',
        'requestId': 'type-0',
        'text': '我住在梧桐里，记一下',
      });
      await until(
        () async {
          final day = await harness.effectivePipeline.readDay('2026-10-02');
          return day.entries.isNotEmpty;
        },
        label: '种子 episode 写入',
      );

      harness.sendFront({
        'type': 'text',
        'requestId': 'type-1',
        'text': '我住哪儿来着',
      });
      // 等选择调用建连（队列第 2 条被消费，应答被门住）。
      await until(
        () => harness.connector.connectCount >= 2,
        label: '选择调用建连',
      );
      final createsBefore = harness.connection.framesOfType('response.create').length;

      // 抢占：工具回填未完成前用户开启新轮。
      harness.sendFront({
        'type': 'text',
        'requestId': 'type-2',
        'text': '先别管这个',
      });
      await until(
        () => harness.frontEvents.any(
          (event) => event['type'] == 'replyDone' && event['turnId'] == 'text-3',
        ),
        label: '抢占轮收束',
      );

      // 释放旧检索：回填照常（对话历史不悬挂），但不请求续答。
      gate.complete();
      await until(
        () => harness.connection.framesOfType('conversation.item.create').any(
              (frame) =>
                  ((frame['item']! as Map<String, Object?>)['type']) ==
                  'function_call_output',
            ),
        label: '旧检索回填',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final createsAfter = harness.connection.framesOfType('response.create').length;
      expect(createsAfter, createsBefore + 1);
      // 旧检索结果不唤醒旧语音：查找轮（text-2）无可见回复。
      expect(
        harness.frontEvents.where(
          (event) =>
              event['turnId'] == 'text-2' && event['type'] == 'replyDelta',
        ),
        isEmpty,
      );
    });
  });

  group('有界重连与结束（T03:16，spec:73）', () {
    test('断线后按 1/2/4 秒有界重连并回放本机上下文', () async {
      final harness = _Harness(
        callReplies: [
          // 打字轮回复（文本轮由 response.create 触发脚本应答）。
          [
            _responseCreated('resp-1'),
            _transcriptDelta('resp-1', '在。'),
            _responseDone('resp-1', 'completed'),
          ],
        ],
      );
      // 预置一条历史（重连回放素材）。
      final preSession = await harness.repository.openSession();
      await harness.repository.appendTurn(
        preSession,
        RawSessionTurn.user(
          requestId: 'pre-1',
          text: '昨天聊过雨声',
          at: _fixedClock(),
        ),
      );

      await harness.start();
      harness.sendFront({
        'type': 'text',
        'requestId': 'type-1',
        'text': '在吗',
      });
      await until(
        () => harness.frontEvents.any((event) => event['type'] == 'replyDone'),
        label: '首轮收束',
      );

      // 断线（无 close 帧的静默断开同形）。
      await harness.connection.close();
      await until(
        () => harness.phases().contains('reconnecting'),
        label: '进入重连',
      );
      await until(() => harness.reconnectWaits.isNotEmpty, label: '重连等待挂起');
      final second = harness.connector.enqueue();
      _respondWithScript(second, const []);
      harness.reconnectWaits.single.complete();

      await until(
        () =>
            harness.connector.connectCount >= 2 &&
            harness.phases().last == 'active',
        label: '重连成功',
      );
      // 回放本机最近上下文（含预置历史与本通话已落盘轮），不触发回复。
      final replayTexts = second.framesOfType('conversation.item.create')
          .map(_itemText)
          .toList();
      expect(replayTexts.join('\n'), contains('昨天聊过雨声'));
      expect(replayTexts.join('\n'), contains('在吗'));
      expect(second.framesOfType('response.create'), isEmpty);
    });

    test('重连等待期间用户结束：撤销等待，不再建连', () async {
      final harness = _Harness();
      await harness.start();

      await harness.connection.close();
      await until(
        () => harness.reconnectWaits.isNotEmpty,
        label: '重连等待挂起',
      );
      await harness.callService.stopCall();
      harness.reconnectWaits.single.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(harness.connector.connectCount, 1);
      expect(harness.phases().last, 'ended');
    });

    test('鉴权错误直接结束，不重试', () async {
      final harness = _Harness();
      await harness.start();

      harness.connection.server({
        'type': 'error',
        'error': {'code': 'InvalidApiKey'},
      });
      await until(
        () => harness.phases().last == 'ended',
        label: '鉴权失败结束',
      );
      expect(harness.connector.connectCount, 1);
      final ended = harness.frontEvents
          .where(
            (event) => event['type'] == 'state' && event['phase'] == 'ended',
          )
          .single;
      expect(ended['reason'], contains('API Key'));
    });

    test('Provider 切换（凭据作用域变化）后重连直接结束', () async {
      final harness = _Harness();
      await harness.start();
      await harness.connection.close();
      await until(
        () => harness.reconnectWaits.isNotEmpty,
        label: '重连等待挂起',
      );
      // 等待期间切换配置（不同地址 → 凭据指纹不匹配）。
      const switched = ProviderConfig(
        kind: ProviderKind.qwenOmniRealtime,
        baseUrl: 'wss://other.example.com/realtime',
        model: 'qwen3.8-omni-flash-realtime',
        temperature: 0.7,
        timeoutSeconds: 1,
      );
      harness.configRepo.config = switched.withApiKey('key-omni');
      harness.reconnectWaits.single.complete();
      await until(
        () => harness.phases().last == 'ended',
        label: '切换后结束',
      );
      final ended = harness.frontEvents
          .where(
            (event) => event['type'] == 'state' && event['phase'] == 'ended',
          )
          .last;
      expect(ended['reason'], contains('切换'));
      expect(harness.connector.connectCount, 1);
    });
  });

  group('记忆控制与热层（T03:12、14）', () {
    test('禁提动作即时生效并整体刷新实时 instructions', () async {
      final harness = _Harness(
        callReplies: [
          // 静默 memory_ban 调用。
          [
            _responseCreated('resp-1'),
            _functionCallItem('item-1', 'call-1', 'memory_ban'),
            _argsDone(
              'resp-1',
              'item-1',
              jsonEncode({'summary': '芒果过敏的话题'}),
            ),
            _responseDone('resp-1', 'completed'),
          ],
          [
            _responseCreated('resp-1b'),
            _transcriptDelta('resp-1b', '好，不提了。'),
            _responseDone('resp-1b', 'completed'),
          ],
        ],
      );
      await harness.start();

      harness.sendFront({
        'type': 'text',
        'requestId': 'type-1',
        'text': '以后别提芒果的事了',
      });
      await until(
        () => harness.connection.framesOfType('session.update').length >= 2,
        label: '热层刷新下发',
      );

      // 控制已写盘：受控集合出现该话题。
      expect(
        await harness.memoryModule.openLoopStore.controlledTitles(),
        contains('芒果过敏的话题'),
      );
      // 回填照常，续答交付确认语。
      final backfill = harness.connection.framesOfType('conversation.item.create')
          .map((frame) => frame['item']! as Map<String, Object?>)
          .firstWhere((item) => item['type'] == 'function_call_output');
      expect(jsonDecode(backfill['output']! as String), {'status': 'ok'});
      await until(
        () => harness.frontEvents.any(
          (event) =>
              event['type'] == 'replyDelta' &&
              (event['text']! as String).contains('不提了'),
        ),
        label: '确认语交付',
      );
    });

    test('控制命中本通话已说内容时重建连接，重放剔除受控轮', () async {
      final harness = _Harness(
        callReplies: [
          // 第一轮：正常可见回复（话里带受控词）。
          [
            _responseCreated('resp-1'),
            _transcriptDelta('resp-1', '你说过你住在梧桐里。'),
            _responseDone('resp-1', 'completed'),
          ],
          // 第二轮：静默 memory_ban。
          [
            _responseCreated('resp-2'),
            _functionCallItem('item-2', 'call-2', 'memory_ban'),
            _argsDone('resp-2', 'item-2', jsonEncode({'summary': '梧桐里'})),
            _responseDone('resp-2', 'completed'),
          ],
          [
            _responseCreated('resp-2b'),
            _transcriptDelta('resp-2b', '好。'),
            _responseDone('resp-2b', 'completed'),
          ],
        ],
      );
      await harness.start();

      harness.sendFront({
        'type': 'text',
        'requestId': 'type-1',
        'text': '我以前住梧桐里',
      });
      await until(
        () => harness.frontEvents.any(
          (event) =>
              event['type'] == 'replyDone' && event['status'] == 'completed',
        ),
        label: '第一轮收束',
      );
      // 等第一轮收束链（落盘 + 轮次收束）真正排空再开第二轮。
      await until(
        () async {
          final session = await harness.turnsOnDisk();
          return session.turns.length >= 2;
        },
        label: '第一轮落盘',
      );
      harness.sendFront({
        'type': 'text',
        'requestId': 'type-2',
        'text': '这件事别再提了',
      });
      // 受控重建走有界重连路径：等待挂起后放行，新连接才发放。
      await until(
        () => harness.reconnectWaits.isNotEmpty,
        label: '重建重连等待挂起',
      );
      final second = harness.connector.enqueue();
      _respondWithScript(second, const []);
      harness.reconnectWaits.single.complete();
      await until(
        () => harness.connector.connectCount >= 2,
        label: '受控重建建连',
      );
      await until(
        () => harness.phases().last == 'active',
        label: '重建完成',
      );
      // 重放里受控轮整条剔除：任何回放 item 都不含「梧桐里」。
      final replayTexts = second.framesOfType('conversation.item.create')
          .map(_itemText)
          .toList();
      expect(replayTexts.join('\n'), isNot(contains('梧桐里')));
    });
  });

  group('晚安与节奏（T03:14）', () {
    test('晚安信号触发日终归档（当天 finalized）', () async {
      final harness = _Harness(
        callReplies: [
          // 静默 memory_signal（写下「睡了」这条信息，让当天有 episode）。
          [
            _responseCreated('resp-1'),
            _functionCallItem('item-1', 'call-1', 'memory_signal'),
            _argsDone(
              'resp-1',
              'item-1',
              jsonEncode({'summary': '用户今晚早睡', 'evidence': '我睡了'}),
            ),
            _responseDone('resp-1', 'completed'),
          ],
          [
            _responseCreated('resp-1b'),
            _transcriptDelta('resp-1b', '晚安。'),
            _responseDone('resp-1b', 'completed'),
          ],
        ],
      );
      await harness.start();

      harness.sendFront({
        'type': 'text',
        'requestId': 'type-1',
        'text': '晚安，我睡了',
      });
      await until(
        () => harness.frontEvents.any(
          (event) =>
              event['type'] == 'replyDone' && event['status'] == 'completed',
        ),
        label: '晚安轮收束',
      );
      // onDeliveryComplete 在轮次收束尾部才把归档挂上节奏链：轮询到
      // finalized 为止，避免测试的 finalizePending 抢在挂链之前 await。
      var day = await harness.effectivePipeline.readDay('2026-10-02');
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!day.finalized) {
        if (DateTime.now().isAfter(deadline)) {
          fail('日终归档未完成');
        }
        await harness.memoryModule.memoryCadence.finalizePending();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        day = await harness.effectivePipeline.readDay('2026-10-02');
      }
      expect(day.finalized, true);
      expect(day.entries.any((entry) => entry.summary.contains('早睡')), true);
    });
  });

  group('上行门禁与结束边界（T03:11、16）', () {
    test('闭麦丢弃上行音频，结束后的上行帧一律不转发', () async {
      final harness = _Harness();
      await harness.start();

      harness.sendFront({'type': 'audio', 'pcm': base64Encode([1, 2, 3, 4])});
      await until(
        () =>
            harness.connection.framesOfType('input_audio_buffer.append').length ==
            1,
        label: '上行转发',
      );
      harness.sendFront({'type': 'mute', 'muted': true});
      harness.sendFront({'type': 'audio', 'pcm': base64Encode([5, 6, 7, 8])});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        harness.connection.framesOfType('input_audio_buffer.append').length,
        1,
      );
      harness.sendFront({'type': 'mute', 'muted': false});
      harness.sendFront({'type': 'audio', 'pcm': base64Encode([9, 10, 11, 12])});
      await until(
        () =>
            harness.connection.framesOfType('input_audio_buffer.append').length ==
            2,
        label: '恢复上行',
      );

      await harness.callService.stopCall();
      harness.sendFront({'type': 'audio', 'pcm': base64Encode([13])});
      harness.sendFront({
        'type': 'text',
        'requestId': 'after-end',
        'text': '还在吗',
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        harness.connection.framesOfType('input_audio_buffer.append').length,
        2,
      );
      expect(harness.connection.framesOfType('response.create'), isEmpty);
    });
  });
}
