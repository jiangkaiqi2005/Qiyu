/// Host 客户端测试共享的传输前置：客户端先向 `/api/bootstrap` 换取 CSRF
/// 令牌，变更请求再以 `x-qiyu-csrf` 头携带（见
/// `lib/features/baseline/host_api_gateway.dart`）。本文件只收拢这一件事
/// ——bootstrap 交换与 CSRF 头的 fixture 和断言读法；各客户端的领域响应
/// 仍由各测试通过 [hostTransportClient] 的 respond 参数自行路由，领域断言
/// 留在各测试里。
///
/// 如果某个用例的 bootstrap 行为本身就是被测对象（例如 bootstrap 失败
/// 路径），保留内联 mock，不用这里的收拢。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// bootstrap fixture 里交换的 CSRF 令牌；所有变更请求断言都读它。
const String hostTestCsrfToken = 'csrf-1';

/// 默认的 bootstrap 响应 fixture。
const Map<String, Object?> hostTestBootstrapBody = {
  'csrfToken': hostTestCsrfToken,
};

/// 与 Host 返回一致的 JSON 响应：utf-8 字节加 application/json 头。
http.Response hostJsonResponse(Object body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

/// 造一个自带传输前置的 MockClient：`/api/bootstrap` 用共享 fixture 应答，
/// 其余路径留给 [respond] 做各测试自己的领域路由。
///
/// [requests] 传入时记录实际发出的请求，供用例断言方法与请求体；
/// [bootstrapBody] 在 bootstrap 响应需要额外字段时整体替换（例如记忆动作
/// 随令牌一并返回会话状态）。
MockClient hostTransportClient(
  http.Response Function(http.Request request) respond, {
  List<http.Request>? requests,
  Map<String, Object?> bootstrapBody = hostTestBootstrapBody,
}) {
  return MockClient((request) async {
    requests?.add(request);
    if (request.url.path == '/api/bootstrap') {
      return hostJsonResponse(bootstrapBody, 200);
    }
    return respond(request);
  });
}

/// 断言变更请求带上了 bootstrap 换来的 CSRF 头。
void expectCsrfHeader(http.Request request) {
  expect(request.headers['x-qiyu-csrf'], hostTestCsrfToken);
}

/// 断言只读请求没有携带 CSRF 头（GET 不触发 bootstrap）。
void expectNoCsrfHeader(http.Request request) {
  expect(request.headers.containsKey('x-qiyu-csrf'), isFalse);
}

/// 断言 bootstrap 只交换了一次：同一网关实例内令牌复用，不重复换取。
void expectBootstrapRequestedOnce(List<http.Request> requests) {
  expect(
    requests.where((request) => request.url.path == '/api/bootstrap'),
    hasLength(1),
  );
}
