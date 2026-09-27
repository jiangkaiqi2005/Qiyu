import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:shelf/shelf.dart';

import 'api_http.dart';
import 'markdown_memory_repository.dart';
import 'stt_settings_service.dart';
import 'tts_settings_service.dart';

/// 语音领域路由：录音转写（STT）与栖语回复朗读（TTS）。
///
/// 虽然挂在 api/chat/ 路径下，但两者是独立于聊天文本链路的语音
/// 管线（ADR 0001/0002）：本模块持有语音领域的路径匹配、二进制与
/// JSON payload 解析、音频响应序列化与 Stt/TtsServiceException 到
/// HTTP 状态的翻译；删除本模块，这些职责会整体摊回路由总控。
final class VoiceRoutes implements ApiRoutes {
  VoiceRoutes({
    required this.sttSettingsService,
    required this.ttsSettingsService,
    required this.memoryRepository,
  });

  final SttSettingsService sttSettingsService;
  final TtsSettingsService ttsSettingsService;

  /// 朗读端点从这里取已落盘的栖语 turn 文字（Host 是文字真相源）。
  final MemoryRepository memoryRepository;

  /// 朗读音频响应头：音频字节直出（PCM 档已由 Host 包 WAV 头，容器由
  /// 播放端嗅探），不落盘不缓存。
  static const _audioHeaders = {
    HttpHeaders.contentTypeHeader: 'audio/mpeg',
    HttpHeaders.cacheControlHeader: 'no-store',
  };

  /// 语音转写请求体上限：一次 60 秒以内的浏览器录音（opus/webm 远低于
  /// 该值）；超限直接拒绝，不进入转写。
  static const _transcribeMaxBytes = 10 * 1024 * 1024;

  @override
  Future<Response?> handle(Request request) async {
    // 领域差异只有语音服务故障；请求体不可读、invalid_request、Provider
    // 配置故障与记忆仓储故障走共享翻译前导。
    return runApiRoute(
      () => _route(request),
      translateDomainError: (error) => switch (error) {
        SttServiceException(
          :final code,
          :final message,
          :final retryable,
        ) =>
          _voiceServiceError(code, message, retryable),
        TtsServiceException(
          :final code,
          :final message,
          :final retryable,
        ) =>
          _voiceServiceError(code, message, retryable),
        _ => null,
      },
    );
  }

  /// 语音服务异常的统一口径：未配置、请求本身与本地配置无效等本地
  /// 缺陷按客户端错误，上游合成/转写失败按网关错误。
  Response _voiceServiceError(String code, String message, bool retryable) {
    const clientErrorCodes = {
      'stt_not_configured',
      'stt_no_speech',
      'stt_config_invalid',
      'tts_not_configured',
      'tts_config_invalid',
      'tts_empty_text',
      'tts_text_too_long',
      'tts_turn_not_found',
    };
    return jsonError(
      clientErrorCodes.contains(code)
          ? HttpStatus.badRequest
          : HttpStatus.badGateway,
      code: code,
      message: message,
      retryable: retryable,
    );
  }

  Future<Response?> _route(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'POST' && path == 'api/chat/transcribe') {
      final audio = await readLimitedBytes(
        request,
        maxBytes: _transcribeMaxBytes,
        onOversize: () => invalidRequest('录音文件太大，请录短一些再试。'),
      );
      final contentType = request.headers[HttpHeaders.contentTypeHeader];
      final mimeType = contentType?.split(';').first.trim().toLowerCase();
      if (mimeType == null || !mimeType.startsWith('audio/')) {
        throw invalidRequest('音频请求格式不正确。');
      }
      final text = await sttSettingsService.transcribe(
        audio: audio,
        mimeType: mimeType,
      );
      return Response.ok(jsonEncode({'text': text}), headers: jsonHeaders);
    }
    if (method == 'POST' && path == 'api/chat/speak') {
      final payload = await readJsonObject(request, maxBytes: 8 * 1024);
      final requestId = payload['requestId'];
      final turnIndex = payload['turnIndex'];
      final sessionId = payload['sessionId'];
      if (requestId is! String ||
          requestId.trim().isEmpty ||
          turnIndex is! int ||
          turnIndex < 0 ||
          (sessionId != null && sessionId is! String)) {
        throw invalidRequest('朗读请求格式不正确。');
      }
      // Host 是文字真相源：浏览器只传定位符，朗读文字从已落盘的
      // 栖语 turn 取（ADR 0002：只有完整交付并落盘的话才读）。
      // turnIndex 是该 requestId 的第 N 个栖语 turn：轮内召回的
      // bubble 2 落为同一 requestId 的第二个栖语 turn，一次交付 =
      // 一段朗读。
      final session = await memoryRepository.openSession(
        sessionId: sessionId as String?,
      );
      var matched = 0;
      RawSessionTurn? turn;
      for (final candidate in session.turns) {
        if (candidate.requestId == requestId &&
            candidate.speaker == Speaker.qiyu) {
          if (matched == turnIndex) {
            turn = candidate;
            break;
          }
          matched += 1;
        }
      }
      if (turn == null) {
        throw const TtsServiceException(
          code: 'tts_turn_not_found',
          message: '找不到这句话，请刷新后重试。',
          retryable: false,
        );
      }
      final audio = await ttsSettingsService.synthesize(turn.text);
      return Response.ok(audio, headers: _audioHeaders);
    }
    return null;
  }
}
