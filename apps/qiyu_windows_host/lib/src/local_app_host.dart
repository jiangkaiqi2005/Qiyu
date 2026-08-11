import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

import 'browser_launcher.dart';
import 'secure_token.dart';

const _sessionCookieName = 'qiyu_session';
const _csrfHeaderName = 'x-qiyu-csrf';

final class LocalAppHost {
  LocalAppHost._(this._server, this._requestHandler);

  final HttpServer _server;
  final _LocalAppRequestHandler _requestHandler;

  InternetAddress get address => _server.address;

  int get port => _server.port;

  Uri get origin => Uri(scheme: 'http', host: address.address, port: port);

  Uri get launchUri => origin.replace(
    path: '/_session/start',
    queryParameters: {'token': _requestHandler.startupToken},
  );

  static Future<LocalAppHost> start({
    required String webRoot,
    String? activationToken,
    Future<BrowserLaunchResult> Function()? onActivate,
  }) async {
    final indexFile = File('$webRoot${Platform.pathSeparator}index.html');
    if (!indexFile.existsSync()) {
      throw ArgumentError.value(webRoot, 'webRoot', 'index.html not found');
    }

    if ((activationToken == null) != (onActivate == null)) {
      throw ArgumentError(
        'activationToken and onActivate must either both be set or both be null',
      );
    }
    final requestHandler = _LocalAppRequestHandler(
      webRoot,
      activationToken: activationToken,
      onActivate: onActivate,
    );
    final handler = const Pipeline()
        .addMiddleware(_securityHeaders())
        .addHandler(requestHandler.call);
    final server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    requestHandler.attach(
      Uri(scheme: 'http', host: server.address.address, port: server.port),
    );
    return LocalAppHost._(server, requestHandler);
  }

  Future<void> close() => _server.close(force: true);
}

final class _LocalAppRequestHandler {
  _LocalAppRequestHandler(
    String webRoot, {
    required this.activationToken,
    required this.onActivate,
  }) : startupToken = generateSecureToken(),
       _sessionToken = generateSecureToken(),
       _csrfToken = generateSecureToken(),
       _staticHandler = createStaticHandler(
         webRoot,
         defaultDocument: 'index.html',
         listDirectories: false,
       );

  final String startupToken;
  final String? activationToken;
  final Future<BrowserLaunchResult> Function()? onActivate;
  final String _sessionToken;
  final String _csrfToken;
  final Handler _staticHandler;
  Uri? _origin;

  void attach(Uri origin) {
    if (_origin != null) {
      throw StateError('Local app request handler is already attached');
    }
    _origin = origin;
  }

  FutureOr<Response> call(Request request) {
    final origin = _origin;
    if (origin == null) {
      return _plainError(HttpStatus.serviceUnavailable, 'Host is starting');
    }

    if (!_hasExpectedHost(request, origin)) {
      return _plainError(HttpStatus.forbidden, 'Unexpected Host');
    }

    if (request.url.path == '_session/start') {
      return _startSession(request);
    }

    if (request.url.path == '_instance/activate') {
      return _activateInstance(request, origin);
    }

    if (request.url.path.startsWith('api/')) {
      return _handleApi(request, origin);
    }

    return _staticHandler(request);
  }

  Response _startSession(Request request) {
    if (request.method != 'GET' ||
        request.url.queryParameters['token'] != startupToken) {
      return _plainError(HttpStatus.unauthorized, 'Invalid startup credential');
    }

    return Response(
      HttpStatus.seeOther,
      headers: {
        HttpHeaders.locationHeader: '/',
        HttpHeaders.setCookieHeader:
            '$_sessionCookieName=$_sessionToken; Path=/; HttpOnly; SameSite=Strict',
        HttpHeaders.cacheControlHeader: 'no-store',
      },
    );
  }

  Future<Response> _activateInstance(Request request, Uri origin) async {
    final expectedToken = activationToken;
    final activate = onActivate;
    if (request.method != 'POST' ||
        expectedToken == null ||
        activate == null ||
        request.headers['x-qiyu-activation'] != expectedToken) {
      return _plainError(HttpStatus.forbidden, 'Invalid activation request');
    }
    final result = await activate();
    if (result.succeeded) {
      return Response(HttpStatus.noContent, headers: _noStoreHeaders);
    }
    final displayUrl = origin.replace(
      path: '/_session/start',
      queryParameters: {'token': startupToken},
    );
    return Response(
      HttpStatus.serviceUnavailable,
      body: jsonEncode({'displayUrl': displayUrl.toString()}),
      headers: _jsonHeaders,
    );
  }

  Response _handleApi(Request request, Uri origin) {
    final modifying = request.method != 'GET' && request.method != 'HEAD';
    if (!_hasExpectedSource(request, origin, requireOrigin: modifying)) {
      return _plainError(HttpStatus.forbidden, 'Unexpected request source');
    }
    if (!_hasSession(request)) {
      return _plainError(HttpStatus.unauthorized, 'Invalid session');
    }
    if (modifying && request.headers[_csrfHeaderName] != _csrfToken) {
      return _plainError(HttpStatus.forbidden, 'Invalid CSRF token');
    }

    if (request.method == 'GET' && request.url.path == 'api/bootstrap') {
      return Response.ok(
        jsonEncode({
          'csrfToken': _csrfToken,
          'session': 'active',
          'host': origin.host,
          'port': origin.port,
        }),
        headers: _jsonHeaders,
      );
    }
    if (request.method == 'GET' && request.url.path == 'api/health') {
      return Response.ok(jsonEncode({'status': 'ok'}), headers: _jsonHeaders);
    }
    if (request.method == 'POST' && request.url.path == 'api/session/verify') {
      return Response(HttpStatus.noContent, headers: _noStoreHeaders);
    }
    return _plainError(HttpStatus.notFound, 'Not found');
  }

  bool _hasExpectedHost(Request request, Uri origin) {
    return request.headers[HttpHeaders.hostHeader] ==
        '${origin.host}:${origin.port}';
  }

  bool _hasExpectedSource(
    Request request,
    Uri origin, {
    required bool requireOrigin,
  }) {
    final sourceOrigin = request.headers['origin'];
    final referer = request.headers[HttpHeaders.refererHeader];
    if (requireOrigin && sourceOrigin == null) {
      return false;
    }
    if (sourceOrigin != null && !_sameOrigin(sourceOrigin, origin)) {
      return false;
    }
    if (referer != null && !_sameOrigin(referer, origin)) {
      return false;
    }
    return true;
  }

  bool _hasSession(Request request) {
    final cookieHeader = request.headers[HttpHeaders.cookieHeader];
    if (cookieHeader == null) {
      return false;
    }
    for (final part in cookieHeader.split(';')) {
      final segments = part.trim().split('=');
      if (segments.length >= 2 &&
          segments.first == _sessionCookieName &&
          segments.sublist(1).join('=') == _sessionToken) {
        return true;
      }
    }
    return false;
  }
}

const _jsonHeaders = {
  HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
  HttpHeaders.cacheControlHeader: 'no-store',
};

const _noStoreHeaders = {HttpHeaders.cacheControlHeader: 'no-store'};

Response _plainError(int statusCode, String message) {
  return Response(
    statusCode,
    body: message,
    headers: {
      HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
      HttpHeaders.cacheControlHeader: 'no-store',
    },
  );
}

bool _sameOrigin(String value, Uri expected) {
  final candidate = Uri.tryParse(value);
  if (candidate == null || !candidate.hasScheme || candidate.host.isEmpty) {
    return false;
  }
  return candidate.scheme == expected.scheme &&
      candidate.host == expected.host &&
      candidate.port == expected.port;
}

Middleware _securityHeaders() {
  return createMiddleware(
    responseHandler: (response) => response.change(
      headers: {
        'content-security-policy':
            "default-src 'self'; connect-src 'self'; img-src 'self' data:; "
            "font-src 'self'; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'wasm-unsafe-eval'; "
            "worker-src 'self' blob:",
        'referrer-policy': 'same-origin',
        'x-content-type-options': 'nosniff',
      },
    ),
  );
}
