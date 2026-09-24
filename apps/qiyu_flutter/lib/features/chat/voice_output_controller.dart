import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

import 'api_error_dialog.dart';
import 'local_chat_client.dart';
import 'voice_player_platform.dart';
import 'voice_playback_lifecycle.dart';

/// 一条待朗读的栖语交付段定位：Host 按 (requestId, deliveryIndex) 从已
/// 落盘 session 取文字（浏览器只传定位符，Host 是文字真相源）。
final class VoiceOutputRequest {
  const VoiceOutputRequest({
    required this.requestId,
    required this.deliveryIndex,
    this.sessionId,
  });

  final String requestId;
  final int deliveryIndex;
  final String? sessionId;
}

/// 一个搭车聊天事件流到达的语音块（票二）：PCM 字节 + 协商采样率 +
/// 交付段序号与块序号（Host 已保证有序）。
final class VoiceStreamChunk {
  const VoiceStreamChunk({
    required this.requestId,
    required this.deliveryIndex,
    required this.chunkIndex,
    required this.sampleRate,
    required this.data,
    this.mimeType,
    this.sessionId,
  });

  final String requestId;
  final int deliveryIndex;
  final int chunkIndex;

  /// PCM 流式块的协商采样率（播放端按它初始化，不猜）。
  final int sampleRate;

  /// base64 解出的音频字节。
  final Uint8List data;

  /// 完整音频容器的 MIME（票二 E1）：非空即这是一段已合成完的完整音频
  /// （容器由服务定义），走既有整段播放器按序播；为空即 PCM 流式块，
  /// 走流式播放器（AudioWorklet / AudioTrack）。
  final String? mimeType;

  /// 是否是完整容器块（E1）：与 [mimeType] 同义。
  bool get isWhole => mimeType != null;

  final String? sessionId;
}

enum VoiceOutputPhase { idle, synthesizing, playing }

/// 失败提示的归属：只有同一交付段重新真正出声才清掉，避免队列里的
/// 后续成功或另一交付段的成功把别的失败提示误当「过期」。
final class _VoiceFailureNotice {
  const _VoiceFailureNotice({required this.request, required this.message});

  final VoiceOutputRequest request;
  final String message;

  bool belongsTo(VoiceOutputRequest other) =>
      request.requestId == other.requestId &&
      request.deliveryIndex == other.deliveryIndex;
}

/// 整段播放队列的一项（票二）：要么是一次 Host 端合成请求（既有路径），
/// 要么是已在手的完整音频（E1 的句子级顺序播——每句独立整段合成，容器
/// 原样，不包 WAV 头）。两者共用同一条按序全播的队列。
final class _VoiceQueueItem {
  const _VoiceQueueItem.request(this.request)
    : audio = null,
      mimeType = null;
  const _VoiceQueueItem.audio({
    required this.request,
    required this.audio,
    required this.mimeType,
  });

  /// 队列项的定位（「正在读」指示与合成失败归因都用它）。
  final VoiceOutputRequest request;

  /// 已在手的音频字节（E1 整段块）；null 即走 Host 端合成。
  final Uint8List? audio;
  final String? mimeType;
}

/// 一路流式语音播放会话（票二）：首块开流、后续块追加、end 后播完
/// 缓冲即结束。音频只在内存，不落盘。
final class _VoiceStreamSession {
  _VoiceStreamSession({
    required this.requestId,
    required this.deliveryIndex,
    required this.sampleRate,
    this.sessionId,
  });

  final String requestId;
  final int deliveryIndex;

  /// 首块的协商采样率（Host 记录 Provider 协商结果）：播放端按它初始化。
  final int sampleRate;
  final String? sessionId;

  /// 开流之前到达的块（首块的 startStream 是异步的）。
  final List<Uint8List> pending = [];
  VoiceStreamPlayback? playback;

  /// 块收完或失败已判：之后到达的块丢弃（Host 不会发，防御性）。
  bool closed = false;

  /// 平台开流失败：已到块没有真正进入播放器，等 done 后再回退整段。
  bool startupFailed = false;

  /// Host 已发 done：开流若尚未落定，失败回调要在此时补上整段回退。
  bool endRequested = false;

  /// Host 的 voiceError（D1）已判：本段不再整段回退。
  bool synthesisFailed = false;

  /// 整段回退只入队一次，避免 done 重复到达时重复合成。
  bool fallbackQueued = false;
}

/// 语音朗读的播放队列（ADR 0002）：按序全播、不抢占正在播的一段；
/// 停止按钮 / Esc / 点麦克风清空全部队列；点小喇叭重听则立即顶播。
/// 合成或播放失败：同一页面生命周期内首次以人话提示一次，之后安静
/// 跳过——文字早已交付，读不出来绝不打断聊天主链路。
final class VoiceOutputController extends ChangeNotifier {
  VoiceOutputController(this._gateway, {VoicePlayerPlatform? playerPlatform})
    : // 缺省走平台接缝：web 真播放，其余环境如实「不支持」降级。
      _playerPlatform = playerPlatform ?? createVoicePlayerPlatform() {
    _volume = _playerPlatform.getInitialVolume();
    _playback = VoicePlaybackLifecycle(
      _playerPlatform,
      onInterrupted: interruptOutput,
    );
  }

  final ChatSpeechGateway _gateway;
  final VoicePlayerPlatform _playerPlatform;
  late final VoicePlaybackLifecycle _playback;
  bool _interrupted = false;

  void interruptOutput() {
    _interrupted = true;
    stopAll();
  }

  /// 朗读合成遇到 429 或 40x 异常时的回调。
  void Function(ApiErrorCategory category)? onApiError;

  /// 前端停播时通知 Host 作废在途分句合成（票二）：不白烧 Provider
  /// 配额。与轮交付的取消路径分开——停止只针对语音。
  void Function(String requestId)? onVoiceStopRequested;

  /// 页面连接录音设备占用状态，自动朗读和手动重听都在入口丢弃。
  bool Function()? isMicrophoneInUse;

  late double _volume;
  final Queue<_VoiceQueueItem> _queue = Queue();
  bool _failureNotified = false;
  bool _sessionInitialized = false;
  String? _sessionId;

  /// 当前流式播放会话（票二）：null 即没有搭车音频在播。
  _VoiceStreamSession? _stream;

  /// 已被用户停播的 requestId（票二）：Host 收到停止信号前产出的块
  /// 还在途，到达后直接丢弃——按了停播声音就不该再起来。换会话时清空。
  final Set<String> _stoppedStreamRequests = <String>{};

  VoiceOutputPhase _phase = VoiceOutputPhase.idle;
  VoiceOutputRequest? _nowReading;
  _VoiceFailureNotice? _failureNotice;

  /// 控制器是否已释放：[stopAllForLeavingPage] 的通知排在微任务里，可能落在
  /// 释放之后，那时再 notifyListeners 会撞 ChangeNotifier 的释放断言。
  bool _disposed = false;

  @override
  void dispose() {
    _playback.unsubscribe();
    _haltNow();
    _disposed = true;
    super.dispose();
  }

  VoiceOutputPhase get phase => _phase;
  VoiceOutputRequest? get nowReading => _nowReading;
  double get volume => _volume;

  void setVolume(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if ((_volume - clamped).abs() < 0.001) {
      return;
    }
    _volume = clamped;
    _playerPlatform.saveVolume(_volume);
    _playback.setVolume(_volume);
    notifyListeners();
  }

  /// 最近一次失败的人话提示：同一生命周期最多置一次（首次提示后续
  /// 静默），UI 展示后调用 [consumeFailureNotice] 清除。提示归属发起
  /// 失败的交付段，只有同一段真正出声才自动清理。
  String? get failureNotice => _failureNotice?.message;

  bool get isReading => _phase != VoiceOutputPhase.idle;

  /// 自动朗读入口（message 事件 diff 出的新 bubble）。朗读开关关闭
  /// （enabled=false）时直接丢弃，不排队。
  void offer(VoiceOutputRequest request, {required bool enabled}) {
    if (_disposed ||
        _interrupted ||
        !enabled ||
        (isMicrophoneInUse?.call() ?? false)) {
      return;
    }
    _enterSession(request.sessionId);
    _queue.addLast(_VoiceQueueItem.request(request));
    _drain();
  }

  /// 手动重听（气泡小喇叭）：用户主动点播优先于自动队列——立即播这
  /// 条，正在播的直接顶掉，清空自动排队（用户要听的是这一句）。
  void playNow(VoiceOutputRequest request) {
    if (_disposed || (isMicrophoneInUse?.call() ?? false)) return;
    prepareForUserInitiatedPlayback();
    _enterSession(request.sessionId);
    _haltNow();
    _queue
      ..clear()
      ..addLast(_VoiceQueueItem.request(request));
    _drain();
  }

  /// 用户发送消息或主动点播时调用；必须发生在第一个 await 前。
  void prepareForUserInitiatedPlayback() {
    _interrupted = false;
    _playback.prepareForUserGesture();
  }

  /// 停止播放并清空队列（停止按钮 / Esc / 点麦克风立即停播）。
  void stopAll() {
    _haltNow();
    notifyListeners();
  }

  /// 离开聊天页时的停播（ADR 0002）：动作与 [stopAll] **完全一致**（同走
  /// [_haltNow]）——立刻停声、清掉排队的气泡、作废在途合成——只有通知时机不同。
  ///
  /// 页面卸载跑在框架锁定树的阶段，而卸载顺序是「先子后父」：轮到 `State.dispose`
  /// 时本页的 `AnimatedBuilder` 已经 defunct 却可能还没解除订阅，同步
  /// [notifyListeners] 会打在它们身上抛「setState() or markNeedsBuild() called
  /// when widget tree was locked」。「只在 isReading 时才停」是靠削弱这条语义来
  /// 绕开崩溃，代价是排队的 bubble 跨页继续朗读。改成把通知延到本帧之后：正在
  /// 消失的监听者届时已解除订阅，还活着的监听者（例如路由过渡期同时挂着的另一个
  /// 聊天页）照常收到更新。
  void stopAllForLeavingPage() {
    if (_playback.interruptible) {
      _interrupted = true;
    }
    _haltNow();
    scheduleMicrotask(() {
      if (_disposed) {
        return;
      }
      notifyListeners();
    });
  }

  /// 立即停播的公共动作：作废在途的合成/播放并清队，状态回到 idle。
  /// 唯一的差别（要不要通知、什么时候通知）留在两个调用方身上。
  void _haltNow() {
    _queue.clear();
    _playback.stop();
    _toIdle();
    // 停播即通知 Host 停止在途合成（票二）：本地不出声了，就不该继续
    // 烧 Provider 配额。自然播完不走这里（那时 Host 早已收尾）。
    final session = _stream;
    _stream = null;
    if (session != null) {
      _stoppedStreamRequests.add(session.requestId);
      onVoiceStopRequested?.call(session.requestId);
    }
  }

  /// 状态回到 idle（清掉「正在读」的定位）；是否通知、何时通知由调用方决定。
  void _toIdle() {
    _phase = VoiceOutputPhase.idle;
    _nowReading = null;
  }

  /// 语音块搭车到达（票二）：PCM 块开流式播放，完整容器块（E1）进既有
  /// 整段队列按序播。文/音解耦——文字照常显示，这里只负责把先到口的
  /// 音频按时序播出去。
  ///
  /// 返回是否受理：未受理（朗读关着、被中断、麦克风占用、被停播过、
  /// 已有别的音频在读/在排队）时调用方不应把这笔账记成「播过」——
  /// 否则该交付段在 done 时既不听整段、直播又丢了，彻底失声。PCM 首块
  /// 的开流是异步的；这里返回 true 只表示控制器已接管，若随后开流失败，
  /// 控制器会在 done 的 [endStream] 里补一次整段回退。
  ///
  /// 降级口径与整段路径一致：平台没有流式播放能力时，等终局整段回退
  /// 也失败才提示一次「读不出来」。
  bool offerStreamChunk(VoiceStreamChunk chunk, {required bool enabled}) {
    if (_disposed ||
        _interrupted ||
        !enabled ||
        chunk.data.isEmpty ||
        _stoppedStreamRequests.contains(chunk.requestId) ||
        (isMicrophoneInUse?.call() ?? false)) {
      return false;
    }
    // E1：完整容器块——走既有整段播放器，按序全播、不抢占。
    if (chunk.isWhole) {
      if (_phase != VoiceOutputPhase.idle || _stream != null) {
        // 有音频在读，或上一路流正在等 done 确认能否出声：排队等它，
        // 不能让后续完整块越过本段回退抢先播放。
        _queue.addLast(
          _VoiceQueueItem.audio(
            request: VoiceOutputRequest(
              requestId: chunk.requestId,
              deliveryIndex: chunk.deliveryIndex,
              sessionId: chunk.sessionId,
            ),
            audio: chunk.data,
            mimeType: chunk.mimeType!,
          ),
        );
        return true;
      }
      _enterSession(chunk.sessionId);
      _queue.addLast(
        _VoiceQueueItem.audio(
          request: VoiceOutputRequest(
            requestId: chunk.requestId,
            deliveryIndex: chunk.deliveryIndex,
            sessionId: chunk.sessionId,
          ),
          audio: chunk.data,
          mimeType: chunk.mimeType!,
        ),
      );
      _drain();
      return true;
    }
    final session = _stream;
    if (session != null) {
      if (session.closed ||
          session.requestId != chunk.requestId ||
          session.deliveryIndex != chunk.deliveryIndex) {
        return false;
      }
      _appendToSession(session, chunk.data);
      return true;
    }
    if (_phase != VoiceOutputPhase.idle || _queue.isNotEmpty) {
      // 有整段在读/在排队：直播语音不抢占、不排长队，按丢弃处理。
      return false;
    }
    final opened = _VoiceStreamSession(
      requestId: chunk.requestId,
      deliveryIndex: chunk.deliveryIndex,
      sampleRate: chunk.sampleRate,
      sessionId: chunk.sessionId,
    );
    _enterSession(chunk.sessionId);
    _stream = opened;
    _appendToSession(opened, chunk.data);
    _startStream(opened);
    return true;
  }

  void _appendToSession(_VoiceStreamSession session, Uint8List data) {
    final playback = session.playback;
    if (playback == null) {
      session.pending.add(data);
      return;
    }
    playback.append(data);
  }

  Future<void> _startStream(_VoiceStreamSession session) async {
    final activity = _playback.capture();
    _phase = VoiceOutputPhase.playing;
    _nowReading = VoiceOutputRequest(
      requestId: session.requestId,
      deliveryIndex: session.deliveryIndex,
      sessionId: session.sessionId,
    );
    notifyListeners();
    final prepared = activity.prepare();
    if (prepared != null) {
      final allowed = await prepared;
      if (!activity.isCurrent) return;
      if (!allowed) {
        interruptOutput();
        return;
      }
    }
    VoiceStreamPlayback? playback;
    try {
      playback = await activity.startStream(
        sampleRate: session.sampleRate,
        volume: _volume,
      );
    } on Object {
      // 平台桥接抛错与返回 null 同义：已合成但尚未出声，交给 done 回退。
      playback = null;
    }
    if (!activity.acceptStream(playback)) {
      return;
    }
    if (playback == null) {
      // 平台没有流式播放能力或 AudioWorklet 开不起来：合成已成功，但
      // 这一段还没有任何声音。先留住失败态，等 done 再把整段请求放进
      // 队列——/speak 只能在消息落盘后调用，不能在这里抢跑。
      activity.finish();
      session.startupFailed = true;
      session.closed = true;
      _toIdle();
      if (session.endRequested) {
        _queueStreamFallback(session);
      }
      notifyListeners();
      return;
    }
    if (!session.synthesisFailed) {
      // 真正拿到播放句柄就算这段出声成功；只清同一段此前留下的失败
      // 提示，不重置同会话的失败频控，也不误清其他交付段的提示。
      final cleared = _clearFailureNoticeFor(
        VoiceOutputRequest(
          requestId: session.requestId,
          deliveryIndex: session.deliveryIndex,
          sessionId: session.sessionId,
        ),
      );
      if (cleared) {
        notifyListeners();
      }
    }
    session.playback = playback;
    // 开流之前到达的块按序补写，之后 arrive 的块直接进播放器。
    final pending = List<Uint8List>.of(session.pending);
    session.pending.clear();
    for (final bytes in pending) {
      playback.append(bytes);
    }
    if (session.closed) {
      playback.end();
    }
    await playback.done;
    if (!activity.isCurrent) {
      return;
    }
    activity.finish();
    if (identical(_stream, session)) {
      _stream = null;
    }
    _toIdle();
    notifyListeners();
    // 流式播完不等于没事做：播放期间入队的整段项（轮内召回的 bubble 2、
    // E1 的后续句）按序继播——不等下一次 offer。
    _drain();
  }

  /// 块收完（轮交付 done）：声明流结束，播完缓冲即 idle。
  void endStream({required String requestId}) {
    final session = _stream;
    if (session == null || session.requestId != requestId) {
      return;
    }
    session.closed = true;
    session.endRequested = true;
    if (session.playback != null) {
      session.playback!.end();
      return;
    }
    // 开流还没落定时，_startStream 的失败回调会在这里补回退；已经
    // 失败则现在就能入队。两种情况都只交给一个幂等 helper。
    if (session.startupFailed) {
      _queueStreamFallback(session);
    }
  }

  /// 开流失败且 Host 已收尾：把该交付段放回整段队列首位。它必须等到
  /// done 才会被调用，因而不会在消息落盘前请求 /speak；放首位是为了
  /// 不让失败期间排队的后续完整块越过本段。
  void _queueStreamFallback(_VoiceStreamSession session) {
    if (session.synthesisFailed) {
      // D1 已经收声：不能把开流失败再解释成整段回退。但 ADR 0018 的
      // D1 语义是已排队到的音频照常播完，所以只释放本段占位，不清队列。
      if (identical(_stream, session)) {
        _stream = null;
      }
      _toIdle();
      _drain();
      return;
    }
    if (session.fallbackQueued) {
      return;
    }
    session.fallbackQueued = true;
    if (identical(_stream, session)) {
      _stream = null;
    }
    _queue.addFirst(
      _VoiceQueueItem.request(
        VoiceOutputRequest(
          requestId: session.requestId,
          deliveryIndex: session.deliveryIndex,
          sessionId: session.sessionId,
        ),
      ),
    );
    _toIdle();
    _drain();
  }

  /// 硬停一路流式播放（票二：轮交付取消时调用）：立刻停声，但**不清
  /// 整段队列**——取消针对这一路搭车音频，排队里的整段项照常继播
  /// （停完立刻排空，不等下一次 offer）。与 [stopAll] 的差别只有
  /// 「清不清队列、要不要通知 Host」。
  void stopStream({required String requestId}) {
    final session = _stream;
    _stoppedStreamRequests.add(requestId);
    if (session == null || session.requestId != requestId) {
      return;
    }
    _stream = null;
    _playback.stop();
    _toIdle();
    notifyListeners();
    _drain();
  }

  /// 同一 requestId 开新轮时调用（票二：幂等重发复用 requestId）：上一轮
  /// 的停播记账已翻篇——残块丢弃的使命已完成，再留着会把新轮的直播块
  /// 误判成旧轮残块（首音提前静默失效，done 还多烧一次整段合成）。
  /// 新 requestId 不在账本里，调用即无操作。
  void forgetStreamStop(String requestId) {
    _stoppedStreamRequests.remove(requestId);
  }

  /// 一句合成失败（票二 D1）：本段语音结束——已到的块照常播完
  /// （已播句子 standing），后续块即使到达也丢弃；同会话首次失败
  /// 提示一次，之后静默。提示归属该交付段，同一RequestId的其他交付
  /// 段成功播放不会把它清掉。
  void notifyStreamFailure({
    required String requestId,
    required int deliveryIndex,
  }) {
    final request = VoiceOutputRequest(
      requestId: requestId,
      deliveryIndex: deliveryIndex,
      sessionId: _sessionId,
    );
    final session = _stream;
    if (session != null &&
        session.requestId == requestId &&
        session.deliveryIndex == deliveryIndex) {
      session.synthesisFailed = true;
      session.closed = true;
      if (session.startupFailed) {
        // 没有任何播放句柄时，本段已彻底无声；只把状态回到 idle，保留
        // closed 占位到 done，挡住迟到 PCM。已排队的整段音频按 D1 的
        // standing 语义保留，done 后由 _queueStreamFallback 排空。
        _toIdle();
      } else {
        session.playback?.end();
      }
    }
    _notifyFailureOnce('有句话没合成出来，后面的先不读了。', request: request);
  }

  void consumeFailureNotice() {
    if (_failureNotice == null) {
      return;
    }
    _failureNotice = null;
    notifyListeners();
  }

  /// 清掉同一段归属的失败提示；返回是否真的发生了变化，由调用方决定
  /// 是否补一次通知（已在相邻状态通知里的调用不重复通知）。
  bool _clearFailureNoticeFor(VoiceOutputRequest request) {
    if (_failureNotice?.belongsTo(request) != true) {
      return false;
    }
    _failureNotice = null;
    return true;
  }

  Future<void> _drain() async {
    if (_phase != VoiceOutputPhase.idle || _stream != null) {
      // 已有一段在读/在合成，或上一路流在等 done 确认回退：新项已在
      // 队列里，按序等它收尾，不能越过本段先出声。
      return;
    }
    while (_queue.isNotEmpty) {
      final item = _queue.removeFirst();
      final request = item.request;
      final activity = _playback.capture();
      _phase = VoiceOutputPhase.synthesizing;
      _nowReading = request;
      notifyListeners();
      final Uint8List audio;
      final prepared = activity.prepare();
      if (prepared != null) {
        final allowed = await prepared;
        if (!activity.isCurrent) return;
        if (!allowed) {
          interruptOutput();
          return;
        }
      }
      final inHand = item.audio;
      if (inHand != null) {
        // E1 整段块：音频已在手，直接播（容器原样，两种播放端都按
        // 字节嗅探）。
        audio = inHand;
      } else {
        try {
          audio = await _gateway.speak(
            requestId: request.requestId,
            deliveryIndex: request.deliveryIndex,
            sessionId: request.sessionId,
          );
        } on Object catch (error) {
          if (!activity.isCurrent) {
            return;
          }
          activity.finish();
          _notifyFailureOnce('语音服务连不上，这条读不出来。', request: request);
          final category = categorizeVoiceApiError(error, isInput: false);
          if (category != null) {
            onApiError?.call(category);
          }
          continue;
        }
      }
      if (!activity.isCurrent) {
        return;
      }
      final playback = await activity.play(
        audio,
        mimeType: item.mimeType ?? voiceWholeAudioAdvisoryMime,
        volume: _volume,
      );
      if (!activity.accept(playback)) {
        return;
      }
      if (playback == null) {
        activity.finish();
        // 合成已成功；播放许可、解码或音频设备失败不能冒充服务断线。
        // 文案平台中性：web 是浏览器自动播放策略，安卓是系统音频设备。
        _notifyFailureOnce('无法播放语音，点小喇叭再听一次。', request: request);
        continue;
      }
      // 整段回退或手动重听真正拿到播放句柄：只清同一段此前留下的过期
      // 失败提示。清除结果与「开始播放」的状态变化合并进下一次通知。
      _clearFailureNoticeFor(request);
      _phase = VoiceOutputPhase.playing;
      notifyListeners();
      await playback.done;
      if (!activity.isCurrent) {
        return;
      }
      activity.finish();
    }
    _toIdle();
    notifyListeners();
  }

  void _notifyFailureOnce(
    String message, {
    required VoiceOutputRequest request,
  }) {
    if (!_failureNotified) {
      _failureNotified = true;
      _failureNotice = _VoiceFailureNotice(request: request, message: message);
      notifyListeners();
    }
  }

  void _enterSession(String? sessionId) {
    if (_sessionInitialized && _sessionId == sessionId) {
      return;
    }
    _sessionInitialized = true;
    _sessionId = sessionId;
    // 新会话重新计「首次失败提示一次」；停播记账也随会话翻篇（旧
    // requestId 不会再收到块，留着只会无界增长）。
    _stoppedStreamRequests.clear();
    _failureNotified = false;
    _failureNotice = null;
  }
}
