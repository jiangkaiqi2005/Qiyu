import 'dart:async';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'daily_finalization.dart';
import 'developer_diagnostics.dart';
import 'dream.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_actions.dart';
import 'memory_controls.dart';
import 'memory_recall.dart';
import 'memory_recovery.dart';
import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'monthly_summary.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'provider_settings_service.dart';
import 'relationship_lifecycle.dart';
import 'state_pack_reader.dart';

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

/// 晚安信号词：可见回复交付后据此触发日终归档与 Dream 资格预登记。
/// 词根定稿见笔记《栖语记忆/Memory.md》「晚安怎么认」：宁可认宽
/// （提前归档可由增量整理补回），不可认漏（一晚对话整理丢失）。
/// 光秃秃的「睡觉」不认——「没睡觉」「不想睡觉」是抱怨，不是道别；
/// 但带趋向的说法（「睡觉了」「想睡」「去睡」）即便带着否定也会认，
/// 认宽的代价只是提前归档一次。
final _bedtimeSignalPattern = RegExp(r'晚安|睡了|先睡|睡觉了|想睡|去睡|困了|该睡了');

final class LocalChatService {
  LocalChatService(
    this._repository, {
    QiyuBehaviorCore? behaviorCore,
    this.providerPort,
    this.modelPromptBuilder = const ModelPromptBuilder(''),
    this.episodePipeline,
    this.dailyFinalization,
    this.openLoopStore,
    this.statePackReader,
    this.memoryRecall,
    this.personaTree,
    this.monthlySummary,
    this.dreamService,
    this.memoryControls,
    this.relationshipLifecycle,
    this.memoryActions,
    this.memoryRecovery,
    this.requestDiagnostics,
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
  final DailyFinalizationService? dailyFinalization;
  final OpenLoopStore? openLoopStore;
  final StatePackReader? statePackReader;

  /// 用户记忆控制记录（ticket 18）：冻结/禁提/删除的落盘与读取。
  /// 必须与 OpenLoopStore 使用同一实例，避免两条写入链互相覆盖。
  final MemoryControlsStore? memoryControls;

  /// relationship.md 生命周期：删除时需要立即清掉命中的关系证据行。
  /// 与日终归档共享同一实例。
  final RelationshipLifecycle? relationshipLifecycle;

  /// 记忆动作执行端（ticket 20）：删除管线与记忆中心 UI 共用同一
  /// 实现，保证聊天删除与界面删除的清理范围完全一致。
  final MemoryActionService? memoryActions;

  /// 损坏隔离与证据驱动恢复（ticket 21）：启动后台任务链上排在补
  /// 归档、月压缩与 Dream 之前执行——恢复修好的材料才能被后续整理
  /// 安全引用；受损层跳过，绝不阻塞首个可见回应。
  final MemoryRecoveryService? memoryRecovery;

  /// 召回模型查找轮内循环。只在配置了 Provider 时有意义：查找由
  /// 模型隐藏动作触发，命中快时当轮补 bubble 2，没赶上时压缩结果
  /// 注入下一轮模型上下文。
  final RecallOrchestrator? memoryRecall;

  /// PersonaTree 叶与中间理解（ticket 14）。必须与日终归档使用
  /// 同一实例：树文件的串行锁在实例内部，两个实例会互相覆盖。
  final PersonaTreeStore? personaTree;

  /// 月压缩（ticket 15，五段节奏第四动作）：进入新月、跨年或启动
  /// 补做时压缩当前月之前的月份。
  final MonthlySummaryStore? monthlySummary;

  /// Dream（ticket 16，五段节奏第五动作）：晚安后且距上次成功至少
  /// 七天时深度重组产出长期印象；启动时补跑上次晚安未成功的请求。
  /// 与日终归档、月压缩挂同一条后台任务链，保证只看到 finalized 材料。
  final DreamService? dreamService;

  /// 开发者诊断最近请求记录器（ticket 23）：只记来源、结果与脱敏
  /// 细节，绝不记用户文本；null 时不记录。
  final RequestDiagnosticsRecorder? requestDiagnostics;
  final DeliveryPause _deliveryPause;
  final RecallWindowWait _recallWindowWait;
  final Clock _clock;
  final void Function(String message) _diagnosticsSink;
  final Map<String, _DeliveryCancellation> _activeDeliveries = {};
  Future<void> _pending = Future.value();
  Future<void> _finalizationTask = Future.value();
  Future<void> _recallTask = Future.value();
  String? _lastDeliveryDate;

  Future<void> initialize() async {
    await _repository.initialize();
    // 启动恢复扫描（ticket 21）：排在一切补归档之前——先隔离损坏原件、
    // 自底向上重建，补归档与月压缩才看得到修复后的材料。后台执行，
    // 受损层跳过，绝不阻塞首个可见回应。
    final recovery = memoryRecovery;
    if (recovery != null) {
      _finalizationTask = _finalizationTask.then((_) async {
        try {
          await recovery.sweepAndRecover();
        } on Object catch (error) {
          _diagnosticsSink('memory recovery deferred [$error]');
        }
      });
    }
    // 启动补扫：发现 finalized 仍为 false 的历史日期并安全补做日终归档。
    // 后台执行，绝不阻塞首个可见回应。
    _runFinalization(
      'startup',
      (service) =>
          service.catchUpUnfinalized(before: localSessionDate(_clock())),
    );
    // 启动也补做月压缩：跨月停机后重新打开时，上月摘要在这里补齐。
    _scheduleMonthlyCompression();
    // 启动补跑 Dream：只兑现上次晚安留下且仍满足七天间隔的请求，
    // 没有晚安请求时绝不自行运行。
    _scheduleDream(bedtime: false);
  }

  /// 等待已调度的后台日终归档完成。日终归档幂等且每一步原子写入，
  /// 供测试断言与 Host 优雅收尾使用。
  Future<void> finalizePending() => _finalizationTask;

  /// 等待已调度的后台召回检索完成。检索失败只记诊断，供测试断言使用。
  Future<void> settlePendingRecalls() => _recallTask;

  /// 先等全部在途交付与后台任务（补归档、月压缩、Dream、召回保存）
  /// 完成，再独占交付串行槽运行 [operation]：期间新交付一律排在
  /// operation 之后，不会与之并发。「清除产品数据」这类整机危险操作
  /// （ticket 23）必须经此执行——操作前落盘的写入都能被其快照覆盖，
  /// 操作后也不会被在途写入把已清除的数据复活。
  Future<T> runExclusively<T>(Future<T> Function() operation) =>
      _serialized(() async {
        await _finalizationTask;
        await _recallTask;
        return operation();
      });

  /// 把一次后台归档挂到串行任务链上：归档之间不并发，失败只记诊断。
  void _runFinalization(
    String reason,
    Future<FinalizationReport> Function(DailyFinalizationService service) work,
  ) {
    final service = dailyFinalization;
    if (service == null) {
      return;
    }
    _finalizationTask = _finalizationTask.then((_) async {
      try {
        final report = await work(service);
        var troubled = 0;
        for (final outcome in report.outcomes) {
          if (outcome.status == FinalizationStatus.failed ||
              outcome.status == FinalizationStatus.skippedUnreadable) {
            troubled += 1;
            final detail = outcome.detail == null ? '' : ' [${outcome.detail}]';
            _diagnosticsSink(
              'finalization ${outcome.status.name} date=${outcome.date}'
              '$detail reason=$reason',
            );
          }
        }
        requestDiagnostics?.record(
          source: RecentRequestSources.finalization,
          result: troubled == 0
              ? RecentRequestResults.ok
              : RecentRequestResults.failed,
          detail:
              'dates=${report.outcomes.length} troubled=$troubled '
              'reason=$reason',
        );
      } on Object catch (error) {
        requestDiagnostics?.record(
          source: RecentRequestSources.finalization,
          result: RecentRequestResults.failed,
          // 细节只记错误类别，不记第三方错误原文。
          detail: '${error.runtimeType} reason=$reason',
        );
        _diagnosticsSink('finalization deferred [$error] reason=$reason');
      }
    });
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
      } on LocalChatException catch (error) {
        failureDetail = error.code;
        controller.add(
          ChatDeliveryEvent(
            kind: ChatDeliveryEventKind.error,
            requestId: trimmedRequestId,
            text: error.message,
            code: error.code,
            retryable: error.retryable,
          ),
        );
      } on Object {
        failureDetail = 'internal_error';
        controller.add(
          ChatDeliveryEvent(
            kind: ChatDeliveryEventKind.error,
            requestId: trimmedRequestId,
            text: '本地服务暂时不可用。',
            code: 'internal_error',
            retryable: true,
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
    if (existingUser != null && existingUser.text != archivedText) {
      throw const LocalChatException(
        code: 'request_id_conflict',
        message: '这条消息标识已被另一条内容使用，请重新发送。',
        retryable: false,
      );
    }
    if (existingReply != null) {
      yield ChatDeliveryEvent(
        kind: ChatDeliveryEventKind.accepted,
        requestId: trimmedRequestId,
        sessionId: session.id,
      );
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

    yield ChatDeliveryEvent(
      kind: ChatDeliveryEventKind.accepted,
      requestId: trimmedRequestId,
      sessionId: session.id,
    );
    if (cancellation.isCancelled) {
      yield ChatDeliveryEvent(
        kind: ChatDeliveryEventKind.cancelled,
        requestId: trimmedRequestId,
        sessionId: session.id,
      );
      return;
    }

    final state = _stateFromCompletedTurns(session.turns, trimmedRequestId);
    List<HiddenAction> hiddenActions = const [];
    final localOutcome = _behaviorCore.reply(
      ChatRequest(requestId: trimmedRequestId, text: trimmedText),
      state,
    );
    if (localOutcome is! ChatResult) {
      final error = localOutcome as ErrorResult;
      throw LocalChatException(
        code: error.code.wireName,
        message: error.message,
        retryable: error.retryable,
      );
    }
    var outcome = localOutcome;
    yield ChatDeliveryEvent(
      kind: ChatDeliveryEventKind.waiting,
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
    if (localOutcome.safety == null && providerPort != null) {
      ModelCompletion? completion;
      ModelPromptBuilder? requestBuilder;
      try {
        requestBuilder = await _promptBuilderForRequest(session.id);
        final prepared = await providerPort.prepareChatRequest();
        if (prepared != null) {
          completion = await _collectModelCompletion(
            requestBuilder.build(
              state,
              trimmedText,
              hardRulesAddendum: prepared.hardRulesAddendum,
              currentMoment: pendingUserMoment,
            ),
            cancellation,
            prepared: prepared,
          );
        }
      } on Object {
        completion = const ModelCompletion.failure(ModelFailureKind.provider);
      }
      // 模型没有真正收到本轮（失败/无流/取消）时，把已取用的短期
      // memory context 放回，留给下一轮注入；「晚一拍」允许再晚一拍。
      final consumedContext = requestBuilder?.memoryContext ?? '';
      final modelSucceeded = completion != null && completion.failure == null;
      if (consumedContext.isNotEmpty &&
          (!modelSucceeded || cancellation.isCancelled)) {
        memoryRecall?.restorePendingContext(session.id, consumedContext);
      }
      if (cancellation.isCancelled) {
        yield ChatDeliveryEvent(
          kind: ChatDeliveryEventKind.cancelled,
          requestId: trimmedRequestId,
          sessionId: session.id,
        );
        return;
      }
      if (completion != null) {
        final rawText = completion.failure == null ? completion.text : null;
        // 隐藏动作协议与可见文本在进入行为核心前就严格分离；
        // 动作只在 runtime 内部流转，绝不进入交付事件。
        final parsed = rawText == null ? null : parseHiddenActions(rawText);
        if (parsed != null) {
          hiddenActions = parsed.actions;
          for (final diagnostic in parsed.diagnostics) {
            _diagnosticsSink(
              'hidden-action dropped [$diagnostic] request=$trimmedRequestId',
            );
          }
        }
        outcome =
            _behaviorCore.reply(
                  ChatRequest(requestId: trimmedRequestId, text: trimmedText),
                  state,
                  candidateReply: parsed?.visibleText ?? completion.text,
                  modelFailure: completion.failure == null
                      ? null
                      : _fallbackReasonFor(completion.failure!),
                )
                as ChatResult;
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
    )) {
      lastEvent = event;
      yield event;
    }
    if (lastEvent != null && lastEvent.kind == ChatDeliveryEventKind.done) {
      final completedSession = completion.session!;
      await _applyHiddenActions(
        completedSession,
        trimmedRequestId,
        hiddenActions,
        // 只有模型真正参与的本轮才消费整理窗口；本地降级保持
        // pending，等 Provider 恢复后补跑。
        consumeWindow: outcome.source == ReplySource.llm,
      );
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
      _scheduleEndOfDayTriggers(bedtime: bedtime);
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

    final task = recall.runTurnRecall(
      userText: userText,
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

  /// 可见回复交付之后的后台记忆触发点，全部不阻塞首响：
  /// - 晚安：可见回复完成后归档当天并补做更早的未完成日期（第三动作），
  ///   随后依次补月压缩（第四动作）与 Dream（第五动作，ticket 16）。
  ///   Dream 是独立动作：归档服务绝不调用它，资格在 DreamService 内复查。
  /// - 日期变化（含进程跨午夜后的第一条消息）：补做昨天及更早的未完成日期；
  ///   当天仍在进行中，不归档。
  void _scheduleEndOfDayTriggers({required bool bedtime}) {
    if (dailyFinalization == null) {
      return;
    }
    final today = localSessionDate(_clock());
    final dateChanged = _lastDeliveryDate != today;
    _lastDeliveryDate = today;
    if (bedtime) {
      // 晚安请求先登记：即使进程在随后的归档完成前退出，启动补跑
      // 也能兑现这次 Dream（笔记定稿：当晚没跑成，下次启动补）。
      _markDreamBedtime();
      _runFinalization(
        'bedtime',
        (service) => service.finalizeForBedtime(date: today),
      );
      _scheduleMonthlyCompression();
      // Dream 排在补归档与月压缩之后：只读 finalized 材料与最新月摘要。
      // 资格（晚安 + 距上次成功 ≥3 天）在 DreamService 内复查。
      _scheduleDream(bedtime: true);
    } else if (dateChanged) {
      _runFinalization(
        'date-change',
        (service) => service.catchUpUnfinalized(before: today),
      );
      // 新月（含跨年）的第一次对话在这里触发上月压缩（五段节奏
      // 第四动作）。压缩排在补归档之后：只收 finalized 日期。
      _scheduleMonthlyCompression();
    }
  }

  /// 月压缩挂到日终归档同一条后台任务链上：保证补归档先完成、
  /// 压缩只看到 finalized 日期；失败只记诊断，绝不阻塞聊天。
  void _scheduleMonthlyCompression() {
    final compressor = monthlySummary;
    if (compressor == null) {
      return;
    }
    final now = _clock();
    final month = '${now.year}-${'${now.month}'.padLeft(2, '0')}';
    _finalizationTask = _finalizationTask.then((_) async {
      try {
        await compressor.compressBefore(month);
      } on Object catch (error) {
        _diagnosticsSink('monthly compression deferred [$error]');
      }
    });
  }

  /// 晚安触发预登记：排在晚安任务链最前面，把七天间隔已到的请求先
  /// 落成 pending；失败只记诊断。
  void _markDreamBedtime() {
    final dream = dreamService;
    if (dream == null) {
      return;
    }
    _finalizationTask = _finalizationTask.then((_) async {
      try {
        await dream.markBedtime();
      } on Object catch (error) {
        _diagnosticsSink('dream bedtime mark deferred [$error]');
      }
    });
  }

  /// Dream 挂到日终归档同一条后台任务链上：补归档与月压缩先完成，
  /// Dream 只看到 finalized 材料；失败只记诊断，绝不阻塞聊天，
  /// 未成功的请求由下次晚安或启动补跑继续。
  void _scheduleDream({required bool bedtime}) {
    final dream = dreamService;
    if (dream == null) {
      return;
    }
    _finalizationTask = _finalizationTask.then((_) async {
      try {
        final outcome = await dream.run(bedtime: bedtime);
        final status = outcome.status;
        if (status == DreamStatus.modelFailed ||
            status == DreamStatus.validationFailed ||
            status == DreamStatus.writeFailed ||
            status == DreamStatus.skippedUnreadable) {
          final detail = outcome.detail == null ? '' : ' [${outcome.detail}]';
          _diagnosticsSink('dream deferred status=${status.name}$detail');
        }
        requestDiagnostics?.record(
          source: RecentRequestSources.dream,
          result: switch (status) {
            DreamStatus.accepted => RecentRequestResults.ok,
            DreamStatus.notEligible ||
            DreamStatus.notDue ||
            DreamStatus.skippedNoMaterial ||
            DreamStatus.skippedNoProvider => RecentRequestResults.skipped,
            _ => RecentRequestResults.failed,
          },
          detail: 'status=${status.name}',
        );
      } on Object catch (error) {
        requestDiagnostics?.record(
          source: RecentRequestSources.dream,
          result: RecentRequestResults.failed,
          // 细节只记错误类别，不记第三方错误原文。
          detail: '${error.runtimeType}',
        );
        _diagnosticsSink('dream deferred [$error]');
      }
    });
  }

  /// 可见回复落盘之后的增量记忆整理：写失败只记诊断，不影响本轮回复。
  /// 用户记忆控制（不记录/禁提/冻结/解除/删除）在回复后异步立即生效，
  /// 不等日终（记忆控制定稿）。
  Future<void> _applyHiddenActions(
    RawSession completedSession,
    String requestId,
    List<HiddenAction> hiddenActions, {
    required bool consumeWindow,
  }) async {
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
          consumeWindow: consumeWindow,
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
            final banned =
                await store?.banTitle(action.title, origin: 'chat') ?? false;
            if (!banned) {
              // controls 不可写：禁提没有落盘，热层也保持不动，
              // 等待下次触发重试，绝不留下半生效状态。
              _diagnosticsSink(
                'memory ban deferred [controls not writable] '
                'request=$requestId',
              );
            } else {
              // 用户禁提高于 PersonaTree 提炼：立即清出树（ticket 14）。
              final tree = personaTree;
              if (tree != null) {
                await tree.applyBan(action.title);
              }
            }
          case MemoryFreezeAction():
            final controls = memoryControls;
            final frozen = await controls?.freeze(action.title) ?? false;
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

  /// 每轮实测状态包，组装本轮【近况】、【长期印象】与【用户画像】块；
  /// 读取失败降级为空块（空块不输出），绝不阻塞回复。注入关统一预算：
  /// 近况 + 长期印象 + 用户画像总量超热层硬上限时按砍序先压长期印象
  /// （clipLongMemoryBlock），再压用户画像可裁节（clipPersonaBlock，
  /// 边界禁区永不裁）；近况块内部再压近日状态；relationship 与
  /// open-loops 永不砍，当前安全信息与近况优先保住。
  /// 同时消费该会话上一轮后台召回命中的短期 memory context（临时透镜，
  /// 只注入一次）。
  Future<ModelPromptBuilder> _promptBuilderForRequest(String sessionId) async {
    var builder = modelPromptBuilder;
    final reader = statePackReader;
    if (reader != null) {
      try {
        final block = await reader.readDailyStateBlock();
        builder = builder.copyWithDailyState(block);
        final longMemory = await reader.readLongMemoryBlock();
        final persona = await reader.readPersonaBlock();
        final overflow =
            block.runes.length +
            longMemory.runes.length +
            persona.runes.length -
            hotLayerMaxRunes;
        var clippedLongMemory = longMemory;
        var clippedPersona = persona;
        if (overflow > 0) {
          clippedLongMemory = clipLongMemoryBlock(
            longMemory,
            longMemory.runes.length - overflow,
          );
          final remainingOverflow =
              block.runes.length +
              clippedLongMemory.runes.length +
              persona.runes.length -
              hotLayerMaxRunes;
          if (remainingOverflow > 0) {
            clippedPersona = clipPersonaBlock(
              persona,
              persona.runes.length - remainingOverflow,
            );
          }
        }
        builder = builder.copyWithLongMemory(clippedLongMemory);
        builder = builder.copyWithPersona(clippedPersona);
      } on Object catch (error) {
        _diagnosticsSink('state pack unavailable [$error]');
      }
    }
    final pendingContext = memoryRecall?.consumePendingContext(sessionId);
    if (pendingContext != null) {
      builder = builder.copyWithMemoryContext(pendingContext);
    }
    return builder;
  }

  Future<ModelCompletion?> _collectModelCompletion(
    List<ModelMessage> messages,
    _DeliveryCancellation cancellation, {
    required PreparedProviderChatRequest prepared,
  }) async {
    // 一次 open：协议适配、终止判定、错误分类与取消下传全部在快照与
    // 网关内部完成；主链只对交付事件做缓冲与上限护栏。
    final stream = await prepared.openStream(
      messages,
      whenCancelled: cancellation.whenCancelled,
    );
    if (stream == null) {
      return null;
    }
    final iterator = StreamIterator<ModelStreamEvent>(stream);
    final buffer = StringBuffer();
    var bufferedRunes = 0;
    try {
      while (true) {
        final moveNext = iterator.moveNext();
        final moved = await Future.any<Object?>([
          moveNext,
          cancellation.whenCancelled.then<Object?>((_) => null),
        ]);
        if (moved == null || cancellation.isCancelled) {
          await iterator.cancel();
          return null;
        }
        if (moved != true) {
          break;
        }
        final event = iterator.current;
        switch (event.kind) {
          case ModelStreamEventKind.delta:
            bufferedRunes += event.text!.runes.length;
            if (bufferedRunes > _maxModelReplyRunes) {
              await iterator.cancel();
              return const ModelCompletion.failure(
                ModelFailureKind.incompatibleResponse,
              );
            }
            buffer.write(event.text);
          case ModelStreamEventKind.done:
            return ModelCompletion.reply(buffer.toString());
          case ModelStreamEventKind.failure:
            return ModelCompletion.failure(event.failure!);
        }
      }
      return buffer.isEmpty
          ? const ModelCompletion.failure(ModelFailureKind.contentParsing)
          : ModelCompletion.reply(buffer.toString());
    } finally {
      await iterator.cancel();
    }
  }

  Stream<ChatDeliveryEvent> _deliverOutcome(
    RawSession session,
    ChatResult result,
    _DeliveryCancellation cancellation, {
    bool persist = false,
    _OutcomeCompletion? completion,
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
      yield ChatDeliveryEvent(
        kind: ChatDeliveryEventKind.fallback,
        requestId: requestId,
        sessionId: sessionId,
        fallbackReason: result.fallbackReason,
      );
    }
    var firstChunk = true;
    for (final chunk in _visibleChunks(result.messages)) {
      if (!firstChunk && result.safety == null) {
        await Future.any<void>([
          _deliveryPause(const Duration(milliseconds: 70)),
          cancellation.whenCancelled,
        ]);
      }
      firstChunk = false;
      if (cancellation.isCancelled) {
        yield ChatDeliveryEvent(
          kind: ChatDeliveryEventKind.cancelled,
          requestId: requestId,
          sessionId: sessionId,
        );
        return;
      }
      yield ChatDeliveryEvent(
        kind: ChatDeliveryEventKind.delta,
        requestId: requestId,
        sessionId: sessionId,
        text: chunk,
      );
    }
    yield ChatDeliveryEvent(
      kind: ChatDeliveryEventKind.message,
      requestId: requestId,
      sessionId: sessionId,
      messages: result.messages,
    );
    if (cancellation.isCancelled) {
      yield ChatDeliveryEvent(
        kind: ChatDeliveryEventKind.cancelled,
        requestId: requestId,
        sessionId: sessionId,
      );
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
          mode: result.mode,
          safety: result.safety,
        ),
      );
    }
    completion?.session = completedSession;
    yield ChatDeliveryEvent(
      kind: ChatDeliveryEventKind.state,
      requestId: requestId,
      sessionId: completedSession.id,
      source: result.source,
      fallbackReason: result.fallbackReason,
      mode: result.mode,
      safety: result.safety,
    );
    yield ChatDeliveryEvent(
      kind: ChatDeliveryEventKind.done,
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
    for (var offset = 0; offset < runes.length; offset += 12) {
      final end = offset + 12 < runes.length ? offset + 12 : runes.length;
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
      completed.add(ChatTurn(speaker: Speaker.qiyu, text: turn.text, at: turn.at));
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
    messages: reply.messages.isEmpty ? [reply.text] : reply.messages,
    nextState: _stateFromCompletedTurns(session.turns, ''),
    source: reply.source ?? ReplySource.local,
    fallbackReason: reply.fallbackReason,
    mode: reply.mode ?? 'local',
    safety: reply.safety,
  );
}

Map<String, Object?> _turnToPublicJson(RawSessionTurn turn) => {
  'requestId': turn.requestId,
  'speaker': turn.speaker.name,
  'text': turn.text,
  'at': turn.at.toUtc().toIso8601String(),
  if (turn.source != null) 'source': turn.source!.name,
  if (turn.fallbackReason != null)
    'fallbackReason': turn.fallbackReason!.wireName,
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
      ModelFailureKind.rateLimited => FallbackReason.modelRateLimited,
      ModelFailureKind.incompatibleResponse =>
        FallbackReason.incompatibleModelResponse,
      ModelFailureKind.contentParsing => FallbackReason.modelContentParsing,
      ModelFailureKind.provider => FallbackReason.modelProvider,
      ModelFailureKind.internal => FallbackReason.modelInternal,
    };
