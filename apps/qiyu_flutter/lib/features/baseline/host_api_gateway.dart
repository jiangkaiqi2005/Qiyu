import 'dart:convert';

import 'package:http/http.dart' as http;

/// 面向用户的人话错误：本机程序网关异常都实现该接口，视图层统一
/// 透出 [message]，不再按异常类型各写一套 switch。
abstract interface class UserFacingException {
  String get message;
}

/// 与本机 Host API 通信的网关底座：`/api/bootstrap` 换取 CSRF 令牌、
/// 变更请求头与 JSON 成功/失败解码共用同一套口径（聊天、模型设置与
/// 语音设置三个 HTTP 网关同形，收拢在此，不逐个复制）。
abstract base class HostApiGateway {
  HostApiGateway({http.Client? client, Uri? baseUri})
    : _client = client ?? http.Client(),
      _baseUri = baseUri ?? Uri.base;

  final http.Client _client;
  final Uri _baseUri;
  String? _csrfToken;

  /// 底座持有的 HTTP 客户端；子类请求统一经由此发出。
  http.Client get httpClient => _client;

  /// 构造本网关对外的错误异常；子类决定异常类型。
  Object errorFor(String message);

  /// 服务不可用等场景的默认提示文案。
  String get unavailableMessage;

  Uri resolve(String path) => _baseUri.resolve(path);

  /// GET /api/bootstrap 换取 CSRF 令牌；会话内只换一次。
  Future<void> ensureBootstrap() async {
    if (_csrfToken != null) {
      return;
    }
    final response = await httpClient.get(resolve('/api/bootstrap'));
    final json = decodeSuccess(response);
    _csrfToken = json['csrfToken']! as String;
  }

  /// JSON 变更请求（PUT/POST/DELETE）的头：bootstrap + CSRF。
  Future<Map<String, String>> modifyingHeaders() async {
    await ensureBootstrap();
    return {'content-type': 'application/json', 'x-qiyu-csrf': _csrfToken!};
  }

  /// 只带 CSRF 的头（content-type 由调用方指定，如音频上送）。
  Future<Map<String, String>> csrfHeaders() async {
    await ensureBootstrap();
    return {'x-qiyu-csrf': _csrfToken!};
  }

  /// 解码 2xx JSON 成功响应；非 2xx 抛出携带服务端 message 的网关
  /// 异常，无法解析的成功体视为「本机程序返回了无法读取的内容」。
  Map<String, Object?> decodeSuccess(http.Response response) {
    Map<String, Object?>? json;
    try {
      json = jsonDecode(response.body) as Map<String, Object?>;
    } on Object {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw errorFor('本机程序返回了无法读取的内容。');
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw errorFor(json?['message'] as String? ?? unavailableMessage);
    }
    return json!;
  }

  /// JSON GET 的终态收发：显式引导 → 请求 → 成功解码 → 终态构造。
  /// 错误分流仍由 [decodeSuccess] 抛出的 [errorFor] 承担，本方法只收
  /// HTTP 样板，不改错误语义。各设置网关的读取方法共用。
  Future<T> getJson<T>(
    String path,
    T Function(Map<String, Object?> json) decode,
  ) async {
    await ensureBootstrap();
    final response = await httpClient.get(resolve(path));
    return decode(decodeSuccess(response));
  }

  /// JSON PUT 的终态收发：修改头（内含引导与 CSRF）→ 请求 → 解码构造。
  Future<T> putJson<T>(
    String path,
    Object? body,
    T Function(Map<String, Object?> json) decode,
  ) async {
    final response = await httpClient.put(
      resolve(path),
      headers: await modifyingHeaders(),
      body: jsonEncode(body),
    );
    return decode(decodeSuccess(response));
  }

  /// JSON POST 的终态收发：修改头（内含引导与 CSRF）→ 请求 → 解码构造。
  Future<T> postJson<T>(
    String path,
    Object? body,
    T Function(Map<String, Object?> json) decode,
  ) async {
    final response = await httpClient.post(
      resolve(path),
      headers: await modifyingHeaders(),
      body: jsonEncode(body),
    );
    return decode(decodeSuccess(response));
  }

  /// JSON DELETE 的终态收发：修改头（内含引导与 CSRF）→ 请求 → 解码构造。
  Future<T> deleteJson<T>(
    String path,
    T Function(Map<String, Object?> json) decode,
  ) async {
    final response = await httpClient.delete(
      resolve(path),
      headers: await modifyingHeaders(),
    );
    return decode(decodeSuccess(response));
  }
}

/// 网关异常透出其人话 message，其余错误按调用方默认文案兜底。
String readableError(Object error, {required String fallback}) =>
    switch (error) {
      UserFacingException() => error.message,
      _ => fallback,
    };
