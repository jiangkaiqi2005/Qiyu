import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'qwen_tts_gateway.dart';
import 'tts_gateway.dart';
import 'tts_ws_session_skeleton.dart';
import 'volc_seed_asr_gateway.dart';

// ---------------------------------------------------------------------------
// 千问 DashScope 经典 WS 推理（SpeechSynthesizer，票 07）
// ---------------------------------------------------------------------------

/// DashScope 经典推理协议（SpeechSynthesizer）的客户端动作名（官方文档
/// header.action 字段值，probe 02 实测形状）。
const qwenWsInferenceActionRunTask = 'run-task';
const qwenWsInferenceActionContinueTask = 'continue-task';
const qwenWsInferenceActionFinishTask = 'finish-task';

/// DashScope 经典推理协议的服务端事件名（官方文档 header.event 字段值）。
const qwenWsInferenceEventTaskStarted = 'task-started';
const qwenWsInferenceEventTaskFinished = 'task-finished';
const qwenWsInferenceEventTaskFailed = 'task-failed';

/// 经典推理端点的默认路径：用户填的地址缺路径（`wss://host`）时补上，
/// 路径齐全的地址原样使用（服务商自建网关的路径不一，Host 不改写）。
const qwenWsInferenceDefaultPath = '/api-ws/v1/inference';

/// 文本与二进制两路帧流的合并视图：DashScope 经典推理的控制事件走 JSON
/// 文本帧、音频走二进制帧，两路同源于一条 WebSocket 连接（豆包把两者
/// 复用在二进制流里、千问 Realtime 只有文本，本协议是第一条需要两路
/// 同听的）。单订阅转发——会话读循环是唯一消费者；两路都结束（连接
/// 关闭）后合并流才结束，错误原样转发由读循环按既有分类说话。
Stream<dynamic> mergeWsFrameStreams(Stream<dynamic> text, Stream<dynamic> binary) {
  late final StreamController<dynamic> controller;
  final subscriptions = <StreamSubscription<dynamic>>[];
  var open = 2;
  void onDone() {
    open -= 1;
    if (open == 0 && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  controller = StreamController<dynamic>(
    onListen: () {
      subscriptions
        ..add(
          text.listen(
            controller.add,
            onError: controller.addError,
            onDone: onDone,
          ),
        )
        ..add(
          binary.listen(
            controller.add,
            onError: controller.addError,
            onDone: onDone,
          ),
        );
    },
    onPause: () {
      for (final subscription in subscriptions) {
        subscription.pause();
      }
    },
    onResume: () {
      for (final subscription in subscriptions) {
        subscription.resume();
      }
    },
    onCancel: () {
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
    },
  );
  return controller.stream;
}

/// task-failed 的允许列表映射（票 07）：错误码只用于分类，第三方错误
/// 原文绝不透出。auth/rate 指纹沿用千问 Realtime 错误事件的口径，
/// ModelNotFound 是该协议的结构化信号（probe 1.1 实测形状），按既有
/// 「找不到模型」分类说话——不新增分类与错误码，其余一律按服务拒绝。
TtsGatewayException _qwenInferenceTaskFailedFailure(Map<String, Object?> event) {
  final header = event['header'];
  final code = header is Map<String, Object?> ? header['error_code'] : null;
  if (code is String) {
    final normalized = code.toLowerCase();
    if (normalized.contains('modelnotfound')) {
      return const TtsGatewayException(
        kind: ModelFailureKind.modelNotFound,
        message: '找不到这个模型，请检查模型名称。',
      );
    }
    if (normalized.contains('auth') ||
        normalized.contains('api_key') ||
        normalized.contains('permission')) {
      return const TtsGatewayException(
        kind: ModelFailureKind.authentication,
        message: 'API Key 未通过语音合成服务验证。',
      );
    }
    if (normalized.contains('rate') ||
        normalized.contains('quota') ||
        normalized.contains('limit') ||
        normalized.contains('throttl')) {
      return const TtsGatewayException(
        kind: ModelFailureKind.rateLimited,
        message: '语音合成服务请求过于频繁。',
      );
    }
  }
  return const TtsGatewayException(
    kind: ModelFailureKind.provider,
    message: '语音合成服务拒绝了这次请求。',
  );
}

/// 千问 DashScope 经典 WS 推理合成网关（票 07，ADR 0020 补篇）：官方
/// SpeechSynthesizer 协议，端点 `wss://…/api-ws/v1/inference`。地址即
/// 用户在设置页填的完整 ws/wss 端点（路径空缺时补默认推理路径，不再由
/// Host 派生——服务商网关路径不一）。生命周期：run-task → task-started
/// → continue-task（流式按 ADR 0019 增量喂文本）→ finish-task →
/// task-finished 收束；音频走 binary 帧，实测每帧自带完整 WAV 容器头
/// （probe 02/03 基线形状），按既有剥头口径归一成裸 PCM——整段路径拼
/// PCM 后在 Host 包一次 WAV 头，流式路径按既有 PCM 块通道交付。
///
/// 3.1（qwen-audio-3.1-tts-flash 等）在 CosyVoice 引擎层只认 3.1 专属
/// 音色（如 longanhuan_v3.1，3.0 音色会报 Engine error 411），音色
/// 空缺时按型号自动回落为 [qwenTts31DefaultVoice]。
final class QwenWsInferenceTtsGateway
    implements
        TtsSynthesisGateway,
        TtsStreamSynthesisGateway,
        VoiceStreamSessionGateway {
  QwenWsInferenceTtsGateway(this.connector, {this.timeout = ttsRequestTimeout});

  final ProviderWebSocketConnector connector;

  /// 空闲超时预算：含建连、握手、音频间隔与收尾等待（与豆包/千问
  /// Realtime 网关同律，测试用小值验证超时降级）。
  final Duration timeout;

  /// 推理地址：用户填的完整 ws/wss 端点，host/port/path/query 原样
  /// 保留，只在路径空缺时补默认推理路径。
  static Uri resolveInferenceUri(TtsConfig config) {
    final base = Uri.parse(config.baseUrl.trim());
    final path = base.path.isEmpty || base.path == '/'
        ? qwenWsInferenceDefaultPath
        : base.path;
    return base.replace(path: path);
  }

  /// run-task 的 payload（官方文档逐字段，probe 02 实测）：task_group/
  /// task/function 固定，音色空缺按型号回落本家族官方示例音色（3.1 专属
  /// 音色 vs 3.0 音色），format/sample_rate 缺省 wav/24000（与票 02 maas
  /// 形状同律）；高级参数深合并进 parameters——用户显式写的字段覆盖缺省。
  static Map<String, Object?> runTaskPayload(TtsConfig config) {
    final voice = config.voice?.trim();
    final fallbackVoice = qwenTtsDefaultVoiceForModel(config.model);
    final parameters = <String, Object?>{
      'text_type': 'PlainText',
      'voice': voice == null || voice.isEmpty ? fallbackVoice : voice,
      'format': 'wav',
      'sample_rate': qwenTtsPcmSampleRate,
    };
    final extra = config.extraParams;
    return {
      'task_group': 'audio',
      'task': 'tts',
      'function': 'SpeechSynthesizer',
      'model': config.model.trim(),
      'parameters':
          extra == null ? parameters : mergeTtsExtraIntoInput(parameters, extra),
      'input': <String, Object?>{},
    };
  }

  /// 协商采样率（块上标注，播放端按它初始化）：parameters 里经高级参数
  /// 覆盖后的生效值，缺省 24kHz——请求送的就是它，服务端 WAV 帧头与
  /// 之一致（probe 基线）。
  static int negotiatedSampleRate(TtsConfig config) =>
      switch (runTaskPayload(config)['parameters']) {
        final Map parameters =>
          switch (parameters['sample_rate']) {
            final num rate => rate.toInt(),
            _ => qwenTtsPcmSampleRate,
          },
        _ => qwenTtsPcmSampleRate,
      };

  /// 压缩格式覆盖的 E1 守卫（票 07 评审收口）：高级参数可把
  /// parameters.format 覆盖成 mp3/opus（官方协议支持），此后 binary 帧
  /// 是压缩字节——流式被当 PCM 播噪音、整段被包出无效 WAV。与豆包网关
  /// isStreamablePcm 同律对深合并后的生效 format 判定，只放行 wav/pcm
  /// （wav 帧剥头即裸 PCM，pcm 帧原样透传）；本通道没有 HTTP 回落（地址
  /// 即 WS 端点），压缩值在开会话/合成入口按人话拒绝、不出网。
  static bool isDeliverableAudioFormat(TtsConfig config) =>
      switch (runTaskPayload(config)['parameters']) {
        final Map parameters => switch (parameters['format']) {
          final String format =>
            switch (format.trim().toLowerCase()) {
              'wav' || 'pcm' => true,
              _ => false,
            },
          // 非字符串 format 属脏参数，交给服务端参数校验说话。
          _ => true,
        },
        _ => true,
      };

  @override
  Future<VoiceStreamSession?> openSession({
    required TtsConfig config,
    required String? apiKey,
    required String sessionId,
  }) async => _openSession(config: config, apiKey: apiKey);

  Future<_QwenWsInferenceSession> _openSession({
    required TtsConfig config,
    required String? apiKey,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    // E1 守卫（与豆包网关 isStreamablePcm 同律）：压缩格式覆盖在本通道
    // 交付不了，出网前按人话拒绝——连接子一个字节都不发。
    if (!isDeliverableAudioFormat(config)) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.provider,
        message: '高级参数把音频格式覆盖成了压缩格式，本通道只支持 wav 或 '
            'pcm，请改回后再试。',
      );
    }
    final uri = resolveInferenceUri(config);
    // 用户填的 WS 地址照常过出网 SSRF 校验（与派生地址同律）。
    ensureTtsOutboundAllowed(uri);
    return guardTtsWebSocket(() async {
      // 建连也包超时（与豆包双向/千问 Realtime 同律）：端点不响应时
      // 上界不能只剩 OS/dart:io 默认值。
      final connection = await connector
          .connect(uri: uri, headers: {'authorization': 'Bearer $key'})
          .timeout(timeout);
      final session = _QwenWsInferenceSession(
        connection: connection,
        taskId: newVolcRequestId(),
        runTaskPayload: runTaskPayload(config),
        sampleRate: negotiatedSampleRate(config),
        timeout: timeout,
        diagnosticsSink: stderrDiagnostics,
      );
      session.startReader();
      try {
        // 官方生命周期：run-task 先行，服务端 task-started 后才喂文本
        // （probe 实测 run-task 与 task-started 之间的合法等待形状）。
        session.sendRunTask();
        await session
            .awaitEvent(qwenWsInferenceEventTaskStarted)
            .timeout(timeout);
        // 握手完成：会话中途的空闲计时器这才武装（每帧重置）。
        session.onHandshakeComplete();
      } on Object catch (error) {
        session.cancel();
        throw fromTtsWebSocketFailure(error);
      }
      return session;
    });
  }

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    // 一次性会话收完整 PCM，本地包 WAV 头（现有整段播放器零改动）。
    final session = await _openSession(config: config, apiKey: apiKey);
    try {
      session.appendText(text);
      await session.close();
      final audio = BytesBuilder(copy: false);
      await for (final chunk in session.chunks) {
        audio.add(chunk.bytes);
      }
      final bytes = audio.takeBytes();
      if (bytes.isEmpty) {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务没有返回音频。',
        );
      }
      return wrapPcmAsWav(bytes, sampleRate: negotiatedSampleRate(config));
    } finally {
      session.cancel();
    }
  }

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async* {
    // 句子级流式：本句开一个一次性会话，binary 帧边到边转 PCM 块（帧
    // 已剥 WAV 头），不等整句合成完——与现行千问 SSE 档的按句流式同
    // 口径。失败经块流的错误上报，由分句层按 D1 降级。
    final session = await _openSession(config: config, apiKey: apiKey);
    try {
      session.appendText(text);
      await session.close();
      var produced = false;
      // 空 PCM 块已在会话读循环统一跳过（纯容器头帧不上屏）。
      await for (final chunk in session.chunks) {
        produced = true;
        yield chunk;
      }
      if (!produced) {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务没有返回音频。',
        );
      }
    } finally {
      session.cancel();
    }
  }
}

final class _QwenWsInferenceSession extends WsVoiceStreamSession {
  _QwenWsInferenceSession({
    required ProviderWebSocketConnection connection,
    required this._taskId,
    required this._runTaskPayload,
    required this._sampleRate,
    required Duration timeout,
    required void Function(String message) diagnosticsSink,
  }) : super(connection, timeout, diagnosticsSink);

  final String _taskId;
  final Map<String, Object?> _runTaskPayload;
  final int _sampleRate;

  @override
  int get sampleRate => _sampleRate;

  @override
  Stream<dynamic> get frames => _frames ??= mergeWsFrameStreams(
    connection.textMessages,
    connection.messages,
  );

  Stream<dynamic>? _frames;

  @override
  String get finishedEvent => qwenWsInferenceEventTaskFinished;

  @override
  WsServerFrameAction handleFrame(Object? frame) => switch (frame) {
    final String text => _handleTextEvent(text),
    final List<int> audio => _handleAudioFrame(audio),
    _ => throw const TtsGatewayException(
      kind: ModelFailureKind.contentParsing,
      message: '语音合成服务返回的内容无法解析。',
    ),
  };

  /// 服务端事件（JSON 文本帧）：header.event 命名；task-failed 按允许
  /// 列表映射，其余事件登记（task-started 供握手等待、task-finished
  /// 由基类收束块流），result-generated 等中间事件不参与判定。
  WsServerFrameAction _handleTextEvent(String text) {
    final Map<String, Object?> event;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('inference event must be an object');
      }
      event = decoded;
    } on TtsGatewayException {
      rethrow;
    } on Object {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
    final header = event['header'];
    final name = header is Map<String, Object?> ? header['event'] : null;
    if (name is! String || name.isEmpty) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
    if (name == qwenWsInferenceEventTaskFailed) {
      return WsErrorAction(_qwenInferenceTaskFailedFailure(event));
    }
    return WsEventAction(name);
  }

  /// 音频帧（binary）：实测每帧自带完整 WAV 容器头（probe 02/03），按
  /// 既有剥头口径归一成裸 PCM；裸样本帧（用户经高级参数覆盖 format=pcm）
  /// 不以 RIFF 开头，原样通过。
  WsServerFrameAction _handleAudioFrame(List<int> audio) =>
      WsAudioAction(qwenTtsNormalizeWavChunk(Uint8List.fromList(audio)).pcm);

  void sendRunTask() => _sendAction(qwenWsInferenceActionRunTask, _runTaskPayload);

  @override
  void sendAppend(String text) => _sendAction(qwenWsInferenceActionContinueTask, {
    'input': {'text': text},
  });

  @override
  void sendFinish() =>
      _sendAction(qwenWsInferenceActionFinishTask, {'input': <String, Object?>{}});

  @override
  void sendCancel() =>
      // 协议取消：finish-task 带 directive=cancel（官方文档字段值）。
      _sendAction(qwenWsInferenceActionFinishTask, {
        'input': {'directive': 'cancel'},
      });

  void _sendAction(String action, Map<String, Object?> payload) {
    connection.sendText(
      jsonEncode({
        'header': {
          'action': action,
          'task_id': _taskId,
          'streaming': 'duplex',
        },
        'payload': payload,
      }),
    );
  }
}
