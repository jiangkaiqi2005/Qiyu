import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';

// ---------------------------------------------------------------------------
// Omni 实时对话（ADR 0026，T02）：qwen3.8-omni-flash-realtime 经 DashScope
// Realtime WebSocket 直接听说文字与语音。本文件只承载 T01 原型（2026-10-02
// 真实凭据实测）已经核实的事件形状；未核实事件（conversation.item.truncate、
// input_text_buffer.*、session.finish 等）一律不发不判，不做兼容猜测。
// ---------------------------------------------------------------------------

/// Omni 实时会话的默认音色。服务端 `session.created` 回显的默认音色
/// Chelsie 在实际生成音频时被拒（400 `Voice 'Chelsie' is not supported`，
/// 连不做 session.update 的裸会话也一样；Cherry/Ethan/Nyla/Nova 同拒），
/// 因此会话配置必须显式携带已核实可生成的音色，绝不依赖服务端默认值。
/// Tina 与 Serena 实测可正常生成，起步取 Tina；最终默认音色属产品裁定。
const qwenOmniRealtimeDefaultVoice = 'Tina';

/// 输出音频的协商采样率：会话显式设置 `output_audio_format: pcm24`
/// （24000 Hz 单声道 16-bit，实测回显一致）；`response.audio.delta`
/// 解码后的 PCM 块按该速率交付播放端。
const qwenOmniRealtimeOutputSampleRate = 24000;

/// 会话配置的实测必带字段（2026-10-02 真实端点对拍：省略这些字段的
/// session.update 被接受且回显，但随后的 response.create 一律被拒
/// `COMMON_ERROR`，无响应——T01 §13.2「格式字段可省」的推断对本端点
/// 不成立，故音频与纯文字两种模式都按 T01 §4 的完整扁平形状下发）。
const qwenOmniRealtimeInputAudioFormat = 'pcm16';
const qwenOmniRealtimeOutputAudioFormat = 'pcm24';
const qwenOmniRealtimeInputTranscriptionModel = 'gummy-realtime-v1';

/// 轮次检测（turn_detection）的会话配置。spec 以 semantic_vad 为起点，
/// 但 T01 §1.1 实测 semantic_vad 裸配 22 轮漏检 4 轮（18% 整轮漏检，
/// 连 speech_started 都不触发），server_vad（官方默认参数 threshold
/// 0.5）22/22 全响应——初值取 server_vad；最终选型与参数调优待原型
/// 证据裁定后由会话配置参数传入，不新增用户配置面。
enum OmniRealtimeTurnDetection {
  serverVad('server_vad'),
  semanticVad('semantic_vad');

  const OmniRealtimeTurnDetection(this.wireName);

  final String wireName;
}

/// 原生函数工具（扁平 OpenAI 形）。T01 §4 实测只有扁平形状
/// `{type:'function', name, description, parameters}` 被服务端真实注册；
/// chat-completions 嵌套 `{type, function:{…}}` 会被回显但不注册，禁止使用。
final class OmniRealtimeTool {
  const OmniRealtimeTool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;

  /// JSON Schema（object 形状），原样进入 session.update。
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() => {
    'type': 'function',
    'name': name,
    'description': description,
    'parameters': parameters,
  };
}

/// 实时会话配置（session.update 的载荷参数）。[instructions] 是全量人格
/// 提示词——T01 §11 实测 session.update 的 instructions 为整体替换而非
/// 合并，热层刷新即重发完整提示词。[voice] 空缺时用
/// [qwenOmniRealtimeDefaultVoice]（见常量注释）。[audioOutput] 为 false
/// 时是纯文字会话（modalities ['text']，实测纯文字轮只产 response.text
/// 事件，零音频事件——记忆维护等文字调用走此模式）。其余字段（音色、
/// 输入/输出音频格式、输入转录模型、turn_detection）在两种模式下都
/// 实测必带，见 [qwenOmniRealtimeInputAudioFormat] 等常量注释。
final class OmniRealtimeSessionConfig {
  const OmniRealtimeSessionConfig({
    required this.instructions,
    this.voice,
    this.audioOutput = true,
    this.turnDetection = OmniRealtimeTurnDetection.serverVad,
    this.tools = const [],
  });

  final String instructions;
  final String? voice;
  final bool audioOutput;
  final OmniRealtimeTurnDetection turnDetection;
  final List<OmniRealtimeTool> tools;

  /// 生效音色：空缺回落默认音色（生成时刻被拒的服务端默认值绝不依赖）。
  String get effectiveVoice {
    final trimmed = voice?.trim();
    return trimmed == null || trimmed.isEmpty
        ? qwenOmniRealtimeDefaultVoice
        : trimmed;
  }

  Map<String, Object?> toSessionPayload() => {
    if (instructions.trim().isNotEmpty) 'instructions': instructions,
    'modalities': audioOutput ? const ['text', 'audio'] : const ['text'],
    'voice': effectiveVoice,
    'input_audio_format': qwenOmniRealtimeInputAudioFormat,
    'output_audio_format': qwenOmniRealtimeOutputAudioFormat,
    'input_audio_transcription': {
      'model': qwenOmniRealtimeInputTranscriptionModel,
    },
    'turn_detection': {'type': turnDetection.wireName},
    if (tools.isNotEmpty) 'tools': [for (final tool in tools) tool.toJson()],
  };
}

/// 服务端事件归一后的会话事件面。只承载 T01 已核实的事件；未知事件类型
/// 忽略并记诊断（不猜兼容），[OmniRealtimeSessionFailed] 之后事件流结束。
sealed class OmniRealtimeEvent {
  const OmniRealtimeEvent(this.responseId);

  /// 所属回复（response）的 id；会话级事件（VAD、输入转录、会话失败）
  /// 为 null。请求级看门狗超时（response.created 未到）也为 null。
  final String? responseId;
}

/// 会话配置被服务端接受的回执（session.updated）：session.update（含热层
/// 刷新）的确认信号（T01 §11 实测整体替换、下一条回复生效）。
final class OmniRealtimeSessionUpdated extends OmniRealtimeEvent {
  const OmniRealtimeSessionUpdated() : super(null);
}

/// 用户语音输入的完整转写
/// （conversation.item.input_audio_transcription.completed）。
final class OmniRealtimeInputTranscript extends OmniRealtimeEvent {
  const OmniRealtimeInputTranscript(this.text) : super(null);

  final String text;
}

/// 服务端 VAD 判定用户开口（input_audio_buffer.speech_started）。
final class OmniRealtimeSpeechStarted extends OmniRealtimeEvent {
  const OmniRealtimeSpeechStarted() : super(null);
}

/// 服务端 VAD 判定用户说完（input_audio_buffer.speech_stopped）。
final class OmniRealtimeSpeechStopped extends OmniRealtimeEvent {
  const OmniRealtimeSpeechStopped() : super(null);
}

/// 回复可见文字增量：有声回复取同回复的 audio_transcript.delta，纯文字
/// 回复取 response.text.delta，两种已核实来源归一成一个事件（T02:13——
/// 不生成另一份显示稿，也不等待整轮缓存）。
final class OmniRealtimeReplyDelta extends OmniRealtimeEvent {
  const OmniRealtimeReplyDelta(super.responseId, this.text);

  final String text;
}

/// 回复音频块：response.audio.delta 的 base64 解码结果（裸 PCM，采样率
/// [qwenOmniRealtimeOutputSampleRate]）。收到即交付，不做内容审判。
final class OmniRealtimeAudioChunk extends OmniRealtimeEvent {
  const OmniRealtimeAudioChunk(super.responseId, this.bytes);

  final List<int> bytes;
}

/// 原生工具调用（arguments 完整后一次性交付；T01 §9 实测工具参数零发声）。
final class OmniRealtimeToolCall extends OmniRealtimeEvent {
  const OmniRealtimeToolCall(
    super.responseId, {
    required this.itemId,
    required this.callId,
    required this.name,
    required this.arguments,
  });

  final String itemId;
  final String callId;
  final String name;

  /// 完整参数 JSON（response.function_call_arguments.done 的原文）。
  final String arguments;
}

/// 单个 response 的终态（response.done 的 status）。完成判定只认这里的
/// status——`response.audio.done` 在取消时也会到达，不是完成信号（T01
/// §13.3）；cancelled 即原生打断（T01 §8.3：speech_started 同毫秒以
/// cancelled 收束，不存在独立的取消事件）。
enum OmniRealtimeResponseStatus { completed, cancelled, failed, incomplete }

final class OmniRealtimeResponseFinished extends OmniRealtimeEvent {
  const OmniRealtimeResponseFinished(super.responseId, this.status);

  final OmniRealtimeResponseStatus status;
}

/// 单个回复的本地看门狗超时：建连后模型长时间无输出是真实故障（T01 §11
/// 实测服务端降级窗口——会话能建连、能 ACK item，但模型完全不产出且无
/// close 帧），有界处理为该回复不再等待；会话本身继续可用，重连与否由
/// 调用方按自身恢复策略决定。[responseId] 为 null 表示请求级悬空——
/// response.create 已发但 response.created 始终未到（T01 §9.4 实测服务端
/// 会静默忽略续答请求）。
final class OmniRealtimeResponseTimedOut extends OmniRealtimeEvent {
  const OmniRealtimeResponseTimedOut(super.responseId);
}

/// 会话级失败（error 事件、无帧断开、EOF、建连/就绪超时）：会话进入
/// 不可用态，本事件之后事件流结束。第三方错误原文不透出，只给分类文案。
final class OmniRealtimeSessionFailed extends OmniRealtimeEvent {
  const OmniRealtimeSessionFailed(this.kind, this.message) : super(null);

  final ModelFailureKind kind;
  final String message;
}

/// Omni 实时会话网关：建立 WebSocket 连接、下发 session 配置并等待
/// session.updated 就绪回执。凭据经 Authorization: Bearer 头出网（T01
/// §13.1 实测形态），Key 只在 Host 内流转，绝不进事件流或诊断输出。
/// 出网走 WebSocket 连接子直连（与语音 WS 网关同律，不经 HTTP 代理通道）。
final class QwenOmniRealtimeGateway {
  const QwenOmniRealtimeGateway(this.connector, {this.diagnosticsSink});

  final ProviderWebSocketConnector connector;
  final void Function(String message)? diagnosticsSink;

  /// 会话地址：配置的 baseUrl 为完整实时端点（路径与 query 原样保留），
  /// 型号以 `model` query 参数携带（T01 §13.1 实测形态）；地址里已带的
  /// model 参数以配置为准覆盖。
  Uri resolveUri(ProviderConfig config) {
    final base = Uri.parse(config.baseUrl.trim());
    return base.replace(
      queryParameters: {...base.queryParameters, 'model': config.model.trim()},
    );
  }

  /// 建连并完成会话配置：配置校验 → Key 必填 → 出网 SSRF 校验（ws/wss
  /// 限公网目标，与语音 WS 出网同律）→ WebSocket 握手 → session.update
  /// → 等待 session.updated（T01 §6 的冷启动边界）。超时与断线按
  /// [ModelFailureKind] 分类抛 [ModelGatewayException]；期限取配置的
  /// timeoutSeconds（覆盖建连、就绪与后续每个回复的看门狗空闲上界）。
  Future<OmniRealtimeSession> connect({
    required ProviderConfig config,
    required String? apiKey,
    required OmniRealtimeSessionConfig sessionConfig,
  }) async {
    config.validate();
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.authentication,
        message: '还没有保存 API Key。',
      );
    }
    final uri = resolveUri(config);
    final refusal = speechOutboundRefusalReason(uri);
    if (refusal != null) {
      throw ModelGatewayException(
        kind: ModelFailureKind.network,
        message: refusal,
      );
    }
    final timeout = Duration(seconds: config.timeoutSeconds);
    final ProviderWebSocketConnection connection;
    try {
      connection = await connector
          .connect(uri: uri, headers: {'authorization': 'Bearer $key'})
          .timeout(timeout);
    } on TimeoutException {
      _diagnose('omni realtime connect timeout');
      throw const ModelGatewayException(
        kind: ModelFailureKind.timeout,
        message: '连接模型服务超时。',
      );
    } on HandshakeException {
      _diagnose('omni realtime connect tls error');
      throw const ModelGatewayException(
        kind: ModelFailureKind.tls,
        message: '模型服务的 TLS 安全连接失败。',
      );
    } on SocketException catch (error) {
      final failure = providerSocketFailure(error, serviceLabel: '模型服务');
      _diagnose('omni realtime connect socket error [${failure.kind}]');
      throw failure;
    } on Object {
      _diagnose('omni realtime connect error');
      throw const ModelGatewayException(
        kind: ModelFailureKind.network,
        message: '无法连接模型服务。',
      );
    }
    final session = OmniRealtimeSession._(
      connection,
      timeout,
      (message) => diagnosticsSink?.call(message),
    );
    // 先挂读循环（订阅在发送之前，T01 §12.4）再发 session.update。
    session._start();
    try {
      session.updateSession(sessionConfig);
      await session._awaitSessionUpdated().timeout(timeout);
    } on ModelGatewayException catch (error) {
      await session.close();
      _diagnose('omni realtime session ready failed [${error.kind}]');
      rethrow;
    } on TimeoutException {
      await session.close();
      _diagnose('omni realtime session ready timeout');
      throw const ModelGatewayException(
        kind: ModelFailureKind.timeout,
        message: '连接模型服务超时。',
      );
    } on Object catch (error) {
      await session.close();
      _diagnose('omni realtime session ready error [$error]');
      throw const ModelGatewayException(
        kind: ModelFailureKind.network,
        message: '无法连接模型服务。',
      );
    }
    return session;
  }

  /// 文字模型调用的 Omni 接线（T02:14）：记忆维护等需要文字模型的调用
  /// 按 T01 §10 已核实的纯文字模式跑一次会话内轮次——system 消息并入
  /// instructions，其余消息按原序重放为会话 item，然后 response.create，
  /// 收集本回复的 response.text 增量直到 response.done。选中 Omni 后
  /// 维护调用走这里，不悄悄沿用旧聊天模型。回复非 completed（取消/失败/
  /// 不完整/超时/会话失败）一律抛 [ModelGatewayException]，半句不当完整
  /// 回复。maxTokens 在实时协议侧没有已核实字段，不发送，输出长度依赖
  /// 模型自身上限——超长输出按失败降级，由调用方既有补跑机制兜底。
  Future<String> completeText({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
  }) async {
    final session = await connect(
      config: config,
      apiKey: apiKey,
      sessionConfig: OmniRealtimeSessionConfig(
        instructions: messages
            .where((message) => message.role == ModelMessageRole.system)
            .map((message) => message.content)
            .join('\n'),
        audioOutput: false,
      ),
    );
    final replyText = StringBuffer();
    final completion = Completer<void>();
    ModelFailureKind? failureKind;
    String? failureMessage;
    late final StreamSubscription<OmniRealtimeEvent> subscription;
    subscription = session.events.listen((event) {
      if (completion.isCompleted) {
        return;
      }
      switch (event) {
        case OmniRealtimeReplyDelta(:final text):
          replyText.write(text);
        case OmniRealtimeResponseFinished(:final status):
          switch (status) {
            case OmniRealtimeResponseStatus.completed:
              completion.complete();
            case OmniRealtimeResponseStatus.cancelled:
              failureKind = ModelFailureKind.network;
              failureMessage = '模型回复在完成前被中止。';
              completion.complete();
            case OmniRealtimeResponseStatus.failed:
              failureKind = ModelFailureKind.provider;
              failureMessage = '模型服务返回了错误。';
              completion.complete();
            case OmniRealtimeResponseStatus.incomplete:
              failureKind = ModelFailureKind.contentParsing;
              failureMessage = '模型回复在完成前被截断。';
              completion.complete();
          }
        case OmniRealtimeResponseTimedOut():
          failureKind = ModelFailureKind.timeout;
          failureMessage = '模型服务响应超时。';
          completion.complete();
        case OmniRealtimeSessionFailed(:final kind, :final message):
          failureKind = kind;
          failureMessage = message;
          completion.complete();
        default:
          break;
      }
    });
    try {
      // 纯文字会话无 VAD、无音频回复：事件流里只有本轮回复的增量，全部
      // 收集即本轮正文（旧事件隔离由会话侧按 response 归属保证）。
      for (final message in messages) {
        switch (message.role) {
          case ModelMessageRole.system:
            break;
          case ModelMessageRole.user:
            session.sendUserItem(message.content);
          case ModelMessageRole.assistant:
            session.sendAssistantItem(message.content);
        }
      }
      session.createResponse();
      await completion.future;
    } finally {
      await subscription.cancel();
      await session.close();
    }
    // failureKind/failureMessage 在事件回调里赋值，Dart 无法对闭包赋值
    // 的变量做提升，这里落回局部变量再判空。
    final settledKind = failureKind;
    final settledMessage = failureMessage;
    if (settledKind != null) {
      throw ModelGatewayException(kind: settledKind, message: settledMessage!);
    }
    final reply = replyText.toString().trim();
    if (reply.isEmpty) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的内容无法解析。',
      );
    }
    return reply;
  }

  void _diagnose(String message) => diagnosticsSink?.call(message);
}

/// 一条已就绪（session.updated 已回）的 Omni 实时会话。事件经 [events]
/// 广播；客户端动作全部是即发即收的文本帧，不等待逐帧确认（协议以服务端
/// 事件回推为准）。响应轮归属与旧事件隔离：只有见过 response.created 的
/// 回复才被交付，回复终态（response.done / 本地看门狗超时）之后同 id 的
/// 迟到事件一律丢弃（T02:15——后到的旧回复事件不能继续播放或追加文字）。
final class OmniRealtimeSession {
  OmniRealtimeSession._(this._connection, this._timeout, this._diagnostics);

  final ProviderWebSocketConnection _connection;
  final Duration _timeout;
  final void Function(String) _diagnostics;

  final _events = StreamController<OmniRealtimeEvent>.broadcast();
  final _sessionUpdated = Completer<void>();
  final _doneCompleter = Completer<void>();

  /// 客户端事件 id 全连接唯一（T01 §12.1：复用导致服务端丢弃后续上行、
  /// VAD 停摆），递增计数保证。
  int _eventId = 0;

  bool _closed = false;
  bool _failed = false;
  ModelGatewayException? _failure;

  final _knownResponses = <String>{};
  final _finishedResponses = <String>{};
  final _responseWatchdogs = <String, Timer>{};
  final _functionItems = <String, ({String callId, String name})>{};
  final _argumentBuffers = <String, StringBuffer>{};

  /// 客户端 response.create 已发但 response.created 未到的悬空等待：
  /// 覆盖「服务端静默忽略 response.create」（T01 §9.4 实测——收下
  /// function_call_output 却不响应，无 error）。
  Timer? _pendingCreateWatchdog;

  /// 会话事件流（广播）。[OmniRealtimeSessionFailed] 之后流结束。
  Stream<OmniRealtimeEvent> get events => _events.stream;

  /// 会话结束（主动关闭、失败或断线）后完成。
  Future<void> get done => _doneCompleter.future;

  bool get isClosed => _closed || _failed;

  void _start() {
    _connection.textMessages.listen(
      _handleFrame,
      onError: (Object error) {
        if (_closed || _failed) {
          return;
        }
        _diagnose('omni realtime stream error [$error]');
        _failSession(
          error is SocketException
              ? providerSocketFailure(error, serviceLabel: '模型服务').kind
              : ModelFailureKind.network,
          '与模型服务的实时连接中断。',
        );
      },
      onDone: () {
        if (_closed || _failed) {
          return;
        }
        // 无帧断开（T01 §13.7：code=null 的静默断开真实存在）与正常
        // 关帧在本抽象下同形，都按连接结束处理，恢复策略归调用方。
        _diagnose('omni realtime stream closed by remote');
        _failSession(ModelFailureKind.network, '与模型服务的实时连接已断开。');
      },
    );
  }

  // --- 客户端动作（即发即收；会话终结后一律空操作） ---

  /// 下发（或刷新）会话配置：instructions 为整体替换（T01 §11），热层
  /// 刷新即用新配置重发；接受回执经 [events] 的
  /// [OmniRealtimeSessionUpdated] 确认。
  void updateSession(OmniRealtimeSessionConfig config) =>
      _send({'type': 'session.update', 'session': config.toSessionPayload()});

  /// 上行一段输入音频：PCM16 单声道字节（采集口径 16 kHz，spec:70），
  /// base64 后进 input_audio_buffer.append；收到即发，不缓冲整轮。
  void appendAudio(List<int> pcmBytes) => _send({
    'type': 'input_audio_buffer.append',
    'audio': base64Encode(pcmBytes),
  });

  /// 发送一条用户文字 item（通话中打字，T01 §13.6 实测 message item +
  /// input_text 形状可用），不触发回复。
  void sendUserItem(String text) => _sendItem('user', 'input_text', text);

  /// 回放一条 assistant 文字 item（重连后本机上下文恢复，T01 §11 实测
  /// 重放后模型可准确续接）。
  void sendAssistantItem(String text) => _sendItem('assistant', 'text', text);

  void _sendItem(String role, String contentType, String text) => _send({
    'type': 'conversation.item.create',
    'item': {
      'type': 'message',
      'role': role,
      'content': [
        {'type': contentType, 'text': text},
      ],
    },
  });

  /// 回填原生工具结果并请求续答（T01 §9.3 实测：function_call_output +
  /// response.create 可正常续答；回填必须尽快于 call 之后、用户新轮之前
  /// ——回填前插入用户新轮会被服务端静默忽略，该时序约束由调用方保证）。
  void sendToolResult({required String callId, required String output}) {
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'function_call_output',
        'call_id': callId,
        'output': output,
      },
    });
    createResponse();
  }

  /// 请求生成一个回复（裸 response.create；文字重放或工具回填后的续答
  /// 触发点）。看门狗自发送时刻起算，服务端静默忽略也有界可察。
  void createResponse() {
    _send({'type': 'response.create'});
    _pendingCreateWatchdog ??= Timer(_timeout, () {
      _pendingCreateWatchdog = null;
      _diagnose('omni realtime response.create unanswered');
      _publish(const OmniRealtimeResponseTimedOut(null));
    });
  }

  /// 主动结束会话：客户端直接关闭 WebSocket 帧（session.finish 不被本
  /// 型号支持——T01 §10 实测返回 error 且连接保持，收束只能走关闭帧）。
  /// 幂等。
  Future<void> close() async {
    if (_closed) {
      return _doneCompleter.future;
    }
    _closed = true;
    _diagnose('omni realtime session closed by client');
    await _connection.close();
    _finish();
    return _doneCompleter.future;
  }

  // --- 服务端帧处理 ---

  void _handleFrame(String frame) {
    if (_closed || _failed) {
      return;
    }
    final Map<String, Object?> event;
    try {
      final decoded = jsonDecode(frame);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('realtime event must be an object');
      }
      event = decoded;
    } on FormatException {
      _diagnose('omni realtime undecodable frame');
      _failIncompatible();
      return;
    }
    switch (event['type']) {
      case 'session.updated':
        if (!_sessionUpdated.isCompleted) {
          _sessionUpdated.complete();
        }
        _publish(const OmniRealtimeSessionUpdated());
      case 'input_audio_buffer.speech_started':
        _publish(const OmniRealtimeSpeechStarted());
      case 'input_audio_buffer.speech_stopped':
        _publish(const OmniRealtimeSpeechStopped());
      case 'conversation.item.input_audio_transcription.completed':
        final transcript = event['transcript'];
        if (transcript is String && transcript.isNotEmpty) {
          _publish(OmniRealtimeInputTranscript(transcript));
        }
      case 'response.created':
        final id = _responseId(event);
        if (id == null) {
          _failIncompatible();
          return;
        }
        _knownResponses.add(id);
        // 客户端请求的回复：悬空等待挂到具体回复上。
        _pendingCreateWatchdog?.cancel();
        _pendingCreateWatchdog = null;
        _armWatchdog(id);
      case 'response.output_item.added' || 'conversation.item.created':
        _registerItem(event['item']);
      case 'response.audio.delta':
        final attributed = _attributable(event);
        if (attributed == null) {
          return;
        }
        final delta = event['delta'];
        if (delta is! String || delta.isEmpty) {
          return;
        }
        final List<int> bytes;
        try {
          bytes = base64Decode(delta);
        } on FormatException {
          _failIncompatible();
          return;
        }
        _publish(OmniRealtimeAudioChunk(attributed, bytes));
        _armWatchdog(attributed);
      case 'response.audio_transcript.delta' || 'response.text.delta':
        final attributed = _attributable(event);
        if (attributed == null) {
          return;
        }
        final delta = event['delta'];
        if (delta is String && delta.isNotEmpty) {
          _publish(OmniRealtimeReplyDelta(attributed, delta));
        }
        _armWatchdog(attributed);
      case 'response.function_call_arguments.delta':
        final attributed = _attributable(event);
        if (attributed == null) {
          return;
        }
        final delta = event['delta'];
        final itemId = event['item_id'];
        if (delta is String &&
            delta.isNotEmpty &&
            itemId is String &&
            itemId.isNotEmpty) {
          _argumentBuffers.putIfAbsent(itemId, StringBuffer.new).write(delta);
        }
        _armWatchdog(attributed);
      case 'response.function_call_arguments.done':
        final attributed = _attributable(event);
        if (attributed == null) {
          return;
        }
        final itemId = event['item_id'];
        if (itemId is! String) {
          _failIncompatible();
          return;
        }
        final item = _functionItems[itemId];
        if (item == null) {
          // 工具 item 未登记 = 无法回填结果，工具链路已断，如实失败。
          _diagnose('omni realtime function call without registered item');
          _failIncompatible();
          return;
        }
        final doneArguments = event['arguments'];
        final arguments = doneArguments is String && doneArguments.isNotEmpty
            ? doneArguments
            : (_argumentBuffers.remove(itemId)?.toString() ?? '');
        _argumentBuffers.remove(itemId);
        _publish(
          OmniRealtimeToolCall(
            attributed,
            itemId: itemId,
            callId: item.callId,
            name: item.name,
            arguments: arguments,
          ),
        );
        _armWatchdog(attributed);
      case 'response.done':
        final response = event['response'];
        if (response is! Map<String, Object?>) {
          _failIncompatible();
          return;
        }
        final id = response['id'];
        final status = response['status'];
        if (id is! String || status is! String) {
          _failIncompatible();
          return;
        }
        // 终态事件同样过归属检查：本地已终结（含看门狗超时）或未知的
        // 迟到 done 不再交付，避免旧回复的终态复活（T02:15）。
        if (_finishedResponses.contains(id) || !_knownResponses.contains(id)) {
          _diagnose(
            'omni realtime response.done for settled/unknown response dropped [$id]',
          );
          return;
        }
        final mapped = switch (status) {
          'completed' => OmniRealtimeResponseStatus.completed,
          'cancelled' => OmniRealtimeResponseStatus.cancelled,
          'failed' => OmniRealtimeResponseStatus.failed,
          'incomplete' => OmniRealtimeResponseStatus.incomplete,
          // 未核实状态按协议不兼容失败关闭，不猜语义（T02:19）。
          _ => null,
        };
        if (mapped == null) {
          _diagnose('omni realtime unknown response status [$status]');
          _failIncompatible();
          return;
        }
        _settleResponse(id);
        _publish(OmniRealtimeResponseFinished(id, mapped));
      case 'error':
        // 错误面全覆盖（T01 §12.5）：错误事件、无帧断开、降级静默三层
        // 之外，错误载荷只按允许列表指纹分类，原文绝不透出。
        _diagnose('omni realtime server error event');
        final (kind, message) = _serverErrorFailure(event);
        _failSession(kind, message);
      case _:
        // 未核实事件忽略并记诊断（含 rate_limits 等已知无害事件），
        // 不参与任何判定。
        _diagnose('omni realtime ignored event [${event['type']}]');
    }
  }

  /// response 归属检查：事件携带的 response 必须是已知且未终结的回复，
  /// 返回 id；否则按旧事件/游离事件丢弃并记诊断（T02:15 旧事件隔离）。
  String? _attributable(Map<String, Object?> event) {
    final id = _responseId(event);
    if (id == null) {
      _diagnose('omni realtime event without response id');
      return null;
    }
    if (_finishedResponses.contains(id)) {
      _diagnose('omni realtime late event for finished response dropped');
      return null;
    }
    if (!_knownResponses.contains(id)) {
      _diagnose('omni realtime stray event for unknown response dropped');
      return null;
    }
    return id;
  }

  String? _responseId(Map<String, Object?> event) {
    final id = event['response_id'];
    if (id is String && id.isNotEmpty) {
      return id;
    }
    // response.created / response.done 的 id 在嵌套的 response 对象里。
    final response = event['response'];
    final nested = response is Map<String, Object?> ? response['id'] : null;
    return nested is String && nested.isNotEmpty ? nested : null;
  }

  /// 从 item 事件登记 function_call 的 item_id → (call_id, name) 映射，
  /// 供 arguments.done 配对回填（T01 §9 实测 item 先于参数事件到达）。
  void _registerItem(Object? item) {
    if (item is! Map<String, Object?> || item['type'] != 'function_call') {
      return;
    }
    final id = item['id'];
    final callId = item['call_id'];
    final name = item['name'];
    if (id is String && callId is String && name is String) {
      _functionItems[id] = (callId: callId, name: name);
    }
  }

  // --- 看门狗（回复空闲上界） ---

  /// 武装（或续期）一个回复的空闲看门狗：回复仍有事件流动就重置计时，
  /// 只抓「模型长时间无输出」的静默故障，不惩罚正常的长回复流（T01 §11
  /// 降级窗口的形态是彻底无产出）。
  void _armWatchdog(String responseId) {
    if (_closed || _failed) {
      return;
    }
    _responseWatchdogs.remove(responseId)?.cancel();
    _responseWatchdogs[responseId] = Timer(_timeout, () {
      _diagnose('omni realtime response idle watchdog fired [$responseId]');
      _settleResponse(responseId);
      _publish(OmniRealtimeResponseTimedOut(responseId));
    });
  }

  void _settleResponse(String responseId) {
    _finishedResponses.add(responseId);
    _responseWatchdogs.remove(responseId)?.cancel();
  }

  void _teardownWatchdogs() {
    _pendingCreateWatchdog?.cancel();
    _pendingCreateWatchdog = null;
    for (final timer in _responseWatchdogs.values) {
      timer.cancel();
    }
    _responseWatchdogs.clear();
  }

  // --- 会话收束与发布 ---

  void _failIncompatible() {
    _diagnose('omni realtime incompatible protocol shape');
    _failSession(ModelFailureKind.incompatibleResponse, '模型服务返回了不兼容的响应格式。');
  }

  /// error 事件的允许列表分类（指纹沿用语音网关口径，第三方错误原文
  /// 绝不透出）。
  (ModelFailureKind, String) _serverErrorFailure(Map<String, Object?> event) {
    final error = event['error'];
    final code = error is Map<String, Object?> ? error['code'] : null;
    final type = error is Map<String, Object?> ? error['type'] : null;
    final fingerprints = '$code $type'.toLowerCase();
    if (fingerprints.contains('auth') ||
        fingerprints.contains('api_key') ||
        fingerprints.contains('apikey') ||
        fingerprints.contains('permission') ||
        fingerprints.contains('unauthorized')) {
      return (ModelFailureKind.authentication, 'API Key 未通过模型服务验证。');
    }
    if (fingerprints.contains('rate') ||
        fingerprints.contains('quota') ||
        fingerprints.contains('limit') ||
        fingerprints.contains('throttl')) {
      return (ModelFailureKind.rateLimited, '模型服务请求过于频繁。');
    }
    if (fingerprints.contains('model') &&
        (fingerprints.contains('notfound') ||
            fingerprints.contains('not_found'))) {
      return (ModelFailureKind.modelNotFound, '模型名称不存在或当前账号不可用。');
    }
    return (ModelFailureKind.provider, '模型服务返回了错误。');
  }

  void _failSession(ModelFailureKind kind, String message) {
    if (_closed || _failed) {
      return;
    }
    _failed = true;
    _failure = ModelGatewayException(kind: kind, message: message);
    _events.add(OmniRealtimeSessionFailed(kind, message));
    _finish();
    unawaited(_connection.close());
  }

  void _publish(OmniRealtimeEvent event) {
    if (_closed || _failed || _events.isClosed) {
      return;
    }
    _events.add(event);
  }

  void _finish() {
    _teardownWatchdogs();
    if (!_sessionUpdated.isCompleted) {
      _sessionUpdated.complete();
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
    unawaited(_events.close());
  }

  /// 等待 session.updated 回执；会话在等待期间失败时以会话失败异常完成
  /// （connect 的就绪等待据此区分「就绪」与「建连后即失败」）。
  Future<void> _awaitSessionUpdated() async {
    final failure = _failure;
    if (failure != null) {
      throw failure;
    }
    await _sessionUpdated.future;
    final settled = _failure;
    if (settled != null) {
      throw settled;
    }
  }

  void _send(Map<String, Object?> payload) {
    if (_closed || _failed) {
      return;
    }
    _connection.sendText(
      jsonEncode({'event_id': 'ev-${++_eventId}', ...payload}),
    );
  }

  void _diagnose(String message) => _diagnostics(message);
}
