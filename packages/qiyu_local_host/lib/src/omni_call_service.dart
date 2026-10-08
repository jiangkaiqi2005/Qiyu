import 'dart:async';
import 'dart:convert';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'chat_memory_module.dart';
import 'hidden_action_executor.dart';
import 'local_chat_service.dart' show bedtimeSignalPattern;
import 'markdown_memory_repository.dart';
import 'memory_recall.dart';
import 'memory_text_primitives.dart';
import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'omni_realtime_tools.dart';
import 'provider_settings_service.dart';
import 'qwen_omni_realtime_gateway.dart';

/// 输入语音转录缺失时的落盘标识（spec:58：缺失／失败如实标识，不用
/// 推断文字伪造原话）。标识只说明「这段语音没能转出文字」，绝不
/// 猜测内容。
const omniMissingTranscriptMarker = '（这段语音没能转出文字）';

/// 有声回复转录缺失时的落盘标识：音频已交付播放但同回复 transcript
/// 缺失，记录同样如实标识。
const omniMissingReplyTranscriptMarker = '（这条回复没能转出文字）';

/// 通话事件发往前端的出口形态：一个 JSON 对象（路由层负责编码成
/// WS 文本帧）。
typedef OmniCallFrontSink = void Function(Map<String, Object?> event);

/// 有界重连的单次等待注入点（spec:73 等待 1/2/4 秒）；测试注入即时
/// 完成的等待。
typedef OmniReconnectWait = Future<void> Function(Duration delay);

/// 每次断线的有界重连参数（spec:73）：最多 3 次，等待 1/2/4 秒，
/// 成功清零，明确结束撤销。
const omniReconnectMaxAttempts = 3;
const omniReconnectDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
];

/// 连接存活多久算「成功清零」（spec:73）：断线计数只在上一条连接
/// 真正跑过一段对话（本口径取 10 秒）后才清零，瞬断抖动仍按同一段
/// 断线累计，不会靠反复闪连绕开有界重连。
const _reconnectResetAfterActive = Duration(seconds: 10);

/// 连续看门狗超时的重连阈值（T01 §11：建连后模型长时间无输出是真实
/// 故障；连续两轮无产出即视为降级，按有界重连处理，不无限等）。
const _consecutiveTimeoutReconnectThreshold = 2;

/// 一轮通话用户输入的记录态（语音轮或打字轮）。一条用户轮可以跨
/// 多条回复（主回复 + 工具静默轮 + 续答，续答落盘沿用聊天召回
/// bubble 2 的同 requestId 多栖语轮形状）。
final class _CallTurn {
  _CallTurn({required this.turnId, required this.requestId, this.typedText});

  final String turnId;
  final String requestId;

  /// 打字轮的净化原文；语音轮为 null（内容以输入转录为准）。
  final String? typedText;

  /// 输入转录（服务端 gummy completed 事件为权威整段）。
  String transcript = '';

  /// 用户部分是否已可落盘（语音轮 VAD 判停或打字轮即真）。
  bool speechStopped = false;

  /// 用户轮是否已落盘。
  bool userPersisted = false;

  /// 已校验待提交的动作（轮次收束时经共享执行器落地）。
  final List<HiddenAction> actions = [];

  /// 当前在途回复内已接受的动作数（聊天契约：每条回复最多两个）。
  int actionsThisResponse = 0;

  /// 本轮仍在途的回复数（>0 时轮次不收束）。
  int openResponses = 0;

  /// 等待回填的原生工具调用数（>0 时轮次不收束）。
  int openToolBackfills = 0;

  /// 工具调用时刻的用户活动计数（回填先于用户新轮的抢占判据）。
  int userActivityAtToolCall = 0;

  /// 本轮最近一条回复的在途记录（静默工具轮的续答判定依据）。
  _CallResponse? currentResponse;

  /// 轮次记忆（动作/称呼/晚安）是否已提交：正常收束与放弃收束共用
  /// 同一提交入口，幂等防双写。
  bool memoryCommitted = false;

  /// 晚安信号只按用户轮触发一次。
  bool bedtimeApplied = false;
}

/// 一条回复（response）的在途记录：同一轮的多条回复各自独立做增量
/// 卫生与终态落盘，互不锁定。
final class _CallResponse {
  _CallResponse(this.turn);

  final _CallTurn turn;
  final CandidateReplyStream reply = CandidateReplyStream();
  bool audioSeen = false;
  bool hasVisibleText = false;
  bool persisted = false;
}

/// Omni 实时通话的会话级状态（state 事件的 phase 取值）。
enum OmniCallPhase { idle, connecting, active, reconnecting, ended }

/// Omni 双工实时通话服务（T03）：Host 侧完整对话链路——完整人格
/// 提示词（实时工具指令变体）、原生工具承载隐藏动作、晚一拍回忆
/// （工具回填先于用户新轮）、Markdown 会话落盘、热层刷新、禁提
/// 过滤与有界重连。双方音频只在内存流转、用完即弃，不落盘、不进
/// 日志、不进备份（spec:58）。
///
/// 前端不直接拿 Key 连接 Provider：本服务经 [QwenOmniRealtimeGateway]
/// 出网，凭据只在 Host 内解析流转；前端经 [OmniCallFrontSink] 收事件、
/// 经 [handleFrontFrame] 发控制帧，传输由路由层适配（T04 接 Web 界面）。
final class OmniRealtimeCallService {
  OmniRealtimeCallService({
    required this.gateway,
    required this.providerSettings,
    required this.repository,
    required this.memory,
    required this.actionExecutor,
    required this.modelPromptBuilder,
    Clock? clock,
    void Function(String message)? diagnosticsSink,
    OmniReconnectWait? reconnectWait,
  }) : _clock = clock ?? DateTime.now,
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics,
       _reconnectWait = reconnectWait ?? Future<void>.delayed;

  final QwenOmniRealtimeGateway gateway;
  final ProviderSettingsService providerSettings;
  final MemoryRepository repository;
  final ChatMemoryModule memory;
  final HiddenActionExecutor actionExecutor;
  final ModelPromptBuilder modelPromptBuilder;
  final Clock _clock;
  final void Function(String message) _diagnosticsSink;
  final OmniReconnectWait _reconnectWait;

  /// 当前通话的出口（一次通话一个前端连接；新通话顶替旧通话）。
  OmniCallFrontSink? _front;

  OmniCallPhase _phase = OmniCallPhase.idle;
  String? _phaseReason;

  /// 通话期间用户主动结束的信号。
  Completer<void>? _endRequested;

  OmniRealtimeSession? _session;
  StreamSubscription<OmniRealtimeEvent>? _eventSubscription;

  /// 会话级失败（error 事件/断线）的分类，连接收口后据此决定结束
  /// 还是重连。
  ModelGatewayException? _sessionFailure;

  /// 建连时锁定的凭据指纹：重连时与现值比对，Provider/作用域变化
  /// 即结束（T03:16 切换停旧连接，不沿用另一凭据作用域的旧 Key）。
  OmniRealtimeCredentials? _callCredentials;

  String? _sessionId;
  RawSession? _rawSession;

  int _turnCounter = 0;

  /// 用户活动计数（开口/判停/打字都推进）：工具调用之后是否又来了
  /// 新用户轮的抢占判据。
  int _userActivity = 0;

  /// 说话中（speech_started 后、speech_stopped 前）积攒的输入转录。
  String _liveTranscript = '';

  bool _muted = false;

  /// 期望下一个 response.created 归属的用户轮（语音判停自动建响应 /
  /// 打字轮显式建响应）。
  String? _pendingResponseTurnId;

  /// 工具续答期望的归属轮（回填续答 response.created 的归属）。
  String? _continuationTurnId;

  final _turns = <String, _CallTurn>{};
  final _responses = <String, _CallResponse>{};

  int _consecutiveTimeouts = 0;

  bool get _ended => _phase == OmniCallPhase.ended;

  /// fire-and-forget 异步收口：轮次落盘/收束/检索等后台任务的失败
  /// 只进诊断（含原因），绝不成为未捕获异常、绝不中断通话事件流。
  void _fireAndForget(Future<void> future, String label) {
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        _diagnosticsSink('omni call $label deferred [$error]');
      }),
    );
  }

  /// 轮次工作串行链：回复落盘与轮次收束共享一条 FIFO 链——二者都要
  /// 读改会话快照与用户轮标志，并发跑会双写用户轮、读到过期快照
  /// （记忆控制的重建判定因此失真）。失败只进诊断，链条不断。
  Future<void> _turnWorkChain = Future.value();

  void _chainTurnWork(Future<void> Function() work, String label) {
    final result = _turnWorkChain.then((_) => work());
    _turnWorkChain =
        result.catchError((Object error, StackTrace stackTrace) {
      _diagnosticsSink('omni call $label deferred [$error]');
    });
  }

  // -------------------------------------------------------------------------
  // 通话生命周期（路由层入口）
  // -------------------------------------------------------------------------

  /// 开始一通通话：校验 Omni 实时档凭据 → 建连 → 装配会话 → 回放
  /// 本机上下文。事件经 [send] 推给前端（state/语音事件/转录/回复
  /// 增量/音频块）；控制帧经 [handleFrontFrame] 回流。同一时刻至多
  /// 一通：重复开始先安静结束旧通话（新通话顶替，不并存）。
  Future<void> startCall({
    required OmniCallFrontSink send,
    String? sessionId,
  }) async {
    if (!_ended && _phase != OmniCallPhase.idle) {
      await stopCall(reason: '新的通话已开始，本通已结束。');
    }
    _front = send;
    _sessionId = sessionId?.trim().isEmpty == false ? sessionId!.trim() : null;
    _phase = OmniCallPhase.connecting;
    _phaseReason = null;
    _turnCounter = 0;
    _userActivity = 0;
    _consecutiveTimeouts = 0;
    _liveTranscript = '';
    _muted = false;
    _pendingResponseTurnId = null;
    _continuationTurnId = null;
    _turns.clear();
    _responses.clear();
    _endRequested = Completer<void>();
    _sendState();
    _fireAndForget(_run(), 'run');
  }

  /// 结束当前通话（幂等）：立即撤回复连等待、关闭 Provider 会话；
  /// 在途轮按打断语义收束落盘；结束后的上行帧一律丢弃，旧事件不能
  /// 复活通话（spec:24）。
  Future<void> stopCall({String? reason}) async {
    if (_phase == OmniCallPhase.idle || _ended) {
      return;
    }
    _phase = OmniCallPhase.ended;
    _phaseReason = reason ?? '通话已结束。';
    await _abandonOpenResponses();
    await _detachCall();
  }

  /// 会话与前端 detachment 公共收尾（stopCall / _finishCall 共用）：
  /// 撤结束信号与事件订阅、关闭 Provider 会话、推送终态并清空出口。
  Future<void> _detachCall() async {
    _endRequested?.complete();
    _endRequested = null;
    _eventSubscription?.cancel();
    _eventSubscription = null;
    await _session?.close();
    _session = null;
    _sendState();
    _front = null;
  }

  /// 前端控制帧（路由层已解码 JSON 对象）：
  /// `{"type":"audio","pcm":"<base64>"}`、`{"type":"text",...}`、
  /// `{"type":"mute","muted":bool}`、`{"type":"end"}`。
  Future<void> handleFrontFrame(Map<String, Object?> frame) async {
    if (_ended || _phase == OmniCallPhase.idle) {
      return;
    }
    switch (frame['type']) {
      case 'audio':
        final pcm = frame['pcm'];
        if (pcm is String && pcm.isNotEmpty && !_muted) {
          final session = _session;
          if (session != null) {
            try {
              session.appendAudio(base64Decode(pcm));
            } on FormatException {
              _diagnosticsSink('omni call dropped malformed uplink audio');
            }
          }
        }
      case 'text':
        final requestId = frame['requestId'];
        final text = frame['text'];
        if (requestId is! String ||
            requestId.trim().isEmpty ||
            text is! String ||
            text.trim().isEmpty) {
          _diagnosticsSink('omni call rejected malformed text frame');
          return;
        }
        await _openTextTurn(requestId.trim(), sanitizeUserInput(text));
      case 'mute':
        // 闭麦只停收音，回答照常听（spec 前端摆放语义）；Host 侧
        // 丢弃上行是边界，前端停采集是第一道。
        _muted = frame['muted'] == true;
      case 'end':
        await stopCall();
      default:
        _diagnosticsSink(
          'omni call ignored unknown front frame [${frame['type']}]',
        );
    }
  }

  // -------------------------------------------------------------------------
  // 连接与重连
  // -------------------------------------------------------------------------

  Future<void> _run() async {
    var attempt = 0;
    while (!_ended) {
      final credentials = await providerSettings.resolveRealtimeCredentials();
      if (credentials == null) {
        await _finishCall('还没有配置百炼 Omni 实时模型或 API Key。');
        return;
      }
      final switching = _callCredentials != null &&
          !_callCredentials!.matches(credentials);
      _callCredentials = credentials;
      if (switching) {
        await _finishCall('模型配置已切换，本次通话已结束。');
        return;
      }
      try {
        final sessionConfig = await _sessionConfig();
        final session = await gateway.connect(
          config: credentials.config,
          apiKey: credentials.apiKey,
          sessionConfig: sessionConfig,
        );
        if (_ended) {
          await session.close();
          return;
        }
        _session = session;
        _activeInstructions = sessionConfig.instructions;
        _sessionFailure = null;
        // 先挂事件订阅（同步生效）再回放上下文：广播事件流不重放，
        // 建连后立刻到达的服务端事件绝不能落在订阅之前丢失。
        final pump = _startPump(session);
        _phase = OmniCallPhase.active;
        _phaseReason = null;
        _sendState();
        await _replayContext();
        final connectedAt = _clock();
        await pump;
        if (_ended) {
          return;
        }
        await _abandonOpenResponses();
        final failure = _sessionFailure;
        if (failure != null &&
            (failure.kind == ModelFailureKind.authentication ||
                failure.kind == ModelFailureKind.modelNotFound)) {
          // 鉴权／配置错误直接说明并结束（spec:73），不重试。
          await _finishCall(failure.message);
          return;
        }
        // 上一条连接真正跑过一段时间才清零断线计数（成功清零口径见
        // [_reconnectResetAfterActive]）。
        if (_clock().difference(connectedAt) >= _reconnectResetAfterActive) {
          attempt = 0;
        }
        if (!await _enterReconnect(attempt)) {
          return;
        }
        attempt += 1;
      } on ModelGatewayException catch (error) {
        if (_ended) {
          return;
        }
        if (error.kind == ModelFailureKind.authentication ||
            error.kind == ModelFailureKind.modelNotFound) {
          await _finishCall(error.message);
          return;
        }
        if (!await _enterReconnect(attempt)) {
          return;
        }
        attempt += 1;
      } on Object catch (error) {
        if (_ended) {
          return;
        }
        _diagnosticsSink('omni call connect error [$error]');
        if (!await _enterReconnect(attempt)) {
          return;
        }
        attempt += 1;
      }
    }
  }

  /// 重连耗尽判定：达到上限时按可理解原因终局结束并返回 false。
  Future<bool> _exhaustedReconnects(int attempt) async {
    if (attempt < omniReconnectMaxAttempts) {
      return false;
    }
    await _finishCall('与模型服务的实时连接多次中断，本次通话已结束。');
    return true;
  }

  /// 进入下一次重连前的公共收尾：切 reconnecting 状态并等待退避。
  /// 返回 false 表示期间通话已被明确结束，调用方直接收口。
  Future<bool> _enterReconnect(int attempt) async {
    if (await _exhaustedReconnects(attempt)) {
      return false;
    }
    _phase = OmniCallPhase.reconnecting;
    _phaseReason = null;
    _sendState();
    await _reconnectWait(omniReconnectDelays[attempt]);
    return !_ended;
  }

  /// 挂上事件订阅并抽干一通连接直到会话结束（主动关闭、失败或断线
  /// 都会收口）。订阅在调用时刻同步生效，返回的 Future 在会话结束后
  /// 完成（订阅取消、连接关闭）。事件经微任务分派处理：服务的回调会
  /// 同步发出客户端帧（工具回填、续答），帧在真实 WebSocket 上原样
  /// 出网，但绝不允许服务回调重入网关的事件发布栈（看门狗定时器与
  /// 帧驱动的发布可能同刻并发）。
  Future<void> _startPump(OmniRealtimeSession session) async {
    final failure = Completer<void>();
    final sub = session.events.listen(
      (event) {
        // 就算连接收口先于本微任务（error/收尾同刻到达），事件本身
        // 仍要处理：会话失败分类据此决定结束还是重连。
        scheduleMicrotask(() {
          if (!_ended) {
            _handleSessionEvent(event);
          }
        });
      },
      onError: (Object error) {
        if (!failure.isCompleted) {
          failure.complete();
        }
      },
      onDone: () {
        if (!failure.isCompleted) {
          failure.complete();
        }
      },
    );
    _eventSubscription = sub;
    final endWait = _endRequested?.future;
    try {
      await Future.any<void>([
        failure.future,
        session.done,
        ?endWait,
      ]);
    } finally {
      await sub.cancel();
      if (identical(_eventSubscription, sub)) {
        _eventSubscription = null;
      }
      await session.close();
      if (identical(_session, session)) {
        _session = null;
      }
    }
  }

  /// 以给定原因终局结束（重连耗尽/鉴权失败/配置切换等）：在途工作由
  /// 调用方先行收束，这里只做会话与前端 detachment。
  Future<void> _finishCall(String reason) async {
    _phase = OmniCallPhase.ended;
    _phaseReason = reason;
    await _detachCall();
  }

  // -------------------------------------------------------------------------
  // 会话装配与上下文回放
  // -------------------------------------------------------------------------

  /// 组装会话配置：完整人格与硬规则（实时工具指令变体）+ 本机过滤
  /// 后的热层三块 + 11 个原生动作工具。每次建连现读热层——当前实时
  /// 会话不沿用建连快照（spec:52）。
  Future<OmniRealtimeSessionConfig> _sessionConfig() async {
    final prepared = await memory.statePackReader.readHotLayerBlocks();
    final failure = prepared.failure;
    if (failure != null) {
      _diagnosticsSink('omni call state pack unavailable [$failure]');
    }
    final builder = prepared.applyTo(modelPromptBuilder);
    return OmniRealtimeSessionConfig(
      instructions: builder.buildRealtimeInstructions(),
      audioOutput: true,
      tools: omniRealtimeMemoryTools,
    );
  }

  /// 建连后回放本机最近上下文（T01 §11 实测机制）：最近若干轮按序
  /// 重放为对话 item，先经记忆控制过滤与会话脱敏；不触发回复、不
  /// 落盘、不自动重发旧输入（spec:24）。
  Future<void> _replayContext() async {
    final session = _session;
    if (session == null) {
      return;
    }
    final raw = await _openRawSession();
    final controlled = await memory.openLoopStore.controlledTitles();
    final turns = raw.turns.length <= 8
        ? raw.turns
        : raw.turns.sublist(raw.turns.length - 8);
    for (final turn in turns) {
      if (bannedMemoryText(turn.text, controlled)) {
        _diagnosticsSink('omni call replay turn withheld reason=controlled');
        continue;
      }
      final text =
          '${MomentPrefix.format(turn.at)} ${redactSessionText(turn.text)}';
      if (turn.speaker == Speaker.user) {
        session.sendUserItem(text);
      } else {
        session.sendAssistantItem(text);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Provider 事件处理
  // -------------------------------------------------------------------------

  void _handleSessionEvent(OmniRealtimeEvent event) {
    if (_ended) {
      return;
    }
    switch (event) {
      case OmniRealtimeSpeechStarted():
        _userActivity += 1;
        _liveTranscript = '';
        _front?.call({'type': 'speechStarted'});
      case OmniRealtimeSpeechStopped():
        _front?.call({'type': 'speechStopped'});
        _openVoiceTurn();
      case OmniRealtimeInputTranscript(:final text):
        _attachTranscript(text);
      case OmniRealtimeResponseCreated(:final responseId?):
        _attachResponse(responseId);
      case OmniRealtimeReplyDelta(:final responseId?, :final text):
        _handleReplyDelta(responseId, text);
      case OmniRealtimeAudioChunk(:final responseId, :final bytes):
        final response = _responses[responseId];
        if (response != null) {
          response.audioSeen = true;
          _front?.call({
            'type': 'audio',
            'turnId': response.turn.turnId,
            'pcm': base64Encode(bytes),
          });
        }
      case OmniRealtimeToolCall(
          :final responseId?,
          :final callId,
          :final name,
          :final arguments,
        ):
        _handleToolCall(responseId, callId, name, arguments);
      case OmniRealtimeResponseFinished(:final responseId?, :final status):
        _handleResponseFinished(responseId, status);
      case OmniRealtimeResponseTimedOut(:final responseId?):
        _handleResponseTimeout(responseId);
      case OmniRealtimeSessionFailed(:final kind, :final message):
        _sessionFailure = ModelGatewayException(kind: kind, message: message);
      case OmniRealtimeSessionUpdated():
        break;
      // 网关按构造保证这些事件携带非空 response id；空 id 形态按
      // 未知事件忽略（网关侧也不会发布）。
      case OmniRealtimeEvent():
        break;
    }
  }

  String _nextTurnId(String prefix) {
    _turnCounter += 1;
    return '$prefix-$_turnCounter';
  }

  void _openVoiceTurn() {
    _userActivity += 1;
    final turn = _CallTurn(
      turnId: _nextTurnId('voice'),
      requestId: 'omni-${_clock().millisecondsSinceEpoch}-$_turnCounter',
    )..speechStopped = true;
    turn.transcript = _liveTranscript;
    _liveTranscript = '';
    _turns[turn.turnId] = turn;
    _pendingResponseTurnId = turn.turnId;
  }

  Future<void> _openTextTurn(String requestId, String cleanText) async {
    // 幂等：同一 requestId 的重复打字帧不重复开轮、不重复送模型。
    final duplicated = _turns.values.any(
      (turn) => turn.typedText != null && turn.requestId == requestId,
    );
    if (duplicated) {
      _diagnosticsSink('omni call ignored duplicate text requestId=$requestId');
      return;
    }
    _userActivity += 1;
    final turn = _CallTurn(
      turnId: _nextTurnId('text'),
      requestId: requestId,
      typedText: cleanText,
    )..speechStopped = true;
    _turns[turn.turnId] = turn;
    _pendingResponseTurnId = turn.turnId;
    final session = _session;
    if (session == null) {
      return;
    }
    session.sendUserItem('${MomentPrefix.format(_clock())} $cleanText');
    session.createResponse();
  }

  /// 输入转录归轮：正在等本语音轮首条回复时整段覆盖（completed 事件
  /// 是权威全文）；回复都已收束才到达的迟到转录如实丢弃并记诊断
  /// （不编原话、不复活旧轮）。
  void _attachTranscript(String text) {
    final turnId = _pendingResponseTurnId ?? _continuationTurnId;
    final turn = turnId == null ? null : _turns[turnId];
    if (turn != null && turn.typedText == null) {
      turn.transcript = text;
      _front?.call({'type': 'inputTranscript', 'turnId': turn.turnId, 'text': text});
      return;
    }
    _diagnosticsSink('omni call dropped late input transcript');
  }

  /// response.created 归属：优先等首条回复的用户轮，其次工具续答轮；
  /// 都没有时挂到最近用户轮并记诊断（不猜新轮）。
  void _attachResponse(String responseId) {
    var turnId = _pendingResponseTurnId;
    _pendingResponseTurnId = null;
    if (turnId == null) {
      turnId = _continuationTurnId;
      _continuationTurnId = null;
    }
    var turn = turnId == null ? null : _turns[turnId];
    if (turn == null) {
      turn = _turns.values.isEmpty ? null : _turns.values.last;
      if (turn != null) {
        _diagnosticsSink('omni call response attributed to last turn');
      }
    }
    if (turn == null) {
      return;
    }
    turn.openResponses += 1;
    final response = _CallResponse(turn);
    turn.currentResponse = response;
    _responses[responseId] = response;
  }

  // -------------------------------------------------------------------------
  // 回复增量与音频
  // -------------------------------------------------------------------------

  void _handleReplyDelta(String responseId, String delta) {
    final response = _responses[responseId];
    if (response == null) {
      return;
    }
    response.hasVisibleText = true;
    final visible = response.reply.add(delta);
    if (visible.isNotEmpty) {
      _front?.call({
        'type': 'replyDelta',
        'turnId': response.turn.turnId,
        'text': visible,
      });
    }
  }

  // -------------------------------------------------------------------------
  // 原生工具承载（隐藏动作 + 晚一拍回忆）
  // -------------------------------------------------------------------------

  void _handleToolCall(
    String responseId,
    String callId,
    String name,
    String arguments,
  ) {
    final response = _responses[responseId];
    final session = _session;
    if (response == null || session == null) {
      return;
    }
    final turn = response.turn;
    Map<String, Object?> fields;
    try {
      final decoded = jsonDecode(arguments.isEmpty ? '{}' : arguments);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('tool arguments must be an object');
      }
      fields = decoded;
    } on FormatException {
      _diagnosticsSink('omni call tool arguments invalid [$name]');
      session.sendToolResult(
        callId: callId,
        output: jsonEncode({'status': 'rejected'}),
        requestContinuation: false,
      );
      return;
    }
    final diagnostics = <String>[];
    final action = parseHiddenActionObject(name, fields, diagnostics);
    for (final diagnostic in diagnostics) {
      _diagnosticsSink('omni call action dropped [$diagnostic]');
    }
    if (action == null) {
      session.sendToolResult(
        callId: callId,
        output: jsonEncode({'status': 'rejected'}),
        requestContinuation: false,
      );
      return;
    }
    if (turn.actionsThisResponse >= maxHiddenActionsPerReply) {
      _diagnosticsSink('omni call action over limit [$name]');
      session.sendToolResult(
        callId: callId,
        output: jsonEncode({'status': 'rejected', 'reason': 'limit'}),
        requestContinuation: false,
      );
      return;
    }
    turn.actionsThisResponse += 1;
    turn.actions.add(action);
    turn.userActivityAtToolCall = _userActivity;
    turn.openToolBackfills += 1;
    if (action is MemoryRecallAction) {
      // 晚一拍回忆（spec:54）：检索后台继续，绝不阻塞、绝不在工具轮
      // 发声；回填先于用户新轮（T01 §1.1 第 3 条时序约束），被抢话的
      // 旧检索不唤醒旧语音（spec:55）。
      _fireAndForget(_runRecallTool(turn, session, callId, action), 'recall tool');
      return;
    }
    // 记录／控制动作：先回填结果保持对话历史不悬挂调用；执行语义
    // 统一在轮次收束时经共享执行器落地（提交语义见 _closeTurn 文档：
    // 按条校验的原生工具调用即完整提案，与回复终态解耦）。
    turn.openToolBackfills -= 1;
    session.sendToolResult(
      callId: callId,
      output: jsonEncode({'status': 'ok'}),
      requestContinuation: false,
    );
    _maybeContinueAfterTool(turn);
  }

  /// 回忆工具的后台执行：与轮内召回同一套定位（票 07：启用 RAG 时经
  /// 共享服务语义定位，未启用走旧目录查找；选择小调用仍走选中
  /// Provider，不换模型，spec:54）→ 证据压缩 → 三态回填（有候选／无
  /// 有效候选／暂不可用，不互相冒充）→ 视抢占情况请求续答。
  Future<void> _runRecallTool(
    _CallTurn turn,
    OmniRealtimeSession session,
    String callId,
    MemoryRecallAction action,
  ) async {
    final result = await memory.memoryRecall.lookupForRealtime(
      query: action.query,
      userText: turn.typedText ?? turn.transcript,
    );
    for (final diagnostic in result.diagnostics) {
      _diagnosticsSink(diagnostic);
    }
    turn.openToolBackfills -= 1;
    if (!identical(session, _session) || _ended) {
      return;
    }
    session.sendToolResult(
      callId: callId,
      output: jsonEncode(switch (result) {
        RealtimeRecallFound(:final context) => {
          'status': 'found',
          'context': context,
        },
        RealtimeRecallEmpty() => const {'status': 'empty'},
        RealtimeRecallUnavailable() => const {'status': 'unavailable'},
      }),
      requestContinuation: false,
    );
    _maybeContinueAfterTool(turn);
  }

  /// 工具回填后的续答判定（T01 §9 实测形状）：回填全部落定、所在回复
  /// 也已收束，而该回复完全「没有可见文字」（静默工具轮）时请求续答
  /// ——模型需要开口补充或确认；可见回复已交付的轮不追加续答。回填
  /// 必须先于用户新轮：判据是工具调用之后用户是否又开了口／发了字，
  /// 被抢占的旧结果不再唤醒旧语音（spec:55）。续答判定发生在回复
  /// 收束之后（工具调用到达时回复仍在途，此时只等待），因此回忆等
  /// 异步回填晚于回复收束完成时同样能触发续答。
  void _maybeContinueAfterTool(_CallTurn turn) {
    if (_ended || turn.openToolBackfills > 0 || turn.openResponses > 0) {
      return;
    }
    final session = _session;
    if (session == null) {
      return;
    }
    if (turn.userActivityAtToolCall != _userActivity) {
      _diagnosticsSink('omni call tool continuation preempted by new turn');
      _chainTurnWork(() => _closeTurn(turn), 'turn close');
      return;
    }
    final silentToolResponse = turn.actions.isNotEmpty &&
        !(turn.currentResponse?.hasVisibleText ?? false);
    if (!silentToolResponse) {
      _chainTurnWork(() => _closeTurn(turn), 'turn close');
      return;
    }
    _continuationTurnId = turn.turnId;
    session.createResponse();
  }

  // -------------------------------------------------------------------------
  // 回复收束与落盘
  // -------------------------------------------------------------------------

  void _handleResponseFinished(
    String responseId,
    OmniRealtimeResponseStatus status,
  ) {
    final response = _responses.remove(responseId);
    if (response == null) {
      return;
    }
    final turn = response.turn;
    turn.openResponses -= 1;
    turn.actionsThisResponse = 0;
    if (status == OmniRealtimeResponseStatus.completed &&
        !response.reply.rejected) {
      _consecutiveTimeouts = 0;
    }
    _chainTurnWork(() => _persistResponse(response, status), 'reply persist');
    _maybeContinueAfterTool(turn);
  }

  void _handleResponseTimeout(String? responseId) {
    _consecutiveTimeouts += 1;
    if (responseId != null) {
      _handleResponseFinished(responseId, OmniRealtimeResponseStatus.incomplete);
    } else {
      // 请求级悬空（response.create 被静默忽略，T01 §9.4）：按在途
      // 等待的归属轮收束。
      final turnId = _pendingResponseTurnId ?? _continuationTurnId;
      _pendingResponseTurnId = null;
      _continuationTurnId = null;
      final turn = turnId == null ? null : _turns[turnId];
      if (turn != null) {
        _chainTurnWork(() => _closeTurn(turn), 'turn close');
      }
    }
    if (_consecutiveTimeouts >= _consecutiveTimeoutReconnectThreshold) {
      _diagnosticsSink('omni call model silent, reconnecting');
      _fireAndForget(_session?.close() ?? Future.value(), 'session close');
    }
  }

  /// 轮次收束：补齐用户轮落盘、提交隐藏动作（共享执行器）、对话自述
  /// 称呼、晚安节奏与热层刷新。回复内容的落盘在每条回复终态时已发生
  /// （[_persistResponse]）。
  ///
  /// 动作提交语义（与聊天链路的有意分歧，裁定 2026-10-03）：聊天链路
  /// 的动作从回复文本解析，随回复级验收 gate 整体取舍；实时链路的
  /// 动作是独立原生工具调用——按条经行为核心校验即构成完整提案
  /// （spec:56「完整动作仍按现有成功条件、幂等规则执行」），与可见
  /// 回复的终态（取消/不完整/候选被拒）解耦提交。这样裁定还受 spec:56
  /// 「显式用户控制不因音频模式被丢弃」约束：打断瞬间的 memory_ban
  /// 等控制动作不得因回复被打断而丢失。格式不合法的半套提案仍在
  /// 校验层整体丢弃，不进入本列表。
  Future<void> _closeTurn(_CallTurn turn) async {
    _pendingResponseTurnId = null;
    _continuationTurnId = null;
    final userText = (turn.typedText ?? turn.transcript).trim();
    var raw = await _openRawSession();
    if (!turn.userPersisted && userText.isNotEmpty) {
      if (_sessionSlotAvailable(raw)) {
        raw = await _appendTurn(
          raw,
          RawSessionTurn.user(
            requestId: turn.requestId,
            text: turn.typedText ?? turn.transcript,
            at: _clock(),
          ),
        );
      }
      turn.userPersisted = true;
    }
    final actions = await _commitTurnMemory(raw, turn, userText);
    // 记忆控制（禁提/冻结/删除/解除）命中本通话已说内容时触发受控
    // 重建连接，不让云端残留绕过本机过滤（spec:56；memory_forget 是
    // 当轮控制，不动上下文）。
    final controls = actions
        .whereType<MemoryControlAction>()
        .where((action) => action is! MemoryForgetAction)
        .toList();
    final rebuild = controls.isNotEmpty && _controlTouchesInCall(controls);
    if (rebuild) {
      _diagnosticsSink('omni call rebuilding connection after control');
      _fireAndForget(_session?.close() ?? Future.value(), 'session close');
      return;
    }
    // 每轮收束后刷新热层（spec:52「实时会话不能永久使用建连时的过期
    // 热记忆」/ T03:12）：记录动作写入的 episode、画像、开环状态与
    // 对话自述称呼都随下一轮 instructions 生效；session.update 整体
    // 替换、下一条回复生效为 T01 §11 实测形态。
    await _refreshInstructions();
  }

  /// 轮次记忆提交（正常收束与放弃收束共用，幂等）：隐藏动作沿用既有
  /// 执行器（轮内整理 + 记忆控制即时生效；动作已按条校验构成完整
  /// 提案，提交语义见 [_closeTurn] 文档）、对话自述称呼当轮生效、
  /// 晚安信号触发日终归档与 Dream 资格。返回已提交动作供上下文刷新
  /// 判定。
  Future<List<HiddenAction>> _commitTurnMemory(
    RawSession raw,
    _CallTurn turn,
    String userText,
  ) async {
    if (turn.memoryCommitted) {
      return const [];
    }
    turn.memoryCommitted = true;
    final actions = List<HiddenAction>.of(turn.actions);
    turn.actions.clear();
    if (actions.isNotEmpty) {
      await actionExecutor.applyActions(raw, turn.requestId, actions);
    }
    if (userText.isNotEmpty) {
      // 对话自述称呼当轮生效（与聊天同一写路径，不依赖动作）。
      await actionExecutor.applyAppellation(userText, turn.requestId);
    }
    if (!turn.bedtimeApplied &&
        userText.isNotEmpty &&
        bedtimeSignalPattern.hasMatch(userText)) {
      turn.bedtimeApplied = true;
      // 晚安信号照旧触发日终归档与 Dream 资格（交付完成后时序不变）。
      memory.memoryCadence.onDeliveryComplete(bedtime: true);
    }
    return actions;
  }

  /// 单条回复终态落盘（T03:15）：完成轮落校验后的最终消息；取消/失败/
  /// 不完整/超时轮落已显示前缀并如实按未完成交付；隐藏块协议残留由
  /// 增量清洗器剥离。回复 transcript 整体缺失但音频已播出时用标识
  /// 占位，不编原话（spec:58）。
  Future<void> _persistResponse(
    _CallResponse response,
    OmniRealtimeResponseStatus status,
  ) async {
    if (response.persisted) {
      return;
    }
    response.persisted = true;
    final turn = response.turn;
    final completed =
        status == OmniRealtimeResponseStatus.completed &&
        !response.reply.rejected;
    var persistMessages = response.reply.finalizeMessages();
    if (!completed) {
      // 候选被拒或未完成：可见前缀如实落盘，不冒充完整回复
      // （spec:20 / spec:106）。
      persistMessages = response.reply.visibleMessages;
    }
    if (persistMessages.isEmpty) {
      if (response.audioSeen) {
        persistMessages = [omniMissingReplyTranscriptMarker];
      } else {
        // 静默轮（如被抢占的工具轮）：没有可落盘的回复。
        return;
      }
    }
    var raw = await _openRawSession();
    if (!turn.userPersisted) {
      final userText = (turn.typedText ?? turn.transcript).trim();
      if (_sessionSlotAvailable(raw)) {
        if (userText.isNotEmpty) {
          raw = await _appendTurn(
            raw,
            RawSessionTurn.user(
              requestId: turn.requestId,
              text: turn.typedText ?? turn.transcript,
              at: _clock(),
            ),
          );
        } else if (turn.typedText == null && turn.speechStopped) {
          raw = await _appendTurn(
            raw,
            RawSessionTurn.user(
              requestId: turn.requestId,
              text: omniMissingTranscriptMarker,
              at: _clock(),
            ),
          );
        }
      }
      turn.userPersisted = true;
    }
    await _appendTurn(
      raw,
      RawSessionTurn.qiyu(
        requestId: turn.requestId,
        messages: persistMessages,
        at: _clock(),
        source: ReplySource.llm,
        mode: 'omni-realtime',
      ),
    );
    _front?.call({
      'type': 'replyDone',
      'turnId': turn.turnId,
      'status': status.name,
      'incomplete': !completed,
    });
  }

  // -------------------------------------------------------------------------
  // Markdown 会话（复用既有仓储：单段上限、跨日切段，不另开库）
  // -------------------------------------------------------------------------

  /// 开段记忆化：回复落盘、轮次收束与上下文回放可能同刻都要开段，
  /// 并发的开段（递归建目录/列目录/建段写盘）在 Windows 上有原生层
  /// 争用窗口，这里收敛为单次在途调用共享同一结果；追加写经
  /// [_appendTurn] 串行链，绝不并发。开段完成后直接返回最新快照
  /// （[_rawSession] 随每次追加保持更新，回放读到最新落盘轮）。
  Future<RawSession>? _rawSessionFuture;
  Future<void> _writeChain = Future.value();

  Future<RawSession> _openRawSession() {
    final current = _rawSession;
    if (current != null) {
      return Future.value(current);
    }
    return _rawSessionFuture ??= repository.openSession(sessionId: _sessionId)
        .then((raw) {
      _rawSession = raw;
      _sessionId = raw.id;
      return raw;
    });
  }

  bool _sessionSlotAvailable(RawSession raw) =>
      raw.turns.length <= maxRawSessionTurns - 2 &&
      raw.date == localSessionDate(_clock());

  /// 追加写串行链：轮内多步写（用户轮 → 回复轮 → 新段切换）彼此
  /// 排队，绝不与开段并发。
  Future<RawSession> _appendTurn(RawSession raw, RawSessionTurn turn) {
    final result = _writeChain.then((_) async {
      var current = raw;
      if (!_sessionSlotAvailable(current)) {
        current = await repository.createSession();
        _rawSession = current;
        _sessionId = current.id;
      }
      final updated = await repository.appendTurn(current, turn);
      _rawSession = updated;
      return updated;
    });
    _writeChain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 连接断开或通话结束时收束在途工作：在途回复不会再回来（云端上下
  /// 文随连接消亡），可见前缀按打断语义落盘；已建轮但尚无任何回复的
  /// 用户输入（判停建轮后、回复到达前即挂断/断线）补落盘用户转录，
  /// 转录缺失用标识占位——文字记录可靠且可恢复（T03:15），与聊天
  /// 「取消仍保留用户轮」语义对齐。旧事件不能复活（T02:15）。
  Future<void> _abandonOpenResponses() async {
    _pendingResponseTurnId = null;
    _continuationTurnId = null;
    for (final turn in _turns.values) {
      turn.openResponses = 0;
      turn.openToolBackfills = 0;
    }
    final responses = List<_CallResponse>.of(_responses.values);
    _responses.clear();
    for (final response in responses) {
      if (response.persisted) {
        continue;
      }
      try {
        await _persistResponse(response, OmniRealtimeResponseStatus.cancelled);
      } on Object catch (error) {
        _diagnosticsSink('omni call abandon response deferred [$error]');
      }
    }
    for (final turn in _turns.values) {
      try {
        var raw = await _openRawSession();
        final userText = (turn.typedText ?? turn.transcript).trim();
        if (!turn.userPersisted && _sessionSlotAvailable(raw)) {
          raw = await _appendTurn(
            raw,
            RawSessionTurn.user(
              requestId: turn.requestId,
              text: userText.isNotEmpty
                  ? (turn.typedText ?? turn.transcript)
                  : omniMissingTranscriptMarker,
              at: _clock(),
            ),
          );
          turn.userPersisted = true;
        }
        // 已校验的完整动作提案与称呼/晚安随放弃收束一并提交（spec:56
        // 显式用户控制不因音频模式被丢弃）；重建/刷新无意义，跳过。
        await _commitTurnMemory(raw, turn, userText);
      } on Object catch (error) {
        _diagnosticsSink('omni call abandon turn deferred [$error]');
      }
    }
  }

  /// 控制动作是否命中本通话已落盘的内容（命中＝云端上下文残留受控
  /// 内容，需要重建连接做硬清理；T01 §11 实测跨连接无上下文）。
  bool _controlTouchesInCall(List<MemoryControlAction> controls) {
    final raw = _rawSession;
    if (raw == null) {
      return false;
    }
    final titles = controls
        .map((action) => normalizeMemoryText(action.title))
        .where((title) => title.isNotEmpty)
        .toSet();
    if (titles.isEmpty) {
      return false;
    }
    return raw.turns.any((turn) => bannedMemoryText(turn.text, titles));
  }

  /// 当前活动会话已下发的 instructions（建连与每次刷新后记录）：热层
  /// 未变化时跳过重复的 session.update。
  String? _activeInstructions;

  /// 热层刷新（session.update 整体替换，T01 §11 实测下一条回复生效）：
  /// 重读热层三块，内容有变化才整体重发 instructions。
  Future<void> _refreshInstructions() async {
    final session = _session;
    if (session == null || _ended) {
      return;
    }
    final config = await _sessionConfig();
    if (config.instructions == _activeInstructions) {
      return;
    }
    _activeInstructions = config.instructions;
    session.updateSession(config);
  }

  void _sendState() {
    final front = _front;
    if (front == null) {
      return;
    }
    front.call({
      'type': 'state',
      'phase': _phase.name,
      'reason': ?_phaseReason,
    });
  }
}
