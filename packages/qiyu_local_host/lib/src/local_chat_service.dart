import 'dart:async';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'chat_memory_module.dart';
import 'delivery_stream_state.dart';
import 'developer_diagnostics.dart';
import 'hidden_action_executor.dart';
import 'markdown_memory_repository.dart';
import 'memory_recall.dart';
import 'model_prompt_builder.dart';
import 'provider_settings_service.dart';
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

/// 召回窗口预算的等待注入点：与流式分段停顿（[DeliveryPause]）语义
/// 不同，单独注入，测试可分别控制。
typedef RecallWindowWait = Future<void> Function(Duration window);

/// 晚安信号词：可见回复交付后据此触发日终归档与 Dream 资格预登记。
/// 词根定稿见笔记《栖语记忆/Memory.md》「晚安怎么认」：宁可认宽
/// （提前归档可由增量整理补回），不可认漏（一晚对话整理丢失）。
/// 光秃秃的「睡觉」不认——「没睡觉」「不想睡觉」是抱怨，不是道别；
/// 但带趋向的说法（「睡觉了」「想睡」「去睡」）即便带着否定也会认，
/// 认宽的代价只是提前归档一次。聊天与 Omni 实时通话（T03）共用
/// 同一词根，不各养一份。
final bedtimeSignalPattern = RegExp(r'晚安|睡了|先睡|睡觉了|想睡|去睡|困了|该睡了');

/// 模型流已收尾而会话还没落定时的有界宽限缺省值（票三）：快速档位（不开
/// 会话）一个配置读取内就回，正常 WS 握手也白送这段时间——内落定即挂载
/// （补喂缓冲文本、替会话收尾，尾块照常播完）；端点不可达时上限默认就在
/// 这里，超出才作废会话——done 不被握手无限期拖住。生产走缺省值；测试经
/// [LocalChatService.voiceSessionGrace] 注入小值。
const defaultVoiceSessionGrace = Duration(seconds: 2);

final class LocalChatService {
  LocalChatService(
    this._repository, {
    required this.memory,
    this.providerPort,
    this.modelPromptBuilder = const ModelPromptBuilder(''),
    this.requestDiagnostics,
    this.aliasClient,
    this.voiceStreamSynthesizer,
    DeliveryPause? deliveryPause,
    RecallWindowWait? recallWindowWait,
    Duration? voiceSessionGrace,
    Clock? clock,
    void Function(String message)? diagnosticsSink,
  }) : _deliveryPause = deliveryPause ?? Future<void>.delayed,
       _recallWindowWait = recallWindowWait ?? Future<void>.delayed,
       _voiceSessionGrace = voiceSessionGrace ?? defaultVoiceSessionGrace,
       _clock = clock ?? DateTime.now,
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics,
       // 隐藏动作执行端（T03 抽出）：与 Omni 实时通话共用同一执行器，
       // 动作语义与提交边界不随链路漂移。
       _actionExecutor = HiddenActionExecutor(
         memory: memory,
         aliasClient: aliasClient,
         diagnosticsSink: diagnosticsSink ?? stderrDiagnostics,
       );

  final MemoryRepository _repository;
  final QiyuBehaviorCore _behaviorCore = const QiyuBehaviorCore();

  /// 记忆依赖族（票 10 / ADR 0022）：轮内整理、开环即时生效、禁提/
  /// 冻结/删除、维护准入、交付节奏、轮内召回、称呼自述与热层装配的
  /// 全部承载模块收成一个必填 module，忘注入在构造期报错；成员实例
  /// 的同实例约束（控制存储与开环存储）由 [ChatMemoryModule] 构造期
  /// 校验。
  final ChatMemoryModule memory;

  final ProviderChatPort? providerPort;
  final ModelPromptBuilder modelPromptBuilder;

  /// 控制时关联扩展的 Provider 客户端（裁定票 03）：聊天禁提与冻结
  /// 两个分支直接用它做有界别名调用（都在维护准入之外），删除走
  /// memoryActions 的删除管线（其客户端随 memoryActions 注入）。未配置
  /// 或调用失败都静默退回无别名，控制本身照常生效。
  final ProviderChatClient? aliasClient;

  /// 分句流式语音合成的服务层接缝（票二）：文字流式推进中每出一个
  /// 完整句，Host 经它请求该句合成，音频块搭车聊天事件流推出。未注入
  /// （或档位拿不到音频块、自动朗读关着）时本轮就是纯文字流式，语音
  /// 继续走 done 时的整段朗读路径。票三起同一实例还承担连续供给会话
  /// （[VoiceStreamSessionOpener]）：档位开了 WS 时增量原文直接进会话，
  /// 分句层切句与在途上限都不参与。
  final VoiceStreamSynthesizer? voiceStreamSynthesizer;

  /// 开发者诊断最近请求记录器（ticket 23）：只记来源、结果与脱敏
  /// 细节，绝不记用户文本；null 时不记录。
  final RequestDiagnosticsRecorder? requestDiagnostics;
  final DeliveryPause _deliveryPause;
  final RecallWindowWait _recallWindowWait;

  /// 模型流已收尾而会话还没落定时的有界宽限（票三）：生产走缺省值，测试注入小值。
  final Duration _voiceSessionGrace;
  final Clock _clock;
  final void Function(String message) _diagnosticsSink;

  /// 隐藏动作执行端（T03 抽出）：与实时通话共用的同一执行器实例逻辑
  /// （每服务各自一个实例，语义同源）。
  final HiddenActionExecutor _actionExecutor;
  final Map<String, DeliveryCancellation> _activeDeliveries = {};

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

  /// 等待在途召回索引构建与增量同步推进到安全点（票 05）：Host 关闭
  /// 等排空场景经它收口，与 [settlePendingRecalls] 同律，不向调用方
  /// 暴露记忆模块内部装配。未接入 Episode RAG 时是空操作。
  Future<void> settlePendingIndexWork() =>
      memory.embeddingRecall?.settlePendingWork() ?? Future<void>.value();

  /// 维护独占边界（spec「维护隔离及恢复」）：导入、回滚、清除、一致
  /// 性导出共用这唯一入口。先抑制记忆节奏与召回索引的新后台排程，再
  /// 等已在途的全部工作（在途交付、轮内召回与保存延续、补归档、月压
  /// 缩、Dream、召回保存与索引构建），然后独占交付串行槽运行
  /// [operation]：期间新交付与并发维护请求一律排在 operation 之后，
  /// 空闲补办 tick 跳过当次，不会与之并发。「清除产品数据」「备份导
  /// 入」这类整机改写操作必须经此执行——操作前落盘的写入都能被其快
  /// 照覆盖，操作后也不会被在途写入把已恢复的数据复活。
  ///
  /// [invalidatesDerivedCaches] 标记本次维护改写了记忆来源（导入/回滚
  /// /清除）：结束后召回索引缓存一律失效并显示需重建（Spec 决策 7），
  /// 在途构建凭代数错位不得发布旧来源结果；一致性导出是只读操作，
  /// 不传此标记、不失效缓存。
  ///
  /// 成功或失败都在 finally 里恢复常规调度：维护抛异常不卡死后续
  /// 调度，未完成整理由下一次空闲补办继续。等待的只有已在途工作，
  /// 维护入口自身不在任何被等待的任务链上，不会形成自身等待死锁。
  Future<T> runExclusively<T>(
    Future<T> Function() operation, {
    bool invalidatesDerivedCaches = false,
  }) {
    Future<T> drainAndRun() async {
      memory.memoryCadence.pauseBackgroundScheduling();
      memory.embeddingRecall?.pauseBackgroundScheduling();
      try {
        await memory.memoryCadence.finalizePending();
        await _recallTask;
        await memory.embeddingRecall?.settlePendingWork();
        final result = await operation();
        return result;
      } finally {
        // 来源改写型维护（含失败中断：来源可能已部分改写）结束后缓存
        // 一律失效并显示需重建；只读维护不失效。
        if (invalidatesDerivedCaches) {
          memory.embeddingRecall?.onMaintenanceCompleted();
        }
        memory.embeddingRecall?.resumeBackgroundScheduling();
        memory.memoryCadence.resumeBackgroundScheduling();
      }
    }

    // 同步关闭新 UI 操作准入并保留聊天队列中的维护位置：等待在途
    // UI 时，新聊天也不能插队。排空和维护都不持有短提交锁。
    final commits = memory.episodePipeline.commits;
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
    String locale = 'zh',
  }) {
    final trimmedRequestId = requestId.trim();
    final cancellation = DeliveryCancellation();
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
            locale: locale,
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

  /// 为本轮准备分句语音合成管线（票二）+ 连续供给会话（票三）：未注入接缝、
  /// 档位拿不到音频块（自定义档 JSON 字段形态）、自动朗读关着或未配置时
  /// 返回 null——本轮就是纯文字流式，done 时的整段朗读路径不受影响。
  /// 查询本身失败只记诊断，同样按「不流式」处理（文字链路永远优先）。
  ///
  /// 连续供给（票三）：接缝同时实现 [VoiceStreamSessionOpener] 时启动开会话
  /// ——档位开了 WS（豆包 transport=ws_bidirection 且生效音频参数可流式
  /// PCM、千问 -realtime 型号）就进会话模式（增量原文直接进 WS），返回
  /// null 的档位维持票二分句模式。
  ///
  /// 开会话是网络 I/O（WS 握手）：返回的 Future 由交付主循环挂进等待集
  /// （迟到挂载）——**文字首字不等握手**；会话落定才 attachSession，落定前
  /// 喂进的文本不合成（首句可能不出声，文字永远优先）；模型流已收尾时才
  /// 落定＝直接作废会话（语音没启动，不是失败）；开会话失败走 D1 同口径
  /// （failedSession 形态 + 一次 voiceError），不回落分句模式（避免同一条
  /// 链路上再烧一次配额）。
  Future<DeliveryVoiceHandoff?> _startVoiceStreamPipeline(
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
    if (synthesizer case final VoiceStreamSessionOpener opener) {
      // 连续供给：管线先就绪并登记（stopVoice 握手窗口也能定位到），会话
      // Future 交给主循环迟到挂载。
      final pipeline = VoiceStreamPipeline(
        synthesizer: synthesizer,
        requestId: requestId,
        sessionId: session.id,
        deliveryIndex: _voiceDeliveryIndex(session, requestId),
        diagnosticsSink: _diagnosticsSink,
        pendingSession: true,
      );
      _activeVoiceStreams[requestId] = pipeline;
      return DeliveryVoiceHandoff(
        pipeline: pipeline,
        requestId: requestId,
        openSession: opener.openSession(sessionId: session.id),
      );
    }
    // 票二分句模式（档位不开会话）：管线即刻可用。
    final pipeline = VoiceStreamPipeline(
      synthesizer: synthesizer,
      requestId: requestId,
      sessionId: session.id,
      deliveryIndex: _voiceDeliveryIndex(session, requestId),
      diagnosticsSink: _diagnosticsSink,
    );
    _activeVoiceStreams[requestId] = pipeline;
    return DeliveryVoiceHandoff(pipeline: pipeline, requestId: requestId);
  }

  /// 作废迟到的连续供给会话（票三）：管线 cancel 并从登记表移除（identical
  /// 校验，重复调用无副作用），会话 Future 落定也作废——连接绝不比文字多活
  /// 一刻；落定失败（开会话抛错）同样清表。收敛「取消赶在落定前」「模型流
  /// 没开到」「主循环提前 break」三条泄漏路径的唯一出口。
  void _abandonVoiceStream(DeliveryVoiceHandoff? voice) {
    if (voice == null) {
      return;
    }
    final pipeline = voice.pipeline;
    final registered = identical(
      _activeVoiceStreams[voice.requestId],
      pipeline,
    );
    pipeline.cancel();
    if (registered) {
      _activeVoiceStreams.remove(voice.requestId);
    }
    voice.openSession?.then((session) => session?.cancel(), onError: (_) {});
  }

  /// 语音块所属的交付段序号（与朗读定位同口径）：该 requestId 已落盘的
  /// 栖语 turn 数（重放路径不进这里，活前缀轮恒从 0 起算，防御性取现值）。
  int _voiceDeliveryIndex(RawSession session, String requestId) => session.turns
      .where(
        (turn) => turn.requestId == requestId && turn.speaker == Speaker.qiyu,
      )
      .length;

  Stream<ChatDeliveryEvent> _deliver({
    required String requestId,
    required String text,
    required String? sessionId,
    required DeliveryCancellation cancellation,
    String locale = 'zh',
  }) async* {
    final trimmedRequestId = requestId.trim();
    final trimmedText = sanitizeUserInput(text);
    final bedtime = bedtimeSignalPattern.hasMatch(trimmedText);
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
      yield* _OutcomeDelivery(
        session: session,
        result: _storedResult(session, existingReply),
        cancellation: cancellation,
        repository: _repository,
        clock: _clock,
        deliveryPause: _deliveryPause,
      ).events();
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
      ChatRequest(requestId: trimmedRequestId, text: trimmedText, locale: locale),
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
    // （含无可用 Provider 的常规轮）仍走终局交付（_OutcomeDelivery）
    // 的分片节奏。
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
      // 本轮注入过的召回临时材料：模型没真正收到本轮时经维护边界放回
      // （消费前已重核过，放回的是核验后的材料，下轮消费再核一次）。
      PendingRecallMaterial? consumedPendingMaterial;
      StreamedReplyOutcome? streamed;
      // 连续供给会话（票三）：Provider 分支进来时就绪，与文字流式共用
      // 同一个活前缀；拿不到音频块的档位这里是 null。开会话是网络 I/O
      // （WS 握手）——管线先就绪、会话 Future 由流式状态机挂进等待集
      // （迟到挂载），文字首字不等握手（票一「第一个字立刻开始出」
      // 不被语音握手抵消）。
      DeliveryVoiceHandoff? pendingVoice;
      try {
        final preparedPrompt = await _promptBuilderForRequest(session.id);
        requestBuilder = preparedPrompt.builder;
        consumedPendingMaterial = preparedPrompt.pendingMaterial;
        final prepared = await providerPort.prepareChatRequest();
        if (prepared != null) {
          // Provider 确实可用才准备语音：没配上时不白烧握手。
          pendingVoice = await _startVoiceStreamPipeline(
            session,
            trimmedRequestId,
          );
          // 流式段的全部状态与转移内收在状态机（票 09）：流内异常（含
          // 已吐出若干 delta 后才炸）由它自行收尾成半句/本地兜底，绝不
          // 在这里重置交付状态——否则半句与兜底话术会叠加显示。
          final machine = StreamedReplyMachine(
            prepared: prepared,
            messages: requestBuilder.build(
              state,
              trimmedText,
              hardRulesAddendum: prepared.hardRulesAddendum,
              at: pendingUserMoment,
              locale: locale,
            ),
            cancellation: cancellation,
            // 敏感输入（危机/医疗/法律/金融）的回复沿用现状：不分片
            // 停顿，整段一次到位。
            pace: outcome.safety == null,
            precomputedLocalOutcome: outcome,
            state: state,
            requestId: trimmedRequestId,
            sessionId: session.id,
            text: trimmedText,
            locale: locale,
            voice: pendingVoice,
            abandonVoice: _abandonVoiceStream,
            voiceSessionGrace: _voiceSessionGrace,
            deliveryPause: _deliveryPause,
            diagnosticsSink: _diagnosticsSink,
          );
          yield* machine.events();
          streamed = await machine.settled;
        }
      } on Object catch (error) {
        // 只有还没进流就炸的（提示词装配、能力快照）才在这里兜底：
        // 此时一个 delta 都没产出，本地兜底话术照旧分片上屏。
        _diagnosticsSink(
          'model dispatch error [$error] request=$trimmedRequestId',
        );
        streamed = StreamedReplyOutcome(
          result: fallbackOutcome(
            state,
            trimmedRequestId,
            trimmedText,
            FallbackReason.modelProvider,
            null,
            locale: locale,
          ),
        );
      } finally {
        // 模型流没开到（prepare/openStream 抛错）时会话还在途：作废并
        // 清表，绝不留继续烧配额的连接（正常轮次里状态机已收过一次，
        // abandon 幂等）。
        _abandonVoiceStream(pendingVoice);
      }
      // 模型没有真正收到本轮（本地兜底/取消）时，把已取用的短期
      // memory context 材料放回，留给下一轮注入；「晚一拍」允许再晚一拍。
      final modelSucceeded = streamed?.result?.source == ReplySource.llm;
      if (consumedPendingMaterial != null &&
          (!modelSucceeded || cancellation.isCancelled)) {
        memory.memoryRecall.restorePendingContext(
          session.id,
          consumedPendingMaterial,
        );
      }
      if ((streamed?.cancelled ?? false) || cancellation.isCancelled) {
        yield _cancelledEvent(trimmedRequestId, session.id);
        return;
      }
      // 没有可用 Provider（prepare 返回 null）时本轮就是普通本地兜底：
      // 沿用进入 Provider 分支前算好的本地结果，行为与今天一致。
      final streamedResult = streamed?.result;
      if (streamedResult != null) {
        hiddenActions = streamed!.hiddenActions;
        outcome = streamedResult;
        incomplete = streamed.incomplete;
        streamedDeltas = streamed.deltasDelivered;
      }
    }

    // 终局交付（票 09 出参盒消除）：事件流与落盘后的会话由同一对象
    // 交付——async* 无法返回值，落盘结果经 [_OutcomeDelivery.persisted]
    // 在事件流结束后取用，不再经过调用方持有的可变盒。
    final delivery = _OutcomeDelivery(
      session: session,
      result: outcome,
      cancellation: cancellation,
      persist: true,
      deltasDelivered: streamedDeltas,
      incomplete: incomplete,
      repository: _repository,
      clock: _clock,
      deliveryPause: _deliveryPause,
    );
    ChatDeliveryEvent? lastEvent;
    await for (final event in delivery.events()) {
      lastEvent = event;
      yield event;
    }
    if (lastEvent != null && lastEvent.kind == ChatDeliveryEventKind.done) {
      final completedSession = (await delivery.persisted)!;
      // 只有完整且最终被接受的模型回复才提交其隐藏动作：候选被行为
      // 核心拒绝（回退本地回复）时整体丢弃——不改控制记录、不写派生
      // 记忆、不触发轮内召回；协议失败留下的半句同样没有可提交的
      // 动作（文本如实落盘，动作不落地）；失败与取消的轮次根本没有
      // 可提交的动作。
      if (outcome.source == ReplySource.llm && !incomplete) {
        // 只有完整且最终被接受的模型回复才提交其隐藏动作：候选被行为
        // 核心拒绝（回退本地回复）时整体丢弃——不改控制记录、不写派生
        // 记忆、不触发轮内召回；协议失败留下的半句同样没有可提交的
        // 动作（文本如实落盘，动作不落地）；失败与取消的轮次根本没有
        // 可提交的动作。
        await _actionExecutor.applyActions(
          completedSession,
          trimmedRequestId,
          hiddenActions,
        );
      }
      // 对话自述称呼（用户说「以后叫我老王」）当轮生效：与用户明确
      // 纠正同一精神，用户当前明确说的话最高；本地降级轮同样生效。
      await _actionExecutor.applyAppellation(trimmedText, trimmedRequestId);
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
          locale: locale,
        );
      }
      memory.memoryCadence.onDeliveryComplete(bedtime: bedtime);
    }
  }

  /// 召回模型查找轮内循环（查找流程定稿 2026-08-16）：bubble 1 交付
  /// 之后，模型隐藏块里有 memory_recall 请求时，Host 读取两级索引请
  /// 模型定位，在窗口预算内命中就把 bubble 2 用同一套交付事件补上
  /// （同套安全校验，落为同一 requestId 的栖语 turn）；没赶上、被
  /// 停止或未命中时，压缩结果并入下一用户轮注入（现状路径）。组织
  /// 调用明确拒绝（票 01）时候选本轮不补气泡、下一轮也不留候选；
  /// 调用失败属于未完成判断，候选照旧并入下一轮，不误报为拒绝。
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
    required DeliveryCancellation cancellation,
    String locale = 'zh',
  }) async* {
    if (providerPort == null || outcome.safety != null || bedtime) {
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
    final recall = memory.memoryRecall;
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
      if (late.pendingMaterial != null) {
        recall.storePendingContext(session.id, late.pendingMaterial!);
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
      // 窗口超时或用户已停止：查找在后台继续，命中后的材料由
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
      if (result.pendingMaterial != null) {
        recall.storePendingContext(session.id, result.pendingMaterial!);
      }
      return;
    }

    // bubble 2 走与 bubble 1 同一套安全校验：行为核心拒绝候选时
    // 什么都不交付；压缩结果仍可留给下一轮。
    final validated = _behaviorCore.reply(
      ChatRequest(requestId: requestId, text: userText, locale: locale),
      state,
      candidateReply: bubbleText,
    );
    if (validated is! ChatResult || validated.source != ReplySource.llm) {
      _diagnosticsSink(
        'recall bubble dropped reason=validation request=$requestId',
      );
      if (result.pendingMaterial != null) {
        recall.storePendingContext(session.id, result.pendingMaterial!);
      }
      return;
    }
    // bubble 2 与 bubble 1 走同一套终局交付（票 09 归一）：重放与召回
    // 交付不取落盘结果，persisted 完成值无人等待。
    yield* _OutcomeDelivery(
      session: session,
      result: ChatResult(
        requestId: requestId,
        messages: validated.messages,
        nextState: validated.nextState,
        source: ReplySource.llm,
        mode: validated.mode,
      ),
      cancellation: cancellation,
      persist: true,
      repository: _repository,
      clock: _clock,
      deliveryPause: _deliveryPause,
    ).events();
  }

  /// 组装本轮 prompt builder：热层三块（【近况】、【长期印象】、
  /// 【用户画像】）的串行读取、既有记忆控制过滤与跨块预算协调全部
  /// 由 StatePackReader.readHotLayerBlocks 完成，这里只消费准备结果
  /// 并按部分成功语义装配（准备失败的块保持原值，已成功的部分不
  /// 撤销），读取失败只记诊断降级空块，绝不阻塞回复，也绝不新映射
  /// 成 Provider 错误。
  /// 同时消费该会话上一轮后台召回命中的短期 memory context（临时透镜，
  /// 只注入一次）：消费前由召回编排按当前来源重核材料，注入内容随核
  /// 验结果重新渲染；材料一并交还调用方，本轮没被模型真正消费时放回。
  Future<({ModelPromptBuilder builder, PendingRecallMaterial? pendingMaterial})>
  _promptBuilderForRequest(String sessionId) async {
    var builder = modelPromptBuilder;
    final prepared = await memory.statePackReader.readHotLayerBlocks();
    final failure = prepared.failure;
    if (failure != null) {
      _diagnosticsSink('state pack unavailable [$failure]');
    }
    builder = prepared.applyTo(builder);
    final consumed = await memory.memoryRecall.consumePendingContext(
      sessionId,
      onDiagnostic: _diagnosticsSink,
    );
    final material = consumed.material;
    final context = consumed.context;
    if (material != null && context != null) {
      builder = builder.copyWithMemoryContext(context);
      return (builder: builder, pendingMaterial: material);
    }
    return (builder: builder, pendingMaterial: null);
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

/// 终局交付（票 09 出参盒消除）：可见回复的事件序列与落盘由同一对象
/// 交付——async* 无法返回值，落盘后的会话经 [persisted] 在事件流结束
/// 后取用，不再经过调用方持有的可变盒。主聊天、重放与召回 bubble 三条
/// 路径共用同一份事件序列与分片节奏。
final class _OutcomeDelivery {
  _OutcomeDelivery({
    required this.session,
    required this.result,
    required this.cancellation,
    this.persist = false,
    this.deltasDelivered = false,
    this.incomplete = false,
    required this._repository,
    required this._clock,
    required DeliveryPause deliveryPause,
  }) : _pacing = DeliveryPacing(
         pause: deliveryPause,
         cancellation: cancellation,
       );

  final RawSession session;
  final ChatResult result;
  final DeliveryCancellation cancellation;

  /// 是否把可见回复落盘为新的栖语 turn（重放路径只重发事件不落盘）。
  final bool persist;

  /// 本轮是否真的吐出过流式 delta：吐过就不再重复分片，只补 message
  /// 与收尾事件；本地兜底、召回 bubble 与重放仍走完整分片节奏。
  final bool deltasDelivered;
  final bool incomplete;

  final MemoryRepository _repository;
  final Clock _clock;
  final DeliveryPacing _pacing;
  final Completer<RawSession?> _persisted = Completer<RawSession?>();

  /// 落盘后的会话快照：事件流结束后取用。未落盘（persist=false 或
  /// 事件序列未走完）时完成值为 null。
  Future<RawSession?> get persisted => _persisted.future;

  Stream<ChatDeliveryEvent> events() => _events();

  Stream<ChatDeliveryEvent> _events() async* {
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
      for (final chunk in _visibleChunks(result.messages)) {
        if (!await _pacing.beforeChunk(paced: result.safety == null)) {
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
    _persisted.complete(completedSession);
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
    for (var offset = 0; offset < runes.length; offset += deliveryChunkRunes) {
      final end = offset + deliveryChunkRunes < runes.length
          ? offset + deliveryChunkRunes
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
