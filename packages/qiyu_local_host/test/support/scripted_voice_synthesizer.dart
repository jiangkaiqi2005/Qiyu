import 'dart:async';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 流式合成网关的脚本化假件（票二）：按**句子文本**应答（不按调用
/// 顺序——在途合成并发完成，调用顺序本就无关；交付顺序由分句层按句
/// 序保证，测试据此断言）。同时实现整段接口（朗读路由/连接测试用），
/// 请求序列留档供断言（分句边界即合成请求边界）。经
/// `TtsSettingsService` 注入进程内 Host——分句层走的是真实服务层
/// （配置加载、Key 归一、文本校验）。
///
/// 票三起兼作连续供给会话的脚本化假件（[VoiceStreamSessionGateway]）：
/// 按**累计文本**应答（喂到什么程度出什么音，与真实 WS 会话「边喂边
/// 出」同形状），开会话记录留档供路由断言。整段与分句行为不受会话
/// 配置影响（试听、历史重听等整段路径与传输选择无关）。
final class ScriptedTtsGateway
    implements
      TtsSynthesisGateway,
      TtsStreamSynthesisGateway,
      VoiceStreamSessionGateway {
  ScriptedTtsGateway({
    this.replies = const {},
    this.defaultReply = const ScriptedVoiceChunks([
      [1],
    ]),
    this.sessionReplies = const {},
    this.failAfterAppends,
    this.closeGate,
    this.closeChunks = const [],
    this.sessionOpenError,
    this.sessionOpenGate,
    this.chunkDelay,
  });

  /// 开会话即抛出的异常（票三 裁定 A：会话开失败的 D1 口径用例）。
  final Object? sessionOpenError;

  /// 开会话前要等待的门（票三：取消赶在会话落定前的用例）。
  final Future<void>? sessionOpenGate;

  /// 每个音频块产出前的延时（票三：复现“模型流在往时服务端来块”的竞速）。
  final Duration? chunkDelay;

  /// 句子文本 → 应答脚本（分句模式）。
  final Map<String, ScriptedVoiceReply> replies;
  final ScriptedVoiceReply defaultReply;

  /// 累计文本 → 块序列（连续供给会话模式，票三）。
  final Map<String, List<List<int>>> sessionReplies;

  /// 第几段追加后让会话块流报错（D1 用例）；null 不失败。
  final int? failAfterAppends;

  /// 收尾门：close() 后等它放行才吐 [closeChunks]（验证「收尾后尾块
  /// 照常播完」）；null 不等。
  final Future<void>? closeGate;
  final List<List<int>> closeChunks;

  final List<String> requests = [];

  /// 连续供给会话的开启记录（票三）：配置、Key 与聊天会话标识留档，
  /// 供路由与 section_id 语义断言。
  final List<({TtsConfig config, String? apiKey, String sessionId})>
  sessionOpens = [];

  /// 最近一次开出的会话（票三）：供断言追加序列（增量原文不切句）。
  ScriptedVoiceSession? lastSession;

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async => Uint8List.fromList(const [9, 9, 9]);

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) {
    requests.add(text);
    return switch (replies[text] ?? defaultReply) {
      ScriptedVoiceChunks(:final chunks) => Stream.fromIterable([
        for (final chunk in chunks)
          VoiceAudioChunk(bytes: Uint8List.fromList(chunk), sampleRate: 24000),
      ]),
      // E1：整响应当一块（容器块，不带采样率）。
      ScriptedVoiceWhole(:final bytes) => Stream.fromIterable([
        VoiceAudioChunk(
          bytes: Uint8List.fromList(bytes),
          mimeType: voiceWholeContainerMime,
        ),
      ]),
      ScriptedVoiceFailure() => Stream.error(
        const TtsGatewayException(
          kind: ModelFailureKind.provider,
          message: '语音合成服务拒绝了这次请求。',
        ),
      ),
      ScriptedVoiceGated(:final gate) => _gated(gate),
    };
  }

  @override
  Future<VoiceStreamSession?> openSession({
    required TtsConfig config,
    required String? apiKey,
    required String sessionId,
  }) async {
    // 与 TtsModelGateway 的分派同口径：豆包档看传输选择、千问档看 WS 推理，
    // 其余组合不开会话（分句层维持分句模式）。假件照抄这条判定，
    // 否则任何配置都会被会话模式接管，分句用例全部失真。
    final supported = switch (config.provider) {
      TtsProviderKind.volcTts =>
        config.transport == TtsTransport.wsBidirection,
      TtsProviderKind.qwenTts => qwenTtsUsesWsInference(config.baseUrl),
      TtsProviderKind.openAiCompatible || TtsProviderKind.custom => false,
    };
    // 门先于档位判定等待：这样“迟到的 null”（不支持档位经门延迟后返回 null）也能被用例回放，覆盖“宽限内落定且落回分句”路径。
    if (sessionOpenGate case final gate?) {
      await gate;
    }
    if (!supported) {
      return null;
    }
    if (sessionOpenError case final error?) {
      throw error;
    }
    sessionOpens.add((config: config, apiKey: apiKey, sessionId: sessionId));
    lastSession = ScriptedVoiceSession(
      replies: sessionReplies,
      failAfterAppends: failAfterAppends,
      closeGate: closeGate,
      closeChunks: closeChunks,
      chunkDelay: chunkDelay,
    );
    return lastSession;
  }

  /// 挂在 [gate] 上不吐块：停止信号用例用来把合成停在在途状态。
  static Stream<VoiceAudioChunk> _gated(Future<void> gate) async* {
    await gate;
    yield VoiceAudioChunk(
      bytes: Uint8List.fromList(const [1]),
      sampleRate: 24000,
    );
  }
}

/// 语音合成脚本条目。
sealed class ScriptedVoiceReply {
  const ScriptedVoiceReply();
}

/// 按序吐出若干 PCM 块（每块一个 `List<int>`）。
final class ScriptedVoiceChunks extends ScriptedVoiceReply {
  const ScriptedVoiceChunks(this.chunks);

  final List<List<int>> chunks;
}

/// E1：整响应当一块（拿不到音频块的档位按句子级顺序播）。
final class ScriptedVoiceWhole extends ScriptedVoiceReply {
  const ScriptedVoiceWhole(this.bytes);

  final List<int> bytes;
}

/// 合成失败（D1：一句失败即本段语音结束）。
final class ScriptedVoiceFailure extends ScriptedVoiceReply {
  const ScriptedVoiceFailure();
}

/// 等待 [gate] 完成才吐块：把合成停在在途状态（停止信号用例）。
final class ScriptedVoiceGated extends ScriptedVoiceReply {
  const ScriptedVoiceGated(this.gate);

  final Future<void> gate;
}

/// 连续供给会话的脚本化假件（票三）：[appendText] 每来一段就按**累计
/// 文本**查应答脚本吐块（不等标点——「前几个字就出声」的形状），
/// [close] 收尾（可挂 [closeGate] 验证尾块照常播完），[failAfterAppends]
/// 在第 n 段后让块流报错（D1）。追加序列留档供断言。
final class ScriptedVoiceSession implements VoiceStreamSession {
  ScriptedVoiceSession({
    required this.replies,
    this.failAfterAppends,
    this.closeGate,
    this.closeChunks = const [],
    this.chunkDelay,
  });

  /// 每个音频块产出前的延时；非空时块经 timer 延迟到达（复现“模型流在
  /// 往时服务端来块”的竞速）。
  final Duration? chunkDelay;

  /// 累计文本 → 块序列。
  final Map<String, List<List<int>>> replies;
  final int? failAfterAppends;
  final Future<void>? closeGate;
  final List<List<int>> closeChunks;

  final _controller = StreamController<VoiceAudioChunk>();
  final List<String> appends = [];
  String _accumulated = '';
  bool _closed = false;
  bool _cancelled = false;
  bool _failed = false;

  /// 会话已被作废（取消/落定时已收尾）：用例据此断言连接被作废。
  bool get cancelled => _cancelled;

  /// 每块音频产出时的累计文本（票三）：首音时序门禁的服务端里程碑——
  /// 首块产出时累计文本还不含句末标点，即「前几个字就出声」。
  final List<String> chunkMoments = [];

  /// 产出一块：配置了 chunkDelay 时经 timer 延迟到达（复现服务端异步来块）。
  void _emit(List<int> chunk) {
    final event = VoiceAudioChunk(
      bytes: Uint8List.fromList(chunk),
      sampleRate: 24000,
    );
    if (chunkDelay case final delay?) {
      Future<void>.delayed(delay).then((_) {
        if (!_cancelled && !_closed) {
          _controller.add(event);
        }
      });
    } else {
      _controller.add(event);
    }
  }

  @override
  void appendText(String text) {
    if (text.isEmpty || _closed || _cancelled || _failed) {
      return;
    }
    appends.add(text);
    _accumulated += text;
    for (final chunk in replies[_accumulated] ?? const <List<int>>[]) {
      chunkMoments.add(_accumulated);
      _emit(chunk);
    }
    if (failAfterAppends case final count?) {
      if (appends.length >= count) {
        _failed = true;
        _controller.addError(
          const TtsGatewayException(
            kind: ModelFailureKind.provider,
            message: '语音合成服务拒绝了这次请求。',
          ),
        );
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed || _cancelled) {
      return;
    }
    _closed = true;
    if (_failed) {
      await _controller.close();
      return;
    }
    if (closeGate case final gate?) {
      await gate;
      if (_cancelled) {
        return;
      }
      for (final chunk in closeChunks) {
        chunkMoments.add(_accumulated);
        _controller.add(
          VoiceAudioChunk(
            bytes: Uint8List.fromList(chunk),
            sampleRate: 24000,
          ),
        );
      }
    }
    await _controller.close();
  }

  @override
  Stream<VoiceAudioChunk> get chunks => _controller.stream;

  @override
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _controller.close();
  }
}
