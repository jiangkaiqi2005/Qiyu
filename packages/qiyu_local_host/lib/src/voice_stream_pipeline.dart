import 'dart:async';
import 'dart:typed_data';

import 'tts_gateway.dart';

/// 句末标点（票二）：按业界标准做法（GPT-SoVITS `cut_text`+`cut_punc`
/// 一手实证）切句，句边界即合成请求边界与播放边界。只收中文/常规句
/// 末标点与换行——不收 ASCII 句点（「3.14」「etc.」会被错切），也不收
/// 分号（从句不是句子）。
final _sentenceEndPattern = RegExp(r'[。！？!?…\n\r]');

/// 在途合成请求的上限：请求间不抢占（在途的照常跑完），但无界并行会
/// 把限流敏感的 TTS 服务一次打满。块按序交付，上限只影响「提前几条
/// 开始合成」的提前量。按在途请求数封顶（不按排队数——排队的句子
/// 里有已合成完只是还没播的，拿它封顶会把在途数压到 0 后没人再启动
/// 后续句子）。
const _maxConcurrentSynthesis = 2;

/// 分句层产出的一个音频块（票二）：[chunkIndex] 是交付段内块序号
/// （跨句连续、严格递增，播放端按序全播）。
final class VoiceStreamChunk {
  const VoiceStreamChunk({
    required this.bytes,
    required this.chunkIndex,
    this.sampleRate,
    this.mimeType,
  });

  final Uint8List bytes;

  /// PCM 流式块的协商采样率（播放端按它初始化，不猜）。
  final int? sampleRate;

  /// 完整容器块的 MIME（票二 E1）：非空即这是一段已合成完的完整音频
  /// （容器由服务定义，不包 WAV 头），播放端走既有整段播放器。为空即
  /// PCM 流式块。两者恰居其一。
  final String? mimeType;
  final int chunkIndex;
}

/// 分句流式合成管线（票二）：与文字流式共用同一个活前缀——每出一个
/// 完整句就向 Provider 请求该句合成，音频块按序排进交付队列，由
/// [LocalChatService] 的交付循环搭车现有聊天 NDJSON 事件流推出。
///
/// 失败降级（D1）：一句失败即本段语音结束——已交付的块 standing，
/// 后续句不合成、不出声，在途请求取消（不白烧配额）；失败信号
/// （[failed]）只在交付指针排到失败句后才置位，保证「先吐完已到的
/// 块、再报失败」的顺序。停止信号（[cancel]）与轮交付的取消路径分开：
/// 前端停播只停语音，不撤回文字。
///
/// 连续供给（票三）：注入了 [VoiceStreamSession]（豆包双向 WS / 千问
/// Realtime WS）时走会话模式——增量原文直接进 WS（不按标点切句、不受
/// 在途上限约束），音频块按到达序交付，[close] 收尾后尾块照常播完。
/// 票二全部分句语义在会话模式下逐条对应：按序不抢占（WS 单连接天然
/// 有序）、D1（会话失败即本段语音结束、已播 standing、同会话提示一次）、
/// 停止信号停合成、deliveryIndex/chunkIndex 口径不变。
final class VoiceStreamPipeline {
  VoiceStreamPipeline({
    required VoiceStreamSynthesizer synthesizer,
    required this.requestId,
    required this.sessionId,
    required this.deliveryIndex,
    required void Function(String message) diagnosticsSink,
    VoiceStreamSession? streamSession,
    bool pendingSession = false,
  }) :
       _sessionPending = pendingSession,
       // ignore: prefer_initializing_formals
       _synthesizer = synthesizer,
       // ignore: prefer_initializing_formals
       _diagnosticsSink = diagnosticsSink,
       _streamSession = streamSession {
    // 连续供给（票三）：会话音频块按到达序进缓冲；流错误即 D1（先吐完
    // 已到的块再报失败），流结束即收尾完成。
    if (streamSession case final session?) {
      _listenToSession(session);
    }
  }

  final VoiceStreamSynthesizer _synthesizer;
  final void Function(String message) _diagnosticsSink;

  /// 所属聊天请求（停止信号与幂等都按它定位）。
  final String requestId;
  final String sessionId;

  /// 语音块所属的栖语交付段序号（与朗读定位同口径）。
  final int deliveryIndex;

  /// 连续供给会话（票三）：非空即会话模式，分句字段全部不参与。
  VoiceStreamSession? _streamSession;

  /// 连续供给会话在途（票三 迟到挂载）：管线先就绪、文字首字不等握手，
  /// 会话落定后经 [attachSession] 挂上（或回落分句模式/放弃）。在途期间
  /// 喂进的文本先缓冲，挂载时整段补喂。
  bool _sessionPending;
  StreamSubscription<VoiceAudioChunk>? _sessionSubscription;
  final List<VoiceAudioChunk> _sessionChunks = [];
  bool _sessionFailed = false;
  bool _sessionEnded = false;

  final List<_VoiceSentence> _queue = [];
  final StringBuffer _tail = StringBuffer();

  /// 会话在途（迟到挂载）期间缓冲的原文：挂载时整段补喂，不丢内容。
  final StringBuffer _pendingText = StringBuffer();
  final Completer<void> _stopped = Completer<void>();
  Completer<void>? _progressWaiter;

  bool _closed = false;
  bool _failed = false;
  bool _failureReached = false;
  int _nextChunkIndex = 0;

  /// 停止信号已触发（用户停播 / 轮取消）：在途合成作废，后续块不再
  /// 交付。与 D1 的 [_failed] 分开——停止是外部动作，一句话都不留；
  /// D1 是合成失败，已排队到的音频照常播完。
  bool get isCancelled => _stopped.isCompleted;

  /// D1：某句合成失败（且交付指针已排到它）；会话模式即会话失败且
  /// 已到的块吐完。
  bool get failed => _failureReached;

  /// 活前缀已关闭（或已失败/已停止）且队列排空：全部句子交付完、
  /// 失败句已跳过或在途请求已作废。会话模式：会话流已结束/失败/停止。
  /// 会话在途（迟到挂载）：只有停止、放弃（模型流已收尾）与失败能让它
  /// 结束——落定与 E1 回落都经挂载后转分会话模式或分句模式。
  bool get isFinished =>
      _streamSession != null
          ? (isCancelled || _sessionEnded || _sessionFailed)
          : _sessionPending
          ? (isCancelled || _sessionEnded || _failed)
          : _queue.isEmpty && (_closed || _failed || isCancelled);

  /// 喂入一段新通过卫生检查的可见文本（与文字流式同一个活前缀，
  /// 不二次解析最终文本）：切出的完整句立即入队合成；会话模式（票三）
  /// 原文直接进 WS，不等标点；会话在途（迟到挂载）时文本不合成——首句
  /// 可能不出声，文字永远优先。
  void addText(String text) {
    final session = _streamSession;
    if (session != null) {
      // 连续供给：增量原文直接进 WS——不按标点切句、不受在途上限约束
      // （服务端决定分段与合成时机）。失败/收尾后的文本不再发送。
      if (!_closed && !isCancelled && !_sessionFailed && !_sessionEnded) {
        session.appendText(text);
      }
      return;
    }
    if (_sessionPending) {
      // 会话还没落定：文本先缓冲（挂载时整段补喂——不丢内容，也不在
      // 握手窗口抢先起分句请求）。
      _pendingText.write(text);
      return;
    }
    // D1 失败后本段语音已收声：新句子不入队（入队也不会启动，交付时
    // 整体丢弃——先切再丢纯属白做）。
    if (_closed || isCancelled || _failed || text.isEmpty) {
      return;
    }
    _feedSentences(text);
  }

  /// 切句入队（票二口径）：完整句立即入队合成，残句留 [_tail]。
  void _feedSentences(String text) {
    _tail.write(text);
    while (true) {
      final buffer = _tail.toString();
      final end = _sentenceEndPattern.firstMatch(buffer)?.end;
      if (end == null) {
        return;
      }
      final sentence = buffer.substring(0, end);
      _tail.clear();
      _tail.write(buffer.substring(end));
      _enqueue(sentence);
    }
  }

  /// 活前缀关闭（模型流终止）：没有句末标点的尾句与已播句子同权，
  /// 照常合成播出——少一句话比读不全更糟。会话模式（票三）：通知会话
  /// 收尾（协议层发结束事件），已到达的音频块继续按序播完。会话在途
  /// （迟到挂载）时只标记收尾——挂载时若已收尾，补喂缓冲文本并替会话
  /// 收尾，尾块照常播完（ADR 0019：宽限内落定即挂载）。
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_streamSession case final session?) {
      // close 的失败经会话块流错误上报（D1），这里不抛。
      unawaited(session.close());
      return;
    }
    if (_sessionPending) {
      // 会话在途：只标记收尾。落定挂载时由 attachSession 补喂缓冲文本
      // 并替会话收尾；宽限外落定则由调用方作废（语音没启动，不是失败）。
      return;
    }
    final tail = _tail.toString().trim();
    _tail.clear();
    if (tail.isNotEmpty) {
      _enqueue(tail);
    }
    _launch();
  }

  /// 迟到挂载（票三）：会话落定后挂上。文字首字不等握手——挂载前喂进的
  /// 文本先进缓冲，挂载时整段补喂（不丢内容）。[session] 为 null（档位不
  /// 支持 WS / E1 非 PCM）时回落票二分句模式。模型流已收尾时才落定＝照常
  /// 挂载并替会话收尾（尾块照常播完，ADR 0019 宽限语义）；已取消才作废
  /// （用户明确停了，一句话不留）。
  void attachSession(VoiceStreamSession? session) {
    if (_streamSession != null || _failed) {
      session?.cancel();
      return;
    }
    _sessionPending = false;
    if (session == null) {
      // 回落分句模式（档位不支持 WS / E1）：缓冲的原文按票二口径切句
      // 合成——握手窗口里到达的文字不丢；模型流已收尾时照尾句同权播出
      // （与 close 的尾句处理同一口径）。
      final buffered = _pendingText.toString();
      _pendingText.clear();
      _feedSentences(buffered);
      if (_closed) {
        // 模型流已收尾：尾句与已播句子同权（与 close 的尾句处理同口径）。
        final tail = _tail.toString().trim();
        _tail.clear();
        if (tail.isNotEmpty) {
          _enqueue(tail);
        }
        _launch();
      }
      return;
    }
    if (isCancelled) {
      // 用户明确停了（停播/轮取消）：一句话不留。
      session.cancel();
      return;
    }
    _streamSession = session;
    // 缓冲的增量原文整段补喂进会话（服务端决定分段与合成时机）。
    final buffered = _pendingText.toString();
    _pendingText.clear();
    if (buffered.isNotEmpty) {
      session.appendText(buffered);
    }
    _listenToSession(session);
    if (_closed) {
      // 模型流已收尾才落定：替会话收尾（协议层结束事件），尾块照常播完
      // ——短回复（一次 delta 就 done）也不能整轮没声音。
      unawaited(session.close());
    }
  }

  /// 会话开启失败（票三，挂载时）：管线转入「已失败」态——交付循环按 D1
  /// 同口径提示一次（同会话首次一次），文字链路完全不受影响。
  void markSessionFailed() {
    if (_streamSession != null || _failed || isCancelled) {
      return;
    }
    _sessionPending = false;
    _closed = true;
    _failed = true;
    _failureReached = true;
    _notifyProgress();
  }

  /// 在途会话被放弃（票三）：模型流已收尾（或其它不等会话的出口），语音
  /// 没启动过——管线就此结束，不是失败、不发提示。
  void abandonPendingSession() {
    if (_streamSession != null || _failed || _sessionEnded) {
      return;
    }
    _sessionPending = false;
    _sessionEnded = true;
    _notifyProgress();
  }

  void _listenToSession(VoiceStreamSession session) {
    _sessionSubscription = session.chunks.listen(
      (chunk) {
        if (isCancelled) {
          return;
        }
        _sessionChunks.add(chunk);
        _notifyProgress();
      },
      onError: (Object error) {
        // 只打异常类型不打消息：消息可能嵌着用户输入或第三方原文。
        _diagnosticsSink(
          'voice stream session failed [${error.runtimeType}] '
          'request=$requestId',
        );
        _sessionFailed = true;
        _notifyProgress();
      },
      onDone: () {
        _sessionEnded = true;
        _notifyProgress();
      },
    );
  }

  /// 取下一块可交付的音频（按序）。头句音频没到齐时返回 null（等），
  /// 头句结束（播完/失败）后出队；失败或停止后剩余句子整体丢弃。
  /// 会话模式（票三）：块按到达序出缓冲，失败信号在缓冲排空后才置位
  /// （先吐完已到的块、再报失败，与分句模式同一顺序口径）。
  VoiceStreamChunk? takeChunk() {
    if (_streamSession != null) {
      return _takeSessionChunk();
    }
    while (_queue.isNotEmpty) {
      final head = _queue.first;
      if (_failureReached || isCancelled) {
        _queue.removeAt(0);
        continue;
      }
      if (head.chunks.isNotEmpty) {
        final bytes = head.chunks.removeAt(0);
        return VoiceStreamChunk(
          bytes: bytes,
          sampleRate: head.sampleRate,
          mimeType: head.mimeType,
          chunkIndex: _nextChunkIndex++,
        );
      }
      if (!head.settled) {
        return null;
      }
      _queue.removeAt(0);
      if (head.failed) {
        _failureReached = true;
      }
      _launch();
    }
    return null;
  }

  VoiceStreamChunk? _takeSessionChunk() {
    if (isCancelled) {
      return null;
    }
    if (_sessionChunks.isNotEmpty) {
      final chunk = _sessionChunks.removeAt(0);
      return VoiceStreamChunk(
        bytes: chunk.bytes,
        sampleRate: chunk.sampleRate,
        mimeType: chunk.mimeType,
        chunkIndex: _nextChunkIndex++,
      );
    }
    if (_sessionFailed) {
      // D1：已到的块都在上面吐完了才报失败。
      _failureReached = true;
    }
    return null;
  }

  /// 等待管线推进（新块到达、句子落定或失败）。调用方只在「队列非空」
  /// 时挂这个等待——空队列意味着管线在等更多文字，没有可通知的事件。
  /// 已结束时立即返回，不空等。
  Future<void> whenProgress() {
    if (isFinished) {
      return Future.value();
    }
    return (_progressWaiter ??= Completer<void>()).future;
  }

  /// 停止信号（前端停播端点 / 轮取消）：在途合成作废，一句话都不再交付。
  void cancel() {
    if (!_stopped.isCompleted) {
      _stopped.complete();
    }
    _streamSession?.cancel();
    unawaited(_sessionSubscription?.cancel());
    _sessionChunks.clear();
    _notifyProgress();
  }

  void _enqueue(String sentence) {
    final trimmed = sentence.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _queue.add(_VoiceSentence(trimmed));
    _launch();
  }

  /// 按在途上限启动未启动的句子：请求间不抢占，块按序交付。
  void _launch() {
    while (!isCancelled && !_failed && _inFlight < _maxConcurrentSynthesis) {
      final next = _queue.where((sentence) => !sentence.started).firstOrNull;
      if (next == null) {
        return;
      }
      next.started = true;
      _runSentence(next);
    }
  }

  /// 在途合成请求数（已启动未落定）。
  int get _inFlight =>
      _queue.where((sentence) => sentence.started && !sentence.settled).length;

  Future<void> _runSentence(_VoiceSentence sentence) async {
    try {
      await for (final chunk in _synthesizer.synthesizeStream(sentence.text)) {
        if (isCancelled || sentence.abandoned) {
          break;
        }
        sentence.chunks.add(chunk.bytes);
        sentence.sampleRate ??= chunk.sampleRate;
        sentence.mimeType ??= chunk.mimeType;
        _notifyProgress();
      }
      sentence.settled = true;
    } on Object catch (error) {
      // 只打异常类型不打消息：消息可能嵌着用户输入或第三方原文。
      _diagnosticsSink(
        'voice synthesis failed [${error.runtimeType}] request=$requestId',
      );
      sentence.failed = true;
      sentence.settled = true;
      // D1：一句失败即本段语音结束。失败句之后的在途请求一并作废
      // （后续句不出声、不白烧配额）；失败句之前的在途请求照常跑完
      // ——已排队到的音频属于已播句子，standing。
      _failed = true;
      final index = _queue.indexOf(sentence);
      if (index >= 0) {
        for (
          var position = index + 1;
          position < _queue.length;
          position += 1
        ) {
          _queue[position].abandoned = true;
        }
      }
      _notifyProgress();
      return;
    }
    _notifyProgress();
  }

  void _notifyProgress() {
    final waiter = _progressWaiter;
    _progressWaiter = null;
    waiter?.complete();
  }
}

/// 一个待合成/在途/已完成的句子。块先缓冲在句子里，交付指针按句序取，
/// 因此多句并行合成也不乱序。
final class _VoiceSentence {
  _VoiceSentence(this.text);

  final String text;
  final List<Uint8List> chunks = [];
  int? sampleRate;

  /// E1 整段块的 MIME（该句拿不到音频块时）：与 [sampleRate] 恰居其一。
  String? mimeType;
  bool started = false;
  bool settled = false;
  bool failed = false;

  /// D1 作废：失败句之后的在途请求——不再收块，已缓冲的整体丢弃。
  bool abandoned = false;
}
