import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:path/path.dart' as path;

import 'browser_launcher.dart';
import 'local_chat_service.dart';
import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'provider_config.dart';
import 'provider_settings_service.dart';
import 'secure_token.dart';
import 'secret_store.dart';

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
    required String memoryDirectory,
    required String productSoul,
    String? activationToken,
    Future<BrowserLaunchResult> Function()? onActivate,
    ProviderSettingsService? providerSettingsService,
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
    final modelPromptBuilder = ModelPromptBuilder(productSoul);
    final effectiveProviderSettings =
        providerSettingsService ??
        ProviderSettingsService(
          JsonProviderConfigRepository(
            filePath: path.join(
              Directory(memoryDirectory).parent.path,
              'provider.json',
            ),
          ),
          const WindowsCredentialSecretStore(),
          const ProviderModelGateway(DartIoProviderHttpClient()),
          modelPromptBuilder,
        );
    final chatService = LocalChatService(
      MarkdownMemoryRepository(memoryDirectory: memoryDirectory),
      providerChatClient: effectiveProviderSettings,
      modelPromptBuilder: modelPromptBuilder,
    );
    await chatService.initialize();
    final requestHandler = _LocalAppRequestHandler(
      webRoot,
      chatService: chatService,
      providerSettingsService: effectiveProviderSettings,
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
    required this.chatService,
    required this.providerSettingsService,
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
  final LocalChatService chatService;
  final ProviderSettingsService providerSettingsService;
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

  Future<Response> _handleApi(Request request, Uri origin) async {
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
    try {
      if (request.method == 'GET' && request.url.path == 'api/provider') {
        final settings = await providerSettingsService.read();
        return Response.ok(
          jsonEncode(settings.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'PUT' && request.url.path == 'api/provider') {
        final payload = await _readJsonObject(request, maxBytes: 32 * 1024);
        final config = _providerConfigFromPayload(payload);
        final apiKey = payload['apiKey'];
        if (apiKey != null && apiKey is! String) {
          throw const ProviderConfigException('API Key 格式不正确。');
        }
        final settings = await providerSettingsService.save(
          config: config,
          apiKey: apiKey as String?,
        );
        return Response.ok(
          jsonEncode(settings.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'POST' && request.url.path == 'api/provider/test') {
        final payload = await _readJsonObject(request, maxBytes: 32 * 1024);
        final apiKey = payload['apiKey'];
        if (apiKey != null && apiKey is! String) {
          throw const ProviderConfigException('API Key 格式不正确。');
        }
        final config = payload.isEmpty
            ? (await providerSettingsService.read()).config
            : _providerConfigFromPayload(payload);
        if (config == null) {
          const result = ProviderTestResult(
            status: ProviderTestStatus.notConfigured,
            message: '还没有保存模型配置。',
          );
          return Response.ok(
            jsonEncode(result.toJson()),
            headers: _jsonHeaders,
          );
        }
        final result = await providerSettingsService.test(
          config: config,
          apiKey: apiKey as String?,
        );
        return Response.ok(jsonEncode(result.toJson()), headers: _jsonHeaders);
      }
      if (request.method == 'DELETE' &&
          request.url.path == 'api/provider/key') {
        final settings = await providerSettingsService.forgetApiKey();
        return Response.ok(
          jsonEncode(settings.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'GET' && request.url.path == 'api/chat/session') {
        final snapshot = await chatService.restore(
          sessionId: request.url.queryParameters['sessionId'],
        );
        return Response.ok(
          jsonEncode(snapshot.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'GET' && request.url.path == 'api/history') {
        final listing = await chatService.history();
        return Response.ok(
          jsonEncode(_historyJson(listing)),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'DELETE' &&
          request.url.path.startsWith('api/history/sessions/')) {
        final sessionId = request.url.path.substring(
          'api/history/sessions/'.length,
        );
        if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(sessionId)) {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '会话标识格式不正确。',
            retryable: false,
          );
        }
        await chatService.deleteSession(sessionId);
        return Response.ok(
          jsonEncode({'deleted': true}),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'POST' && request.url.path == 'api/chat/cancel') {
        final payload = await _readJsonObject(request, maxBytes: 4 * 1024);
        final requestId = payload['requestId'];
        if (requestId is! String || requestId.trim().isEmpty) {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '聊天请求格式不正确。',
            retryable: false,
          );
        }
        return Response.ok(
          jsonEncode({'cancelled': chatService.cancel(requestId)}),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'POST' && request.url.path == 'api/chat') {
        final contentLength = request.contentLength;
        if (contentLength != null && contentLength > 64 * 1024) {
          return _jsonError(
            HttpStatus.requestEntityTooLarge,
            code: 'invalid_request',
            message: '消息内容过长。',
            retryable: false,
          );
        }
        final body = await request.readAsString();
        final payload = jsonDecode(body) as Map<String, Object?>;
        final requestId = payload['requestId'];
        final text = payload['text'];
        final sessionId = payload['sessionId'];
        if (requestId is! String ||
            text is! String ||
            (sessionId != null && sessionId is! String) ||
            requestId.trim().isEmpty ||
            text.trim().isEmpty) {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '聊天请求格式不正确。',
            retryable: false,
          );
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
    } on FormatException {
      return _jsonError(
        HttpStatus.badRequest,
        code: 'invalid_request',
        message: '聊天请求格式不正确。',
        retryable: false,
      );
    } on LocalChatException catch (error) {
      final status = switch (error.code) {
        'invalid_request' => HttpStatus.badRequest,
        'request_id_conflict' => HttpStatus.conflict,
        _ => HttpStatus.internalServerError,
      };
      return _jsonError(
        status,
        code: error.code,
        message: error.message,
        retryable: error.retryable,
      );
    } on ProviderConfigException catch (error) {
      return _jsonError(
        HttpStatus.badRequest,
        code: 'invalid_provider_config',
        message: error.message,
        retryable: false,
      );
    } on SecretStoreException catch (error) {
      return _jsonError(
        HttpStatus.internalServerError,
        code: 'credential_store_error',
        message: error.message,
        retryable: true,
      );
    } on MemoryRepositoryException catch (error) {
      final status = error.code == 'session_not_found'
          ? HttpStatus.notFound
          : HttpStatus.internalServerError;
      return _jsonError(
        status,
        code: error.code,
        message: error.message,
        retryable: error.retryable,
      );
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

Future<Map<String, Object?>> _readJsonObject(
  Request request, {
  required int maxBytes,
}) async {
  final contentLength = request.contentLength;
  if (contentLength != null && contentLength > maxBytes) {
    throw const FormatException('request body is too large');
  }
  final decoded = jsonDecode(await request.readAsString());
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('request body must be an object');
  }
  return decoded;
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

ProviderConfig _providerConfigFromPayload(Map<String, Object?> payload) {
  final provider = payload['provider'];
  final baseUrl = payload['baseUrl'];
  final model = payload['model'];
  final temperature = payload['temperature'];
  final timeoutSeconds = payload['timeoutSeconds'];
  if (provider is! String ||
      baseUrl is! String ||
      model is! String ||
      temperature is! num ||
      timeoutSeconds is! int) {
    throw const ProviderConfigException('模型配置格式不正确。');
  }
  return ProviderConfig(
    kind: ProviderKind.fromWireName(provider),
    baseUrl: baseUrl,
    model: model,
    temperature: temperature.toDouble(),
    timeoutSeconds: timeoutSeconds,
  );
}

const _jsonHeaders = {
  HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
  HttpHeaders.cacheControlHeader: 'no-store',
};

const _streamHeaders = {
  HttpHeaders.contentTypeHeader: 'application/x-ndjson; charset=utf-8',
  HttpHeaders.cacheControlHeader: 'no-store',
  'x-accel-buffering': 'no',
};

const _noStoreHeaders = {HttpHeaders.cacheControlHeader: 'no-store'};

Response _plainError(int statusCode, String message) {
  return Response(
    statusCode,
    body: redactDiagnosticText(message),
    headers: {
      HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
      HttpHeaders.cacheControlHeader: 'no-store',
    },
  );
}

Response _jsonError(
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
    headers: _jsonHeaders,
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
