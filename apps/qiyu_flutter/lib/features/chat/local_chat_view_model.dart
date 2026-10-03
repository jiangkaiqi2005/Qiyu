import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:uuid/uuid.dart';

import '../baseline/host_api_gateway.dart';
import '../baseline/host_connection_probe.dart';
import '../baseline/background_status_client.dart';
import '../settings/tts_settings_client.dart';
import '../shell/host_status_monitor.dart';
import '../shell/qiyu_strings.dart';
import 'chat_delivery_assembly.dart';
import 'local_chat_client.dart';
import 'omni_call_controller.dart';
import 'voice_output_controller.dart';

typedef RequestIdFactory = String Function();

enum ChatSendStatus {
  notAccepted,
  acceptedIncomplete,

  /// 沿用交付语义：首段已完成后取消第二段，也保留完成结果。
  completed,
  staleSession,
}

/// 本次发送的草稿归属；拒绝或尚在排队时没有创建请求，requestId 为 null。
final class ChatSendResult {
  const ChatSendResult({required this.status, this.requestId});

  final ChatSendStatus status;
  final String? requestId;
}

/// 一轮聊天事务：从发送到事件流终结。等待指示、流式文本与交付段进度
/// 都属于事务自身；事务失效（新发送 / 恢复 / 丢弃会话）之后，旧流再来
/// 的事件整体丢弃——不写状态、不通知界面。
final class _ChatTurn {
  _ChatTurn({
    required this.generation,
    required this.requestId,
    required this.text,
    required bool accepted,
  }) : assembly = ChatDeliveryAssembly(requestId: requestId, accepted: accepted);

  /// 创建时取得的唯一代际标识：与视图模型的当前代数一致才允许落地。
  final int generation;
  final String requestId;
  final String text;

  bool waiting = false;
  String streamingText = '';
  final ChatDeliveryAssembly assembly;

  /// 流式期间已完结的行：终局文本按 '\n' 拆、除最后一段。流式前缀＝终局
  /// 文本前缀（协议保证），这样拆与 Host done 交付的按行拆分一致，视图
  /// 把完结行按最终消息的同一装配渲染，done 换届时几何不变。派生即得，
  /// 不另设状态同步。
  List<String> get completedLines {
    final text = streamingText;
    if (text.isEmpty) {
      return const [];
    }
    final lines = text.split('\n');
    return lines.sublist(0, lines.length - 1);
  }

  /// 流式正在增长的尾段（最后一段，可能为空）：留在临时行，live region
  /// 标签跟它走。
  String get tailSegment {
    final text = streamingText;
    if (text.isEmpty) {
      return '';
    }
    return text.substring(text.lastIndexOf('\n') + 1);
  }
}

final class LocalChatViewModel extends ChangeNotifier
    implements OmniCallChatSurface {
  LocalChatViewModel(
    this._gateway, {
    HostConnectionProbe? hostConnectionProbe,
    RequestIdFactory? requestIdFactory,
    TtsSettingsGateway? ttsSettingsGateway,
    BackgroundStatusGateway? backgroundStatusGateway,
    VoiceOutputController? voiceOutput,
    this._localeController,
    bool autoStart = true,
    Duration monitorInterval = const Duration(seconds: 2),
  }) : _requestIdFactory = requestIdFactory ?? _defaultRequestId,
       // ignore: prefer_initializing_formals
       _ttsSettingsGateway = ttsSettingsGateway,
       // 缺省独立创建朗读网关（与聊天网关同构；widget 测试注入桩）。
       voiceOutput =
           voiceOutput ?? VoiceOutputController(HttpLocalChatGateway()) {
    // 停播即通知 Host 作废在途分句合成（票二）：本地不出声了就不该
    // 继续烧 Provider 配额。与轮交付的取消路径分开。（构造体里
    // voiceOutput 指的是可空形参，字段要显式 this。）
    this.voiceOutput.onVoiceStopRequested = (requestId) {
      unawaited(_gateway.stopVoice(requestId));
    };
    // 连接探测轮询与后台失败状态的唯一所有者：计时器、重入保护、恢复
    // 提示窗口与对应生命周期都在监控模块内部，聊天事务只读它的结论。
    _hostMonitor = HostStatusMonitor(
      hostConnectionProbe: hostConnectionProbe,
      backgroundStatusGateway: backgroundStatusGateway,
      autoStart: autoStart,
      monitorInterval: monitorInterval,
    );
    _hostMonitor.addListener(_onHostMonitorChanged);
    _localeController?.addListener(notifyListeners);
    if (autoStart) {
      unawaited(initialize());
    }
  }

  final StreamingLocalChatGateway _gateway;
  final RequestIdFactory _requestIdFactory;
  final TtsSettingsGateway? _ttsSettingsGateway;
  final LocaleController? _localeController;
  String _locale = 'zh';

  String get locale => _localeController?.locale ?? _locale;
  bool get isZh => locale == 'zh';
  bool get isEn => locale == 'en';

  void setLocale(String next) {
    if (locale == next) return;
    if (_localeController != null) {
      _localeController.setLocale(next);
    } else {
      _locale = next;
      notifyListeners();
    }
  }

  void toggleLocale() {
    setLocale(isZh ? 'en' : 'zh');
  }

  /// 连接与后台状态监控（阶段 C 收拢）：周期轮询计时器、连接三态、后台
  /// 失败快照与恢复提示窗口的唯一所有者。壳层装配仍经本视图模型读取
  /// （对外 getter 原样保留），内部不存在第二份轮询状态。
  late final HostStatusMonitor _hostMonitor;

  /// 监控的状态变化按原语义透传给界面：监控只在连接三态或后台状态实际
  /// 变化时通知，这里不做第二次去重。
  void _onHostMonitorChanged() {
    notifyListeners();
  }

  /// 语音朗读播放队列（ADR 0002）：view 观察它渲染「正在朗读」指示与
  /// 停止按钮。
  final VoiceOutputController voiceOutput;
  bool _voiceOutputEnabled = false;
  bool _voiceOutputConfigured = false;
  final Map<String, int> _announcedDeliveries = {};

  /// 已流过式语音的交付段（票二，requestId#deliveryIndex）：done 时
  /// 据此跳过整段重合成，同一段话不响两遍。
  final Set<String> _voiceStreamedDeliveries = {};
  final List<LocalChatMessage> _messages = [];
  String? _sessionId;
  String? _errorMessage;
  bool _initializing = false;
  bool _initialized = false;

  /// initialize 是否至少启动过（含 hostStopped 早退）：页面挂载补拉据此
  /// 跳过与 initialize 自带刷新的并发重复。只做观测记录，不动重入门控
  /// ——[_initialized] 仍只在恢复完成时置位。生产 autoStart 在构造期即
  /// 置位，首挂载补拉照常发生（与 initialize 自带刷新并发共读两次，
  /// 幂等）；门控实际只在测试装配（autoStart:false 且未显式 initialize）
  /// 下拦截。
  bool _everRanInitialize = false;

  /// 唯一代数计数器：新发送、会话恢复与丢弃会话都推进它；原恢复代数
  /// 并入这里，不再有两套代际。
  int _generation = 0;

  /// 发送结果与排队语音的会话归属；普通新轮不改变它，恢复/丢弃才使其失效。
  Object _sessionScope = Object();

  /// 当前活跃事务。为 null 即不在发送之中（事务完成、失败或被新一代
  /// 取代都置空），`sending` / `waiting` / `streamingText` 都由它派生。
  _ChatTurn? _activeTurn;
  String? _pendingRequestId;
  String? _pendingText;

  List<LocalChatMessage> get messages => List.unmodifiable(_messages);
  String? get sessionId => _sessionId;
  String? get errorMessage => _errorMessage;
  bool get loading => _initializing && !_initialized;
  bool get sending => _activeTurn != null;
  bool get waiting => _activeTurn?.waiting ?? false;

  /// Omni 通话回复的在途文本（T04）：通话事件经 [OmniCallChatSurface]
  /// 写入同一套流式行与消息列表；打字轮（/api/chat）与通话流互斥——
  /// 通话中打字走通话线协议，不再进 [_activeTurn]。
  String _callStreamingText = '';
  int _callBubbleCounter = 0;

  String get streamingText => _activeTurn?.streamingText ?? _callStreamingText;

  /// 流式期间已完结的行：视图按最终消息的同一装配渲染（拆分口径见
  /// [_ChatTurn.completedLines]）。通话流沿用同一拆分。
  List<String> get streamingCompletedLines =>
      _activeTurn?.completedLines ?? _callCompletedLines;

  /// 通话流式的已完结行：与 [_ChatTurn.completedLines] 同一口径。
  List<String> get _callCompletedLines {
    final text = _callStreamingText;
    if (text.isEmpty) {
      return const [];
    }
    final lines = text.split('\n');
    return lines.sublist(0, lines.length - 1);
  }

  /// 流式正在增长的尾段：留在临时行渲染（见 [_ChatTurn.tailSegment]）。
  String get streamingTailSegment =>
      _activeTurn?.tailSegment ??
      (_callStreamingText.isEmpty
          ? ''
          : _callStreamingText.substring(
              _callStreamingText.lastIndexOf('\n') + 1,
            ));
  bool get hostStopped => _hostMonitor.hostAvailable == false;

  /// 最近一次已完成的栖语回复的 fallbackReason。
  FallbackReason? get latestFallbackReason {
    final last = _messages.lastOrNull;
    if (last == null || last.speaker != LocalChatSpeaker.qiyu) {
      return null;
    }
    return last.fallbackReason;
  }

  /// 最近一次已完成回复的安全服务故障类别。
  ServiceErrorCategory? get latestServiceError {
    final last = _messages.lastOrNull;
    return last?.speaker == LocalChatSpeaker.qiyu ? last?.serviceError : null;
  }

  /// 代际归属校验：所有界面状态写入与副作用落地前先过这一关。新发送 /
  /// 恢复 / 丢弃会话推进代数或取代活跃事务后，旧事务的任何事件都整体丢弃。
  bool _belongsToActiveGeneration(_ChatTurn turn) =>
      identical(_activeTurn, turn) && turn.generation == _generation;

  /// 本机 Host 是否**已经探过一次**：true 之后 [hostStopped] 才是可信结论。
  /// 探测结果三态（未探明 / 可用 / 不可用）里只有后两态可以拿去宣称，
  /// 「未探明」既不能说正常、也不能说故障。
  bool get hostStatusKnown => _hostMonitor.hostAvailable != null;

  /// 当前需要提示的后台失败（ticket 21，未恢复才计）：null 即没有，
  /// 壳层安静位整体不出现。
  BackgroundFailureStatus? get backgroundFailure =>
      _hostMonitor.backgroundFailure;

  /// 失败恢复后的短暂提示窗口：「已恢复」展示一会儿再隐去，由监控模块
  /// 计时；窗口只在「此前真的展示过失败」时开启。
  bool get backgroundRecoveredNotice => _hostMonitor.backgroundRecoveredNotice;

  /// 合一页（design-system §5）的**空状态 = 首页**唯一判定：一条消息都还没有、
  /// 不在等待与流式之中，**且会话已经恢复完**。
  ///
  /// `loading` 必须在闸内：旧会话恢复期间 `messages` 暂时为空，如果这时算空态，
  /// 打开应用会先闪一帧首页（背景 + 问候 + 居中 composer）再跳回消息流。
  bool get isHomeState =>
      !loading && messages.isEmpty && !waiting && streamingText.isEmpty;

  /// 「本地规则回复」标识只描述最近一次已完成且未开启新交互的栖语回复：
  /// 在发送与等待流式期间不展示过期的 fallback 状态；仅当最后一条消息
  /// 确为栖语的已完成本地规则回复时才显示。
  bool get hasLocalFallback {
    if (sending) {
      return false;
    }
    final last = _messages.lastOrNull;
    if (last == null || last.speaker != LocalChatSpeaker.qiyu) {
      return false;
    }
    return last.source == ReplySource.local;
  }

  /// 本轮用户 turn 的判定与失败回退：乐观插入去重、accepted 去重与
  /// 异常清理共用同一口径。
  bool _hasUserTurn(String requestId) => _messages.any(
    (message) =>
        message.requestId == requestId &&
        message.speaker == LocalChatSpeaker.user,
  );

  void _removeUserTurn(String requestId) => _messages.removeWhere(
    (message) =>
        message.requestId == requestId &&
        message.speaker == LocalChatSpeaker.user,
  );

  /// 直播流新消息的前端时钟预显时刻：Host 落盘权威值要等刷新或恢复
  /// 才换上来，分钟粒度下两边不会可见地跳变——预显先保住消息在发送
  /// 瞬间就有时刻，不必等落盘往返。
  DateTime get _previewMoment => DateTime.now();

  /// 流式完结行气泡的时刻：与最终消息同一预显来源（[_previewMoment]），
  /// 分钟粒度下与 done 落盘的权威时刻不会可见地跳变。
  DateTime get previewMoment => _previewMoment;

  /// 翻代前释放旧事务的流式语音占位。只按旧 requestId 定域：恢复或
  /// 丢弃会话可能打断 startStream 失败后的等待窗，旧流不会再收到
  /// done/EOF 终局；不显式释放会让隐藏 `_stream` 堵死后续自动朗读。
  void _releaseVoiceStreamFor(_ChatTurn? turn) {
    final requestId = turn?.requestId;
    if (requestId == null) {
      return;
    }
    voiceOutput.stopStream(requestId: requestId);
  }

  Future<void> initialize() async {
    if (_initializing || _initialized) {
      return;
    }
    _initializing = true;
    _everRanInitialize = true;
    final supersededTurn = _activeTurn;
    _sessionScope = Object();
    _generation += 1;
    final generation = _generation;
    _activeTurn = null;
    _releaseVoiceStreamFor(supersededTurn);
    // 初始化即翻篇：流式语音账本与交付计数都随恢复重算（见
    // _applyRestore）。
    _voiceStreamedDeliveries.clear();
    notifyListeners();
    try {
      unawaited(refreshVoiceOutputStatus());
      await checkHostNow();
      if (hostStopped) {
        return;
      }
      await _applyRestore(generation, sessionId: _sessionId);
    } finally {
      if (generation == _generation) {
        _initializing = false;
        notifyListeners();
      }
    }
  }

  /// 页面挂载时的朗读状态补拉：go 导航（侧边栏/抽屉换栈）会销毁重建
  /// 聊天页 State，「回到聊天页」的路由监听帮不上忙，挂载即拉一次。VM
  /// 还没启动过 initialize 时不补——initialize 自带一次刷新（测试装配
  /// 的显式刷新同理），避免与它并发重复读本机 GET；生产 autoStart 下
  /// 首挂载补拉照常发生，与 initialize 的刷新并发共读两次，幂等可接受。
  Future<void> refreshVoiceOutputStatusOnMount() async {
    if (!_everRanInitialize) {
      return;
    }
    await refreshVoiceOutputStatus();
  }

  /// 朗读可用性：配了语音合成且自动朗读开着才触发（ADR 0002：配置了
  /// 就自动读，聊天页开关写 Host 的 autoSpeak 位）。Host 不可达或未
  /// 配置时按关闭处理——读不出来不影响文字主链路。
  Future<void> refreshVoiceOutputStatus() async {
    final gateway = _ttsSettingsGateway;
    if (gateway == null) {
      return;
    }
    try {
      final settings = await gateway.read();
      _voiceOutputConfigured = settings.configured;
      _voiceOutputEnabled = settings.configured && settings.autoSpeak;
    } on Object {
      _voiceOutputConfigured = false;
      _voiceOutputEnabled = false;
    }
    notifyListeners();
  }

  /// 是否配了语音合成（聊天页据此显示/隐藏朗读开关）。
  bool get voiceOutputConfigured => _voiceOutputConfigured;

  /// 自动朗读开关状态（写 Host 的 tts.autoSpeak，刷新重启都记住）。
  bool get voiceOutputEnabled => _voiceOutputEnabled;

  Future<void> toggleVoiceOutput() async {
    final gateway = _ttsSettingsGateway;
    if (gateway == null || !_voiceOutputConfigured) {
      return;
    }
    try {
      await gateway.setAutoSpeak(!_voiceOutputEnabled);
      await refreshVoiceOutputStatus();
    } on Object {
      // 开关写失败：保持原状态，不打扰聊天主链路。
    }
  }

  /// 气泡重听：与自动朗读复用当前会话定位，避免同一会话因 null
  /// sessionId 被误判成新会话并重置首次失败提示。
  void replayVoiceOutput(LocalChatMessage message) {
    final deliveryIndex = message.deliveryIndex;
    if (message.speaker != LocalChatSpeaker.qiyu || deliveryIndex == null) {
      return;
    }
    voiceOutput.playNow(
      VoiceOutputRequest(
        requestId: message.requestId,
        deliveryIndex: deliveryIndex,
        sessionId: _sessionId,
      ),
    );
  }

  Future<void> _applyRestore(int generation, {String? sessionId}) async {
    try {
      final snapshot = await _gateway.restore(sessionId: sessionId);
      if (generation != _generation) {
        return;
      }
      // 恢复快照定义新一代：仍挂在旧事务上的流式状态随之失效。
      _activeTurn = null;
      _sessionId = snapshot.sessionId;
      // 历史栖语消息也标注 deliveryIndex（同 requestId 内第 N 个栖语
      // turn，与 Host 朗读定位同口径、从 0 起）：恢复的气泡同样能点
      // 小喇叭重听（重听=重新合成，文字都在）。
      final deliveryCounts = <String, int>{};
      final restored = <LocalChatMessage>[];
      for (final message in snapshot.messages) {
        if (message.speaker != LocalChatSpeaker.qiyu) {
          restored.add(message);
          continue;
        }
        final delivery = deliveryCounts[message.requestId] ?? 0;
        deliveryCounts[message.requestId] = delivery + 1;
        restored.add(
          LocalChatMessage(
            requestId: message.requestId,
            speaker: message.speaker,
            text: message.text,
            source: message.source,
            fallbackReason: message.fallbackReason,
            serviceError: message.serviceError,
            deliveryIndex: delivery,
            at: message.at,
          ),
        );
      }
      _messages
        ..clear()
        ..addAll(restored);
      // 交付计数与已展示消息对齐：恢复后同一 requestId 的新交付段接着
      // 计数，朗读定位不撞号。
      _announcedDeliveries
        ..clear()
        ..addAll(deliveryCounts);
      // 流式语音账本随恢复翻篇：恢复出来的历史段没有直播块，旧账本
      // 只会让同 requestId 的新交付被误判成「播过」而跳过整段朗读。
      _voiceStreamedDeliveries.clear();
      final lastMessage = _messages.isEmpty ? null : _messages.last;
      if (lastMessage?.speaker == LocalChatSpeaker.user) {
        _pendingRequestId = lastMessage!.requestId;
        _pendingText = lastMessage.text;
      } else {
        _pendingRequestId = null;
        _pendingText = null;
      }
      _errorMessage = null;
      _initialized = true;
      notifyListeners();
    } on Object catch (error) {
      if (generation != _generation) {
        return;
      }
      _errorMessage = _readableError(error);
      notifyListeners();
    }
  }

  Future<LocalChatSnapshot> readSession(String sessionId) =>
      _gateway.restore(sessionId: sessionId);

  Future<void> discardSession(String sessionId) async {
    if (_sessionId != sessionId) {
      return;
    }
    _sessionScope = Object();
    final supersededTurn = _activeTurn;
    _generation += 1;
    final generation = _generation;
    // 旧事务随代数失效：等待指示与流式半句一并消失，发送锁同时释放。
    _activeTurn = null;
    _releaseVoiceStreamFor(supersededTurn);
    _sessionId = null;
    _messages.clear();
    _pendingRequestId = null;
    _pendingText = null;
    _errorMessage = null;
    // 丢弃会话即翻篇：流式语音账本不清就会把新会话里同 requestId 的
    // 交付误判成「播过」（_applyRestore 也会清，这里先清保证同步语义）。
    _voiceStreamedDeliveries.clear();
    notifyListeners();
    await _applyRestore(generation);
  }

  /// 探测一次连接并顺带取后台失败状态：转发给监控模块（手动探测与周期
  /// 轮询共用同一条路径与重入保护），壳层重试入口与测试的既有入口不变。
  Future<void> checkHostNow() => _hostMonitor.checkHostNow();

  Future<ChatSendResult> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || sending || hostStopped) {
      return const ChatSendResult(status: ChatSendStatus.notAccepted);
    }
    final sessionScope = _sessionScope;
    if (_voiceOutputEnabled) {
      // send 由按钮/Enter 同步触发：先保住许可，再跨入聊天事件流。
      voiceOutput.prepareForUserInitiatedPlayback();
    }
    _errorMessage = null;
    final requestId = _pendingText == trimmed && _pendingRequestId != null
        ? _pendingRequestId!
        : _requestIdFactory();
    _pendingRequestId = requestId;
    _pendingText = trimmed;
    // 重发复用同一 requestId 开新轮（幂等）：上一轮被停播/取消后记账里
    // 的这个 requestId 已翻篇，不清掉新轮的直播块会被当成旧轮残块丢弃
    // ——首音提前静默失效，done 还多烧一次整段合成。
    voiceOutput.forgetStreamStop(requestId);
    // 「已流式播过」账本同理：只摘本次 requestId 的条目（键是
    // requestId#deliveryIndex，# 分隔保证不误伤 req-1 与 req-10 这类
    // 前缀相似的 id）——否则新轮直播块万一没被受理（播放器正被手动
    // 重听占着），done 会命中旧记录跳过整段入队，这段话彻底不出声。
    // 别的 requestId 的历史记录无辜，不整表清。
    _voiceStreamedDeliveries.removeWhere(
      (key) => key.startsWith('$requestId#'),
    );
    // 一轮聊天即一个事务：推进代数、接管活跃事务；此后凡是代际不符的
    // 事件一律整体丢弃。
    _generation += 1;
    final optimisticallyAdded = !_hasUserTurn(requestId);
    final turn = _ChatTurn(
      generation: _generation,
      requestId: requestId,
      text: trimmed,
      // 重试或恢复出的用户轮已经归会话保管，连接失败也不退回草稿。
      accepted: !optimisticallyAdded,
    );
    _activeTurn = turn;
    if (optimisticallyAdded) {
      _messages.add(
        LocalChatMessage(
          requestId: requestId,
          speaker: LocalChatSpeaker.user,
          text: trimmed,
          at: _previewMoment,
        ),
      );
    }
    notifyListeners();
    try {
      await _sendStreaming(
        turn,
        optimisticallyAdded: optimisticallyAdded,
      );
    } on Object catch (error) {
      if (_belongsToActiveGeneration(turn)) {
        _errorMessage = _readableError(error);
      }
    } finally {
      // 只有仍属当前代际的事务收尾：被恢复/丢弃取代后，新一代界面自己
      // 做主，旧事务的尾巴不再写状态、不再通知。
      if (_belongsToActiveGeneration(turn)) {
        _activeTurn = null;
        notifyListeners();
      }
    }
    final ChatSendStatus status;
    if (sessionScope != _sessionScope) {
      status = ChatSendStatus.staleSession;
    } else if (turn.assembly.hasCompleted) {
      status = ChatSendStatus.completed;
    } else if (turn.assembly.accepted) {
      status = ChatSendStatus.acceptedIncomplete;
    } else {
      status = ChatSendStatus.notAccepted;
    }
    return ChatSendResult(requestId: requestId, status: status);
  }

  Future<void> _sendStreaming(
    _ChatTurn turn, {
    required bool optimisticallyAdded,
  }) async {
    try {
      await for (final event in _gateway.deliver(
        requestId: turn.requestId,
        text: turn.text,
        sessionId: _sessionId,
        locale: locale,
      )) {
        // 写入前校验代际归属：新发送 / 恢复 / 丢弃会话之后，旧事务已经
        // 失效，它余下的事件整体丢弃——不写状态、不通知。
        if (!_belongsToActiveGeneration(turn)) {
          break;
        }
        final delivery = turn.assembly.add(event);
        _sessionId = turn.assembly.sessionId ?? _sessionId;
        switch (event.kind) {
          case LocalChatEventKind.accepted:
            if (!_hasUserTurn(turn.requestId)) {
              _messages.add(
                LocalChatMessage(
                  requestId: turn.requestId,
                  speaker: LocalChatSpeaker.user,
                  text: turn.text,
                  at: _previewMoment,
                ),
              );
            }
          case LocalChatEventKind.waiting:
            turn.waiting = true;
          case LocalChatEventKind.delta:
            turn.waiting = false;
            turn.streamingText += event.text!;
          case LocalChatEventKind.voiceChunk:
            // 语音块搭车（票二）：PCM 块进流式播放器、完整容器块（E1）
            // 进整段队列。文/音解耦——块丢失或播不出来都不影响文字显示。
            // 受理了才记「播过」账：未受理（被停播过、忙于别的音频）时
            // done 仍走整段入队；PCM 已受理但异步开流失败时，由控制器在
            // endStream 里补同一段的终局整段回退。
            final accepted = voiceOutput.offerStreamChunk(
              VoiceStreamChunk(
                requestId: event.requestId,
                deliveryIndex: event.deliveryIndex!,
                chunkIndex: event.chunkIndex ?? 0,
                sampleRate: event.sampleRate ?? 0,
                mimeType: event.audioMimeType,
                data: base64Decode(event.audioData!),
                sessionId: event.sessionId,
              ),
              enabled: _voiceOutputEnabled,
            );
            if (accepted) {
              _voiceStreamedDeliveries.add(_deliveryKey(
                turn.requestId,
                event.deliveryIndex!,
              ));
            }
          case LocalChatEventKind.voiceError:
            // 一句合成失败（票二 D1）：本段语音结束——已播的留着、后续
            // 不出声、同会话只提示一次；文字显示不受影响。失败段同样
            // 记「不再整段重读」：用户刚听完「后面的先不读了」，不能
            // 又被整段读一遍（还多烧一次合成配额）。
            voiceOutput.notifyStreamFailure(
              requestId: turn.requestId,
              deliveryIndex: event.deliveryIndex!,
            );
            _voiceStreamedDeliveries.add(_deliveryKey(
              turn.requestId,
              event.deliveryIndex!,
            ));
          case LocalChatEventKind.message:
          case LocalChatEventKind.state:
          case LocalChatEventKind.fallback:
            break;
          case LocalChatEventKind.done:
            if (delivery != null) {
              // 该 requestId 的第 N 次交付段（轮内召回的 bubble 2 是
              // 第二段）：朗读定位与气泡的「正在朗读」指示共用。
              final deliveryIndex = _announcedDeliveries[turn.requestId] ?? 0;
              _announcedDeliveries[turn.requestId] = deliveryIndex + 1;
              _messages.addAll(
                delivery.messages.map(
                  (message) => LocalChatMessage(
                    requestId: turn.requestId,
                    speaker: LocalChatSpeaker.qiyu,
                    text: message,
                    source: delivery.source,
                    fallbackReason: delivery.fallbackReason,
                    serviceError: delivery.serviceError,
                    deliveryIndex: deliveryIndex,
                    incomplete: delivery.incomplete,
                    at: _previewMoment,
                  ),
                ),
              );
              turn.streamingText = '';
              turn.waiting = false;
              // 块已在流式里播过（或合成失败已收声）的交付段不再走
              // 整段重合成——否则同一段话会响两遍。
              final streamed = _voiceStreamedDeliveries.contains(
                _deliveryKey(turn.requestId, deliveryIndex),
              );
              // 语音块收完：播完缓冲即结束（Host 在 done 前已吐完
              // 所有块）。
              voiceOutput.endStream(requestId: turn.requestId);
              // ADR 0002：只有完整交付并落盘的栖语 turn 才朗读——
              // done 交付即 Host 落盘完成，此时入队按序读。
              if (!streamed) {
                voiceOutput.offer(
                  VoiceOutputRequest(
                    requestId: turn.requestId,
                    deliveryIndex: deliveryIndex,
                    sessionId: _sessionId,
                  ),
                  enabled: _voiceOutputEnabled,
                );
              }
            }
          case LocalChatEventKind.cancelled:
            turn.streamingText = '';
            turn.waiting = false;
            // 轮交付取消：硬停这一路流式语音（缓冲里的 PCM 不再播），
            // 但不清整段队列——取消针对搭车音频，排队里的整段项照常。
            voiceOutput.stopStream(requestId: turn.requestId);
          case LocalChatEventKind.error:
            voiceOutput.stopStream(requestId: turn.requestId);
            throw LocalChatGatewayException(event.text!);
        }
        notifyListeners();
        // 取消即本轮终态；done 后仍消费可能到来的召回第二段。
        if (turn.assembly.end != null) break;
      }
    } on Object {
      turn.assembly.fail();
      // 网关异常、协议错误或传输层断开都可能发生在 done 之前；此时不
      // 能让已受理的流式语音占位等一个不会到来的 endStream，否则下一
      // 轮自动朗读会被堵死。
      if (_belongsToActiveGeneration(turn)) {
        voiceOutput.stopStream(requestId: turn.requestId);
      }
      rethrow;
    } finally {
      turn.assembly.close();
      if (_belongsToActiveGeneration(turn)) {
        if (!turn.assembly.accepted && optimisticallyAdded) {
          _removeUserTurn(turn.requestId);
        }
        if (turn.assembly.hasCompleted) {
          _pendingRequestId = null;
          _pendingText = null;
        }
        if (turn.assembly.end == ChatDeliveryEnd.closed &&
            (turn.assembly.hasIncompleteSegment || !turn.assembly.hasCompleted)) {
          _errorMessage = '回复未完成，可以重新发送。';
          // EOF / 半途关流同样没有 done：显式释放这一路流式语音占位，
          // 但不伪造整段回退（消息没有完整落盘）。
          voiceOutput.stopStream(requestId: turn.requestId);
        }
        turn.streamingText = '';
        turn.waiting = false;
      }
    }
  }

  Future<void> stop() async {
    final requestId = _pendingRequestId;
    if (!sending || requestId == null) {
      return;
    }
    await _gateway.cancel(requestId);
  }

  // -------------------------------------------------------------------------
  // Omni 通话显示面（OmniCallChatSurface，T04）
  // -------------------------------------------------------------------------

  /// 通话开始：清掉上次通话可能残留的流式显示。
  @override
  void callSessionReset() {
    _callStreamingText = '';
    notifyListeners();
  }

  /// 一条用户轮进入消息流：打字轮即真；语音轮以输入转录入列，同
  /// requestId 的后到转录整段覆盖（completed 事件是权威全文，T03）。
  /// 只覆写用户气泡——恢复快照里同一 requestId 的栖语轮不受影响。
  @override
  void callUserTurn({required String requestId, required String text}) {
    final index = _messages.indexWhere((message) {
      return message.requestId == requestId &&
          message.speaker == LocalChatSpeaker.user;
    });
    if (index >= 0) {
      final existing = _messages[index];
      if (existing.text == text) {
        return;
      }
      _messages[index] = LocalChatMessage(
        requestId: existing.requestId,
        speaker: LocalChatSpeaker.user,
        text: text,
        at: existing.at,
      );
    } else {
      _messages.add(
        LocalChatMessage(
          requestId: requestId,
          speaker: LocalChatSpeaker.user,
          text: text,
          at: _previewMoment,
        ),
      );
    }
    notifyListeners();
  }

  /// 通话回复增量：进入流式行（与打字轮共用视图装配）。
  @override
  void callReplyDelta(String text) {
    if (text.isEmpty) {
      return;
    }
    _callStreamingText += text;
    notifyListeners();
  }

  /// 一条回复终态：已显示文本落成气泡；未完成轮保留前缀并如实标记
  /// （spec:20）。空文本不落气泡——静默工具轮没有可显示的内容，
  /// 播过声但转录缺失的占位语由通话结束后的落盘对账补上。
  @override
  void callReplyDone({required bool incomplete}) {
    final text = _callStreamingText;
    _callStreamingText = '';
    if (text.isNotEmpty) {
      _messages.add(
        LocalChatMessage(
          requestId: 'omni-call-bubble-${_callBubbleCounter++}',
          speaker: LocalChatSpeaker.qiyu,
          text: text,
          incomplete: incomplete,
          at: _previewMoment,
        ),
      );
    }
    notifyListeners();
  }

  /// 通话结束后的落盘对账：从 Host 重新恢复会话快照，以落盘事实替换
  /// 显示态。通话写进同一段会话（start 帧带 sessionId），恢复出的
  /// 列表即权威序列；失败时保留现有显示（调用方捕获，不抹内容）。
  @override
  Future<void> resyncAfterCall() async {
    _callStreamingText = '';
    await _applyRestore(_generation, sessionId: _sessionId);
  }

  /// 等正在流式回复的一轮结束后再发送：语音转写完成时栖语可能仍在
  /// 回复，说完的话照常排队发出，不丢也不并发。
  Future<ChatSendResult> sendWhenIdle(
    String text, {
    Future<void>? cancelled,
    bool Function()? isCancelled,
    VoidCallback? onCommitted,
  }) async {
    final sessionScope = _sessionScope;
    while (sending) {
      final idle = Completer<void>();
      void listener() {
        if (!sending && !idle.isCompleted) {
          idle.complete();
        }
      }

      addListener(listener);
      try {
        await (cancelled == null
            ? idle.future
            : Future.any([idle.future, cancelled]));
      } finally {
        removeListener(listener);
      }
      if (sessionScope != _sessionScope) {
        return const ChatSendResult(status: ChatSendStatus.staleSession);
      }
      if (isCancelled?.call() ?? false) {
        return const ChatSendResult(status: ChatSendStatus.notAccepted);
      }
    }
    if (isCancelled?.call() ?? false) {
      return const ChatSendResult(status: ChatSendStatus.notAccepted);
    }
    // 检查与进入 send 之间不让出执行权，取消不能越过提交边界。
    onCommitted?.call();
    return send(text);
  }

  /// 语音转写通道：录音字节经本机程序转成文字，语义与手打输入完全
  /// 一致，成功后由调用方走 [send]/[sendWhenIdle] 现有链路。
  Future<String> transcribeVoice(Uint8List audio, String mimeType) =>
      _gateway.transcribe(audio: audio, mimeType: mimeType, locale: locale);

  @override
  void dispose() {
    // 轮询计时器与恢复提示窗口随监控模块释放；活跃事务随释放失效：尚未
    // 消费完的旧流事件会在代际校验处整体丢弃，不再写入或通知已销毁的
    // 视图模型。
    _localeController?.removeListener(notifyListeners);
    _hostMonitor.removeListener(_onHostMonitorChanged);
    _hostMonitor.dispose();
    _sessionScope = Object();
    _generation += 1;
    _activeTurn = null;
    super.dispose();
  }
}

final Uuid _requestIdUuid = Uuid();

String _defaultRequestId() => 'chat-${_requestIdUuid.v4()}';

/// 交付段在「是否已流式播过」账本里的键：同一 requestId 的多个交付段
/// （轮内召回的 bubble 2）各自独立。
String _deliveryKey(String requestId, int deliveryIndex) =>
    '$requestId#$deliveryIndex';

String _readableError(Object error) =>
    readableError(error, fallback: '本地聊天暂时不可用，请稍后重试。');
