import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'local_chat_service.dart';
import 'markdown_memory_repository.dart';

/// API 层共享的传输口径：统一响应头、请求体读取与对外错误形状。
///
/// 领域路由模块（聊天、记忆、设置、备份、语音、引导）各自持有本领域
/// 的路径匹配、payload 解析、序列化与错误翻译；这份口径只承载它们
/// 共同的 HTTP 机械规则，不含任何领域分支。

const jsonHeaders = {
  HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
  HttpHeaders.cacheControlHeader: 'no-store',
};

const noStoreHeaders = {HttpHeaders.cacheControlHeader: 'no-store'};

/// 领域路由模块的统一形状：返回 null 表示本领域不处理该请求，交回
/// 总控继续分发；返回非 null 即为该请求在本领域的最终响应。
abstract interface class ApiRoutes {
  Future<Response?> handle(Request request);
}

/// API 请求参数或请求体不合法的统一异常（HTTP 400 + invalid_request）。
LocalChatException invalidRequest(String message) => LocalChatException(
  code: 'invalid_request',
  message: message,
  retryable: false,
);

/// 读取 JSON 对象请求体：Content-Length 与累计字节数双重校验覆盖
/// chunked 请求；超限、非 JSON、非对象体一律按 FormatException 拒绝，
/// 由各领域模块翻译为统一的 invalid_request 对外错误。
Future<Map<String, Object?>> readJsonObject(
  Request request, {
  required int maxBytes,
}) async {
  final contentLength = request.contentLength;
  if (contentLength != null && contentLength > maxBytes) {
    throw const FormatException('request body is too large');
  }
  // 累计计数以覆盖无 Content-Length 的 chunked 请求体。
  final buffer = BytesBuilder(copy: false);
  var totalBytes = 0;
  await for (final chunk in request.read()) {
    totalBytes += chunk.length;
    if (totalBytes > maxBytes) {
      throw const FormatException('request body is too large');
    }
    buffer.add(chunk);
  }
  final decoded = jsonDecode(utf8.decode(buffer.takeBytes()));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('request body must be an object');
  }
  return decoded;
}

/// 请求体不可读（超限/非 JSON/非对象体）的统一对外形状。
Response invalidRequestBodyResponse() => jsonError(
  HttpStatus.badRequest,
  code: 'invalid_request',
  message: '聊天请求格式不正确。',
  retryable: false,
);

/// LocalChatException 的对外翻译：invalid_request 与请求本身的缺陷按
/// 客户端错误，request_id_conflict 按冲突，其余按服务端错误。
Response localChatErrorResponse(LocalChatException error) {
  final status = switch (error.code) {
    'invalid_request' => HttpStatus.badRequest,
    'request_id_conflict' => HttpStatus.conflict,
    _ => HttpStatus.internalServerError,
  };
  return jsonError(
    status,
    code: error.code,
    message: error.message,
    retryable: error.retryable,
  );
}

/// Markdown 记忆仓储异常的对外翻译：会话不存在按 404，其余按服务端错误。
Response memoryRepositoryErrorResponse(MemoryRepositoryException error) {
  final status = error.code == 'session_not_found'
      ? HttpStatus.notFound
      : HttpStatus.internalServerError;
  return jsonError(
    status,
    code: error.code,
    message: error.message,
    retryable: error.retryable,
  );
}

Response plainError(int statusCode, String message) {
  return Response(
    statusCode,
    body: redactDiagnosticText(message),
    headers: {
      HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
      HttpHeaders.cacheControlHeader: 'no-store',
    },
  );
}

Response jsonError(
  int statusCode, {
  required String code,
  required String message,
  required bool retryable,
}) {
  return Response(
    statusCode,
    body: jsonEncode({
      'code': code,
      'message': redactDiagnosticText(message),
      'retryable': retryable,
    }),
    headers: jsonHeaders,
  );
}
