import 'dart:async';
import 'dart:convert';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'developer_diagnostics.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_actions.dart';
import 'memory_alias.dart';
import 'memory_ban.dart';
import 'memory_cadence.dart';
import 'memory_controls.dart';
import 'memory_recall.dart';
import 'memory_text_primitives.dart';
import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'provider_settings_service.dart';
import 'relationship_lifecycle.dart';
import 'state_pack_reader.dart';
import 'tts_gateway.dart';
import 'voice_stream_pipeline.dart';

final class LocalChatException implements Exception {
  const LocalChatException({
    required this.code,
    required this.message,
    required this.retryable,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

final class LocalChatSnapshot {
  const LocalChatSnapshot(this.session);

  final RawSession session;

  Map<String, Object?> toJson() => {
    'sessionId': session.id,
    'turns': session.turns.map(_turnToPublicJson).toList(),
    'limits': {
      'maxTurnsPerSegment': maxRawSessionTurns,
      'activeHistoryDays': activeSessionHistoryWindow.inDays,
    },
  };
}

typedef DeliveryPause = Future<void> Function(Duration duration);

/// 召回窗口预算的等待注入点：与流式分段停顿（[DeliveryPause]）语义
/// 不同，单独注入，测试可分别控制。
typedef RecallWindowWait = Future<void> Function(Duration window);

/// 候选回复缓冲上限（runes）。可见回复在行为核心侧另有 2000 runes 限制，
/// 这里只为防止失控的 Provider 流在超时前耗尽内存。
const _maxModelReplyRunes = 8192;

/// 交付节奏的唯一真源：分片大小（runes）与相邻两片之间的停顿。流式活
/// 前缀与本地兜底/召回 bubble 的分片共用这份常量——改一边不会漏另一边。
const _deliveryChunkRunes = 12;
const _deliveryChunkPause = Duration(milliseconds: 70);

/// 晚安信号词：可见回复交付后据此触发日终归档与 Dream 资格预登记。
/// 词根定稿见笔记《栖语记忆/Memory.md》「晚安怎么认」：宁可认宽
/// （提前归档可由增量整理补回），不可认漏（一晚对话整理丢失）。
/// 光秃秃的「睡觉」不认——「没睡觉」「不想睡觉」是抱怨，不是道别；
/// 但带趋向的说法（「睡觉了」「想睡」「去睡」）即便带着否定也会认，
/// 认宽的代价只是提前归档一次。
final _bedtimeSignalPattern = RegExp(r'晚安|睡了|先睡|睡觉了|想睡|去睡|困了|该睡了');

/// 语音管线推进信号（票二）：与模型增量、取消一起进 [Future.any]，
/// 同一个字符串哨兵区分「哪一路先到」——语音块先到就继续搭车，模型
/// 增量先到就照常处理文字。
const _voiceProgress = 'voice-progress';

final class LocalChatService {
  LocalChatService(
    this._repository, {
    QiyuBehaviorCore? behaviorCore,
    this.providerPort,
    this.modelPromptBuilder = const ModelPromptBuilder(''),
    this.episodePipeline,
    this.openLoopStore,
    this.statePackReader,
    this.memoryRecall,
    this.personaTree,
    this.memoryControls,
    this.relationshipLifecycle,
    this.memoryActions,
    this.memoryCadence,
    this.requestDiagnostics,
    this.aliasClient,
    this.voiceStreamSynthesizer,
    DeliveryPause? deliveryPause,
    RecallWindowWait? recallWindowWait,
    Clock? clock,
    void Function(String message)? diagnosticsSink,
  }) : _behaviorCore = behaviorCore ?? const QiyuBehaviorCore(),
       _deliveryPause = deliveryPause ?? Future<void>.delayed,
       _recallWindowWait = recallWindowWait ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now,
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final MemoryRepository _repository;
  final QiyuBehaviorCore _behaviorCore;

  final ProviderChatPort? providerPort;
  final ModelPromptBuilder modelPromptBuilder;
  final EpisodeMemoryPipeline? episodePipeline;
  final OpenLoopStore? openLoopStore;
  final StatePackReader? statePackReader;

  /// 用户记忆控制记录（ticket 18）：冻结/禁提/删除的落盘与读取。
  /// 必须与 OpenLoopStore 使用同一实例，避免两条写入链互相覆盖。
  final MemoryControlsStore? memoryControls;

  /// relationship.md 生命周期：删除时需要立即清掉命中的关系证据行。
  /// 与日终归档共享同一实例。
  final RelationshipLifecycle? relationshipLifecycle;

  /// 记忆动作执行端：禁提执行器和删除管线与记忆中心 UI 共用，
  /// 保持控制范围、清理结果一致。
  final MemoryActionService? memoryActions;

  /// 控制时关联扩展的 Provider 客户端（裁定票 03）：聊天禁提与冻结
  /// 两个分支直接用它做有界别名调用（都在维护准入之外），删除走
  /// memoryActions 的删除管线（其客户端随 memoryActions 注入）。未配置
  /// 或调用失败都静默退回无别名，控制本身照常生效。
  final ProviderChatClient? aliasClient;

  /// 分句流式语音合成的服务层接缝（票二）：文字流式推进中每出一个
  /// 完整句，Host 经它请求该句合成，音频块搭车聊天事件流推出。未注入
  /// （或档位拿不到音频块、自动朗读关着）时本轮就是纯文字流式，语音
  /// 继续走 done 时的整段朗读路径。
  final VoiceStreamSynthesizer? voiceStreamSynthesizer;

  late final MemoryBanExecution? _banExecution =
      memoryActions?.banExecution ??
      (openLoopStore == null
          ? null
          : MemoryBanExecution(
              openLoopStore: openLoopStore!,
              personaTree: personaTree,
            ));

  /// 记忆节奏（ticket 22 / ADR 0002）：交付后时间节奏链独立模块。
  /// 聊天服务只在每轮交付完成（轮内召回循环之后）调
  /// [MemoryCadence.onDeliveryComplete] 一个钩子，危险操作独占前经
  /// [MemoryCadence.finalizePending] 等它的后台任务链排空；日终归档、
  /// 月压缩、Dream、启动补扫与空闲补办全部在模块内部串行。
  final MemoryCadence? memoryCadence;

  /// 召回模型查找轮内循环。只在配置了 Provider 时有意义：查找由
  /// 模型隐藏动作触发，命中快时当轮补 bubble 2，没赶上时压缩结果
  /// 注入下一轮模型上下文。
  final RecallOrchestrator? memoryRecall;

  /// PersonaTree 叶与中间理解（ticket 14）。必须与日终归档使用
  /// 同一实例：树文件的串行锁在实例内部，两个实例会互相覆盖。
  final PersonaTreeStore? personaTree;

  /// 开发者诊断最近请求记录器（ticket 23）：只记来源、结果与脱敏
  /// 细节，绝不记用户文本；null 时不记录。
  final RequestDiagnosticsRecorder? requestDiagnostics;
  final DeliveryPause _deliveryPause;
  final RecallWindowWait _recallWindowWait;
  final Clock _clock;
  final void Function(String message) _diagnosticsSink;
  final Map<String, _DeliveryCancellation> _activeDeliveries = {};

  /// 在途分句语音合成（票二）：停止信号端点按 requestId 定位并作废，
  /// 交付结束（正常/取消/失败）时同一出口清理，绝不留下继续烧 Provider
  /// 配额的在途请求。与 [_activeDeliveries] 分开——取消针对轮交付，
  /// 停止针对语音。
  final Map<String, VoiceStreamPipeline> _activeVoiceStreams = {};
  Future<void> _pending = Future.value();
  Future<void> _recallTask = Future.value();

  /// 是否有在途聊天交付：记忆节奏的空闲补办轮询据此让路（聊天永远
  /// 优先）。只暴露占用与否，不暴露任何会话内容。
  bool get hasActiveDeliveries => _activeDeliveries.isNotEmpty;

  Future<void> initialize() async {
    await _repository.initialize();
  }

  /// 等待已调度的后台召回检索完成。检索失败只记诊断，供测试断言使用。
  Future<void> settlePendingRecalls() => _recallTask;

  /// 维护独占边界（spec「维护隔离及恢复」）：导入、回滚、清除、一致
  /// 性导出共用这唯一入口。先抑制记忆节奏的新后台排程，再等已在途的
  /// 全部工作（在途交付、轮内召回与保存延续、补归档、月压缩、Dream、
  /// 召回保存），然后独占交付串行槽运行 [operation]：期间新交付与
  /// 并发维护请求一律排在 operation 之后，空闲补办 tick 跳过当次，
  /// 不会与之并发。「清除产品数据」「备份导入」这类整机改写操作必须
  /// 经此执行——操作前落盘的写入都能被其快照覆盖，操作后也不会被
  /// 在途写入把已恢复的数据复活。
  ///
  /// 成功或失败都在 finally 里恢复常规调度：维护抛异常不卡死后续
  /// 调度，未完成整理由下一次空闲补办继续。等待的只有已在途工作，
  /// 维护入口自身不在任何被等待的任务链上，不会形成自身等待死锁。
  Future<T> runExclusively<T>(Future<T> Function() operation) {
    Future<T> drainAndRun() async {
      memoryCadence?.pauseBackgroundScheduling();
      try {
        await memoryCadence?.finalizePending();
        await _recallTask;
        return await operation();
      } finally {
        memoryCadence?.resumeBackgroundScheduling();
      }
    }

    final commits = episodePipeline?.commits;
    if (commits == null) {
      return _serialized(drainAndRun);
    }
    // 同步关闭新 UI 操作准入并保留聊天队列中的维护位置：等待在途
    // UI 时，新聊天也不能插队。排空和维护都不持有短提交锁。
    final admitted = Completer<void>();
    late final Future<T> queued;
    final maintenance = commits.maintenance(() {
      admitted.complete();
      return queued;
    });
    queued = _serialized(() async {
      await admitted.future;
      return commits.existingOperation(drainAndRun);
    });
    return maintenance;
  }

  Future<LocalChatSnapshot> restore({String? sessionId}) => _serialized(
    () async =>
        LocalChatSnapshot(await _repository.openSession(sessionId: sessionId)),
  );

  Future<HistoryListing> history() =>
      _serialized(() => _repository.readHistory());

  Future<void> deleteSession(String sessionId) =>
      _serialized(() => _repository.deleteSession(sessionId));

  Stream<ChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) {
    final trimmedRequestId = requestId.trim();
    final cancellation = _DeliveryCancellation();
    final controller = StreamController<ChatDeliveryEvent>(
      onCancel: cancellation.cancel,
    );
    _serialized(() async {
      if (trimmedRequestId.isNotEmpty) {
        _activeDeliveries[trimmedRequestId] = cancellation;
      }
      // 诊断记录（ticket 23）：只取交付事件的来源与回退元数据。
      ChatDeliveryEvent? stateEvent;
      var cancelled = false;
      String? failureDetail;
      try {
        await controller.addStream(
          _deliver(
            requestId: requestId,
            text: text,
            sessionId: sessionId,
            cancellation: cancellation,
          ).map((event) {
            if (event.kind == ChatDeliveryEventKind.state) {
              stateEvent ??= event;
            } else if (event.kind == ChatDeliveryEventKind.cancelled) {
              cancelled = true;
            }
            return event;
          }),
        );
      } on Object catch (error) {
        final chatError = error is LocalChatException ? error : null;
        failureDetail = chatError?.code ?? 'internal_error';
        controller.add(
          ChatDeliveryEvent.error(
            requestId: trimmedRequestId,
            text: chatError?.message ?? '本地服务暂时不可用。',
            code: chatError?.code ?? 'internal_error',
            retryable: chatError?.retryable ?? true,
          ),
        );
      } finally {
        _recordChatRequest(stateEvent, cancelled, failureDetail);
        if (identical(_activeDeliveries[trimmedRequestId], cancellation)) {
          _activeDeliveries.remove(trimmedRequestId);
        }
        await controller.close();
      }
    });
    return controller.stream;
  }

  /// 一次聊天请求交付结束后记一条诊断：有可见结果按结果记，其次
  /// 取消，最后失败；细节只保留错误码级。
  void _recordChatRequest(
    ChatDeliveryEvent? stateEvent,
    bool cancelled,
    String? failureDetail,
  ) {
    final recorder = requestDiagnostics;
    if (recorder == null) {
      return;
    }
    if (stateEvent case final state?) {
      recorder.record(
        source: RecentRequestSources.chat,
        result: state.fallbackReason == null
            ? RecentRequestResults.ok
            : RecentRequestResults.fallback,
        replySource: state.source?.name,
        fallbackReason: state.fallbackReason?.wireName,
      );
    } else if (cancelled) {
      recorder.record(
        source: RecentRequestSources.chat,
        result: RecentRequestResults.cancelled,
      );
    } else {
      recorder.record(
        source: RecentRequestSources.chat,
        result: RecentRequestResults.failed,
        detail: failureDetail ?? 'no_outcome',
      );
    }
  }

  bool cancel(String requestId) {
    final cancellation = _activeDeliveries[requestId.trim()];
    if (cancellation == null) {
      return false;
    }
    cancellation.cancel();
    return true;
  }

  /// 停止信号（票二）：前端停播时通知 Host 作废该轮在途的分句合成，
  /// 不白烧 Provider 配额。与 [cancel] 分开——停止针对语音，不撤回
  /// 已交付的文字。返回是否有在途合成被作废。
  bool stopVoice(String requestId) {
    final pipeline = _activeVoiceStreams[requestId.trim()];
    if (pipeline == null) {
      return false;
    }
    pipeline.cancel();
    return true;
  }

  /// 为本轮建分句语音合成管线：未注入接缝、档位拿不到音频块（自定义
  /// 档 JSON 字段形态）、自动朗读关着或未配置时返回 null——本轮就是
  /// 纯文字流式，done 时的整段朗读路径不受影响。查询本身失败只记
  /// 诊断，同样按「不流式」处理（文字链路永远优先）。
  Future<VoiceStreamPipeline?> _createVoicePipeline(
    RawSession session,
    String requestId,
  ) async {
    final synthesizer = voiceStreamSynthesizer;
    if (synthesizer == null) {
      return null;
    }
    final bool canStream;
    try {
      canStream = await synthesizer.canStream();
    } on Object catch (error) {
      _diagnosticsSink(
        'voice stream probe failed [${error.runtimeType}] request=$requestId',
      );
      return null;
    }
    if (!canStream) {
      return null;
    }
    // 交付段序号与朗读定位同口径：该 requestId 已落盘的栖语 turn 数
    // （重放路径不进这里，活前缀轮恒从 0 起算，防御性取现值）。
    final deliveryIndex = session.turns
        .where(
          (turn) =>
              turn.requestId == requestId && turn.speaker == Speaker.qiyu,
        )
        .length;
    final pipeline = VoiceStreamPipeline(
      synthesizer: synthesizer,
      requestId: requestId,
      sessionId: session.id,
      deliveryIndex: deliveryIndex,
      diagnosticsSink: _diagnosticsSink,
    );
    _activeVoiceStreams[requestId] = pipeline;
    return pipeline;
  }

  Stream<ChatDeliveryEvent> _deliver({
    required String requestId,
    required String text,
    required String? sessionId,
    required _DeliveryCancellation cancellation,
  }) async* {
    final trimmedRequestId = requestId.trim();
    final trimmedText = sanitizeUserInput(text);
    final bedtime = _bedtimeSignalPattern.hasMatch(trimmedText);
    final archivedText = redactSessionText(text);
    if (trimmedRequestId.isEmpty || trimmedText.isEmpty) {
      throw const LocalChatException(
        code: 'invalid_request',
        message: '消息不能为空。',
        retryable: false,
      );
    }

    var session = await _repository.openSession(sessionId: sessionId);
    final existingUser = _findTurn(
      session.turns,
      requestId: trimmedRequestId,
      speaker: Speaker.user,
    );
    final existingReply = _findTurn(
      session.turns,
      requestId: trimmedRequestId,
      speaker: Speaker.qiyu,
    );
    if (existingUser != null &&
        redactSessionText(existingUser.text) != archivedText) {
      throw const LocalChatException(
        code: 'request_id_conflict',
        message: '这条消息标识已被另一条内容使用，请重新发送。',
        retryable: false,
      );
    }
    if (existingReply != null) {
      yield _acceptedEvent(trimmedRequestId, session.id);
      yield* _deliverOutcome(
        session,
        _storedResult(session, existingReply),
        cancellation,
      );
      return;
    }

    if (existingUser == null) {
      if (session.turns.length > maxRawSessionTurns - 2 ||
          session.date != localSessionDate(_clock())) {
        session = await _repository.createSession();
      }
      session = await _repository.appendTurn(
        session,
        RawSessionTurn.user(
          requestId: trimmedRequestId,
          text: text,
          at: _clock(),
        ),
      );
    }

    yield _acceptedEvent(trimmedRequestId, session.id);
    if (cancellation.isCancelled) {
      yield _cancelledEvent(trimmedRequestId, session.id);
      return;
    }

    final state = _stateFromCompletedTurns(session.turns, trimmedRequestId);
    List<HiddenAction> hiddenActions = const [];
    final localOutcome = _behaviorCore.reply(
      ChatRequest(requestId: trimmedRequestId, text: trimmedText),
      state,
    );
    // ChatOutcome sealed 仅两子类，穷尽 switch 免去冗余强转：安全拒绝
    // 与错误结果在此转为本地异常，可见回复直接拿到 ChatResult。
    var outcome = switch (localOutcome) {
      final ChatResult result => result,
      final ErrorResult error => throw LocalChatException(
        code: error.code.wireName,
        message: error.message,
        retryable: error.retryable,
      ),
    };
    // 协议失败留下的半句标记：只活在这一轮的 message 事件上，不新增
    // 事件种类，也不改写落盘格式（ADR 0017）。
    var incomplete = false;
    // 模型流真吐出过 delta 时才由流式路径负责交付序列；本地兜底轮
    // （含无可用 Provider 的常规轮）仍走 _deliverOutcome 的分片节奏。
    var streamedDeltas = false;
    yield ChatDeliveryEvent.waiting(
      requestId: trimmedRequestId,
      sessionId: session.id,
    );
    // 当前消息的时刻用本轮用户 turn 落盘的存储时刻：新消息即发送时的
    // 墙钟，重试/恢复复用原 turn，前缀不跳变。
    final pendingUserMoment = _findTurn(
      session.turns,
      requestId: trimmedRequestId,
      speaker: Speaker.user,
    )?.at;
    final providerPort = this.providerPort;
    // 危机等敏感输入不再拦截外呼（ADR 0010）：配置了 Provider 就照常
    // 参与模型对话；分类结果只在模型不可用、失败或输出不合格时挑本地
    // 兜底话术（危机→热线兜底），由行为核心统一裁定。
    if (providerPort != null) {
      ModelPromptBuilder? requestBuilder;
      final streamed = _StreamedReply();
      // 分句语音合成管线（票二）：Provider 分支进来时就绪，与文字流式
      // 共用同一个活前缀；拿不到音频块的档位这里是 null。
      final voicePipeline = await _createVoicePipeline(session, trimmedRequestId);
      try {
        requestBuilder = await _promptBuilderForRequest(session.id);
        final prepared = await providerPort.prepareChatRequest();
        if (prepared != null) {
          // 流内异常（含已吐出若干 delta 后才炸）由 _streamModelReply
          // 自行收尾成半句/本地兜底，绝不在这里重置交付状态——否则
          // 半句与兜底话术会叠加显示。
          yield* _streamModelReply(
            requestBuilder.build(
              state,
              trimmedText,
              hardRulesAddendum: prepared.hardRulesAddendum,
              at: pendingUserMoment,
            ),
            cancellation,
            prepared: prepared,
            requestId: trimmedRequestId,
            text: trimmedText,
            state: state,
            sessionId: session.id,
            // 敏感输入（危机/医疗/法律/金融）的回复沿用现状：不分片
            // 停顿，整段一次到位。
            pace: outcome.safety == null,
            precomputedLocalOutcome: outcome,
            reply: streamed,
            voicePipeline: voicePipeline,
          );
        }
      } on Object catch (error) {
        // 只有还没进流就炸的（提示词装配、能力快照）才在这里兜底：
        // 此时一个 delta 都没产出，本地兜底话术照旧分片上屏。
        _diagnosticsSink(
          'model dispatch error [$error] request=$trimmedRequestId',
        );
        streamed.result = _fallbackOutcome(
          state,
          trimmedRequestId,
          trimmedText,
          FallbackReason.modelProvider,
          null,
        );
      } finally {
        // 交付收尾（正常/取消/异常同一出口）：作废在途分句合成并注销
        // 登记——语音绝不比文字多活一刻。
        voicePipeline?.cancel();
        if (voicePipeline != null &&
            identical(_activeVoiceStreams[trimmedRequestId], voicePipeline)) {
          _activeVoiceStreams.remove(trimmedRequestId);
        }
      }
      // 模型没有真正收到本轮（本地兜底/取消）时，把已取用的短期
      // memory context 放回，留给下一轮注入；「晚一拍」允许再晚一拍。
      final consumedContext = requestBuilder?.memoryContext ?? '';
      final modelSucceeded = streamed.result?.source == ReplySource.llm;
      if (consumedContext.isNotEmpty &&
          (!modelSucceeded || cancellation.isCancelled)) {
        memoryRecall?.restorePendingContext(session.id, consumedContext);
      }
      if (streamed.cancelled || cancellation.isCancelled) {
        yield _cancelledEvent(trimmedRequestId, session.id);
        return;
      }
      // 没有可用 Provider（prepare 返回 null）时本轮就是普通本地兜底：
      // 沿用进入 Provider 分支前算好的本地结果，行为与今天一致。
      final streamedResult = streamed.result;
      if (streamedResult != null) {
        hiddenActions = streamed.hiddenActions;
        outcome = streamedResult;
        incomplete = streamed.incomplete;
        streamedDeltas = streamed.deltasDelivered;
      }
    }

    final completion = _OutcomeCompletion();
    ChatDeliveryEvent? lastEvent;
    await for (final event in _deliverOutcome(
      session,
      outcome,
      cancellation,
      persist: true,
      completion: completion,
      deltasDelivered: streamedDeltas,
      incomplete: incomplete,
    )) {
      lastEvent = event;
      yield event;
    }
    if (lastEvent != null && lastEvent.kind == ChatDeliveryEventKind.done) {
      final completedSession = completion.session!;
      // 只有完整且最终被接受的模型回复才提交其隐藏动作：候选被行为
      // 核心拒绝（回退本地回复）时整体丢弃——不改控制记录、不写派生
      // 记忆、不触发轮内召回；协议失败留下的半句同样没有可提交的
      // 动作（文本如实落盘，动作不落地）；失败与取消的轮次根本没有
      // 可提交的动作。
      if (outcome.source == ReplySource.llm && !incomplete) {
        await _applyHiddenActions(
          completedSession,
          trimmedRequestId,
          hiddenActions,
        );
      }
      // 对话自述称呼（用户说「以后叫我老王」）当轮生效：与用户明确
      // 纠正同一精神，用户当前明确说的话最高；本地降级轮同样生效。
      // 必须赶在轮内召回之前写入——召回的组织调用按 persona.md 的
      // 称呼装配。
      await _applyAppellationSelfReport(trimmedText, trimmedRequestId);
      if (outcome.source == ReplySource.llm && !incomplete) {
        // 轮内召回循环：bubble 1 交付后才开始，绝不阻塞首响。
        yield* _recallBubble(
          session: completedSession,
          state: state,
          userText: trimmedText,
          hiddenActions: hiddenActions,
          outcome: outcome,
          bedtime: bedtime,
          cancellation: cancellation,
        );
      }
      memoryCadence?.onDeliveryComplete(bedtime: bedtime);
    }
  }

  /// 召回模型查找轮内循环（查找流程定稿 2026-08-16）：bubble 1 交付
  /// 之后，模型隐藏块里有 memory_recall 请求时，Host 读取两级索引请
  /// 模型定位，在窗口预算内命中就把 bubble 2 用同一套交付事件补上
  /// （同套安全校验，落为同一 requestId 的栖语 turn）；没赶上、被
  /// 停止或未命中时，压缩结果并入下一用户轮注入（现状路径）。
  ///
  /// 定稿的放弃条件「用户已发新消息」由交付串行化天然保证：同一
  /// LocalChatService 的所有 deliver 经 [_serialized] 排队，窗口未结束
  /// 前下一轮无法开始，因此 bubble 2 永远不会交付到用户已经开启的
  /// 新一轮之后；UI 侧在窗口内把发送键换成停止键，「停止」则走
  /// [cancellation] 分支。
  ///
  /// 只有模型隐藏动作能触发查找（规则兜底已退役）；晚安信号与安全
  /// 回复不查找；未配置 Provider 不查找（保持现状）。
  Stream<ChatDeliveryEvent> _recallBubble({
    required RawSession session,
    required StateSnapshot state,
    required String userText,
    required List<HiddenAction> hiddenActions,
    required ChatResult outcome,
    required bool bedtime,
    required _DeliveryCancellation cancellation,
  }) async* {
    final recall = memoryRecall;
    if (recall == null ||
        providerPort == null ||
        outcome.safety != null ||
        bedtime) {
      return;
    }
    final requestId = outcome.requestId;
    if (requestId == null) {
      return;
    }
    final hasRecallRequest = hiddenActions.any(
      (action) =>
          action is MemoryRecallAction && action.query.trim().isNotEmpty,
    );
    if (!hasRecallRequest) {
      return;
    }

    // 召回子调用（选择/组织）把当前消息拼进提示发给 Provider：
    // 与主链装配同一份脱敏规则先行过滤，秘密绝不随查找请求外发。
    final task = recall.runTurnRecall(
      userText: redactSessionText(userText),
      recallActions: hiddenActions,
    );
    // 保存延续与窗口竞态共享同一个任务：结果被窗口内inline处理时置位
    // [inlineHandled]，保存只在窗口超时/被停止时执行（压缩结果并入
    // 下一用户轮注入）；整条延续挂到召回任务链上，settlePendingRecalls
    // 与 Host 收尾连保存动作本身也等待，避免「刚落盘就被读取」的竞态。
    final inlineHandled = Completer<bool>();
    final lateSave = task.then((late) async {
      if (await inlineHandled.future) {
        return;
      }
      for (final diagnostic in late.diagnostics) {
        _diagnosticsSink(diagnostic);
      }
      if (late.pendingContext != null) {
        recall.storePendingContext(session.id, late.pendingContext!);
      }
    });
    _recallTask = _recallTask
        .then((_) => lateSave)
        .then((_) {}, onError: (_) {});

    RecallTurnResult? result;
    try {
      result = await Future.any<RecallTurnResult?>([
        task,
        _recallWindowWait(recallBubbleWindow).then((_) => null),
        cancellation.whenCancelled.then((_) => null),
      ]);
    } on Object catch (error) {
      inlineHandled.complete(true);
      _diagnosticsSink('recall deferred [$error] request=$requestId');
      return;
    }

    if (result == null) {
      // 窗口超时或用户已停止：查找在后台继续，命中后的压缩结果由
      // lateSave 并入下一用户轮注入。
      inlineHandled.complete(false);
      return;
    }
    inlineHandled.complete(true);

    for (final diagnostic in result.diagnostics) {
      _diagnosticsSink(diagnostic);
    }
    final bubbleText = result.bubbleText;
    if (bubbleText == null || cancellation.isCancelled) {
      if (result.pendingContext != null) {
        recall.storePendingContext(session.id, result.pendingContext!);
      }
      return;
    }

    // bubble 2 走与 bubble 1 同一套安全校验：行为核心拒绝候选时
    // 什么都不交付；压缩结果仍可留给下一轮。
    final validated = _behaviorCore.reply(
      ChatRequest(requestId: requestId, text: userText),
      state,
      candidateReply: bubbleText,
    );
    if (validated is! ChatResult || validated.source != ReplySource.llm) {
      _diagnosticsSink(
        'recall bubble dropped reason=validation request=$requestId',
      );
      if (result.pendingContext != null) {
        recall.storePendingContext(session.id, result.pendingContext!);
      }
      return;
    }
    yield* _deliverOutcome(
      session,
      ChatResult(
        requestId: requestId,
        messages: validated.messages,
        nextState: validated.nextState,
        source: ReplySource.llm,
        mode: validated.mode,
      ),
      cancellation,
      persist: true,
    );
  }

  /// 可见回复落盘之后的增量记忆整理：写失败只记诊断，不影响本轮回复。
  /// 用户记忆控制（不记录/禁提/冻结/解除/删除）在回复后异步立即生效，
  /// 不等日终（记忆控制定稿）。只在模型回复最终被接受后调用：整理
  /// 窗口由本轮消费。
  Future<void> _applyHiddenActions(
    RawSession completedSession,
    String requestId,
    List<HiddenAction> hiddenActions,
  ) async {
    // 不要记（当轮控制，不产生持久记录）：命中目标的记忆信号、
    // 未完事项候选与关系证据一律不落 episode——内容不进提升、索引
    // 或 PersonaTree；控制动作自身保留为审计条目。
    final forgetTargets = hiddenActions
        .whereType<MemoryForgetAction>()
        .map((action) => normalizeMemoryText(action.title))
        .where((summary) => summary.isNotEmpty)
        .toSet();
    var effectiveActions = hiddenActions;
    if (forgetTargets.isNotEmpty) {
      effectiveActions = hiddenActions.where((action) {
        final summary = switch (action) {
          MemorySignalAction() => action.summary,
          OpenLoopCandidateAction() => action.title,
          RelationshipSignalAction() => action.summary,
          OpenLoopStatusAction() ||
          MemoryControlAction() ||
          MemoryRecallAction() ||
          NoAction() => null,
        };
        if (summary == null) {
          return true;
        }
        return !bannedMemoryText(summary, forgetTargets);
      }).toList();
    }

    final pipeline = episodePipeline;
    if (pipeline != null) {
      try {
        final result = await pipeline.processReply(
          session: completedSession,
          requestId: requestId,
          hiddenActions: effectiveActions,
        );
        if (result.skippedCorruptDay) {
          _diagnosticsSink(
            'episode day unreadable, waiting for recovery request=$requestId',
          );
        }
        // 随手记只建叶指针（ticket 14）：中间理解归日终。建叶失败
        // 只记诊断，日终还会按当天 episode 补齐。
        final tree = personaTree;
        if (tree != null && result.addedEntries.isNotEmpty) {
          await tree.createLeaves(result.addedEntries);
          // 用户明确纠正是唯一在线撤根例外（ticket 17）：当轮身份自述
          // 与根下理解冲突时立即撤根并重投影 persona.md，不等日终。
          await tree.revokeCorrectedIdentityRoots(result.addedEntries);
        }
      } on Object catch (error) {
        _diagnosticsSink('episode update deferred [$error] request=$requestId');
      }
    }
    // 记忆控制与 Open-loop 状态变化：回复后异步立即生效，不等日终。
    final store = openLoopStore;
    for (final action in hiddenActions) {
      try {
        switch (action) {
          case OpenLoopStatusAction():
            await store?.applyStatusChange(
              title: action.title,
              status: action.status.wireName,
              result: action.result,
            );
          case MemoryBanAction():
            final execution = _banExecution;
            // 别名扩展在维护准入之外：模型调用不占 operation zone
            // （提交边界纪律），未配置或失败静默退回无别名，禁提本身
            // 照常生效。
            final aliases = await expandMemoryAliases(
              aliasClient,
              action.title,
            );
            // 此处已经占有聊天槽，维护正在排空聊天时必须继续完成，
            // 不能再等待新 UI 操作的准入。执行器只分步取得短写锁。
            final result = await execution?.controls.commits.existingOperation(
              () => execution.execute(
                action.title,
                origin: 'chat',
                aliases: aliases,
              ),
            );
            if (result == null || !result.controlWritten) {
              _diagnosticsSink(
                'memory ban deferred [controls not writable] '
                'request=$requestId',
              );
            } else {
              for (final step in result.deferred) {
                final reason = switch (step) {
                  MemoryBanCleanup.openLoops => 'open-loops',
                  MemoryBanCleanup.persona => 'persona',
                };
                _diagnosticsSink(
                  'memory ban deferred [$reason] request=$requestId',
                );
              }
            }
          case MemoryFreezeAction():
            final controls = memoryControls;
            // 关联扩展（裁定票 03）：未配置模型或调用失败都静默退回
            // 无别名，冻结本身照常生效。没有控制存储时不做无用调用。
            final aliases = controls == null
                ? const <String>[]
                : await expandMemoryAliases(aliasClient, action.title);
            final frozen =
                await controls?.freeze(action.title, aliases: aliases) ?? false;
            if (!frozen) {
              _diagnosticsSink(
                'memory freeze deferred [controls not writable] '
                'request=$requestId',
              );
            }
          case MemoryUnfreezeAction():
            final controls = memoryControls;
            final removed = await controls?.unfreeze(action.title);
            if (removed == null) {
              _diagnosticsSink(
                'memory unfreeze deferred [controls not writable] '
                'request=$requestId',
              );
            }
          case MemoryUnbanAction():
            // 口语解除禁提（裁定票 03）：与 memory_unfreeze 对称，写失败
            // 只记诊断，控制记录保持现状等待重试。
            final controls = memoryControls;
            final removed = await controls?.unban(action.title);
            if (removed == null) {
              _diagnosticsSink(
                'memory unban deferred [controls not writable] '
                'request=$requestId',
              );
            }
          case MemoryDeleteAction():
            await _applyDelete(action.title, requestId);
          case MemorySignalAction() ||
              OpenLoopCandidateAction() ||
              RelationshipSignalAction() ||
              MemoryForgetAction() ||
              MemoryRecallAction() ||
              NoAction():
            break;
        }
        // memory_forget 是当轮控制：内容过滤已在上面执行，
        // 审计条目随 episode 落盘，没有额外的持久动作。
      } on Object catch (error) {
        _diagnosticsSink('memory control deferred [$error] request=$requestId');
      }
    }
  }

  /// 对话自述称呼的在线写路径（称呼定稿 2026-09-03）：用户在聊天里
  /// 明确说「以后叫我老王」时当轮写入 persona.md 受保护设定行，复用
  /// 「用户明确纠正」在线例外的精神——用户当前明确说的话最高。只认
  /// 确定性句式，识别不出、格式不合法或写失败都只记诊断，绝不影响
  /// 本轮交付。
  Future<void> _applyAppellationSelfReport(
    String userText,
    String requestId,
  ) async {
    final tree = personaTree;
    if (tree == null) {
      return;
    }
    final candidate = extractAppellationSelfReport(userText);
    if (candidate == null) {
      return;
    }
    try {
      final written = await tree.episodePipeline.commits.existingOperation(
        () => tree.setAppellation(candidate),
      );
      if (written == null) {
        _diagnosticsSink(
          'appellation self-report rejected reason=format '
          'request=$requestId',
        );
      }
    } on Object catch (error) {
      _diagnosticsSink(
        'appellation self-report deferred [$error] request=$requestId',
      );
    }
  }

  /// 删除即时生效（ticket 18 / T24 定稿，ticket 20 起与记忆中心共用
  /// [MemoryActionService] 同一管线）：先定位目标，无任何可定位目标
  /// 时不写控制记录也不清除——绝不把宽泛范围变成永久封禁；定位到
  /// 目标后先写 deleted 抽象防复活范围，再清除全部派生内容
  /// （PersonaTree、episodes 与索引、长期印象、月摘要、关系证据、
  /// 近日状态、未闭环事项）。sessions 保留；重复执行安全。
  Future<void> _applyDelete(String summary, String requestId) async {
    final actions = memoryActions;
    if (actions == null || normalizeMemoryText(summary).isEmpty) {
      return;
    }
    final result = await actions.deleteByScope(
      summary,
      origin: 'chat',
      requestId: requestId,
    );
    if (result.status != MemoryActionStatus.success) {
      _diagnosticsSink(
        'memory delete deferred [${result.status.wireName}] '
        'request=$requestId',
      );
    }
  }

  /// 组装本轮 prompt builder：热层三块（【近况】、【长期印象】、
  /// 【用户画像】）的串行读取、既有记忆控制过滤与跨块预算协调全部
  /// 由 StatePackReader.readHotLayerBlocks 完成，这里只消费准备结果
  /// 并按部分成功语义装配（准备失败的块保持原值，已成功的部分不
  /// 撤销），读取失败只记诊断降级空块，绝不阻塞回复，也绝不新映射
  /// 成 Provider 错误。
  /// 同时消费该会话上一轮后台召回命中的短期 memory context（临时透镜，
  /// 只注入一次）。
  Future<ModelPromptBuilder> _promptBuilderForRequest(String sessionId) async {
    var builder = modelPromptBuilder;
    final reader = statePackReader;
    if (reader != null) {
      final prepared = await reader.readHotLayerBlocks();
      final failure = prepared.failure;
      if (failure != null) {
        _diagnosticsSink('state pack unavailable [$failure]');
      }
      builder = prepared.applyTo(builder);
    }
    final pendingContext = memoryRecall?.consumePendingContext(sessionId);
    if (pendingContext != null) {
      builder = builder.copyWithMemoryContext(pendingContext);
    }
    return builder;
  }

  /// 流式交付一轮模型回复（票一 文字流式输出）：Provider 增量到达后
  /// 经 [CandidateReplyStream] 做增量卫生处理，通过的前缀立即按既有
  /// 节奏（12 runes/70ms）以 delta 事件上屏；协议原生终止标记才收尾
  /// 落盘。取消沿用现状语义（只交付 cancelled 事件）；协议失败分叉——
  /// 还没有任何可见文字时走本地兜底，已有可见文字时把已显示部分作为
  /// 该轮最终回复交付并落盘（带「未完成」标记，不补全不伪装）。
  ///
  /// 语音（票二）：同一个活前缀每出一个完整句就进分句合成，PCM 音频
  /// 块经 [VoiceStreamPipeline] 按序搭车本事件流（voiceChunk），一句
  /// 失败即本段语音结束（voiceError，D1）；块全部吐完才终局，刷新/
  /// 重启的重放路径不进这里，幂等与今天一致。
  Stream<ChatDeliveryEvent> _streamModelReply(
    List<ModelMessage> messages,
    _DeliveryCancellation cancellation, {
    required PreparedProviderChatRequest prepared,
    required String requestId,
    required String text,
    required StateSnapshot state,
    required String sessionId,
    required bool pace,
    required ChatResult precomputedLocalOutcome,
    required _StreamedReply reply,
    VoiceStreamPipeline? voicePipeline,
  }) async* {
    // 一次 open：协议适配、终止判定、错误分类与取消下传全部在快照与
    // 网关内部完成；主链只对交付事件做增量卫生与分片节奏。
    final stream = await prepared.openStream(
      messages,
      whenCancelled: cancellation.whenCancelled,
    );
    if (stream == null) {
      // 拿不到可用流：本轮就是普通本地兜底。沿用调用方预计算的本地
      // 结果（危机输入→热线兜底、常规输入→极简回复），不另发明原因值。
      reply.result = precomputedLocalOutcome;
      return;
    }
    final iterator = StreamIterator<ModelStreamEvent>(stream);
    final raw = StringBuffer();
    final visible = CandidateReplyStream();
    final outbox = StringBuffer();
    var rawRunes = 0;
    var firstChunk = true;
    var terminated = false;
    var eof = false;
    var finalized = false;
    var voiceErrorSent = false;
    ModelFailureKind? failure;
    ServiceErrorCategory? serviceError;
    // 在途活前缀的分片上屏：取下一块就立刻吐，绝不让已到来的文字排在
    // 还没到来的模型增量后面。主循环保证 break 出来时 outbox 已排空，
    // 终局段（含结尾行补完的新增文本）复用它排空残余。
    Stream<ChatDeliveryEvent> drainOutbox() async* {
      while (outbox.isNotEmpty) {
        final chunk = _takeRunes(outbox, _deliveryChunkRunes);
        if (!firstChunk && pace) {
          await Future.any<void>([
            _deliveryPause(_deliveryChunkPause),
            cancellation.whenCancelled,
          ]);
        }
        firstChunk = false;
        if (cancellation.isCancelled) {
          reply.cancelled = true;
          return;
        }
        reply.deltasDelivered = true;
        yield ChatDeliveryEvent.delta(
          requestId: requestId,
          sessionId: sessionId,
          text: chunk,
        );
      }
    }

    try {
      while (true) {
        // 语音块优先搭车：文字还在生成，先到口的音频先出声（首音 =
        // 首句生成完 + 首个音频块）。块按序全播，与文字增量互不阻塞。
        while (voicePipeline != null) {
          final chunk = voicePipeline.takeChunk();
          if (chunk == null) {
            break;
          }
          yield ChatDeliveryEvent.voiceChunk(
            requestId: requestId,
            sessionId: sessionId,
            deliveryIndex: voicePipeline.deliveryIndex,
            chunkIndex: chunk.chunkIndex,
            sampleRate: chunk.sampleRate,
            mimeType: chunk.mimeType,
            data: base64Encode(chunk.bytes),
          );
        }
        if (voicePipeline != null &&
            voicePipeline.failed &&
            !voiceErrorSent) {
          // D1：已到的块都在上面吐完了才报失败——顺序上「先有声、后
          // 提示」，提示口径由界面按同会话首次一次落地。
          voiceErrorSent = true;
          yield ChatDeliveryEvent.voiceError(
            requestId: requestId,
            sessionId: sessionId,
            deliveryIndex: voicePipeline.deliveryIndex,
          );
        }
        if (outbox.isNotEmpty) {
          yield* drainOutbox();
          continue;
        }
        if (terminated || failure != null) {
          if (!finalized) {
            // 活前缀收尾只做一次：补完结尾行（新增可见文本照样走分片
            // 节奏）→ 尾句进分句层 → 关闭（之后只剩等音频）。
            finalized = true;
            final trailing = visible.completeTrailingLine();
            outbox.write(trailing);
            voicePipeline?.addText(trailing);
            voicePipeline?.close();
          }
          if (voicePipeline == null || voicePipeline.isFinished) {
            break;
          }
          // 模型流已终止、语音分句还在途：块继续搭车，等它收尾再终局
          // （done 之前用户能听到最后几句）。
          await voicePipeline.whenProgress();
          continue;
        }
        final moveNext = iterator.moveNext();
        final waits = <Future<Object?>>[
          moveNext,
          cancellation.whenCancelled.then<Object?>((_) => null),
        ];
        // 语音管线只在没收尾时挂推进等待：已收尾还挂会空转；没挂也不
        // 丢块——下一个模型事件或取消都会把循环带回到顶部的 flush。
        if (voicePipeline != null && !voicePipeline.isFinished) {
          waits.add(
            voicePipeline.whenProgress().then<Object?>((_) => _voiceProgress),
          );
        }
        final moved = await Future.any<Object?>(waits);
        if (moved == null || cancellation.isCancelled) {
          await iterator.cancel();
          voicePipeline?.cancel();
          reply.cancelled = true;
          return;
        }
        if (identical(moved, _voiceProgress)) {
          continue;
        }
        if (moved != true) {
          // 流干净关闭但没有任何协议终止标记：提前 EOF，按失败处理。
          eof = true;
          break;
        }
        final event = iterator.current;
        switch (event.kind) {
          case ModelStreamEventKind.delta:
            rawRunes += event.text!.runes.length;
            if (rawRunes > _maxModelReplyRunes) {
              await iterator.cancel();
              failure = ModelFailureKind.incompatibleResponse;
              break;
            }
            raw.write(event.text);
            // 同一个活前缀：文字分片与分句合成共用这一份通过卫生检查
            // 的增量，不二次解析最终文本。
            final safe = visible.add(event.text!);
            outbox.write(safe);
            voicePipeline?.addText(safe);
          case ModelStreamEventKind.done:
            terminated = true;
          case ModelStreamEventKind.failure:
            failure = event.failure!;
            serviceError = event.serviceError;
        }
      }
      // 终局后排空在途活前缀：节奏不变，用户看到的吐字不跳字。结尾
      // 行的补完与分句层关闭已在终止分支里做过（[finalized]），这里
      // 只剩把尾句文本分片吐完；语音块也已在 break 前全部交付。
      yield* drainOutbox();
    } on Object catch (error) {
      // 流内异常（读取出错、分片停顿被打破等）：与原生 error 同判——
      // 已有可见文字留半句，没有则本地兜底。绝不向上抛：上层 catch 会
      // 把本地兜底话术再分片吐一遍，与半句叠加。
      _diagnosticsSink('model stream error [$error] request=$requestId');
      failure ??= ModelFailureKind.provider;
    } finally {
      await iterator.cancel();
    }
    _settleStreamedReply(
      visible: visible,
      rawText: raw.toString(),
      requestId: requestId,
      text: text,
      state: state,
      failure: failure,
      eof: eof,
      serviceError: serviceError,
      reply: reply,
    );
  }

  /// 流式终局收尾：隐藏动作协议与可见文本严格分离后，按「有没有
  /// 可见文字」分叉——有就作为该轮最终回复（半句带未完成标记），
  /// 没有就走今天的本地兜底路径。
  void _settleStreamedReply({
    required CandidateReplyStream visible,
    required String rawText,
    required String requestId,
    required String text,
    required StateSnapshot state,
    required ModelFailureKind? failure,
    required bool eof,
    required ServiceErrorCategory? serviceError,
    required _StreamedReply reply,
  }) {
    // 隐藏动作只在 runtime 内部流转，绝不进入交付事件。
    final parsed = parseHiddenActions(rawText);
    for (final diagnostic in parsed.diagnostics) {
      _diagnosticsSink(
        'hidden-action dropped [$diagnostic] request=$requestId',
      );
    }
    final messages = visible.finalizeMessages();
    // 提前 EOF 与原生 error 同判失败：有可见文字留半句，没有则本地兜底。
    final effectiveFailure =
        failure ??
        (eof && !visible.rejected
            ? (messages.isEmpty
                  ? ModelFailureKind.contentParsing
                  : ModelFailureKind.network)
            : null);
    final complete = effectiveFailure == null && !visible.rejected;
    if (complete && messages.isNotEmpty) {
      reply.hiddenActions = parsed.actions;
      reply.result =
          _behaviorCore.reply(
                ChatRequest(requestId: requestId, text: text),
                state,
                candidateReply: messages.join('\n'),
              )
              as ChatResult;
      return;
    }
    final reason = effectiveFailure == null
        ? (visible.rejected
              ? FallbackReason.invalidModelResponse
              : FallbackReason.emptyModelReply)
        : _fallbackReasonFor(effectiveFailure);
    if (messages.isNotEmpty) {
      // 半句如实：失败原因只进本机诊断，页面不弹错、不追加兜底话术。
      _diagnosticsSink(
        'model stream incomplete [${reason.wireName}] request=$requestId',
      );
      reply.incomplete = true;
      // 半句同样带服务故障类别：state 事件有该字段，带上不破坏「不弹
      // 错误框、不追加兜底话术」的口径。
      reply.result = _withServiceError(
        _behaviorCore.reply(
          ChatRequest(requestId: requestId, text: text),
          state,
          candidateReply: messages.join('\n'),
        ) as ChatResult,
        serviceError,
      );
      return;
    }
    reply.result = _fallbackOutcome(
      state,
      requestId,
      text,
      reason,
      serviceError,
    );
  }

  ChatResult _fallbackOutcome(
    StateSnapshot state,
    String requestId,
    String text,
    FallbackReason reason,
    ServiceErrorCategory? serviceError,
  ) {
    return _withServiceError(
      _behaviorCore.reply(
        ChatRequest(requestId: requestId, text: text),
        state,
        modelFailure: reason,
      ) as ChatResult,
      serviceError,
    );
  }

  /// 给行为核心的结果补上服务故障类别（结果本体不变）：本地兜底与
  /// 流式半句两条降级路径共用。
  ChatResult _withServiceError(
    ChatResult outcome,
    ServiceErrorCategory? serviceError,
  ) {
    if (serviceError == null) {
      return outcome;
    }
    return ChatResult(
      requestId: outcome.requestId,
      messages: outcome.messages,
      nextState: outcome.nextState,
      source: outcome.source,
      mode: outcome.mode,
      fallbackReason: outcome.fallbackReason,
      safety: outcome.safety,
      serviceError: serviceError,
    );
  }

  Stream<ChatDeliveryEvent> _deliverOutcome(
    RawSession session,
    ChatResult result,
    _DeliveryCancellation cancellation, {
    bool persist = false,
    _OutcomeCompletion? completion,
    bool deltasDelivered = false,
    bool incomplete = false,
  }) async* {
    final requestId = result.requestId;
    if (requestId == null) {
      throw const LocalChatException(
        code: 'invalid_model_response',
        message: '模型回复缺少消息标识。',
        retryable: true,
      );
    }
    final sessionId = session.id;
    if (result.fallbackReason != null) {
      yield ChatDeliveryEvent.fallback(
        requestId: requestId,
        sessionId: sessionId,
        fallbackReason: result.fallbackReason!,
        serviceError: result.serviceError,
      );
    }
    // 流式路径的 delta 已随活前缀上屏，这里只补本地兜底与召回
    // bubble 的分片节奏。
    if (!deltasDelivered) {
      var firstChunk = true;
      for (final chunk in _visibleChunks(result.messages)) {
        if (!firstChunk && result.safety == null) {
          await Future.any<void>([
            _deliveryPause(_deliveryChunkPause),
            cancellation.whenCancelled,
          ]);
        }
        firstChunk = false;
        if (cancellation.isCancelled) {
          yield _cancelledEvent(requestId, sessionId);
          return;
        }
        yield ChatDeliveryEvent.delta(
          requestId: requestId,
          sessionId: sessionId,
          text: chunk,
        );
      }
    }
    yield ChatDeliveryEvent.message(
      requestId: requestId,
      sessionId: sessionId,
      messages: result.messages,
      incomplete: incomplete,
    );
    if (cancellation.isCancelled) {
      yield _cancelledEvent(requestId, sessionId);
      return;
    }
    var completedSession = session;
    if (persist) {
      completedSession = await _repository.appendTurn(
        session,
        RawSessionTurn.qiyu(
          requestId: requestId,
          messages: result.messages,
          at: _clock(),
          source: result.source,
          fallbackReason: result.fallbackReason,
          serviceError: result.serviceError,
          mode: result.mode,
          safety: result.safety,
        ),
      );
    }
    completion?.session = completedSession;
    yield ChatDeliveryEvent.state(
      requestId: requestId,
      sessionId: completedSession.id,
      source: result.source,
      fallbackReason: result.fallbackReason,
      serviceError: result.serviceError,
      mode: result.mode,
      safety: result.safety,
    );
    yield ChatDeliveryEvent.done(
      requestId: requestId,
      sessionId: completedSession.id,
    );
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

/// 一次可见结果交付完成后的最终会话快照：落盘发生在交付序列内部，
/// 后续隐藏动作与轮内查找需要落盘后的会话，经此在私有实现内回传，
/// 绝不随交付事件出服务边界。
final class _OutcomeCompletion {
  RawSession? session;
}

/// 流式交付的终局结论（票一）：delta 事件在流内边收边送，最终回复
/// 经此回传给交付序列——完整回复、协议失败留下的半句（[incomplete]）
/// 或本地兜底三选一；取消只置位 [cancelled]。
final class _StreamedReply {
  ChatResult? result;

  /// 本轮是否真的吐出过 delta：只有吐过才由流式路径负责交付序列，
  /// 零可见文字的本地兜底轮仍走 _deliverOutcome 的分片节奏。
  bool deltasDelivered = false;
  List<HiddenAction> hiddenActions = const [];
  bool incomplete = false;
  bool cancelled = false;
}

/// 从待吐缓冲头部取 [count] 个 runes：调用方以 outbox 非空为前置条件。
String _takeRunes(StringBuffer buffer, int count) {
  final text = buffer.toString();
  final runes = text.runes.take(count).toList(growable: false);
  final taken = String.fromCharCodes(runes);
  buffer.clear();
  buffer.write(text.substring(taken.length));
  return taken;
}

final class _DeliveryCancellation {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

Iterable<String> _visibleChunks(List<String> messages) sync* {
  for (
    var messageIndex = 0;
    messageIndex < messages.length;
    messageIndex += 1
  ) {
    if (messageIndex > 0) {
      yield '\n';
    }
    final runes = messages[messageIndex].runes.toList(growable: false);
    for (var offset = 0; offset < runes.length; offset += _deliveryChunkRunes) {
      final end = offset + _deliveryChunkRunes < runes.length
          ? offset + _deliveryChunkRunes
          : runes.length;
      yield String.fromCharCodes(runes.sublist(offset, end));
    }
  }
}

StateSnapshot _stateFromCompletedTurns(
  List<RawSessionTurn> turns,
  String pendingRequestId,
) {
  final completed = <ChatTurn>[];
  RawSessionTurn? pendingUser;
  // 轮内召回的 bubble 2 与 bubble 1 共用 requestId：紧跟在已配对
  // 回复之后、同一 requestId 的栖语 turn 属于同一轮，一并带入历史。
  String? lastPairedRequestId;
  for (final turn in turns) {
    if (turn.requestId == pendingRequestId && turn.speaker == Speaker.user) {
      continue;
    }
    if (turn.speaker == Speaker.user) {
      pendingUser = RawSessionTurn.user(
        requestId: turn.requestId,
        text: sanitizeUserInput(turn.text),
        at: turn.at,
      );
      continue;
    }
    if (pendingUser != null && pendingUser.requestId == turn.requestId) {
      completed
        ..add(
          ChatTurn(
            speaker: Speaker.user,
            text: pendingUser.text,
            at: pendingUser.at,
          ),
        )
        ..add(ChatTurn(speaker: Speaker.qiyu, text: turn.text, at: turn.at));
      lastPairedRequestId = turn.requestId;
      pendingUser = null;
      continue;
    }
    if (pendingUser == null && turn.requestId == lastPairedRequestId) {
      completed.add(
        ChatTurn(speaker: Speaker.qiyu, text: turn.text, at: turn.at),
      );
    }
  }
  final recent = completed.length <= maxStateTurns
      ? completed
      : completed.sublist(completed.length - maxStateTurns);
  return StateSnapshot(
    userId: 'local-user',
    relationshipStage: RelationshipStage.stranger,
    turns: recent,
    lastEmotion: const EmotionSnapshot(kind: EmotionKind.neutral, intensity: 0),
  );
}

ChatResult _storedResult(RawSession session, RawSessionTurn reply) {
  return ChatResult(
    requestId: reply.requestId,
    messages: redactSessionMessages(
      reply.messages.isEmpty ? [reply.text] : reply.messages,
    ),
    nextState: _stateFromCompletedTurns(session.turns, ''),
    source: reply.source ?? ReplySource.local,
    fallbackReason: reply.fallbackReason,
    serviceError: reply.serviceError,
    mode: reply.mode ?? 'local',
    safety: reply.safety,
  );
}

/// 请求已受理事件：重放与新一轮交付共用同一形态。
ChatDeliveryEvent _acceptedEvent(String requestId, String sessionId) =>
    ChatDeliveryEvent.accepted(
      requestId: requestId,
      sessionId: sessionId,
    );

/// 交付取消事件：取消语义只交付这一个事件，不带任何内容。
ChatDeliveryEvent _cancelledEvent(String requestId, String sessionId) =>
    ChatDeliveryEvent.cancelled(
      requestId: requestId,
      sessionId: sessionId,
    );

Map<String, Object?> _turnToPublicJson(RawSessionTurn turn) => {
  'requestId': turn.requestId,
  'speaker': turn.speaker.name,
  // 公开读取统一过滤：旧规则时代落盘的轮次在输出处脱敏，落盘文件
  // 本身不做批量改写。
  'text': redactSessionText(turn.text),
  'at': turn.at.toUtc().toIso8601String(),
  if (turn.source != null) 'source': turn.source!.name,
  if (turn.fallbackReason != null)
    'fallbackReason': turn.fallbackReason!.wireName,
  if (turn.serviceError != null) 'serviceError': turn.serviceError!.name,
};

RawSessionTurn? _findTurn(
  List<RawSessionTurn> turns, {
  required String requestId,
  required Speaker speaker,
}) => turns
    .where((turn) => turn.requestId == requestId && turn.speaker == speaker)
    .firstOrNull;

FallbackReason _fallbackReasonFor(ModelFailureKind failure) =>
    switch (failure) {
      ModelFailureKind.dns => FallbackReason.modelDns,
      ModelFailureKind.tls => FallbackReason.modelTls,
      ModelFailureKind.timeout => FallbackReason.modelTimeout,
      ModelFailureKind.authentication => FallbackReason.modelAuthentication,
      ModelFailureKind.network => FallbackReason.modelNetwork,
      ModelFailureKind.modelNotFound => FallbackReason.modelNotFound,
      // 模型与接口不匹配只在语音设置面给人话提示；聊天面的降级归因保持
      // 通用 provider 拒绝，不新增行为契约条目。
      ModelFailureKind.modelInterfaceMismatch => FallbackReason.modelProvider,
      ModelFailureKind.rateLimited => FallbackReason.modelRateLimited,
      ModelFailureKind.incompatibleResponse =>
        FallbackReason.incompatibleModelResponse,
      ModelFailureKind.contentParsing => FallbackReason.modelContentParsing,
      ModelFailureKind.provider => FallbackReason.modelProvider,
      ModelFailureKind.internal => FallbackReason.modelInternal,
    };
