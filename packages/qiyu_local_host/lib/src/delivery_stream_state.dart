// 交付管线的流式段（票 09）：模型回复的流式交付收成一个显式状态机。
// 状态转移（终止/EOF/失败/取消）、分片节奏、原始长度上限引用、分句与
// 语音会话交接全部内收在本文件——交付编排只经单一入口订阅事件流，
// 内部细节不再是调用者知识。
import 'dart:async';
import 'dart:convert';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'model_gateway.dart';
import 'provider_settings_service.dart';
import 'tts_gateway.dart';
import 'voice_stream_pipeline.dart';

/// 交付节奏的等待注入点：测试用它把停顿换成立即完成或门闩，观察
/// 分片节奏而不真等。
typedef DeliveryPause = Future<void> Function(Duration duration);

/// 交付节奏的唯一真源（票 09 归口）：分片大小（runes）与相邻两片
/// 之间的停顿。流式活前缀与终局分片共用这份常量——改一边不会漏
/// 另一边。
const deliveryChunkRunes = 12;
const deliveryChunkPause = Duration(milliseconds: 70);

/// 一次聊天的取消信号：取消语义只交付 cancelled 事件，不带任何内容。
/// 交付与取消之间的全部竞速（分片停顿、模型读取、语音等待）共用这
/// 一个 Future。
final class DeliveryCancellation {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// 分批吐字的节奏执行体（票 09 归一）：首块不停顿，其余每片前按步长
/// 停顿并与取消竞速。流式活前缀与终局交付的分片共用这同一份实现，
/// 节奏只有这一份。取消后的可见后果（静默收尾或 cancelled 事件）由
/// 调用方按所在段决定，这里只回报「还能不能继续吐」。
final class DeliveryPacing {
  DeliveryPacing({required this._pause, required this._cancellation});

  final DeliveryPause _pause;
  final DeliveryCancellation _cancellation;
  bool _firstChunk = true;

  /// 吐出下一片前的等待：首块直接放行；其后按步长停顿并与取消竞速。
  /// 返回 false 表示取消已生效，调用方停止吐字。
  Future<bool> beforeChunk({required bool paced}) async {
    if (!_firstChunk && paced) {
      await Future.any<void>([
        _pause(deliveryChunkPause),
        _cancellation.whenCancelled,
      ]);
    }
    _firstChunk = false;
    return !_cancellation.isCancelled;
  }
}

/// 流式段与语音管线的交接面（票 09 内收）：连续供给会话（票三）的
/// 管线先就绪并登记（停止信号按 requestId 定位），会话 Future 由流式
/// 状态机挂进等待集（迟到挂载）——文字首字不等握手。登记表与作废
/// 出口留在服务侧，状态机只经注入的作废回调收尾。
final class DeliveryVoiceHandoff {
  DeliveryVoiceHandoff({
    required this.pipeline,
    required this.requestId,
    this.openSession,
  });

  final VoiceStreamPipeline pipeline;
  final String requestId;

  /// 开会话的 Future（迟到挂载）：null 表示档位不开会话（票二分句
  /// 模式，管线即刻可用）。
  final Future<VoiceStreamSession?>? openSession;
}

/// 语音管线推进信号（票二）：与模型增量、取消一起进 [Future.any]，
/// 同一个字符串哨兵区分「哪一路先到」——语音块先到就继续搭车，模型
/// 增量先到就照常处理文字。
const _voiceProgress = 'voice-progress';

/// 连续供给会话落定信号（票三 迟到挂载）：与模型增量、取消、语音块
/// 推进同台竞争——文字首字不等会话握手。
const _voiceSessionReady = 'voice-session-ready';

/// 流式段的终局结论（票 09 出参盒消除）：状态机内部不可变地组装，经
/// [StreamedReplyMachine.settled] 在事件流结束后交付——delta 事件在
/// 流内边收边送，最终回复、协议失败留下的半句（[incomplete]）或本地
/// 兜底三选一；取消只置位 [cancelled]。
final class StreamedReplyOutcome {
  const StreamedReplyOutcome({
    this.result,
    this.deltasDelivered = false,
    this.hiddenActions = const [],
    this.incomplete = false,
    this.cancelled = false,
  });

  /// 最终回复（完整、半句或本地兜底）。取消竞速出口没有可交付的
  /// 回复，为 null。
  final ChatResult? result;

  /// 本轮是否真的吐出过 delta：只有吐过才由流式路径负责交付序列，
  /// 零可见文字的本地兜底轮仍走终局交付的分片节奏。
  final bool deltasDelivered;
  final List<HiddenAction> hiddenActions;
  final bool incomplete;
  final bool cancelled;
}

/// 流式段的显式状态（票 09）：泵（搭车语音、分派）、分片上屏、收尾、
/// 终局排残与落定。全部转移都在 [StreamedReplyMachine] 内部完成，
/// 转移面只有这五态。
enum _StreamPhase {
  /// 泵状态：搭车语音块与失败提示，按在途缓冲分派下一个状态。
  pumping,

  /// 活前缀分片上屏（在途读取继续挂着，不被分片打断）。
  draining,

  /// 协议终止或失败后的交接：补结尾行、宽限挂载会话、等语音收尾。
  finishing,

  /// 终局排残：把在途活前缀（含结尾行）按同一节奏吐完。
  drainingTail,

  /// 终局已定。
  settled,
}

/// 流式交付一轮模型回复的显式状态机（票 09）：Provider 增量到达后经
/// [CandidateReplyStream] 做增量卫生处理，通过的前缀立即按既有节奏
/// （12 runes/70ms）以 delta 事件上屏；协议原生终止标记才收尾落盘。
/// 取消沿用现状语义（只交付 cancelled 事件）；协议失败分叉——还没有
/// 任何可见文字时走本地兜底，已有可见文字时把已显示部分作为该轮最终
/// 回复交付并落盘（带「未完成」标记，不补全不伪装）。
///
/// 语音（票二）：同一个活前缀每出一个完整句就进分句合成，PCM 音频块
/// 经 [VoiceStreamPipeline] 按序搭车本事件流（voiceChunk），一句失败即
/// 本段语音结束（voiceError，D1）；块全部吐完才终局，刷新/重启的重放
/// 路径不进这里，幂等与今天一致。连续供给（票三）：档位开了 WS 会话时
/// 同一活前缀的增量原文直接进会话（不等标点），音频块按到达序搭车——
/// 泵状态的搭车口形状不变，模式选择在管线内部。
final class StreamedReplyMachine {
  StreamedReplyMachine({
    required this.prepared,
    required this.messages,
    required this.cancellation,
    required this.pace,
    required this.precomputedLocalOutcome,
    required this.state,
    required this.requestId,
    required this.sessionId,
    required this.text,
    this.locale = 'zh',
    required this.voice,
    required this.abandonVoice,
    required this.voiceSessionGrace,
    required DeliveryPause deliveryPause,
    required this._diagnosticsSink,
  }) : _pacing = DeliveryPacing(
         pause: deliveryPause,
         cancellation: cancellation,
       );

  /// 打开流的方式（Provider 能力快照）：协议适配、终止判定、错误分类
  /// 与取消下传全部在快照与网关内部完成，状态机只消费事件流。
  final PreparedProviderChatRequest prepared;
  final List<ModelMessage> messages;
  final DeliveryCancellation cancellation;

  /// 敏感输入（危机/医疗/法律/金融）的回复沿用现状：不分片停顿，
  /// 整段一次到位。
  final bool pace;

  /// 调用方预计算的本地结果：拿不到可用流时本轮就是普通本地兜底
  /// （危机输入→热线兜底、常规输入→极简回复），不另发明原因值。
  final ChatResult precomputedLocalOutcome;
  final StateSnapshot state;
  final String requestId;
  final String sessionId;
  final String text;
  final String locale;
  final DeliveryVoiceHandoff? voice;

  /// 语音收尾出口（正常/取消/异常同一出口）：作废在途会话并注销登记。
  /// 登记表在服务侧，状态机只经它作废，语音绝不比文字多活一刻。
  final void Function(DeliveryVoiceHandoff? voice) abandonVoice;
  final Duration voiceSessionGrace;
  final DeliveryPacing _pacing;
  final void Function(String message) _diagnosticsSink;

  final Completer<StreamedReplyOutcome> _settled =
      Completer<StreamedReplyOutcome>();
  bool _eventsTaken = false;

  // ── 流式段状态（票 09 内收）：以下字段只属于状态机，调用者不可见。
  final StringBuffer _raw = StringBuffer();
  final CandidateReplyStream _visible = CandidateReplyStream();
  final StringBuffer _outbox = StringBuffer();
  var _rawRunes = 0;
  var _terminated = false;
  var _eof = false;
  var _finalized = false;
  var _voiceErrorSent = false;
  var _cancelled = false;
  var _deltasDelivered = false;
  ModelFailureKind? _failure;
  ServiceErrorCategory? _serviceError;
  Future<VoiceStreamSession?>? _pendingSession;

  /// 终局结论：事件流结束后完成。取消竞速出口直接落定（无可交付
  /// 回复），其余出口按终局分类交付结论。
  Future<StreamedReplyOutcome> get settled => _settled.future;

  /// 对外唯一入口（票 09）：订阅即打开模型流并交付全套事件——增量、
  /// 语音搭车、取消与失败收尾；终局结论经 [settled] 取用。重复订阅
  /// 直接拒绝：单一事件流是结构保证，不靠约定。
  Stream<ChatDeliveryEvent> events() {
    if (_eventsTaken) {
      throw StateError('流式状态机的事件流只能订阅一次。');
    }
    _eventsTaken = true;
    return _events();
  }

  Stream<ChatDeliveryEvent> _events() async* {
    final stream = await prepared.openStream(
      messages,
      whenCancelled: cancellation.whenCancelled,
    );
    if (stream == null) {
      // 拿不到可用流：本轮就是普通本地兜底。语音管线（可能在途的
      // 会话）作废并清表，不白留一条连接。
      abandonVoice(voice);
      _settled.complete(StreamedReplyOutcome(result: precomputedLocalOutcome));
      return;
    }
    final cursor = _ModelEventCursor(stream);
    final voicePipeline = voice?.pipeline;
    _pendingSession = voice?.openSession;
    try {
      var phase = _StreamPhase.pumping;
      while (phase != _StreamPhase.settled) {
        switch (phase) {
          case _StreamPhase.pumping:
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
                !_voiceErrorSent) {
              // D1：已到的块都在上面吐完了才报失败——顺序上「先有声、
              // 后提示」，提示口径由界面按同会话首次一次落地。
              _voiceErrorSent = true;
              yield ChatDeliveryEvent.voiceError(
                requestId: requestId,
                sessionId: sessionId,
                deliveryIndex: voicePipeline.deliveryIndex,
              );
            }
            if (_outbox.isNotEmpty) {
              phase = _StreamPhase.draining;
            } else if (_terminated || _failure != null) {
              phase = _StreamPhase.finishing;
            } else {
              phase = await _readNext(cursor, voicePipeline);
            }
          case _StreamPhase.draining:
            // 在途活前缀的分片上屏：取下一块就立刻吐，绝不让已到来的
            // 文字排在还没到来的模型增量后面。取消生效时回到泵状态——
            // 在途的读取与语音搭车照常收口，由取消竞速出口统一落定。
            final chunk = _takeRunes(_outbox, deliveryChunkRunes);
            if (!await _pacing.beforeChunk(paced: pace)) {
              _cancelled = true;
              phase = _StreamPhase.pumping;
            } else {
              _deltasDelivered = true;
              yield ChatDeliveryEvent.delta(
                requestId: requestId,
                sessionId: sessionId,
                text: chunk,
              );
              phase = _outbox.isNotEmpty
                  ? _StreamPhase.draining
                  : _StreamPhase.pumping;
            }
          case _StreamPhase.finishing:
            phase = await _finish(voicePipeline);
          case _StreamPhase.drainingTail:
            // 终局后排空在途活前缀：节奏不变，用户看到的吐字不跳字。
            // 结尾行的补完与分句层关闭已在收尾状态做过（[_finalized]），
            // 这里只剩把尾句文本分片吐完；语音块也已在进入终局排残前
            // 全部交付。缓冲为空（无结尾行可补、EOF 后无在途文字）直接
            // 落定，绝不发空 delta。
            if (_outbox.isEmpty) {
              phase = _StreamPhase.settled;
              break;
            }
            final chunk = _takeRunes(_outbox, deliveryChunkRunes);
            if (!await _pacing.beforeChunk(paced: pace)) {
              _cancelled = true;
              phase = _StreamPhase.settled;
            } else {
              _deltasDelivered = true;
              yield ChatDeliveryEvent.delta(
                requestId: requestId,
                sessionId: sessionId,
                text: chunk,
              );
              phase = _outbox.isNotEmpty
                  ? _StreamPhase.drainingTail
                  : _StreamPhase.settled;
            }
          case _StreamPhase.settled:
            break;
        }
      }
    } on Object catch (error) {
      // 流内异常（读取出错、分片停顿被打破等）：与原生 error 同判——
      // 已有可见文字留半句，没有则本地兜底。绝不向上抛：上层 catch 会
      // 把本地兜底话术再分片吐一遍，与半句叠加。
      _diagnosticsSink('model stream error [$error] request=$requestId');
      _failure ??= ModelFailureKind.provider;
    } finally {
      await cursor.cancel();
      // 语音收尾（正常/取消/异常同一出口）：作废在途会话并注销登记——
      // 正常轮次此时已自然结束，cancel 幂等；语音绝不比文字多活一刻。
      abandonVoice(voice);
    }
    if (!_settled.isCompleted) {
      _settled.complete(_settle());
    }
  }

  /// 泵状态的读取出口：与模型增量、取消、语音推进和迟到会话落定同台
  /// 竞速，胜者决定下一个状态。
  Future<_StreamPhase> _readNext(
    _ModelEventCursor cursor,
    VoiceStreamPipeline? voicePipeline,
  ) async {
    final read = cursor.next();
    final waits = <Future<Object?>>[
      // 迟到的连续供给会话（票三）排在读取之前：两者都已落定时先挂载
      // 再处理增量——首句文字不等握手，但会话就绪也不被增量挤掉。开会
      // 话失败同样走这条哨兵（错误在挂载处按 D1 处理，不当成模型流
      // 故障）。
      if (_pendingSession case final session?)
        session.then<Object?>(
          (_) => _voiceSessionReady,
          onError: (Object _) => _voiceSessionReady,
        ),
      read,
      cancellation.whenCancelled.then<Object?>((_) => null),
    ];
    // 语音管线只在没收尾时挂推进等待：已收尾还挂会空转；没挂也不丢
    // 块——下一个模型事件或取消都会把循环带回到泵状态的搭车口。
    if (voicePipeline != null && !voicePipeline.isFinished) {
      waits.add(
        voicePipeline.whenProgress().then<Object?>((_) => _voiceProgress),
      );
    }
    final moved = await Future.any<Object?>(waits);
    if (moved == null || cancellation.isCancelled) {
      await cursor.cancel();
      voicePipeline?.cancel();
      _cancelled = true;
      // 取消竞速出口直接落定：没有可交付的回复，终局分类不再执行。
      _settled.complete(
        StreamedReplyOutcome(
          cancelled: true,
          deltasDelivered: _deltasDelivered,
        ),
      );
      return _StreamPhase.settled;
    }
    if (identical(moved, _voiceSessionReady)) {
      // 会话落定即挂载（迟到挂载）：此后增量原文直接进 WS。
      await _attachVoiceSession(voicePipeline, _pendingSession);
      _pendingSession = null;
      return _StreamPhase.pumping;
    }
    if (identical(moved, _voiceProgress)) {
      return _StreamPhase.pumping;
    }
    cursor.advance();
    if (moved != true) {
      // 流干净关闭但没有任何协议终止标记：提前 EOF，按失败处理——
      // 直接进终局排残（收尾口的结尾行补完与语音等待都不再经过）。
      _eof = true;
      return _StreamPhase.drainingTail;
    }
    final event = cursor.current;
    switch (event.kind) {
      case ModelStreamEventKind.delta:
        _rawRunes += event.text!.runes.length;
        if (_rawRunes > maxModelReplyRunes) {
          await cursor.cancel();
          _failure = ModelFailureKind.incompatibleResponse;
          // 超限与终止同路：回泵状态走过搭车口与在途分片，再进收尾。
          return _StreamPhase.pumping;
        }
        _raw.write(event.text);
        // 同一个活前缀：文字分片与分句合成共用这一份通过卫生检查的
        // 增量，不二次解析最终文本。
        final safe = _visible.add(event.text!);
        _outbox.write(safe);
        voicePipeline?.addText(safe);
      case ModelStreamEventKind.done:
        _terminated = true;
      case ModelStreamEventKind.failure:
        _failure = event.failure!;
        _serviceError = event.serviceError;
    }
    return _StreamPhase.pumping;
  }

  /// 收尾状态：模型流已终止或失败后的交接——补结尾行（一次）、迟到
  /// 会话的有界宽限挂载、等语音收尾。返回下一个状态。
  Future<_StreamPhase> _finish(VoiceStreamPipeline? voicePipeline) async {
    if (!_finalized) {
      // 活前缀收尾只做一次：补完结尾行（新增可见文本照样走分片节奏）
      // → 尾句进分句层 → 关闭（之后只剩等音频）。
      _finalized = true;
      final trailing = _visible.completeTrailingLine();
      _outbox.write(trailing);
      voicePipeline?.addText(trailing);
      voicePipeline?.close();
    }
    if (_pendingSession case final session?) {
      // 模型流已收尾、会话还没落定：有界宽限内落定即挂载——补喂缓冲
      // 文本并替会话收尾，尾块照常播完（短回复一次 delta 就 done，也
      // 不能整轮没声音）；宽限外落定才作废（语音没启动，不是失败，
      // 不发提示）。done 不被慢握手无限期拖住。
      final settledSignal = await Future.any<Object?>([
        session.then<Object?>(
          (_) => _voiceSessionReady,
          onError: (Object _) => _voiceSessionReady,
        ),
        Future<void>.delayed(voiceSessionGrace).then<Object?>((_) => null),
      ]);
      if (identical(settledSignal, _voiceSessionReady)) {
        await _attachVoiceSession(voicePipeline, session);
      } else {
        session.then((opened) => opened?.cancel(), onError: (_) {});
        voicePipeline?.abandonPendingSession();
      }
      _pendingSession = null;
    }
    if (voicePipeline == null || voicePipeline.isFinished) {
      return _StreamPhase.drainingTail;
    }
    // 模型流已终止、语音分句还在途：块继续搭车，等它收尾再终局
    // （done 之前用户能听到最后几句）。
    await voicePipeline.whenProgress();
    return _StreamPhase.pumping;
  }

  /// 迟到的连续供给会话落定（票三）：挂载到管线。返回的 Future 已由
  /// [Future.any] 判定胜出，await 立即完成；失败按 D1 同口径标记（提示
  /// 一次、文字不受影响），返回 null（档位不支持 WS / E1）时管线回落
  /// 票二分句模式。模型流已收尾/已停止时才落定＝直接作废会话（语音没
  /// 启动，不是失败，由管线内部判定）。
  Future<void> _attachVoiceSession(
    VoiceStreamPipeline? pipeline,
    Future<VoiceStreamSession?>? session,
  ) async {
    if (pipeline == null || session == null) {
      return;
    }
    final VoiceStreamSession? opened;
    try {
      opened = await session;
    } on Object {
      // 开会话失败：诊断已由开启方记录，这里只按 D1 口径标记。
      pipeline.markSessionFailed();
      return;
    }
    pipeline.attachSession(opened);
  }

  /// 流式终局收尾：隐藏动作协议与可见文本严格分离后，按「有没有
  /// 可见文字」分叉——有就作为该轮最终回复（半句带未完成标记），
  /// 没有就走本地兜底路径。
  StreamedReplyOutcome _settle() {
    // 隐藏动作只在 runtime 内部流转，绝不进入交付事件。
    final parsed = parseHiddenActions(_raw.toString());
    for (final diagnostic in parsed.diagnostics) {
      _diagnosticsSink(
        'hidden-action dropped [$diagnostic] request=$requestId',
      );
    }
    final messages = _visible.finalizeMessages();
    // 提前 EOF 与原生 error 同判失败：有可见文字留半句，没有则本地兜底。
    final effectiveFailure =
        _failure ??
        (_eof && !_visible.rejected
            ? (messages.isEmpty
                  ? ModelFailureKind.contentParsing
                  : ModelFailureKind.network)
            : null);
    final complete = effectiveFailure == null && !_visible.rejected;
    if (complete && messages.isNotEmpty) {
      return StreamedReplyOutcome(
        result:
            _behaviorCore.reply(
                  ChatRequest(requestId: requestId, text: text),
                  state,
                  candidateReply: messages.join('\n'),
                )
                as ChatResult,
        hiddenActions: parsed.actions,
        deltasDelivered: _deltasDelivered,
        cancelled: _cancelled,
      );
    }
    final reason = effectiveFailure == null
        ? (_visible.rejected
              ? FallbackReason.invalidModelResponse
              : FallbackReason.emptyModelReply)
        : fallbackReasonFor(effectiveFailure);
    if (messages.isNotEmpty) {
      // 半句如实：失败原因只进本机诊断，页面不弹错、不追加兜底话术。
      _diagnosticsSink(
        'model stream incomplete [${reason.wireName}] request=$requestId',
      );
      return StreamedReplyOutcome(
        // 半句同样带服务故障类别：state 事件有该字段，带上不破坏「不弹
        // 错误框、不追加兜底话术」的口径。
        result: chatResultWithServiceError(
          _behaviorCore.reply(
                ChatRequest(requestId: requestId, text: text, locale: locale),
                state,
                candidateReply: messages.join('\n'),
              )
              as ChatResult,
          _serviceError,
        ),
        incomplete: true,
        deltasDelivered: _deltasDelivered,
        cancelled: _cancelled,
      );
    }
    return StreamedReplyOutcome(
      result: fallbackOutcome(
        state,
        requestId,
        text,
        reason,
        _serviceError,
        locale: locale,
      ),
      deltasDelivered: _deltasDelivered,
      cancelled: _cancelled,
    );
  }
}

/// 模型事件读取的单点句柄（票 09）：StreamIterator 在上一次 moveNext
/// 完成前再调一次会直接抛 StateError，真实模型流（等下一个增量）必然
/// 踩中。在途读取 Future 封装在本类内部——只有读取自己胜出才经
/// [advance] 清空重取，其余胜者（语音块、取消、会话落定）回到泵状态
/// 时复用同一次读取。这条约定由此成为类型保证，不再依赖注释纪律。
final class _ModelEventCursor {
  _ModelEventCursor(Stream<ModelStreamEvent> stream)
    : _iterator = StreamIterator<ModelStreamEvent>(stream);

  final StreamIterator<ModelStreamEvent> _iterator;
  Future<bool>? _inFlight;

  /// 发起（或复用在途）读取。
  Future<bool> next() => _inFlight ??= _iterator.moveNext();

  /// 读取自己胜出后清空在途句柄：下一次 [next] 才会真正重取。
  void advance() => _inFlight = null;

  /// 胜出读取拿到的事件（仅在 [next] 返回 true 后有效）。
  ModelStreamEvent get current => _iterator.current;

  /// 取消底层订阅：正常、取消与异常三条出口共用，重复调用无副作用。
  Future<void> cancel() => _iterator.cancel();
}

/// 从待吐缓冲头部取 [count] 个 runes：调用方以缓冲非空为前置条件。
String _takeRunes(StringBuffer buffer, int count) {
  final text = buffer.toString();
  final runes = text.runes.take(count).toList(growable: false);
  final taken = String.fromCharCodes(runes);
  buffer.clear();
  buffer.write(text.substring(taken.length));
  return taken;
}

/// 行为核心实例：状态机的候选校验与兜底话术和交付编排共用同一份人格
/// 与安全裁定（const 规范化后本就是同一实例）。
const _behaviorCore = QiyuBehaviorCore();

/// 本地兜底结果：行为核心按失败原因挑话术，服务故障类别随结果透出。
/// 派发兜底（提示词装配失败）与流式终局兜底共用这一份。
ChatResult fallbackOutcome(
  StateSnapshot state,
  String requestId,
  String text,
  FallbackReason reason,
  ServiceErrorCategory? serviceError, {
  String locale = 'zh',
}) {
  return chatResultWithServiceError(
    _behaviorCore.reply(
          ChatRequest(requestId: requestId, text: text, locale: locale),
          state,
          modelFailure: reason,
        )
        as ChatResult,
    serviceError,
  );
}

/// 给行为核心的结果补上服务故障类别（结果本体不变）：本地兜底与
/// 流式半句两条降级路径共用。
ChatResult chatResultWithServiceError(
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

FallbackReason fallbackReasonFor(ModelFailureKind failure) => switch (failure) {
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
