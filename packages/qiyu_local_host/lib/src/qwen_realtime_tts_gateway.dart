import 'dart:convert';
import 'dart:typed_data';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'qwen_tts_gateway.dart';
import 'tts_gateway.dart';
import 'tts_ws_session_skeleton.dart';

// ---------------------------------------------------------------------------
// 千问 Qwen-TTS Realtime（阿里云百炼）
// ---------------------------------------------------------------------------

/// 千问 Realtime WS 型号判定（票三）：型号名以 `-realtime` 结尾即
/// Realtime API 家族（官方仅列 `qwen3-tts-flash-realtime` 与
/// `qwen3-tts-instruct-flash-realtime`），其余千问型号继续走 HTTP SSE
/// （型号驱动，ADR 0018）。
bool isQwenRealtimeTtsModel(String model) =>
    model.trim().toLowerCase().endsWith('-realtime');

/// 千问 Realtime WS 合成网关（票三）：官方 Realtime 风格 JSON 事件协议，
/// 端点 `wss://<host>/api-ws/v1/realtime?model=<型号>`。流式追加文本
/// （`input_text_buffer.append`），`server_commit` 分段模式由服务端决定
/// 合成时机；PCM delta 事件（base64）转块。
///
/// realtime 型号没有 HTTP 整段接口：整段路径（试听、历史重听、连接测试）
/// 开一个一次性会话收完整 PCM，在 Host 本地包 WAV 头后走既有整段播放器。
///
/// 注意：本协议不吃 extraParams（音色走 session.update 的 voice 字段，
/// 没有 instructions 类控制字段的文档入口）——用户在高级参数里给千问
/// realtime 档写的字段不会生效，写不写都不报错。
final class QwenRealtimeTtsGateway
    implements TtsSynthesisGateway, VoiceStreamSessionGateway {
  QwenRealtimeTtsGateway(this.connector, {this.timeout = ttsRequestTimeout});

  final ProviderWebSocketConnector connector;

  /// 空闲超时预算：含握手、音频间隔与收尾等待。
  final Duration timeout;

  /// 派生 WS 地址：baseUrl 是 DashScope HTTP 端点，host/port 保留，路径
  /// 与 model query 按协议写死。http→ws、https→wss。
  static Uri deriveWebSocketUri(TtsConfig config) {
    final base = Uri.parse(config.baseUrl.trim());
    return Uri(
      scheme: base.scheme == 'http' ? 'ws' : 'wss',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/api-ws/v1/realtime',
      queryParameters: {'model': config.model.trim()},
    );
  }

  @override
  Future<VoiceStreamSession?> openSession({
    required TtsConfig config,
    required String? apiKey,
    required String sessionId,
  }) async => _openSession(config: config, apiKey: apiKey);

  Future<_QwenRealtimeSession> _openSession({
    required TtsConfig config,
    required String? apiKey,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = deriveWebSocketUri(config);
    // 派生出的 WS 地址同样过出网校验（与 HTTP 出网同律）。
    ensureTtsOutboundAllowed(uri);
    return guardTtsWebSocket(() async {
      // 建连也包超时（与豆包双向同律）：端点不响应时上界不能只剩 OS/
      // dart:io 默认值。
      final connection = await connector
          .connect(uri: uri, headers: {'authorization': 'Bearer $key'})
          .timeout(timeout);
      final session = _QwenRealtimeSession(
        connection: connection,
        config: config,
        timeout: timeout,
        diagnosticsSink: stderrDiagnostics,
      );
      session.startReader();
      try {
        // 官方生命周期：建连后服务端先回 session.created，客户端再发
        // session.update 配置音色/格式/分段模式。
        await session
            .awaitEvent(qwenRealtimeEventSessionCreated)
            .timeout(timeout);
        session.sendSessionUpdate();
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
    // realtime 型号没有 HTTP 整段接口：一次性会话收完整 PCM，本地包
    // WAV 头（现有整段播放器零改动）。
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
      return wrapPcmAsWav(bytes, sampleRate: qwenTtsPcmSampleRate);
    } finally {
      session.cancel();
    }
  }
}

/// 千问 Realtime 客户端事件名（官方文档 type 字段值）。
const qwenRealtimeEventSessionUpdate = 'session.update';
const qwenRealtimeEventInputTextBufferAppend = 'input_text_buffer.append';
const qwenRealtimeEventSessionFinish = 'session.finish';

/// 千问 Realtime 服务端事件名（官方文档 type 字段值）。
const qwenRealtimeEventSessionCreated = 'session.created';
const qwenRealtimeEventAudioDelta = 'response.audio.delta';
const qwenRealtimeEventSessionFinished = 'session.finished';

final class _QwenRealtimeSession extends WsVoiceStreamSession {
  _QwenRealtimeSession({
    required ProviderWebSocketConnection connection,
    required this._config,
    required Duration timeout,
    required void Function(String message) diagnosticsSink,
  }) : super(connection, timeout, diagnosticsSink);

  final TtsConfig _config;

  @override
  int get sampleRate => qwenTtsPcmSampleRate;

  @override
  Stream<dynamic> get frames => connection.textMessages;

  @override
  String get finishedEvent => qwenRealtimeEventSessionFinished;

  @override
  WsServerFrameAction handleFrame(Object? frame) {
    final Map<String, Object?> event;
    try {
      final decoded = jsonDecode(frame as String);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('realtime event must be an object');
      }
      event = decoded;
    } on Object {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
    final type = event['type'];
    if (type is! String) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
    if (type == qwenRealtimeEventAudioDelta) {
      final delta = event['delta'];
      if (delta is! String || delta.isEmpty) {
        return WsEventAction(type);
      }
      try {
        return WsAudioAction(base64.decode(delta));
      } on Object {
        throw const TtsGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '语音合成服务返回的内容无法解析。',
        );
      }
    }
    // 错误事件按允许列表文案映射（鉴权/限流/服务拒绝），不透第三方原文。
    // 事件名官方未给全表，按 Realtime 家族常见形态识别（推断，ADR 0019）。
    if (type == 'error' || type.endsWith('failed')) {
      return WsErrorAction(_qwenErrorFailure(event));
    }
    return WsEventAction(type);
  }

  void sendSessionUpdate() {
    final voice = _config.voice?.trim();
    connection.sendText(
      jsonEncode({
        'type': qwenRealtimeEventSessionUpdate,
        'session': {
          // 服务端决定分段与合成时机：边喂文本边出音（票三目标形态）。
          'mode': 'server_commit',
          'voice': (voice == null || voice.isEmpty)
              ? qwenTtsDefaultVoice
              : voice,
          'language_type': 'Chinese',
          'response_format': 'pcm',
          'sample_rate': qwenTtsPcmSampleRate,
        },
      }),
    );
  }

  @override
  void sendAppend(String text) {
    connection.sendText(
      jsonEncode({
        'type': qwenRealtimeEventInputTextBufferAppend,
        'text': text,
      }),
    );
  }

  @override
  void sendFinish() {
    connection.sendText(jsonEncode({'type': qwenRealtimeEventSessionFinish}));
  }

  @override
  void sendCancel() {
    // 协议没有会话取消事件：断开连接即作废（基类负责断链）。
  }
}

/// 千问 Realtime 错误事件的允许列表映射：鉴权/限流/服务拒绝三档，第三
/// 方错误原文绝不透出。
TtsGatewayException _qwenErrorFailure(Map<String, Object?> event) {
  final error = event['error'];
  final code = error is Map<String, Object?> ? error['code'] : null;
  if (code is String) {
    final normalized = code.toLowerCase();
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
