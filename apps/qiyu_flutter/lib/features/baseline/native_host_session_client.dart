import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

import '../chat/omni_call_controller.dart' show OmniCallSocket, OmniCallSocketConnector;

/// 会话 Cookie 名：与 Host 的 `qiyu_session`（`local_app_host.dart` 的
/// `_sessionCookieName`）是双端约定，同 `x-qiyu-csrf` 在网关底座里以
/// 字面量表达的同款口径。
const _sessionCookieName = 'qiyu_session';

/// 启动凭据兑换会话失败：原生壳据此中止连接（文案经各域网关的兜底
/// 机制透出，不携带内部诊断细节）。
final class NativeHostException implements Exception {
  const NativeHostException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 原生壳（Android）连接本机 Host 的会话接管 client：接管浏览器在
/// web 下免费提供的两件事——
///
/// 1. **会话 Cookie**：web 下浏览器从 `/_session/start` 的 Set-Cookie
///    接住 `qiyu_session` 并自动回传；原生 http 客户端没有 Cookie
///    jar，本 client 在首个请求前用一次性启动凭据兑换会话（引导请求
///    不跟随 303 重定向，直接从响应头接住），此后每个请求回传
///    `Cookie` 头。
/// 2. **同源 Origin**：web 下浏览器对修改请求自动带同源 Origin；本
///    client 对修改请求显式带 [origin]。修改请求的口径与 Host 校验
///    逐字对齐（`local_app_host.dart` 的 `_handleApi`：非 GET 且非
///    HEAD 即修改请求）。
///
/// CSRF 不在本层接管：[HostApiGateway] 底座早已从 `/api/bootstrap`
/// 换取 CSRF 令牌并随变更请求携带（`x-qiyu-csrf`），web 与原生共用
/// 同一逻辑。
///
/// 接缝位置：原生壳装配时把本 client 作为**共享单例**注入各域网关
/// 既有的 `client` 参数，并把同一实例的 [baseUri] 传给网关的
/// `baseUri` 参数——领域 client 与网关底座零感知；web 不注入本
/// client，一切走浏览器默认行为，缺省路径与改造前完全一致。
///
/// 引导只发生一次且失败不重试：Host 在兑换成功后立即轮换启动凭据，
/// 失败后重试必然 401（凭据可能已被消耗）。Host 重启后会话随进程
/// 失效，壳需以新凭据重建本 client；本 client 不做 401 自动重连。
///
/// [baseUri] 必须是显式端口的本机地址（Host `origin` 的形状，
/// 如 `http://127.0.0.1:43210`）；未显式注入地址时应使用 web 缺省
/// 路径而不是本 client。
final class NativeHostSessionClient extends http.BaseClient {
  NativeHostSessionClient({
    required this.baseUri,
    required String startupToken,
    http.Client? inner,
  }) : // named 参数不能是私有标识；与 HostStatusMonitor 同款先例。
       // ignore: prefer_initializing_formals
       _startupToken = startupToken,
       _inner = inner ?? http.Client(),
       origin = Uri(
         scheme: baseUri.scheme,
         host: baseUri.host,
         port: baseUri.port,
       ).toString();

  /// 本机 Host 的显式基址：原生壳装配时同时传给本 client（引导与
  /// Origin 派生）与各域网关（业务路径 resolve），同一实例的 getter
  /// 保证两处不会错位。
  final Uri baseUri;

  /// 与 Host 同源判定一致的同源 Origin 值（`scheme://host:port`，
  /// 无路径无尾斜杠，与浏览器 Origin 头同形状）。
  final String origin;

  final http.Client _inner;
  final String _startupToken;
  Future<void>? _session;
  String? _cookie;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await _ensureSession();
    // 会话 Cookie 与同源 Origin 都是 [BaseRequest.headers] 上的普通头，
    // 对全部请求类型统一补头：Request、MultipartRequest、StreamedRequest
    // 一视同仁——按类型挑拣会让某个子类静默漏头，被 Host 401/403 拒。
    request.headers[HttpHeaders.cookieHeader] = _cookie!;
    // 修改请求口径与 Host 的 _handleApi 逐字对齐：非 GET 且非 HEAD
    // 才要求同源 Origin；只读请求不带（浏览器对同源 GET 同样不带）。
    if (request.method != 'GET' && request.method != 'HEAD') {
      // dart:io 的 HttpHeaders 没有 origin 常量，与 Host 侧
      // `_hasExpectedSource` 读取的请求头名逐字一致。
      request.headers['origin'] = origin;
    }
    return _inner.send(request);
  }

  /// 兑换会话（引导）：`GET /_session/start?token=启动凭据`，不跟随
  /// 303，从 Set-Cookie 接住 `qiyu_session` 值（`Path=/; HttpOnly;
  /// SameSite=Strict` 由 Host 发出）。并发请求共享同一次引导。
  Future<void> _ensureSession() => _session ??= _exchangeStartupCredential();

  /// 等待会话建立并返回会话 Cookie（`qiyu_session=…` 整值）：WebSocket
  /// 升级请求（`GET api/omni/call`）同样过 Host 会话前置，而原生侧的
  /// WS 连接器靠它补 `Cookie` 头。引导失败会照常抛出。
  Future<String> sessionCookie() async {
    await _ensureSession();
    return _cookie!;
  }

  /// Omni 通话 WebSocket 连接器（T05）：握手前等待会话建立，把会话
  /// Cookie 放进升级请求头（dart:io 的 WebSocket 没有浏览器的 Cookie
  /// 罐）。web 构建不经过本类（浏览器同源升级自带 Cookie），缺省连接
  /// 器零变化。
  OmniCallSocketConnector get omniCallSocketConnector =>
      (uri) => _NativeHostOmniCallSocket(uri, this);

  Future<void> _exchangeStartupCredential() async {
    final request = http.Request(
      'GET',
      baseUri
          .resolve('/_session/start')
          .replace(queryParameters: {'token': _startupToken}),
    )..followRedirects = false;
    final response = await http.Response.fromStream(await _inner.send(request));
    final setCookie = response.headers[HttpHeaders.setCookieHeader];
    if (response.statusCode != HttpStatus.seeOther ||
        setCookie == null ||
        !setCookie.startsWith('$_sessionCookieName=')) {
      throw const NativeHostException('本机服务会话建立失败。');
    }
    _cookie = setCookie.split(';').first.trim();
  }

  @override
  void close() => _inner.close();
}

/// 通话 WebSocket 的会话接管实现：`ready` 先等会话建立（共享同一次引导）
/// 再发起带 `Cookie` 头的 WS 升级；未就绪前不创建底层通道，`close` 在
/// 任何阶段都安全（连接失败的中途收尾路径依赖这一点）。
final class _NativeHostOmniCallSocket implements OmniCallSocket {
  _NativeHostOmniCallSocket(this._uri, this._session);

  final Uri _uri;
  final NativeHostSessionClient _session;
  IOWebSocketChannel? _channel;

  @override
  Future<void> get ready async {
    final cookie = await _session.sessionCookie();
    final channel = IOWebSocketChannel.connect(
      _uri,
      headers: <String, dynamic>{HttpHeaders.cookieHeader: cookie},
    );
    _channel = channel;
    await channel.ready;
  }

  @override
  Stream<String> get stream =>
      (_channel?.stream ?? const Stream<Object?>.empty())
          .where((message) => message is String)
          .cast<String>();

  @override
  void send(String frame) {
    _channel?.sink.add(frame);
  }

  @override
  Future<void> close() => _channel?.sink.close() ?? Future<void>.value();
}
