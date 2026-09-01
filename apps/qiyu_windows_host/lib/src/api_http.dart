import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'local_chat_service.dart';
import 'local_data_service.dart';
import 'markdown_memory_repository.dart';
import 'provider_config.dart';
import 'secret_store.dart';

/// API 层共享的传输口径：统一响应头、限长请求体读取与对外错误形状。
///
/// 领域路由模块（聊天、记忆、设置、备份、语音、引导）各自持有本领域
/// 的路径匹配、payload 解析、序列化与本领域差异的错误翻译；这份口径
/// 承载它们共同的 HTTP 机械规则，以及各领域完全一致的跨领域异常翻译
/// （请求体不可读、请求参数不合法、聊天服务异常、Provider 配置与凭据
/// 库故障、本地数据故障、记忆仓储异常），不含任何领域分支。

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
///
/// 共享层自持的 400 载体：各领域路由用它抛出参数与请求体缺陷，不借用
/// 聊天服务的异常类型；聊天服务自身的 LocalChatException 语义不受影响。
final class ApiRequestException implements Exception {
  const ApiRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// API 请求参数或请求体不合法的统一异常（HTTP 400 + invalid_request）。
ApiRequestException invalidRequest(String message) => ApiRequestException(message);

/// 读取限长二进制请求体：Content-Length 与累计字节数双重校验覆盖
/// chunked 请求；超限抛 [onOversize] 返回的异常，由领域翻译为对外错误。
Future<Uint8List> readLimitedBytes(
  Request request, {
  required int maxBytes,
  required Exception Function() onOversize,
}) async {
  final contentLength = request.contentLength;
  if (contentLength != null && contentLength > maxBytes) {
    throw onOversize();
  }
  // 累计计数以覆盖无 Content-Length 的 chunked 请求体。
  final buffer = BytesBuilder(copy: false);
  var totalBytes = 0;
  await for (final chunk in request.read()) {
    totalBytes += chunk.length;
    if (totalBytes > maxBytes) {
      throw onOversize();
    }
    buffer.add(chunk);
  }
  return buffer.takeBytes();
}

/// 读取 JSON 对象请求体：Content-Length 与累计字节数双重校验覆盖
/// chunked 请求；超限、非 JSON、非对象体一律按 FormatException 拒绝，
/// 由各领域模块翻译为统一的 invalid_request 对外错误。
Future<Map<String, Object?>> readJsonObject(
  Request request, {
  required int maxBytes,
}) async {
  final bytes = await readLimitedBytes(
    request,
    maxBytes: maxBytes,
    onOversize: () => const FormatException('request body is too large'),
  );
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('request body must be an object');
  }
  return decoded;
}

/// 请求体不可读（超限/非 JSON/非对象体）的统一对外形状。文案沿用基线
/// 总控对全部端点共用的「聊天请求格式不正确。」（chat 域逐字不变），
/// 消息参数留作领域差异化的口子，当前基线下各领域一致。
Response invalidRequestBodyResponse({String message = '聊天请求格式不正确。'}) =>
    jsonError(
      HttpStatus.badRequest,
      code: 'invalid_request',
      message: message,
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

/// 领域路由共享的错误翻译前导：请求体不可读、请求参数不合法、聊天
/// 服务异常，以及 Provider 配置、凭据库、本地数据、记忆仓储这些在各
/// 领域口径完全一致的异常，统一按基线总控的对外形状在这里翻译。返回
/// null 表示不属于共享口径，由领域模块按本领域规则处理或继续外抛。
Response? sharedApiErrorResponse(Object error) {
  if (error is FormatException) {
    return invalidRequestBodyResponse();
  }
  if (error is ApiRequestException) {
    return jsonError(
      HttpStatus.badRequest,
      code: 'invalid_request',
      message: error.message,
      retryable: false,
    );
  }
  if (error is LocalChatException) {
    return localChatErrorResponse(error);
  }
  if (error is ProviderConfigException) {
    return jsonError(
      HttpStatus.badRequest,
      code: 'invalid_provider_config',
      message: error.message,
      retryable: false,
    );
  }
  if (error is SecretStoreException) {
    return jsonError(
      HttpStatus.internalServerError,
      code: 'credential_store_error',
      message: error.message,
      retryable: true,
    );
  }
  if (error is LocalDataException) {
    return jsonError(
      HttpStatus.internalServerError,
      code: 'local_data_error',
      message: error.message,
      retryable: true,
    );
  }
  if (error is MemoryRepositoryException) {
    return memoryRepositoryErrorResponse(error);
  }
  return null;
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
