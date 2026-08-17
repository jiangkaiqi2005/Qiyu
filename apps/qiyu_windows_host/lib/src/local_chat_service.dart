import 'dart:async';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'daily_finalization.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_recall.dart';
import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'monthly_summary.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'provider_settings_service.dart';
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

final class LocalChatExchange {
  const LocalChatExchange({required this.session, required this.result});

  final RawSession session;
  final ChatResult result;

  Map<String, Object?> toJson() => {
    ...result.toJson(),
    'sessionId': session.id,
  };
}

typedef LocalChatEventKind = ChatDeliveryEventKind;

final class LocalChatDeliveryEvent extends ChatDeliveryEvent {
  const LocalChatDeliveryEvent({
    required super.kind,
    required super.requestId,
    super.sessionId,
    super.text,
    super.messages,
    super.source,
    super.fallbackReason,
    super.mode,
    super.safety,
    super.code,
    super.retryable,
    this.exchange,
  });
  final LocalChatExchange? exchange;
}

typedef DeliveryPause = Future<void> Function(Duration duration);

/// 召回窗口预算的等待注入点：与流式分段停顿（[DeliveryPause]）语义
/// 不同，单独注入，测试可分别控制。
typedef RecallWindowWait = Future<void> Function(Duration window);

/// 候选回复缓冲上限（runes）。可见回复在行为核心侧另有 2000 runes 限制，
/// 这里只为防止失控的 Provider 流在超时前耗尽内存。
const _maxModelReplyRunes = 8192;

final class LocalChatService {
  LocalChatService(
    this._repository, {
    QiyuBehaviorCore? behaviorCore,
    this.providerChatClient,
    this.modelPromptBuilder = const ModelPromptBuilder(''),
    this.episodePipeline,
    this.dailyFinalization,
    this.openLoopStore,
    this.statePackReader,
    this.memoryRecall,
    this.personaTree,
    this.monthlySummary,
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
  final StreamingProviderChatClient? providerChatClient;
  final ModelPromptBuilder modelPromptBuilder;
  final EpisodeMemoryPipeline? episodePipeline;
  final DailyFinalizationService? dailyFinalization;
  final OpenLoopStore? openLoopStore;
  final StatePackReader? statePackReader;

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
    // 启动补扫：发现 finalized 仍为 false 的历史日期并安全补做日终归档。
    // 后台执行，绝不阻塞首个可见回应。
    _runFinalization(
      'startup',
      (service) => service.catchUpUnfinalized(
        before: localSessionDate(_clock()),
      ),
    );
    // 启动也补做月压缩：跨月停机后重新打开时，上月摘要在这里补齐。
    _scheduleMonthlyCompression();
  }

  /// 等待已调度的后台日终归档完成。日终归档幂等且每一步原子写入，
  /// 供测试断言与 Host 优雅收尾使用。
  Future<void> finalizePending() => _finalizationTask;

  /// 等待已调度的后台召回检索完成。检索失败只记诊断，供测试断言使用。
  Future<void> settlePendingRecalls() => _recallTask;

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
        for (final outcome in report.outcomes) {
          if (outcome.status == FinalizationStatus.failed ||
              outcome.status == FinalizationStatus.skippedUnreadable) {
            final detail = outcome.detail == null ? '' : ' [${outcome.detail}]';
            _diagnosticsSink(
              'finalization ${outcome.status.name} date=${outcome.date}'
              '$detail reason=$reason',
            );
          }
        }
      } on Object catch (error) {
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

  Future<LocalChatExchange> send({
    required String requestId,
    required String text,
    String? sessionId,
  }) async {
    LocalChatExchange? exchange;
    LocalChatException? failure;
    await for (final event in deliver(
      requestId: requestId,
      text: text,
      sessionId: sessionId,
    )) {
      if (event.kind == LocalChatEventKind.error) {
        failure = LocalChatException(
          code: event.code!,
          message: event.text!,
          retryable: event.retryable!,
        );
      }
      exchange = event.exchange ?? exchange;
    }
    if (failure != null) {
      throw failure;
    }
    if (exchange == null) {
      throw const LocalChatException(
        code: 'cancelled',
        message: '回复已停止。',
        retryable: true,
      );
    }
    return exchange;
  }

  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) {
    final trimmedRequestId = requestId.trim();
    final cancellation = _DeliveryCancellation();
    late final StreamController<LocalChatDeliveryEvent> controller;
    controller = StreamController<LocalChatDeliveryEvent>(
      onCancel: cancellation.cancel,
    );
    _serialized(() async {
      if (trimmedRequestId.isNotEmpty) {
        _activeDeliveries[trimmedRequestId] = cancellation;
      }
      try {
        await controller.addStream(
          _deliver(
            requestId: requestId,
            text: text,
            sessionId: sessionId,
            cancellation: cancellation,
          ),
        );
      } on LocalChatException catch (error) {
        controller.add(
          LocalChatDeliveryEvent(
            kind: LocalChatEventKind.error,
            requestId: trimmedRequestId,
            text: error.message,
            code: error.code,
            retryable: error.retryable,
          ),
        );
      } on Object {
        controller.add(
          LocalChatDeliveryEvent(
            kind: LocalChatEventKind.error,
            requestId: trimmedRequestId,
            text: '本地服务暂时不可用。',
            code: 'internal_error',
            retryable: true,
          ),
        );
      } finally {
        if (identical(_activeDeliveries[trimmedRequestId], cancellation)) {
          _activeDeliveries.remove(trimmedRequestId);
        }
        await controller.close();
      }
    });
    return controller.stream;
  }

  bool cancel(String requestId) {
    final cancellation = _activeDeliveries[requestId.trim()];
    if (cancellation == null) {
      return false;
    }
    cancellation.cancel();
    return true;
  }

  Stream<LocalChatDeliveryEvent> _deliver({
    required String requestId,
    required String text,
    required String? sessionId,
    required _DeliveryCancellation cancellation,
  }) async* {
    final trimmedRequestId = requestId.trim();
    final trimmedText = sanitizeUserInput(text);
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
      final exchange = LocalChatExchange(
        session: session,
        result: _storedResult(session, existingReply),
      );
      yield LocalChatDeliveryEvent(
        kind: LocalChatEventKind.accepted,
        requestId: trimmedRequestId,
        sessionId: session.id,
      );
      yield* _deliverOutcome(exchange, cancellation);
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

    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: trimmedRequestId,
      sessionId: session.id,
    );
    if (cancellation.isCancelled) {
      yield LocalChatDeliveryEvent(
        kind: LocalChatEventKind.cancelled,
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
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: trimmedRequestId,
      sessionId: session.id,
    );
    if (localOutcome.safety == null &&
        localOutcome.mode != 'bedtime' &&
        providerChatClient != null) {
      ModelCompletion? completion;
      ModelPromptBuilder? requestBuilder;
      try {
        requestBuilder = await _promptBuilderForRequest(session.id);
        completion = await _collectModelCompletion(
          requestBuilder.build(state, trimmedText),
          cancellation,
        );
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
        yield LocalChatDeliveryEvent(
          kind: LocalChatEventKind.cancelled,
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

    final exchange = LocalChatExchange(session: session, result: outcome);
    LocalChatDeliveryEvent? lastEvent;
    await for (
      final event
      in _deliverOutcome(exchange, cancellation, persist: true)
    ) {
      lastEvent = event;
      yield event;
    }
    if (lastEvent != null && lastEvent.kind == LocalChatEventKind.done) {
      final completedSession = lastEvent.exchange!.session;
      await _applyHiddenActions(
        completedSession,
        trimmedRequestId,
        hiddenActions,
        // 只有模型真正参与的本轮才消费整理窗口；本地降级/晚安收束
        // 保持 pending，等 Provider 恢复后补跑。
        consumeWindow: outcome.source == ReplySource.llm,
      );
      // 轮内召回循环：bubble 1 交付后才开始，绝不阻塞首响。
      yield* _recallBubble(
        session: completedSession,
        state: state,
        userText: trimmedText,
        hiddenActions: hiddenActions,
        outcome: outcome,
        cancellation: cancellation,
      );
      _scheduleEndOfDayTriggers(outcome);
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
  /// 只有模型隐藏动作能触发查找（规则兜底已退役）；晚安收束与安全
  /// 回复不查找；未配置 Provider 不查找（保持现状）。
  Stream<LocalChatDeliveryEvent> _recallBubble({
    required RawSession session,
    required StateSnapshot state,
    required String userText,
    required List<HiddenAction> hiddenActions,
    required ChatResult outcome,
    required _DeliveryCancellation cancellation,
  }) async* {
    final recall = memoryRecall;
    if (recall == null ||
        providerChatClient == null ||
        outcome.safety != null ||
        outcome.mode == 'bedtime') {
      return;
    }
    final requestId = outcome.requestId;
    if (requestId == null) {
      return;
    }
    final hasRecallRequest = hiddenActions.any(
      (action) =>
          action.kind == HiddenActionKind.memoryRecall &&
          (action.query ?? '').trim().isNotEmpty,
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
      LocalChatExchange(
        session: session,
        result: ChatResult(
          requestId: requestId,
          messages: validated.messages,
          nextState: validated.nextState,
          source: ReplySource.llm,
          mode: validated.mode,
        ),
      ),
      cancellation,
      persist: true,
    );
  }

  /// 日终归档触发点（五段节奏第三动作），全部在可见回复交付之后后台执行：
  /// - 晚安：睡前收束完成后归档当天，并补做更早的未完成日期；
  ///   晚安只触发日终归档，Dream 是独立的第五动作（ticket 16），绝不在此触发。
  /// - 日期变化（含进程跨午夜后的第一条消息）：补做昨天及更早的未完成日期；
  ///   当天仍在进行中，不归档。
  void _scheduleEndOfDayTriggers(ChatResult outcome) {
    if (dailyFinalization == null) {
      return;
    }
    final today = localSessionDate(_clock());
    final dateChanged = _lastDeliveryDate != today;
    _lastDeliveryDate = today;
    if (outcome.mode == 'bedtime') {
      _runFinalization(
        'bedtime',
        (service) => service.finalizeForBedtime(date: today),
      );
      _scheduleMonthlyCompression();
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

  /// 可见回复落盘之后的增量记忆整理：写失败只记诊断，不影响本轮回复。
  Future<void> _applyHiddenActions(
    RawSession completedSession,
    String requestId,
    List<HiddenAction> hiddenActions, {
    required bool consumeWindow,
  }) async {
    final pipeline = episodePipeline;
    if (pipeline != null) {
      try {
        final result = await pipeline.processReply(
          session: completedSession,
          requestId: requestId,
          hiddenActions: hiddenActions,
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
        }
      } on Object catch (error) {
        _diagnosticsSink(
          'episode update deferred [$error] request=$requestId',
        );
      }
    }
    // Open-loop 状态变化与禁提属于用户记忆控制：回复后异步立即生效，
    // 不等日终（对齐记忆控制定稿）；禁提同时移出热层并写 controls。
    final store = openLoopStore;
    if (store != null) {
      for (final action in hiddenActions) {
        try {
          if (action.kind == HiddenActionKind.openLoopStatus &&
              action.summary != null &&
              action.status != null) {
            await store.applyStatusChange(
              title: action.summary!,
              status: action.status!,
              result: action.result,
            );
          } else if (action.kind == HiddenActionKind.memoryBan &&
              action.summary != null) {
            final banned = await store.banTitle(action.summary!);
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
                await tree.applyBan(action.summary!);
              }
            }
          }
        } on Object catch (error) {
          _diagnosticsSink(
            'open-loop update deferred [$error] request=$requestId',
          );
        }
      }
    }
  }

  /// 每轮实测状态包，组装本轮【近况】块；读取失败降级为空块
  /// （空块不输出），绝不阻塞回复。同时消费该会话上一轮后台召回
  /// 命中的短期 memory context（临时透镜，只注入一次）。
  Future<ModelPromptBuilder> _promptBuilderForRequest(String sessionId) async {
    var builder = modelPromptBuilder;
    final reader = statePackReader;
    if (reader != null) {
      try {
        final block = await reader.readDailyStateBlock();
        builder = builder.copyWithDailyState(block);
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
    _DeliveryCancellation cancellation,
  ) async {
    final streaming = providerChatClient;
    if (streaming != null) {
      final stream = await streaming.openStream(messages);
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
    return null;
  }

  Stream<LocalChatDeliveryEvent> _deliverOutcome(
    LocalChatExchange exchange,
    _DeliveryCancellation cancellation, {
    bool persist = false,
  }) async* {
    final result = exchange.result;
    final requestId = result.requestId;
    if (requestId == null) {
      throw const LocalChatException(
        code: 'invalid_model_response',
        message: '模型回复缺少消息标识。',
        retryable: true,
      );
    }
    final sessionId = exchange.session.id;
    if (result.fallbackReason != null) {
      yield LocalChatDeliveryEvent(
        kind: LocalChatEventKind.fallback,
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
        yield LocalChatDeliveryEvent(
          kind: LocalChatEventKind.cancelled,
          requestId: requestId,
          sessionId: sessionId,
        );
        return;
      }
      yield LocalChatDeliveryEvent(
        kind: LocalChatEventKind.delta,
        requestId: requestId,
        sessionId: sessionId,
        text: chunk,
      );
    }
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      sessionId: sessionId,
      messages: result.messages,
    );
    if (cancellation.isCancelled) {
      yield LocalChatDeliveryEvent(
        kind: LocalChatEventKind.cancelled,
        requestId: requestId,
        sessionId: sessionId,
      );
      return;
    }
    var completedSession = exchange.session;
    if (persist) {
      completedSession = await _repository.appendTurn(
        exchange.session,
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
    final completed = LocalChatExchange(
      session: completedSession,
      result: result,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      sessionId: completedSession.id,
      source: result.source,
      fallbackReason: result.fallbackReason,
      mode: result.mode,
      safety: result.safety,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
      sessionId: completedSession.id,
      exchange: completed,
    );
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
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
        ..add(ChatTurn(speaker: Speaker.user, text: pendingUser.text))
        ..add(ChatTurn(speaker: Speaker.qiyu, text: turn.text));
      lastPairedRequestId = turn.requestId;
      pendingUser = null;
      continue;
    }
    if (pendingUser == null && turn.requestId == lastPairedRequestId) {
      completed.add(ChatTurn(speaker: Speaker.qiyu, text: turn.text));
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
}) {
  for (final turn in turns) {
    if (turn.requestId == requestId && turn.speaker == speaker) {
      return turn;
    }
  }
  return null;
}

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
