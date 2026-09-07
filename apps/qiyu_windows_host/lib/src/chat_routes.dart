import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'api_http.dart';
import 'local_chat_service.dart';
import 'markdown_memory_repository.dart';

/// 聊天领域路由：交付（NDJSON 流）、取消、会话恢复、历史浏览与删除。
///
/// 本模块持有聊天领域的路径匹配、payload 解析、流式响应序列化与错误
/// 翻译；删除本模块，这些职责会整体摊回路由总控。
final class ChatRoutes implements ApiRoutes {
  ChatRoutes({required this.chatService});

  final LocalChatService chatService;

  /// 流式交付响应头：NDJSON 逐行事件，禁缓存、禁代理缓冲。
  static const _streamHeaders = {
    HttpHeaders.contentTypeHeader: 'application/x-ndjson; charset=utf-8',
    HttpHeaders.cacheControlHeader: 'no-store',
    'x-accel-buffering': 'no',
  };

  /// URL 路径里会话标识的形态上限：不透明 ID 只认这套字符与长度。
  static final RegExp _sessionIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  @override
  Future<Response?> handle(Request request) async {
    // 共享翻译前导覆盖本领域全部异常口径：请求体不可读、invalid_request
    // 与聊天服务真实抛出的 LocalChatException（冲突、模型回复缺陷等）、
    // 记忆仓储故障。
    return runApiRoute(() => _route(request));
  }

  Future<Response?> _route(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/chat/session') {
      final snapshot = await chatService.restore(
        sessionId: request.url.queryParameters['sessionId'],
      );
      return Response.ok(
        jsonEncode(snapshot.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'GET' && path == 'api/history') {
      final listing = await chatService.history();
      return Response.ok(
        jsonEncode(_historyJson(listing)),
        headers: jsonHeaders,
      );
    }
    if (method == 'DELETE' && path.startsWith('api/history/sessions/')) {
      final sessionId = path.substring('api/history/sessions/'.length);
      if (!_sessionIdPattern.hasMatch(sessionId)) {
        throw invalidRequest('会话标识格式不正确。');
      }
      await chatService.deleteSession(sessionId);
      return Response.ok(
        jsonEncode({'deleted': true}),
        headers: jsonHeaders,
      );
    }
    if (method == 'POST' && path == 'api/chat/cancel') {
      final payload = await readJsonObject(request, maxBytes: 4 * 1024);
      final requestId = payload['requestId'];
      if (requestId is! String || requestId.trim().isEmpty) {
        throw invalidRequest('聊天请求格式不正确。');
      }
      return Response.ok(
        jsonEncode({'cancelled': chatService.cancel(requestId)}),
        headers: jsonHeaders,
      );
    }
    if (method == 'POST' && path == 'api/chat') {
      final payload = await readJsonObject(request, maxBytes: 64 * 1024);
      final requestId = payload['requestId'];
      final text = payload['text'];
      final sessionId = payload['sessionId'];
      if (requestId is! String ||
          text is! String ||
          (sessionId != null && sessionId is! String) ||
          requestId.trim().isEmpty ||
          text.trim().isEmpty) {
        throw invalidRequest('聊天请求格式不正确。');
      }
      return Response.ok(
        chatService
            .deliver(
              requestId: requestId,
              text: text,
              sessionId: sessionId as String?,
            )
            .map((event) => utf8.encode('${jsonEncode(event.toJson())}\n')),
        headers: _streamHeaders,
      );
    }
    return null;
  }
}

Map<String, Object?> _historyJson(HistoryListing listing) {
  RawSession? latest;
  for (final session in listing.sessions) {
    if (latest == null || session.updatedAt.isAfter(latest.updatedAt)) {
      latest = session;
    }
  }
  final days = <Map<String, Object?>>[];
  for (final session in listing.sessions) {
    if (days.isEmpty || days.last['date'] != session.date) {
      days.add({'date': session.date, 'sessions': <Map<String, Object?>>[]});
    }
    final daySessions = days.last['sessions']! as List<Map<String, Object?>>;
    daySessions.add(_sessionSummaryJson(session));
  }
  return {
    'latestSessionId': ?latest?.id,
    'days': days,
    'unavailable': [
      for (final entry in listing.unavailable)
        {'name': entry.name, 'message': entry.message},
    ],
  };
}

Map<String, Object?> _sessionSummaryJson(RawSession session) {
  final startedAt = session.turns.isEmpty
      ? session.createdAt
      : session.turns.first.at;
  return {
    'sessionId': session.id,
    'segment': session.segment,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'updatedAt': session.updatedAt.toUtc().toIso8601String(),
    'turnCount': session.turns.length,
    'preview': _historyPreview(session),
  };
}

String _historyPreview(RawSession session) {
  if (session.turns.isEmpty) {
    return '';
  }
  final lines = session.turns.first.text.replaceAll('\r\n', '\n').split('\n');
  final firstLine = lines
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .firstOrNull;
  final runes = (firstLine ?? '').runes.toList(growable: false);
  if (runes.length <= 60) {
    return String.fromCharCodes(runes);
  }
  return '${String.fromCharCodes(runes.sublist(0, 60))}…';
}
